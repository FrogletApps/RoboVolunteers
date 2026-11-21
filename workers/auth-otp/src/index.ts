import {
  generateSixDigitOtp,
  hmacSha256Hex,
  normalizeAndValidateEmail,
  timingSafeEqualStrings,
  verifyInviteCodeConstantTime,
} from "./crypto.ts";
import { sendOtpEmail } from "./email.ts";
import {
  ensureVerifiedVolunteerUser,
  grantInviteVerifiedByUid,
  lookupFirebaseUserByEmail,
  mintFirebaseCustomToken,
  parseServiceAccount,
  verifyFirebaseIdToken,
} from "./firebaseAdmin.ts";
import {
  checkEmailSendQuota,
  commitEmailSendQuota,
  enforceAndRecordRequestIpLimit,
  enforceAndRecordVerifyIpLimit,
  parseRateLimitConfig,
} from "./rateLimit.ts";
import { verifyTurnstileToken } from "./turnstile.ts";
import type {
  ClaimInviteBody,
  Env,
  RequestOtpBody,
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
    "Access-Control-Allow-Methods": "POST, OPTIONS",
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

  // Layer 3a: For new volunteers, validate invite code in constant time BEFORE checking/sending email
  if (mode === "join") {
    const validInvite = await verifyInviteCodeConstantTime(
      body.inviteCode,
      env.INVITE_CODES
    );
    if (!validInvite) {
      throw new HttpError(
        403,
        "invalid_invite_code",
        "Invalid invitation code. Access to RoboVolunteers is invite-only."
      );
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
  const uid = await ensureVerifiedVolunteerUser(
    serviceAccount,
    email,
    fetchImpl
  );
  const customToken = await mintFirebaseCustomToken(
    serviceAccount,
    uid,
    { inviteVerified: true },
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

  const authHeader = request.headers.get("Authorization") ?? "";
  const bearerToken = authHeader.startsWith("Bearer ")
    ? authHeader.slice(7).trim()
    : "";
  const idToken = (bearerToken || body.idToken || "").trim();
  if (!idToken) {
    throw new HttpError(
      401,
      "missing_id_token",
      "Missing Firebase authentication token."
    );
  }

  const now = deps.now ? deps.now() : new Date();
  const fetchImpl = deps.fetchImpl ?? fetch;
  const clientIp =
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ??
    "unknown-ip";

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

  // Layer 3: Constant-time invite code verification BEFORE calling Firebase
  const validInvite = await verifyInviteCodeConstantTime(
    body.inviteCode,
    env.INVITE_CODES
  );
  if (!validInvite) {
    throw new HttpError(
      403,
      "invalid_invite_code",
      "Invalid invitation code. Access to RoboVolunteers is invite-only."
    );
  }

  // Layer 4: Cryptographically verify caller's Firebase ID Token (RS256 JWKS)
  const serviceAccount = parseServiceAccount(env.FIREBASE_SERVICE_ACCOUNT_JSON);
  const verified = await verifyFirebaseIdToken(
    serviceAccount,
    idToken,
    fetchImpl,
    Math.floor(now.getTime() / 1000)
  );

  // Layer 5: Stamp persistent `inviteVerified: true` onto caller's Firebase Auth UID
  await grantInviteVerifiedByUid(serviceAccount, verified.uid, fetchImpl);

  return {
    ok: true,
    uid: verified.uid,
    email: verified.email,
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
