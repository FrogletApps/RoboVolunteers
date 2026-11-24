import { HttpError } from "./types.ts";

const encoder = new TextEncoder();

export interface ServiceAccountCredentials {
  project_id: string;
  client_email: string;
  private_key: string;
}

export interface FirebaseUserSummary {
  uid: string;
  email: string;
  emailVerified: boolean;
  inviteVerified: boolean;
  isAdmin: boolean;
  customClaims: Record<string, unknown>;
}

export interface VerifiedFirebaseToken {
  uid: string;
  email: string;
  emailVerified: boolean;
  inviteVerified: boolean;
  isAdminClaim: boolean;
}

let cachedAccessToken: {
  clientEmail: string;
  token: string;
  expiresAtMs: number;
} | null = null;

export const FIREBASE_SECURETOKEN_JWKS_URL =
  "https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com";

let cachedSecureTokenJwks: {
  keysByKid: Map<string, JsonWebKey>;
  expiresAtMs: number;
} | null = null;

export function parseServiceAccount(rawJson: string | undefined): ServiceAccountCredentials {
  if (!rawJson) {
    throw new HttpError(
      500,
      "firebase_misconfigured",
      "FIREBASE_SERVICE_ACCOUNT_JSON secret is not configured."
    );
  }
  let parsed: Partial<ServiceAccountCredentials>;
  try {
    parsed = JSON.parse(rawJson) as Partial<ServiceAccountCredentials>;
  } catch {
    throw new HttpError(
      500,
      "firebase_misconfigured",
      "FIREBASE_SERVICE_ACCOUNT_JSON is not valid JSON."
    );
  }

  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    throw new HttpError(
      500,
      "firebase_misconfigured",
      "FIREBASE_SERVICE_ACCOUNT_JSON is missing project_id, client_email, or private_key."
    );
  }

  return {
    project_id: parsed.project_id,
    client_email: parsed.client_email,
    private_key: parsed.private_key.replace(/\\n/g, "\n"),
  };
}

function base64UrlEncodeBytes(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64UrlEncodeJson(obj: unknown): string {
  return base64UrlEncodeBytes(encoder.encode(JSON.stringify(obj)));
}

function pemToPkcs8Bytes(pem: string): ArrayBuffer {
  const clean = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(clean);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

async function importRsaPrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8Bytes(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
}

async function signRs256Jwt(
  payload: Record<string, unknown>,
  privateKeyPem: string
): Promise<string> {
  const headerB64 = base64UrlEncodeJson({ alg: "RS256", typ: "JWT" });
  const payloadB64 = base64UrlEncodeJson(payload);
  const signingInput = `${headerB64}.${payloadB64}`;

  const key = await importRsaPrivateKey(privateKeyPem);
  const sigBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    encoder.encode(signingInput)
  );

  return `${signingInput}.${base64UrlEncodeBytes(new Uint8Array(sigBuffer))}`;
}

/**
 * Mints a short-lived (1 hour) Firebase Custom Auth Token for `signInWithCustomToken`.
 */
export async function mintFirebaseCustomToken(
  sa: ServiceAccountCredentials,
  uid: string,
  claims: Record<string, unknown> = { inviteVerified: true },
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<string> {
  if (!uid || uid.length > 128) {
    throw new Error("Invalid Firebase UID length.");
  }

  return signRs256Jwt(
    {
      iss: sa.client_email,
      sub: sa.client_email,
      aud: "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
      iat: nowSeconds,
      exp: nowSeconds + 3600,
      uid,
      claims,
    },
    sa.private_key
  );
}

async function getGoogleOAuthToken(
  sa: ServiceAccountCredentials,
  fetchImpl: typeof fetch
): Promise<string> {
  const nowMs = Date.now();
  if (
    cachedAccessToken &&
    cachedAccessToken.clientEmail === sa.client_email &&
    cachedAccessToken.expiresAtMs - 60_000 > nowMs
  ) {
    return cachedAccessToken.token;
  }

  const nowSeconds = Math.floor(nowMs / 1000);
  const assertion = await signRs256Jwt(
    {
      iss: sa.client_email,
      scope:
        "https://www.googleapis.com/auth/identitytoolkit https://www.googleapis.com/auth/userinfo.email",
      aud: "https://oauth2.googleapis.com/token",
      iat: nowSeconds,
      exp: nowSeconds + 3600,
    },
    sa.private_key
  );

  const body = new URLSearchParams({
    grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion,
  });

  const resp = await fetchImpl("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body.toString(),
  });

  if (!resp.ok) {
    throw new HttpError(
      502,
      "firebase_oauth_failed",
      "Failed to authenticate with Firebase Identity service."
    );
  }

  const data = (await resp.json()) as {
    access_token: string;
    expires_in?: number;
  };
  cachedAccessToken = {
    clientEmail: sa.client_email,
    token: data.access_token,
    expiresAtMs: nowMs + (data.expires_in ?? 3600) * 1000,
  };
  return data.access_token;
}

export function clearCachedGoogleOAuthTokenForTests(): void {
  cachedAccessToken = null;
  cachedSecureTokenJwks = null;
}

function base64UrlDecodeBytes(b64url: string): Uint8Array {
  const padded = b64url
    .replace(/-/g, "+")
    .replace(/_/g, "/")
    .padEnd(Math.ceil(b64url.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function base64UrlDecodeJson(b64url: string): Record<string, unknown> {
  const bytes = base64UrlDecodeBytes(b64url);
  const text = new TextDecoder().decode(bytes);
  const parsed = JSON.parse(text);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("Invalid JWT JSON segment.");
  }
  return parsed as Record<string, unknown>;
}

async function fetchSecureTokenJwk(
  kid: string,
  fetchImpl: typeof fetch,
  forceRefresh: boolean = false
): Promise<JsonWebKey | undefined> {
  const nowMs = Date.now();
  if (
    !forceRefresh &&
    cachedSecureTokenJwks &&
    cachedSecureTokenJwks.expiresAtMs > nowMs
  ) {
    const cached = cachedSecureTokenJwks.keysByKid.get(kid);
    if (cached) return cached;
  }

  const resp = await fetchImpl(FIREBASE_SECURETOKEN_JWKS_URL, {
    method: "GET",
  });
  if (!resp.ok) {
    throw new HttpError(
      502,
      "firebase_jwks_unavailable",
      "Unable to retrieve Firebase public signing keys right now."
    );
  }

  const cacheControl = resp.headers.get("Cache-Control") ?? "";
  const maxAgeMatch = cacheControl.match(/max-age=(\d+)/i);
  const ttlSeconds = maxAgeMatch
    ? Math.max(60, Number.parseInt(maxAgeMatch[1], 10))
    : 3600;

  const data = (await resp.json()) as {
    keys?: Array<JsonWebKey & { kid?: string }>;
  };

  const keysByKid = new Map<string, JsonWebKey>();
  for (const key of data.keys ?? []) {
    if (key && typeof key.kid === "string" && key.kid.length > 0) {
      keysByKid.set(key.kid, key);
    }
  }

  cachedSecureTokenJwks = {
    keysByKid,
    expiresAtMs: nowMs + ttlSeconds * 1000,
  };

  return keysByKid.get(kid);
}

/**
 * Cryptographically verifies a Firebase Auth ID Token (RS256 JWT issued by
 * `https://securetoken.google.com/<project_id>`) using Google's public JWKS.
 */
export async function verifyFirebaseIdToken(
  sa: ServiceAccountCredentials,
  rawIdToken: string,
  fetchImpl: typeof fetch = fetch,
  nowSeconds: number = Math.floor(Date.now() / 1000)
): Promise<VerifiedFirebaseToken> {
  const token = rawIdToken.trim();
  const segments = token.split(".");
  if (segments.length !== 3 || segments.some((s) => s.length === 0)) {
    throw new HttpError(
      401,
      "invalid_id_token",
      "Invalid or malformed authentication token."
    );
  }

  let header: Record<string, unknown>;
  let payload: Record<string, unknown>;
  let signatureBytes: Uint8Array;
  try {
    header = base64UrlDecodeJson(segments[0]);
    payload = base64UrlDecodeJson(segments[1]);
    signatureBytes = base64UrlDecodeBytes(segments[2]);
  } catch {
    throw new HttpError(
      401,
      "invalid_id_token",
      "Invalid or malformed authentication token."
    );
  }

  const kid = typeof header.kid === "string" ? header.kid : "";
  if (header.alg !== "RS256" || !kid) {
    throw new HttpError(
      401,
      "invalid_id_token",
      "Unsupported authentication token signature algorithm."
    );
  }

  const expectedIssuer = `https://securetoken.google.com/${sa.project_id}`;
  const uid = typeof payload.sub === "string" ? payload.sub : "";
  const exp = typeof payload.exp === "number" ? payload.exp : 0;
  const iat = typeof payload.iat === "number" ? payload.iat : 0;

  if (
    payload.iss !== expectedIssuer ||
    payload.aud !== sa.project_id ||
    !uid ||
    uid.length > 128 ||
    exp <= nowSeconds ||
    iat > nowSeconds + 60
  ) {
    throw new HttpError(
      401,
      "invalid_id_token",
      "Authentication token is expired or belongs to another project."
    );
  }

  let jwk = await fetchSecureTokenJwk(kid, fetchImpl, false);
  if (!jwk) {
    jwk = await fetchSecureTokenJwk(kid, fetchImpl, true);
  }
  if (!jwk) {
    throw new HttpError(
      401,
      "invalid_id_token",
      "Unrecognized authentication token signing key."
    );
  }

  let validSignature = false;
  try {
    const publicKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );
    const signingInput = encoder.encode(`${segments[0]}.${segments[1]}`);
    validSignature = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      signatureBytes as BufferSource,
      signingInput
    );
  } catch {
    validSignature = false;
  }

  if (!validSignature) {
    throw new HttpError(
      401,
      "invalid_id_token",
      "Authentication token signature verification failed."
    );
  }

  const email =
    typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
  const emailVerified = payload.email_verified === true;
  const inviteVerified = payload.inviteVerified === true;
  const isAdminClaim = payload.admin === true;
  return { uid, email, emailVerified, inviteVerified, isAdminClaim };
}

/**
 * Stamps persistent `{"inviteVerified": true}` custom claims onto an existing
 * Firebase Auth UID while preserving any existing custom claims (such as `admin: true`).
 */
export async function grantInviteVerifiedByUid(
  sa: ServiceAccountCredentials,
  uid: string,
  fetchImpl: typeof fetch = fetch,
  existingClaims: Record<string, unknown> = {}
): Promise<void> {
  const accessToken = await getGoogleOAuthToken(sa, fetchImpl);
  const baseUrl = `https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(
    sa.project_id
  )}`;

  const mergedClaims: Record<string, unknown> = {
    ...existingClaims,
    inviteVerified: true,
  };

  const updateResp = await fetchImpl(`${baseUrl}/accounts:update`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      localId: uid,
      emailVerified: true,
      customAttributes: JSON.stringify(mergedClaims),
    }),
  });

  if (!updateResp.ok) {
    throw new HttpError(
      502,
      "firebase_claims_update_failed",
      "Unable to finalize account verification claims right now."
    );
  }
}

/**
 * Looks up a Firebase Auth user by normalized email.
 */
export async function lookupFirebaseUserByEmail(
  sa: ServiceAccountCredentials,
  email: string,
  fetchImpl: typeof fetch = fetch
): Promise<FirebaseUserSummary | null> {
  const accessToken = await getGoogleOAuthToken(sa, fetchImpl);
  const resp = await fetchImpl(
    `https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(
      sa.project_id
    )}/accounts:lookup`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ email: [email] }),
    }
  );

  if (!resp.ok) {
    throw new HttpError(
      502,
      "firebase_lookup_failed",
      "Unable to look up account status right now."
    );
  }

  const data = (await resp.json()) as {
    users?: Array<{
      localId: string;
      email: string;
      emailVerified?: boolean;
      customAttributes?: string;
    }>;
  };

  const user = data.users?.[0];
  if (!user) return null;

  let customClaims: Record<string, unknown> = {};
  if (user.customAttributes) {
    try {
      const attrs = JSON.parse(user.customAttributes) as unknown;
      if (attrs && typeof attrs === "object" && !Array.isArray(attrs)) {
        customClaims = attrs as Record<string, unknown>;
      }
    } catch {
      customClaims = {};
    }
  }

  return {
    uid: user.localId,
    email: user.email,
    emailVerified: Boolean(user.emailVerified),
    inviteVerified: customClaims.inviteVerified === true,
    isAdmin: customClaims.admin === true,
    customClaims,
  };
}

/**
 * Ensures a Firebase Auth user exists for `email` with `emailVerified: true`
 * and persistent custom claim `{"inviteVerified": true}` so refreshed tokens
 * continue passing Firestore Security Rules indefinitely.
 */
export async function ensureVerifiedVolunteerUser(
  sa: ServiceAccountCredentials,
  email: string,
  fetchImpl: typeof fetch = fetch,
  preloadedUser?: FirebaseUserSummary | null
): Promise<string> {
  const existing =
    preloadedUser !== undefined
      ? preloadedUser
      : await lookupFirebaseUserByEmail(sa, email, fetchImpl);
  const accessToken = await getGoogleOAuthToken(sa, fetchImpl);
  const baseUrl = `https://identitytoolkit.googleapis.com/v1/projects/${encodeURIComponent(
    sa.project_id
  )}`;

  let uid = existing?.uid;

  if (!uid) {
    const createResp = await fetchImpl(`${baseUrl}/accounts`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email,
        emailVerified: true,
      }),
    });

    if (!createResp.ok) {
      throw new HttpError(
        502,
        "firebase_create_user_failed",
        "Unable to provision volunteer account right now."
      );
    }

    const created = (await createResp.json()) as { localId: string };
    uid = created.localId;
  }

  if (!existing || !existing.emailVerified || !existing.inviteVerified) {
    await grantInviteVerifiedByUid(
      sa,
      uid,
      fetchImpl,
      existing?.customClaims ?? {}
    );
  }

  return uid;
}
