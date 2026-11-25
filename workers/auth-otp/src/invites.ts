import {
  buildInviteCodeHint,
  generateInviteId,
  generateOneTimeInviteCode,
  hmacSha256Hex,
  normalizeInviteCode,
  verifyInviteCodeConstantTime,
} from "./crypto.ts";
import type {
  AdminInviteResponseItem,
  CreateInviteBody,
  Env,
  InviteCodeEffectiveStatus,
  KvStore,
  StoredInviteRecord,
} from "./types.ts";
import { HttpError } from "./types.ts";

export const INVITE_CODE_KEY_PREFIX = "invite:code:";
export const INVITE_ID_KEY_PREFIX = "invite:id:";

const MAX_LABEL_LENGTH = 80;
const MAX_BATCH_CREATE_COUNT = 20;
const MAX_EXPIRY_DAYS = 365;
const DEFAULT_EXPIRY_DAYS = 30;
const MAX_LIST_PAGES = 5;

export interface AdminActor {
  uid: string;
  email: string;
}

export type ResolvedInvite =
  | { kind: "one_time"; codeHash: string; record: StoredInviteRecord }
  | { kind: "static" };

function stripTrailingSlashes(value: string): string {
  let end = value.length;
  while (end > 0 && value[end - 1] === "/") {
    end--;
  }
  return end === value.length ? value : value.slice(0, end);
}

export function getPublicAppUrl(env: Env): string {
  const raw = env.PUBLIC_APP_URL?.trim() || "https://robovolunteers.link";
  return stripTrailingSlashes(raw);
}

export function buildInviteUrl(code: string, appBaseUrl: string): string {
  const cleanBase = stripTrailingSlashes(appBaseUrl);
  return `${cleanBase}/?invite=${encodeURIComponent(code)}`;
}

export function isInviteExpired(
  record: Pick<StoredInviteRecord, "status" | "expiresAt">,
  now: Date
): boolean {
  if (record.status !== "active" || !record.expiresAt) {
    return false;
  }
  const expiresMs = Date.parse(record.expiresAt);
  return Number.isFinite(expiresMs) && now.getTime() >= expiresMs;
}

export function getEffectiveInviteStatus(
  record: Pick<StoredInviteRecord, "status" | "expiresAt">,
  now: Date
): InviteCodeEffectiveStatus {
  if (isInviteExpired(record, now)) {
    return "expired";
  }
  return record.status;
}

function clampStr(val: string | null | undefined, maxLen: number): string | null {
  if (!val) return null;
  return val.length > maxLen ? val.slice(0, maxLen) : val;
}

/**
 * Compact JSON metadata persisted alongside the KV entry so `KV.list()` can return
 * the full admin invite table in a single subrequest (strictly under Cloudflare's 1024B limit).
 */
export function toInviteMetadata(record: StoredInviteRecord): Record<string, unknown> {
  return {
    id: record.id,
    codeHash: record.codeHash,
    code:
      record.status === "active" || record.status === "revoked"
        ? record.code
        : null,
    codeHint: record.codeHint,
    label: clampStr(record.label, MAX_LABEL_LENGTH),
    status: record.status,
    createdAt: record.createdAt,
    createdByUid: clampStr(record.createdByUid, 128) ?? "",
    createdByEmail: clampStr(record.createdByEmail, 100) ?? "",
    expiresAt: record.expiresAt,
    usedAt: record.usedAt,
    usedByUid: clampStr(record.usedByUid, 128),
    usedByEmail: clampStr(record.usedByEmail, 100),
    revokedAt: record.revokedAt,
    revokedByUid: clampStr(record.revokedByUid, 128),
    revokedByEmail: clampStr(record.revokedByEmail, 100),
  };
}

export function toAdminInviteItem(
  record: StoredInviteRecord,
  appBaseUrl: string,
  now: Date
): AdminInviteResponseItem {
  const status = getEffectiveInviteStatus(record, now);
  const hasCode = typeof record.code === "string" && record.code.length > 0;
  const exposeCode = (status === "active" || status === "revoked") && hasCode;
  const exposeUrl = status === "active" && hasCode;
  return {
    id: record.id,
    code: exposeCode ? record.code : null,
    codeHint: record.codeHint,
    inviteUrl: exposeUrl && record.code ? buildInviteUrl(record.code, appBaseUrl) : null,
    label: record.label,
    status,
    createdAt: record.createdAt,
    createdByUid: record.createdByUid,
    createdByEmail: record.createdByEmail,
    expiresAt: record.expiresAt,
    usedAt: record.usedAt,
    usedByUid: record.usedByUid,
    usedByEmail: record.usedByEmail,
    revokedAt: record.revokedAt,
    revokedByUid: record.revokedByUid,
    revokedByEmail: record.revokedByEmail,
  };
}

function isValidStoredInviteRecord(val: unknown): val is StoredInviteRecord {
  if (!val || typeof val !== "object" || Array.isArray(val)) return false;
  const obj = val as Record<string, unknown>;
  return (
    typeof obj.id === "string" &&
    typeof obj.codeHash === "string" &&
    typeof obj.codeHint === "string" &&
    (obj.status === "active" || obj.status === "used" || obj.status === "revoked") &&
    typeof obj.createdAt === "string"
  );
}

export async function saveInviteRecord(
  kv: KvStore,
  record: StoredInviteRecord
): Promise<void> {
  await kv.put(
    `${INVITE_CODE_KEY_PREFIX}${record.codeHash}`,
    JSON.stringify(record),
    { metadata: toInviteMetadata(record) }
  );
}

export async function getInviteRecordByHash(
  kv: KvStore,
  codeHash: string
): Promise<StoredInviteRecord | null> {
  const raw = await kv.get(`${INVITE_CODE_KEY_PREFIX}${codeHash}`);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    return isValidStoredInviteRecord(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

export async function createOneTimeInvites(
  kv: KvStore,
  hmacSecret: string,
  admin: AdminActor,
  body: Partial<CreateInviteBody>,
  now: Date,
  appBaseUrl: string
): Promise<AdminInviteResponseItem[]> {
  let count = 1;
  if (body.count !== undefined) {
    if (
      typeof body.count !== "number" ||
      !Number.isInteger(body.count) ||
      body.count < 1 ||
      body.count > MAX_BATCH_CREATE_COUNT
    ) {
      throw new HttpError(
        400,
        "invalid_count",
        `Count must be an integer between 1 and ${MAX_BATCH_CREATE_COUNT}.`
      );
    }
    count = body.count;
  }

  let baseLabel: string | null = null;
  if (body.label !== undefined && body.label !== null) {
    if (typeof body.label !== "string") {
      throw new HttpError(400, "invalid_label", "Label must be a string.");
    }
    const trimmed = body.label.trim();
    if (trimmed.length > MAX_LABEL_LENGTH) {
      throw new HttpError(
        400,
        "invalid_label",
        `Label must be ${MAX_LABEL_LENGTH} characters or fewer.`
      );
    }
    baseLabel = trimmed.length > 0 ? trimmed : null;
  }

  let expiresAt: string | null = null;
  if (body.expiresInDays === null) {
    expiresAt = null;
  } else {
    const days =
      body.expiresInDays === undefined ? DEFAULT_EXPIRY_DAYS : body.expiresInDays;
    if (
      typeof days !== "number" ||
      !Number.isInteger(days) ||
      days < 1 ||
      days > MAX_EXPIRY_DAYS
    ) {
      throw new HttpError(
        400,
        "invalid_expiry",
        `Expiry must be between 1 and ${MAX_EXPIRY_DAYS} days (or null for no expiry).`
      );
    }
    expiresAt = new Date(now.getTime() + days * 86_400_000).toISOString();
  }

  const createdAt = now.toISOString();
  const createdItems: AdminInviteResponseItem[] = [];

  for (let i = 0; i < count; i++) {
    let code = "";
    let codeHash = "";
    for (let attempt = 0; attempt < 5; attempt++) {
      const candidate = generateOneTimeInviteCode();
      const candidateHash = await hmacSha256Hex(hmacSecret, `invite:${candidate}`);
      const existing = await kv.get(`${INVITE_CODE_KEY_PREFIX}${candidateHash}`);
      if (!existing) {
        code = candidate;
        codeHash = candidateHash;
        break;
      }
    }
    if (!code || !codeHash) {
      throw new HttpError(
        500,
        "invite_generation_failed",
        "Unable to generate a unique invite code. Please try again."
      );
    }

    let itemLabel = baseLabel;
    if (baseLabel && count > 1) {
      const suffix = ` (${i + 1}/${count})`;
      const maxBase = MAX_LABEL_LENGTH - suffix.length;
      itemLabel = `${baseLabel.slice(0, maxBase)}${suffix}`;
    }

    const record: StoredInviteRecord = {
      id: generateInviteId(),
      codeHash,
      code,
      codeHint: buildInviteCodeHint(code),
      label: itemLabel,
      status: "active",
      createdAt,
      createdByUid: admin.uid,
      createdByEmail: admin.email,
      expiresAt,
      usedAt: null,
      usedByUid: null,
      usedByEmail: null,
      revokedAt: null,
      revokedByUid: null,
      revokedByEmail: null,
    };

    await Promise.all([
      saveInviteRecord(kv, record),
      kv.put(`${INVITE_ID_KEY_PREFIX}${record.id}`, codeHash),
    ]);

    createdItems.push(toAdminInviteItem(record, appBaseUrl, now));
  }

  return createdItems;
}

export async function listOneTimeInvites(
  kv: KvStore,
  now: Date,
  appBaseUrl: string
): Promise<AdminInviteResponseItem[]> {
  if (!kv.list) {
    return [];
  }

  const records: StoredInviteRecord[] = [];
  let cursor: string | undefined;

  for (let page = 0; page < MAX_LIST_PAGES; page++) {
    const res = await kv.list({
      prefix: INVITE_CODE_KEY_PREFIX,
      limit: 1000,
      ...(cursor ? { cursor } : {}),
    });

    for (const key of res.keys) {
      if (isValidStoredInviteRecord(key.metadata)) {
        records.push(key.metadata);
      } else {
        const raw = await kv.get(key.name);
        if (raw) {
          try {
            const parsed = JSON.parse(raw) as unknown;
            if (isValidStoredInviteRecord(parsed)) {
              records.push(parsed);
            }
          } catch {
            // Skip malformed KV entry
          }
        }
      }
    }

    if (res.list_complete || !res.cursor) {
      break;
    }
    cursor = res.cursor;
  }

  records.sort((a, b) => Date.parse(b.createdAt) - Date.parse(a.createdAt));
  return records.map((rec) => toAdminInviteItem(rec, appBaseUrl, now));
}

export async function revokeOneTimeInvite(
  kv: KvStore,
  inviteId: string,
  admin: AdminActor,
  now: Date,
  appBaseUrl: string
): Promise<AdminInviteResponseItem> {
  if (!/^inv_[a-f0-9]{8,64}$/i.test(inviteId)) {
    throw new HttpError(404, "invite_not_found", "Invitation code not found.");
  }

  const codeHash = await kv.get(`${INVITE_ID_KEY_PREFIX}${inviteId}`);
  if (!codeHash) {
    throw new HttpError(404, "invite_not_found", "Invitation code not found.");
  }

  const record = await getInviteRecordByHash(kv, codeHash);
  if (!record) {
    throw new HttpError(404, "invite_not_found", "Invitation code not found.");
  }

  if (record.status === "used") {
    throw new HttpError(
      409,
      "invite_already_used",
      "This invitation code has already been used and cannot be revoked."
    );
  }

  if (record.status === "revoked") {
    return toAdminInviteItem(record, appBaseUrl, now);
  }

  const updated: StoredInviteRecord = {
    ...record,
    status: "revoked",
    revokedAt: now.toISOString(),
    revokedByUid: admin.uid,
    revokedByEmail: admin.email,
  };

  await saveInviteRecord(kv, updated);
  return toAdminInviteItem(updated, appBaseUrl, now);
}

function assertInviteActive(record: StoredInviteRecord, now: Date): void {
  if (record.status === "used") {
    throw new HttpError(
      403,
      "invite_code_used",
      "This invitation code has already been used. If you already registered, switch to Sign In, or ask an administrator for a new invite link."
    );
  }
  if (record.status === "revoked") {
    throw new HttpError(
      403,
      "invalid_invite_code",
      "Invalid invitation code. Access to RoboVolunteers is invite-only."
    );
  }
  if (isInviteExpired(record, now)) {
    throw new HttpError(
      403,
      "invite_code_expired",
      "This invitation code has expired. Please ask an administrator for a new invite link."
    );
  }
}

/**
 * Validates a submitted invite code against admin-generated one-time codes in KV,
 * falling back to legacy static `INVITE_CODES` if configured.
 */
export async function validateInviteCodeForJoin(
  submittedRaw: unknown,
  env: Env,
  now: Date
): Promise<ResolvedInvite> {
  const normalized = normalizeInviteCode(submittedRaw);
  if (!normalized) {
    throw new HttpError(
      403,
      "invalid_invite_code",
      "Invalid invitation code. Access to RoboVolunteers is invite-only."
    );
  }

  const codeHash = await hmacSha256Hex(env.OTP_HMAC_SECRET, `invite:${normalized}`);
  const oneTimeRecord = await getInviteRecordByHash(env.AUTH_OTP_KV, codeHash);

  if (oneTimeRecord) {
    assertInviteActive(oneTimeRecord, now);
    return { kind: "one_time", codeHash, record: oneTimeRecord };
  }

  const staticMatch = await verifyInviteCodeConstantTime(
    normalized,
    env.INVITE_CODES
  );
  if (staticMatch) {
    return { kind: "static" };
  }

  throw new HttpError(
    403,
    "invalid_invite_code",
    "Invalid invitation code. Access to RoboVolunteers is invite-only."
  );
}

/**
 * Re-validates a one-time invite code by hash and marks it as single-use `used`.
 * Returns the previous active record so callers can roll back on transient upstream failures.
 */
export async function consumeOneTimeInviteByHash(
  kv: KvStore,
  codeHash: string,
  volunteer: { uid: string; email: string },
  now: Date
): Promise<StoredInviteRecord> {
  const existing = await getInviteRecordByHash(kv, codeHash);
  if (!existing) {
    throw new HttpError(
      403,
      "invalid_invite_code",
      "Invalid invitation code. Access to RoboVolunteers is invite-only."
    );
  }

  assertInviteActive(existing, now);

  const redeemed: StoredInviteRecord = {
    ...existing,
    code: null,
    status: "used",
    usedAt: now.toISOString(),
    usedByUid: volunteer.uid,
    usedByEmail: volunteer.email || null,
  };

  await saveInviteRecord(kv, redeemed);
  return existing;
}
