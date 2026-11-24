import type { Env, KvStore } from "./types.ts";
import { HttpError } from "./types.ts";

export interface RateLimitConfig {
  maxDailyEmailsPerUser: number;
  maxHourlyEmailsPerIp: number;
  maxMinuteEmailsPerIp: number;
  maxDailyEmailsGlobal: number;
  otpCooldownSeconds: number;
}

export function parseRateLimitConfig(env: Env): RateLimitConfig {
  return {
    maxDailyEmailsPerUser: parsePositiveInt(env.MAX_DAILY_EMAILS_PER_USER, 12),
    maxHourlyEmailsPerIp: parsePositiveInt(env.MAX_HOURLY_EMAILS_PER_IP, 20),
    maxMinuteEmailsPerIp: parsePositiveInt(env.MAX_MINUTE_EMAILS_PER_IP, 5),
    maxDailyEmailsGlobal: parsePositiveInt(env.MAX_DAILY_EMAILS_GLOBAL, 150),
    otpCooldownSeconds: parsePositiveInt(env.OTP_COOLDOWN_SECONDS, 60),
  };
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (!raw) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function getUtcBuckets(now: Date) {
  const iso = now.toISOString(); // e.g. 2026-11-02T20:30:15.000Z
  return {
    dayBucket: iso.slice(0, 10), // YYYY-MM-DD
    hourBucket: iso.slice(0, 13), // YYYY-MM-DDTHH
    minuteBucket: iso.slice(0, 16), // YYYY-MM-DDTHH:mm
  };
}

async function readCounter(kv: KvStore, key: string): Promise<number> {
  const raw = await kv.get(key);
  if (!raw) return 0;
  const val = Number.parseInt(raw, 10);
  return Number.isFinite(val) && val >= 0 ? val : 0;
}

/**
 * Enforces per-IP request limits on `/api/auth/request-otp` before doing any
 * downstream Firebase lookups or email sends.
 */
export async function enforceAndRecordRequestIpLimit(
  kv: KvStore,
  ipHash: string,
  config: RateLimitConfig,
  now: Date = new Date()
): Promise<void> {
  const { hourBucket, minuteBucket } = getUtcBuckets(now);
  const minKey = `rl:req:ip:min:${minuteBucket}:${ipHash}`;
  const hourKey = `rl:req:ip:hr:${hourBucket}:${ipHash}`;

  const [minCount, hourCount] = await Promise.all([
    readCounter(kv, minKey),
    readCounter(kv, hourKey),
  ]);

  if (minCount >= config.maxMinuteEmailsPerIp) {
    throw new HttpError(
      429,
      "rate_limit_ip_minute",
      "Too many sign-in attempts from this network. Please wait a minute and try again.",
      60
    );
  }

  if (hourCount >= config.maxHourlyEmailsPerIp) {
    throw new HttpError(
      429,
      "rate_limit_ip_hour",
      "Hourly verification request limit reached for this network. Please try again later.",
      3600
    );
  }

  await Promise.all([
    kv.put(minKey, String(minCount + 1), { expirationTtl: 120 }),
    kv.put(hourKey, String(hourCount + 1), { expirationTtl: 7200 }),
  ]);
}

/**
 * Enforces per-IP throttling on `/api/auth/verify-otp` (max 15 checks/minute).
 */
export async function enforceAndRecordVerifyIpLimit(
  kv: KvStore,
  ipHash: string,
  now: Date = new Date()
): Promise<void> {
  const { minuteBucket } = getUtcBuckets(now);
  const key = `rl:verify:ip:min:${minuteBucket}:${ipHash}`;
  const count = await readCounter(kv, key);
  if (count >= 15) {
    throw new HttpError(
      429,
      "rate_limit_verify_ip",
      "Too many code verification attempts. Please wait a minute and try again.",
      60
    );
  }
  await kv.put(key, String(count + 1), { expirationTtl: 120 });
}

/**
 * Enforces per-IP throttling on admin endpoints (max 60 requests/minute).
 */
export async function enforceAndRecordAdminIpLimit(
  kv: KvStore,
  ipHash: string,
  now: Date = new Date()
): Promise<void> {
  const { minuteBucket } = getUtcBuckets(now);
  const key = `rl:admin:ip:min:${minuteBucket}:${ipHash}`;
  const count = await readCounter(kv, key);
  if (count >= 60) {
    throw new HttpError(
      429,
      "rate_limit_admin_ip",
      "Too many admin requests. Please wait a minute and try again.",
      60
    );
  }
  await kv.put(key, String(count + 1), { expirationTtl: 120 });
}

/**
 * Checks per-user cooldown (60s), per-user daily cap (12 emails/day), and
 * the global daily circuit breaker before sending an outbound OTP email.
 */
export async function checkEmailSendQuota(
  kv: KvStore,
  emailHash: string,
  config: RateLimitConfig,
  now: Date = new Date()
): Promise<{ userCount: number; globalCount: number; dayBucket: string }> {
  const { dayBucket } = getUtcBuckets(now);
  const cooldownKey = `rl:email:cooldown:${emailHash}`;
  const userDayKey = `rl:email:day:${dayBucket}:${emailHash}`;
  const globalDayKey = `rl:global:day:${dayBucket}`;

  const [cooldownRaw, userCount, globalCount] = await Promise.all([
    kv.get(cooldownKey),
    readCounter(kv, userDayKey),
    readCounter(kv, globalDayKey),
  ]);

  if (cooldownRaw) {
    const expiresAtMs = Number.parseInt(cooldownRaw, 10);
    const remainingSec = Number.isFinite(expiresAtMs)
      ? Math.max(1, Math.ceil((expiresAtMs - now.getTime()) / 1000))
      : config.otpCooldownSeconds;
    throw new HttpError(
      429,
      "rate_limit_email_cooldown",
      `Please wait ${remainingSec} seconds before requesting another code.`,
      remainingSec
    );
  }

  if (userCount >= config.maxDailyEmailsPerUser) {
    throw new HttpError(
      429,
      "rate_limit_user_daily",
      `You have reached the daily limit of ${config.maxDailyEmailsPerUser} verification emails. Please try again tomorrow.`,
      3600
    );
  }

  if (globalCount >= config.maxDailyEmailsGlobal) {
    throw new HttpError(
      429,
      "rate_limit_global_daily",
      "Daily verification email limit reached. Please try again later.",
      3600
    );
  }

  return { userCount, globalCount, dayBucket };
}

/**
 * Records that an outbound OTP email has been authorized for delivery, setting
 * the 60s per-user cooldown and incrementing per-user (max 12/day) and global counters.
 */
export async function commitEmailSendQuota(
  kv: KvStore,
  emailHash: string,
  quotaState: { userCount: number; globalCount: number; dayBucket: string },
  config: RateLimitConfig,
  now: Date = new Date()
): Promise<void> {
  const cooldownKey = `rl:email:cooldown:${emailHash}`;
  const userDayKey = `rl:email:day:${quotaState.dayBucket}:${emailHash}`;
  const globalDayKey = `rl:global:day:${quotaState.dayBucket}`;
  const expiresAtMs = now.getTime() + config.otpCooldownSeconds * 1000;

  await Promise.all([
    kv.put(cooldownKey, String(expiresAtMs), {
      expirationTtl: Math.max(60, config.otpCooldownSeconds),
    }),
    kv.put(userDayKey, String(quotaState.userCount + 1), {
      expirationTtl: 90_000, // 25 hours covers the full UTC day
    }),
    kv.put(globalDayKey, String(quotaState.globalCount + 1), {
      expirationTtl: 90_000,
    }),
  ]);
}
