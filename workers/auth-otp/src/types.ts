export interface EmailRecipient {
  email: string;
  name: string;
}

export interface OutboundEmailPayload {
  to: string | EmailRecipient | Array<string | EmailRecipient>;
  from: string | EmailRecipient;
  subject: string;
  text?: string;
  html?: string;
}

export interface SendEmailBinding {
  send(message: OutboundEmailPayload): Promise<{ messageId?: string } | void>;
}

export interface KvListKey {
  name: string;
  expiration?: number;
  metadata?: unknown;
}

export interface KvListResult {
  keys: KvListKey[];
  list_complete: boolean;
  cursor?: string;
}

export interface KvStore {
  get(key: string): Promise<string | null>;
  put(
    key: string,
    value: string,
    options?: { expirationTtl?: number; metadata?: Record<string, unknown> }
  ): Promise<void>;
  delete(key: string): Promise<void>;
  list?(options?: {
    prefix?: string;
    limit?: number;
    cursor?: string;
  }): Promise<KvListResult>;
}

export interface Env {
  EMAIL: SendEmailBinding;
  AUTH_OTP_KV: KvStore;

  // Encrypted Secrets (configured via `wrangler secret put ...`)
  INVITE_CODES?: string;
  ADMIN_EMAILS?: string;
  OTP_HMAC_SECRET: string;
  FIREBASE_SERVICE_ACCOUNT_JSON: string;
  TURNSTILE_SECRET_KEY?: string;

  // Plaintext Environment Variables (`wrangler.jsonc` vars)
  PUBLIC_APP_URL?: string;
  SENDER_EMAIL?: string;
  SENDER_NAME?: string;
  MAX_DAILY_EMAILS_PER_USER?: string;
  MAX_HOURLY_EMAILS_PER_IP?: string;
  MAX_MINUTE_EMAILS_PER_IP?: string;
  MAX_DAILY_EMAILS_GLOBAL?: string;
  OTP_COOLDOWN_SECONDS?: string;
  OTP_TTL_SECONDS?: string;
  MAX_OTP_ATTEMPTS?: string;
  REQUIRE_TURNSTILE?: string;
  ALLOWED_ORIGINS?: string;
}

export interface StoredOtpRecord {
  codeHash: string;
  attempts: number;
  createdAtMs: number;
  inviteCodeHash?: string;
}

export type InviteCodeStoredStatus = "active" | "used" | "revoked";
export type InviteCodeEffectiveStatus = "active" | "used" | "revoked" | "expired";

export interface StoredInviteRecord {
  id: string;
  codeHash: string;
  code: string | null;
  codeHint: string;
  label: string | null;
  status: InviteCodeStoredStatus;
  createdAt: string;
  createdByUid: string;
  createdByEmail: string;
  expiresAt: string | null;
  usedAt: string | null;
  usedByUid: string | null;
  usedByEmail: string | null;
  revokedAt: string | null;
  revokedByUid: string | null;
  revokedByEmail: string | null;
}

export interface AdminInviteResponseItem {
  id: string;
  code: string | null;
  codeHint: string;
  inviteUrl: string | null;
  label: string | null;
  status: InviteCodeEffectiveStatus;
  createdAt: string;
  createdByUid: string;
  createdByEmail: string;
  expiresAt: string | null;
  usedAt: string | null;
  usedByUid: string | null;
  usedByEmail: string | null;
  revokedAt: string | null;
  revokedByUid: string | null;
  revokedByEmail: string | null;
}

export interface CreateInviteBody {
  label?: string;
  expiresInDays?: number | null;
  count?: number;
}

export type AuthMode = "login" | "join";

export interface RequestOtpBody {
  mode: AuthMode;
  email: string;
  inviteCode?: string;
  turnstileToken?: string;
}

export interface VerifyOtpBody {
  email: string;
  code: string;
}

export interface ClaimInviteBody {
  idToken?: string;
  inviteCode: string;
  turnstileToken?: string;
}

export class HttpError extends Error {
  public readonly status: number;
  public readonly code: string;
  public readonly retryAfterSeconds?: number;

  constructor(
    status: number,
    code: string,
    message: string,
    retryAfterSeconds?: number
  ) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}
