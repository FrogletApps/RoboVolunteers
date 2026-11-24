const encoder = new TextEncoder();

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

/**
 * Normalizes and validates an email address.
 * Returns null if invalid or suspiciously long (> 254 chars per RFC 5321).
 */
export function normalizeAndValidateEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const normalized = raw.trim().toLowerCase();
  if (normalized.length < 5 || normalized.length > 254) return null;
  if (!EMAIL_REGEX.test(normalized)) return null;
  return normalized;
}

/**
 * Computes HMAC-SHA256 hex digest using Web Crypto API.
 */
export async function hmacSha256Hex(
  secret: string,
  message: string
): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sigBuffer = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode(message)
  );
  return bytesToHex(new Uint8Array(sigBuffer));
}

/**
 * Constant-time string comparison that hashes both inputs with an ephemeral
 * random HMAC key first so neither content nor string length leaks via timing.
 */
export async function timingSafeEqualStrings(
  a: string,
  b: string
): Promise<boolean> {
  const ephemeralSecret = crypto.getRandomValues(new Uint8Array(32));
  const key = await crypto.subtle.importKey(
    "raw",
    ephemeralSecret,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const [macA, macB] = await Promise.all([
    crypto.subtle.sign("HMAC", key, encoder.encode(a)),
    crypto.subtle.sign("HMAC", key, encoder.encode(b)),
  ]);

  const bytesA = new Uint8Array(macA);
  const bytesB = new Uint8Array(macB);
  let diff = bytesA.length ^ bytesB.length;
  const len = Math.min(bytesA.length, bytesB.length);
  for (let i = 0; i < len; i++) {
    diff |= bytesA[i] ^ bytesB[i];
  }
  return diff === 0;
}

/**
 * Normalizes a submitted invite code (trim + uppercase) and validates bounds.
 */
export function normalizeInviteCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const candidate = raw.trim().toUpperCase();
  if (!candidate || candidate.length > 64) {
    return null;
  }
  return candidate;
}

/**
 * Verifies a submitted invite code against a comma-separated list of valid codes
 * in `INVITE_CODES` without short-circuiting.
 */
export async function verifyInviteCodeConstantTime(
  submittedRaw: unknown,
  configuredCodesCsv: string | undefined
): Promise<boolean> {
  const candidate = normalizeInviteCode(submittedRaw);
  if (!candidate || !configuredCodesCsv) {
    return false;
  }

  const validCodes = configuredCodesCsv
    .split(",")
    .map((c) => c.trim().toUpperCase())
    .filter((c) => c.length > 0);

  if (validCodes.length === 0) {
    return false;
  }

  let matched = false;
  for (const valid of validCodes) {
    const isMatch = await timingSafeEqualStrings(candidate, valid);
    if (isMatch) {
      matched = true;
    }
  }
  return matched;
}

/**
 * Checks whether an email address is listed in a comma/semicolon/newline-separated
 * allowlist (e.g. `ADMIN_EMAILS`) using constant-time comparison without short-circuiting.
 */
export async function isEmailInAllowlist(
  email: string,
  allowlistRaw: string | undefined
): Promise<boolean> {
  const normalized = normalizeAndValidateEmail(email);
  if (!normalized || !allowlistRaw) {
    return false;
  }

  const allowedEmails = allowlistRaw
    .split(/[,;\n\r]+/)
    .map((entry) => entry.trim().toLowerCase())
    .filter((entry) => entry.length > 0);

  if (allowedEmails.length === 0) {
    return false;
  }

  let matched = false;
  for (const allowed of allowedEmails) {
    const isMatch = await timingSafeEqualStrings(normalized, allowed);
    if (isMatch) {
      matched = true;
    }
  }
  return matched;
}

// Visually unambiguous uppercase alphanumeric characters (omits 0, 1, I, L, O)
const INVITE_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

/**
 * Generates a cryptographically random one-time invite code (`RV-XXXX-XXXX-XXXX`,
 * ~59.4 bits of entropy) using CSPRNG rejection sampling.
 */
export function generateOneTimeInviteCode(): string {
  const alphabetLen = INVITE_CODE_ALPHABET.length; // 31
  const maxUnbiased = Math.floor(256 / alphabetLen) * alphabetLen; // 248
  const chars: string[] = [];
  const buf = new Uint8Array(16);

  while (chars.length < 12) {
    crypto.getRandomValues(buf);
    for (let i = 0; i < buf.length && chars.length < 12; i++) {
      if (buf[i] < maxUnbiased) {
        chars.push(INVITE_CODE_ALPHABET[buf[i] % alphabetLen]);
      }
    }
  }

  return `RV-${chars.slice(0, 4).join("")}-${chars.slice(4, 8).join("")}-${chars
    .slice(8, 12)
    .join("")}`;
}

/**
 * Generates a unique opaque invite record ID (`inv_<16-hex-chars>`).
 */
export function generateInviteId(): string {
  const bytes = new Uint8Array(8);
  crypto.getRandomValues(bytes);
  return `inv_${bytesToHex(bytes)}`;
}

/**
 * Produces a non-sensitive masked display hint for an invite code (e.g. `RV-7K4M-••••-••••`).
 */
export function buildInviteCodeHint(code: string): string {
  const parts = code.trim().toUpperCase().split("-");
  if (parts.length === 4 && parts[0] === "RV") {
    return `RV-${parts[1]}-••••-••••`;
  }
  if (code.length <= 4) {
    return "••••";
  }
  return `${code.slice(0, Math.min(7, code.length))}••••`;
}

/**
 * Generates an unbiased 6-digit numeric OTP ("000000" to "999999") using
 * CSPRNG rejection sampling.
 */
export function generateSixDigitOtp(): string {
  const maxUnbiased = 4_294_000_000; // Largest multiple of 1,000,000 < 2^32
  const buf = new Uint32Array(1);
  while (true) {
    crypto.getRandomValues(buf);
    const val = buf[0];
    if (val < maxUnbiased) {
      return (val % 1_000_000).toString().padStart(6, "0");
    }
  }
}

export function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) {
    out += bytes[i].toString(16).padStart(2, "0");
  }
  return out;
}
