import {
  generateSixDigitOtp,
  hmacSha256Hex,
  isEmailInAllowlist,
  normalizeAndValidateEmail,
  timingSafeEqualStrings,
} from "./crypto.ts";
import { sendOtpEmail } from "./email.ts";
import {
  ensureVerifiedVolunteerUser,
  grantInviteVerifiedByUid,
  lookupFirebaseUserByEmail,
  mintFirebaseCustomToken,
  parseServiceAccount,
  verifyFirebaseIdToken,
  type VerifiedFirebaseToken,
} from "./firebaseAdmin.ts";
import {
  consumeOneTimeInviteByHash,
  createOneTimeInvites,
  getPublicAppUrl,
  listOneTimeInvites,
  revokeOneTimeInvite,
  saveInviteRecord,
  validateInviteCodeForJoin,
} from "./invites.ts";
import {
  checkEmailSendQuota,
  commitEmailSendQuota,
  enforceAndRecordAdminIpLimit,
  enforceAndRecordRequestIpLimit,
  enforceAndRecordVerifyIpLimit,
  parseRateLimitConfig,
} from "./rateLimit.ts";
import { verifyTurnstileToken } from "./turnstile.ts";
import type {
  ClaimInviteBody,
  CreateInviteBody,
  Env,
  RequestOtpBody,
  StoredInviteRecord,
  StoredOtpRecord,
  VerifyOtpBody,
} from "./types.ts";
import { HttpError } from "./types.ts";

export interface WorkerDeps {
  fetchImpl?: typeof fetch;
  now?: () => Date;
}

export function isOriginAllowed(origin: string, allowedList: string[]): boolean {
  if (allowedList.includes("*") || allowedList.includes(origin)) {
    return true;
  }
  for (const allowed of allowedList) {
    if (allowed.includes("*")) {
      const regexPattern =
        "^" +
        allowed
          .split("*")
          .map((part) => part.replace(/[-[\]{}()+?.,\\^$|#\s]/g, "\\$&"))
          .join(".*") +
        "$";
      if (new RegExp(regexPattern, "i").test(origin)) {
        return true;
      }
    }
  }
  return false;
}

function getCorsHeaders(request: Request, env: Env): Record<string, string> {
  const origin = request.headers.get("Origin");
  const allowedList = (env.ALLOWED_ORIGINS ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter((o) => o.length > 0);

  const allowsLocalhost = allowedList.some((o) =>
    /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i.test(o)
  );
  const isOriginLocalhost = Boolean(
    origin &&
      /^http:\/\/(localhost|127\.0\.0\.1|192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+)(:\d+)?$/i.test(
        origin
      )
  );

  const isAllowed = Boolean(
    origin &&
      (isOriginAllowed(origin, allowedList) ||
        (allowsLocalhost && isOriginLocalhost))
  );

  const allowOrigin = isAllowed
    ? origin!
    : allowedList[0] ?? "https://robovolunteers.link";

  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

function jsonResponse(
  status: number,
  body: Record<string, unknown>,
  corsHeaders: Record<string, string>,
  extraHeaders?: Record<string, string>
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...corsHeaders,
      ...extraHeaders,
    },
  });
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

async function handleRequestOtp(
  request: Request,
  env: Env,
  deps: WorkerDeps
): Promise<Record<string, unknown>> {
  if (!env.OTP_HMAC_SECRET) {
    throw new HttpError(
      500,
      "server_misconfigured",
      "OTP_HMAC_SECRET is not configured."
    );
  }

  let body: Partial<RequestOtpBody>;
  try {
    body = (await request.json()) as Partial<RequestOtpBody>;
  } catch {
    throw new HttpError(400, "invalid_json", "Invalid JSON request body.");
  }

  const mode = body.mode;
  if (mode !== "login" && mode !== "join") {
    throw new HttpError(
      400,
      "invalid_mode",
      'Auth mode must be either "login" or "join".'
    );
  }

  const email = normalizeAndValidateEmail(body.email);
  if (!email) {
    throw new HttpError(
      400,
      "invalid_email",
      "Please enter a valid email address."
    );
  }

  const now = deps.now ? deps.now() : new Date();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const clientIp =
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown-ip";

  const [ipHash, emailHash] = await Promise.all([
    hmacSha256Hex(env.OTP_HMAC_SECRET, `ip:${clientIp}`),
    hmacSha256Hex(env.OTP_HMAC_SECRET, `email:${email}`),
  ]);

  const rateConfig = parseRateLimitConfig(env);

  // Layer 1: Per-IP request rate limit (5/min, 20/hr)
  await enforceAndRecordRequestIpLimit(
    env.AUTH_OTP_KV,
    ipHash,
    rateConfig,
    now
  );

  // Layer 2: Cloudflare Turnstile bot check
  await verifyTurnstileToken(env, body.turnstileToken, clientIp, fetchImpl);

  // Layer 3a: For new volunteers, validate invite code (one-time KV or legacy static) BEFORE sending email
  let oneTimeInviteCodeHash: string | undefined;
  if (mode === "join") {
    const resolvedInvite = await validateInviteCodeForJoin(
      body.inviteCode,
      env,
      now
    );
    if (resolvedInvite.kind === "one_time") {
      oneTimeInviteCodeHash = resolvedInvite.codeHash;
    }
  }

  // Layer 4: Per-person cooldown (60s), per-person daily cap (12 emails/day), and global daily cap
  const quotaState = await checkEmailSendQuota(
    env.AUTH_OTP_KV,
    emailHash,
    rateConfig,
    now
  );

  const serviceAccount = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT_JSON);

  // Layer 3b: For returning "login" mode, check that a verified volunteer account exists
  // BEFORE sending any email (prevents spamming strangers while returning a generic message).
  if (mode === "login") {
    const existingUser = await lookupFirebaseUserByEmail(
      serviceAccount,
      email,
      fetchImpl
    );
    if (!existingUser || !existingUser.inviteVerified) {
      return {
        ok: true,
        cooldownSeconds: rateConfig.otpCooldownSeconds,
        message:
          "If a registered volunteer account exists for this email, a 6-digit verification code has been sent.",
      };
    }
  }

  const otpTtlSeconds = parsePositiveInt(env.OTP_TTL_SECONDS, 600);
  const otpCode = generateSixDigitOtp();
  const codeHash = await hmacSha256Hex(
    env.OTP_HMAC_SECRET,
    `otp:${email}:${otpCode}`
  );

  const otpRecord: StoredOtpRecord = {
    codeHash,
    attempts: 0,
    createdAtMs: now.getTime(),
    ...(oneTimeInviteCodeHash ? { inviteCodeHash: oneTimeInviteCodeHash } : {}),
  };

  await sendOtpEmail(
    env,
    email,
    otpCode,
    Math.max(1, Math.round(otpTtlSeconds / 60))
  );

  await env.AUTH_OTP_KV.put(`otp:${emailHash}`, JSON.stringify(otpRecord), {
    expirationTtl: otpTtlSeconds,
  });

  // Commit email send quota (sets 60s cooldown + increments 12/day user cap & global daily cap)
  await commitEmailSendQuota(
    env.AUTH_OTP_KV,
    emailHash,
    quotaState,
    rateConfig,
    now
  );

  return {
    ok: true,
    cooldownSeconds: rateConfig.otpCooldownSeconds,
    message:
      mode === "join"
        ? "Invite verified! We've sent a 6-digit verification code to your email."
        : "If a registered volunteer account exists for this email, a 6-digit verification code has been sent.",
  };
}

async function handleVerifyOtp(
  request: Request,
  env: Env,
  deps: WorkerDeps
): Promise<Record<string, unknown>> {
  if (!env.OTP_HMAC_SECRET) {
    throw new HttpError(
      500,
      "server_misconfigured",
      "OTP_HMAC_SECRET is not configured."
    );
  }

  let body: Partial<VerifyOtpBody>;
  try {
    body = (await request.json()) as Partial<VerifyOtpBody>;
  } catch {
    throw new HttpError(400, "invalid_json", "Invalid JSON request body.");
  }

  const email = normalizeAndValidateEmail(body.email);
  if (!email) {
    throw new HttpError(
      400,
      "invalid_email",
      "Please enter a valid email address."
    );
  }

  const submittedCode = typeof body.code === "string" ? body.code.trim() : "";
  if (!/^\d{6}$/.test(submittedCode)) {
    throw new HttpError(
      400,
      "invalid_code_format",
      "Please enter the 6-digit numeric verification code."
    );
  }

  const now = deps.now ? deps.now() : new Date();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const clientIp =
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown-ip";

  const [ipHash, emailHash] = await Promise.all([
    hmacSha256Hex(env.OTP_HMAC_SECRET, `ip:${clientIp}`),
    hmacSha256Hex(env.OTP_HMAC_SECRET, `email:${email}`),
  ]);

  await enforceAndRecordVerifyIpLimit(env.AUTH_OTP_KV, ipHash, now);

  const otpKey = `otp:${emailHash}`;
  const rawRecord = await env.AUTH_OTP_KV.get(otpKey);
  if (!rawRecord) {
    throw new HttpError(
      401,
      "invalid_or_expired_code",
      "Invalid or expired verification code. Please check the code or request a new one."
    );
  }

  let record: StoredOtpRecord;
  try {
    record = JSON.parse(rawRecord) as StoredOtpRecord;
  } catch {
    await env.AUTH_OTP_KV.delete(otpKey);
    throw new HttpError(
      401,
      "invalid_or_expired_code",
      "Invalid or expired verification code."
    );
  }

  const maxAttempts = parsePositiveInt(env.MAX_OTP_ATTEMPTS, 5);
  const otpTtlSeconds = parsePositiveInt(env.OTP_TTL_SECONDS, 600);

  if (record.attempts >= maxAttempts) {
    await env.AUTH_OTP_KV.delete(otpKey);
    throw new HttpError(
      401,
      "max_attempts_exceeded",
      "Too many incorrect attempts. Please request a new 6-digit verification code."
    );
  }

  const candidateHash = await hmacSha256Hex(
    env.OTP_HMAC_SECRET,
    `otp:${email}:${submittedCode}`
  );
  const isMatch = await timingSafeEqualStrings(candidateHash, record.codeHash);

  if (!isMatch) {
    const nextAttempts = record.attempts + 1;
    if (nextAttempts >= maxAttempts) {
      await env.AUTH_OTP_KV.delete(otpKey);
      throw new HttpError(
        401,
        "max_attempts_exceeded",
        "Too many incorrect attempts. Please request a new 6-digit verification code."
      );
    }

    const elapsedSec = Math.floor((now.getTime() - record.createdAtMs) / 1000);
    const remainingTtl = Math.max(60, otpTtlSeconds - elapsedSec);
    await env.AUTH_OTP_KV.put(
      otpKey,
      JSON.stringify({ ...record, attempts: nextAttempts }),
      { expirationTtl: remainingTtl }
    );

    throw new HttpError(
      401,
      "invalid_or_expired_code",
      "Invalid verification code. Please double-check the 6 digits and try again."
    );
  }

  // Single-use OTP: delete immediately upon valid match
  await env.AUTH_OTP_KV.delete(otpKey);

  const serviceAccount = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT_JSON);
  const existingUser = await lookupFirebaseUserByEmail(
    serviceAccount,
    email,
    fetchImpl
  );

  let uid: string;
  if (record.inviteCodeHash && !existingUser?.inviteVerified) {
    let previousInvite: StoredInviteRecord | null = null;
    previousInvite = await consumeOneTimeInviteByHash(
      env.AUTH_OTP_KV,
      record.inviteCodeHash,
      { uid: existingUser?.uid ?? "pending", email },
      now
    );

    try {
      uid = await ensureVerifiedVolunteerUser(
        serviceAccount,
        email,
        fetchImpl,
        existingUser
      );
      if (uid !== (existingUser?.uid ?? "pending")) {
        await saveInviteRecord(env.AUTH_OTP_KV, {
          ...previousInvite,
          code: null,
          status: "used",
          usedAt: now.toISOString(),
          usedByUid: uid,
          usedByEmail: email,
        });
      }
    } catch (err) {
      if (previousInvite) {
        await saveInviteRecord(env.AUTH_OTP_KV, previousInvite);
      }
      throw err;
    }
  } else {
    uid = await ensureVerifiedVolunteerUser(
      serviceAccount,
      email,
      fetchImpl,
      existingUser
    );
  }

  const customTokenClaims: Record<string, unknown> = {
    ...(existingUser?.customClaims ?? {}),
    inviteVerified: true,
  };
  const customToken = await mintFirebaseCustomToken(
    serviceAccount,
    uid,
    customTokenClaims,
    Math.floor(now.getTime() / 1000)
  );

  return {
    ok: true,
    uid,
    email,
    customToken,
  };
}

/**
 * Verifies an invitation code for a first-time Federated (e.g. Sign in with Google)
 * volunteer, cryptographically validates their Firebase ID Token (RS256 against
 * Google's public JWKS), and stamps persistent `inviteVerified: true` onto their
 * Firebase Auth account. Sends ZERO emails.
 */
async function handleClaimInvite(
  request: Request,
  env: Env,
  deps: WorkerDeps
): Promise<Record<string, unknown>> {
  if (!env.OTP_HMAC_SECRET) {
    throw new HttpError(
      500,
      "server_misconfigured",
      "OTP_HMAC_SECRET is not configured."
    );
  }

  let body: Partial<ClaimInviteBody>;
  try {
    body = (await request.json()) as Partial<ClaimInviteBody>;
  } catch {
    throw new HttpError(400, "invalid_json", "Invalid JSON request body.");
  }

  const idToken = extractBearerToken(request, body.idToken);
  if (!idToken) {
    throw new HttpError(
      401,
      "missing_id_token",
      "Missing Firebase authentication token."
    );
  }

  const now = deps.now ? deps.now() : new Date();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const clientIp = getClientIp(request);

  const ipHash = await hmacSha256Hex(env.OTP_HMAC_SECRET, `ip:${clientIp}`);
  const rateConfig = parseRateLimitConfig(env);

  // Layer 1: Per-IP brute-force protection (5/min, 20/hr)
  await enforceAndRecordRequestIpLimit(
    env.AUTH_OTP_KV,
    ipHash,
    rateConfig,
    now
  );

  // Layer 2: Optional Cloudflare Turnstile bot check
  await verifyTurnstileToken(env, body.turnstileToken, clientIp, fetchImpl);

  // Layer 3: Validate invite code (one-time KV or legacy static) BEFORE calling Firebase
  const resolvedInvite = await validateInviteCodeForJoin(
    body.inviteCode,
    env,
    now
  );

  // Layer 4: Cryptographically verify caller's Firebase ID Token (RS256 JWKS)
  const serviceAccount = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT_JSON);
  const verified = await verifyFirebaseIdToken(
    serviceAccount,
    idToken,
    fetchImpl,
    Math.floor(now.getTime() / 1000)
  );

  // If caller already holds inviteVerified, return immediately without burning a one-time code
  if (verified.inviteVerified) {
    return {
      ok: true,
      uid: verified.uid,
      email: verified.email,
    };
  }

  const existingClaims: Record<string, unknown> = verified.isAdminClaim
    ? { admin: true }
    : {};

  // Layer 5: Consume one-time invite (with rollback on Firebase error) & stamp `inviteVerified: true`
  if (resolvedInvite.kind === "one_time") {
    const previousInvite = await consumeOneTimeInviteByHash(
      env.AUTH_OTP_KV,
      resolvedInvite.codeHash,
      { uid: verified.uid, email: verified.email },
      now
    );
    try {
      await grantInviteVerifiedByUid(
        serviceAccount,
        verified.uid,
        fetchImpl,
        existingClaims
      );
    } catch (err) {
      await saveInviteRecord(env.AUTH_OTP_KV, previousInvite);
      throw err;
    }
  } else {
    await grantInviteVerifiedByUid(
      serviceAccount,
      verified.uid,
      fetchImpl,
      existingClaims
    );
  }

  return {
    ok: true,
    uid: verified.uid,
    email: verified.email,
  };
}

function getClientIp(request: Request): string {
  return (
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown-ip"
  );
}

function extractBearerToken(request: Request, fallbackBodyToken?: string): string {
  const authHeader = request.headers.get("Authorization") ?? "";
  const bearerToken = authHeader.startsWith("Bearer ")
    ? authHeader.slice(7).trim()
    : "";
  return (bearerToken || fallbackBodyToken || "").trim();
}

async function isVerifiedAdmin(
  verified: VerifiedFirebaseToken,
  env: Env
): Promise<boolean> {
  if (!verified.inviteVerified) {
    return false;
  }
  if (verified.isAdminClaim) {
    return true;
  }
  if (!verified.emailVerified || !verified.email) {
    return false;
  }
  return isEmailInAllowlist(verified.email, env.ADMIN_EMAILS);
}

async function authenticateAdminRequest(
  request: Request,
  env: Env,
  deps: WorkerDeps,
  enforceRateLimit: boolean
): Promise<{ uid: string; email: string }> {
  if (!env.OTP_HMAC_SECRET) {
    throw new HttpError(
      500,
      "server_misconfigured",
      "OTP_HMAC_SECRET is not configured."
    );
  }

  const idToken = extractBearerToken(request);
  if (!idToken) {
    throw new HttpError(
      401,
      "missing_id_token",
      "Missing Firebase authentication token."
    );
  }

  const now = deps.now ? deps.now() : new Date();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const serviceAccount = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT_JSON);
  const verified = await verifyFirebaseIdToken(
    serviceAccount,
    idToken,
    fetchImpl,
    Math.floor(now.getTime() / 1000)
  );

  const isAdmin = await isVerifiedAdmin(verified, env);
  if (!isAdmin) {
    throw new HttpError(
      403,
      "admin_required",
      "Administrator access is required for this action."
    );
  }

  if (enforceRateLimit) {
    const ipHash = await hmacSha256Hex(
      env.OTP_HMAC_SECRET,
      `ip:${getClientIp(request)}`
    );
    await enforceAndRecordAdminIpLimit(env.AUTH_OTP_KV, ipHash, now);
  }

  return { uid: verified.uid, email: verified.email };
}

async function handleGetAuthMe(
  request: Request,
  env: Env,
  deps: WorkerDeps
): Promise<Record<string, unknown>> {
  const idToken = extractBearerToken(request);
  if (!idToken) {
    throw new HttpError(
      401,
      "missing_id_token",
      "Missing Firebase authentication token."
    );
  }

  const now = deps.now ? deps.now() : new Date();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const serviceAccount = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT_JSON);
  const verified = await verifyFirebaseIdToken(
    serviceAccount,
    idToken,
    fetchImpl,
    Math.floor(now.getTime() / 1000)
  );

  const isAdmin = await isVerifiedAdmin(verified, env);
  return {
    ok: true,
    uid: verified.uid,
    email: verified.email,
    inviteVerified: verified.inviteVerified,
    isAdmin,
  };
}

async function handleAdminListInvites(
  request: Request,
  env: Env,
  deps: WorkerDeps
): Promise<Record<string, unknown>> {
  await authenticateAdminRequest(request, env, deps, false);
  const now = deps.now ? deps.now() : new Date();
  const invites = await listOneTimeInvites(
    env.AUTH_OTP_KV,
    now,
    getPublicAppUrl(env)
  );
  return {
    ok: true,
    invites,
  };
}

async function handleAdminCreateInvites(
  request: Request,
  env: Env,
  deps: WorkerDeps
): Promise<Record<string, unknown>> {
  const admin = await authenticateAdminRequest(request, env, deps, true);
  let body: Partial<CreateInviteBody> = {};
  const rawBody = await request.text();
  if (rawBody.trim().length > 0) {
    try {
      body = JSON.parse(rawBody) as Partial<CreateInviteBody>;
    } catch {
      throw new HttpError(400, "invalid_json", "Invalid JSON request body.");
    }
  }

  const now = deps.now ? deps.now() : new Date();
  const created = await createOneTimeInvites(
    env.AUTH_OTP_KV,
    env.OTP_HMAC_SECRET,
    admin,
    body,
    now,
    getPublicAppUrl(env)
  );
  return {
    ok: true,
    invite: created[0],
    invites: created,
  };
}

async function handleAdminRevokeInvite(
  request: Request,
  env: Env,
  deps: WorkerDeps,
  inviteId: string
): Promise<Record<string, unknown>> {
  const admin = await authenticateAdminRequest(request, env, deps, true);
  const now = deps.now ? deps.now() : new Date();
  const invite = await revokeOneTimeInvite(
    env.AUTH_OTP_KV,
    inviteId,
    admin,
    now,
    getPublicAppUrl(env)
  );
  return {
    ok: true,
    invite,
  };
}

export async function handleWorkerRequest(
  request: Request,
  env: Env,
  deps: WorkerDeps = {}
): Promise<Response> {
  const corsHeaders = getCorsHeaders(request, env);

  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const url = new URL(request.url);

  try {
    if (request.method === "POST" && url.pathname === "/api/auth/request-otp") {
      const result = await handleRequestOtp(request, env, deps);
      return jsonResponse(200, result, corsHeaders);
    }

    if (request.method === "POST" && url.pathname === "/api/auth/verify-otp") {
      const result = await handleVerifyOtp(request, env, deps);
      return jsonResponse(200, result, corsHeaders);
    }

    if (request.method === "POST" && url.pathname === "/api/auth/claim-invite") {
      const result = await handleClaimInvite(request, env, deps);
      return jsonResponse(200, result, corsHeaders);
    }

    if (request.method === "GET" && url.pathname === "/api/auth/me") {
      const result = await handleGetAuthMe(request, env, deps);
      return jsonResponse(200, result, corsHeaders);
    }

    if (request.method === "GET" && url.pathname === "/api/admin/invites") {
      const result = await handleAdminListInvites(request, env, deps);
      return jsonResponse(200, result, corsHeaders);
    }

    if (request.method === "POST" && url.pathname === "/api/admin/invites") {
      const result = await handleAdminCreateInvites(request, env, deps);
      return jsonResponse(201, result, corsHeaders);
    }

    const revokePostMatch =
      request.method === "POST"
        ? url.pathname.match(/^\/api\/admin\/invites\/([^/]+)\/revoke$/)
        : null;
    const revokeDeleteMatch =
      request.method === "DELETE"
        ? url.pathname.match(/^\/api\/admin\/invites\/([^/]+)$/)
        : null;
    const revokeMatch = revokePostMatch ?? revokeDeleteMatch;
    if (revokeMatch) {
      let inviteId = revokeMatch[1];
      try {
        inviteId = decodeURIComponent(inviteId);
      } catch {
        throw new HttpError(400, "invalid_invite_id", "Invalid invite ID.");
      }
      const result = await handleAdminRevokeInvite(request, env, deps, inviteId);
      return jsonResponse(200, result, corsHeaders);
    }

    return jsonResponse(
      404,
      { ok: false, error: "not_found", message: "Endpoint not found." },
      corsHeaders
    );
  } catch (err) {
    if (err instanceof HttpError) {
      const extraHeaders = err.retryAfterSeconds
        ? { "Retry-After": String(err.retryAfterSeconds) }
        : undefined;
      return jsonResponse(
        err.status,
        {
          ok: false,
          error: err.code,
          message: err.message,
          ...(err.retryAfterSeconds
            ? { retryAfterSeconds: err.retryAfterSeconds }
            : {}),
        },
        corsHeaders,
        extraHeaders
      );
    }

    console.error("Unhandled auth worker error:", err);
    return jsonResponse(
      500,
      {
        ok: false,
        error: "internal_error",
        message: "An unexpected server error occurred. Please try again.",
      },
      corsHeaders
    );
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleWorkerRequest(request, env);
  },
};
