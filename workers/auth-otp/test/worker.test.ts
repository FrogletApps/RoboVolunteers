import { describe, it, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { handleWorkerRequest } from "../src/index.ts";
import {
  clearCachedGoogleOAuthTokenForTests,
  FIREBASE_SECURETOKEN_JWKS_URL,
} from "../src/firebaseAdmin.ts";
import type { Env, KvStore, OutboundEmailPayload } from "../src/types.ts";

class MemoryKv implements KvStore {
  private store = new Map<string, { value: string; expiresAtMs?: number }>();
  public nowMs: () => number;

  constructor(nowMs: () => number) {
    this.nowMs = nowMs;
  }

  async get(key: string): Promise<string | null> {
    const item = this.store.get(key);
    if (!item) return null;
    if (item.expiresAtMs !== undefined && this.nowMs() >= item.expiresAtMs) {
      this.store.delete(key);
      return null;
    }
    return item.value;
  }

  async put(
    key: string,
    value: string,
    options?: { expirationTtl?: number }
  ): Promise<void> {
    const expiresAtMs = options?.expirationTtl
      ? this.nowMs() + options.expirationTtl * 1000
      : undefined;
    this.store.set(key, { value, expiresAtMs });
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }
}

async function generateTestServiceAccountJson(): Promise<string> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"]
  );
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", keyPair.privateKey);
  const bytes = new Uint8Array(pkcs8);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  const b64 = btoa(binary);
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----`;
  return JSON.stringify({
    project_id: "roboref-test",
    client_email: "firebase-adminsdk@roboref-test.iam.gserviceaccount.com",
    private_key: pem,
  });
}

describe("RoboVolunteers Auth OTP Cloudflare Worker", () => {
  let currentTimeMs: number;
  let kv: MemoryKv;
  let sentEmails: OutboundEmailPayload[];
  let registeredFirebaseUsers: Map<
    string,
    { uid: string; emailVerified: boolean; inviteVerified: boolean }
  >;
  let serviceAccountJson: string;
  let secureTokenKeyPair: CryptoKeyPair;
  let secureTokenPublicJwk: JsonWebKey & { kid: string };

  beforeEach(async () => {
    clearCachedGoogleOAuthTokenForTests();
    currentTimeMs = Date.parse("2026-11-02T09:00:00.000Z");
    kv = new MemoryKv(() => currentTimeMs);
    sentEmails = [];
    registeredFirebaseUsers = new Map();
    serviceAccountJson = await generateTestServiceAccountJson();
    secureTokenKeyPair = await crypto.subtle.generateKey(
      {
        name: "RSASSA-PKCS1-v1_5",
        modulusLength: 2048,
        publicExponent: new Uint8Array([1, 0, 1]),
        hash: "SHA-256",
      },
      true,
      ["sign", "verify"]
    );
    const pubJwk = await crypto.subtle.exportKey(
      "jwk",
      secureTokenKeyPair.publicKey
    );
    secureTokenPublicJwk = { ...pubJwk, kid: "test-google-kid-1" };
  });

  async function mintMockFirebaseIdToken(overrides: Record<string, unknown> = {}): Promise<string> {
    const b64url = (bytes: Uint8Array) => {
      let bin = "";
      for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
      return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
    };
    const enc = new TextEncoder();
    const nowSec = Math.floor(currentTimeMs / 1000);
    const header = b64url(
      enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT", kid: "test-google-kid-1" }))
    );
    const payload = b64url(
      enc.encode(
        JSON.stringify({
          iss: "https://securetoken.google.com/roboref-test",
          aud: "roboref-test",
          sub: "google-uid-42",
          email: "google-vol@example.org",
          email_verified: true,
          iat: nowSec,
          exp: nowSec + 3600,
          ...overrides,
        })
      )
    );
    const signingInput = `${header}.${payload}`;
    const sig = await crypto.subtle.sign(
      "RSASSA-PKCS1-v1_5",
      secureTokenKeyPair.privateKey,
      enc.encode(signingInput)
    );
    return `${signingInput}.${b64url(new Uint8Array(sig))}`;
  }

  function createEnv(overrides: Partial<Env> = {}): Env {
    return {
      EMAIL: {
        async send(msg: OutboundEmailPayload) {
          sentEmails.push(msg);
          return { messageId: `msg-${sentEmails.length}` };
        },
      },
      AUTH_OTP_KV: kv,
      INVITE_CODES: "UKVEX-2026, VEX-REF-UK",
      OTP_HMAC_SECRET: "test-hmac-secret-32-bytes-minimum-key",
      FIREBASE_SERVICE_ACCOUNT_JSON: serviceAccountJson,
      TURNSTILE_SECRET_KEY: "turnstile-secret",
      REQUIRE_TURNSTILE: "true",
      SENDER_EMAIL: "noreply@roboref.app",
      SENDER_NAME: "RoboVolunteers",
      MAX_DAILY_EMAILS_PER_USER: "12",
      MAX_HOURLY_EMAILS_PER_IP: "100",
      MAX_MINUTE_EMAILS_PER_IP: "20",
      MAX_DAILY_EMAILS_GLOBAL: "150",
      OTP_COOLDOWN_SECONDS: "60",
      OTP_TTL_SECONDS: "600",
      MAX_OTP_ATTEMPTS: "5",
      ALLOWED_ORIGINS: "https://volunteer.roboref.app",
      ...overrides,
    };
  }

  function createMockFetch(): typeof fetch {
    return (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input.toString();

      if (url.includes("turnstile/v0/siteverify")) {
        const params = new URLSearchParams(String(init?.body ?? ""));
        const ok = params.get("response") === "valid-turnstile";
        return new Response(JSON.stringify({ success: ok }), { status: 200 });
      }

      if (url === FIREBASE_SECURETOKEN_JWKS_URL) {
        return new Response(
          JSON.stringify({ keys: [secureTokenPublicJwk] }),
          {
            status: 200,
            headers: { "Cache-Control": "public, max-age=3600" },
          }
        );
      }

      if (url === "https://oauth2.googleapis.com/token") {
        return new Response(
          JSON.stringify({ access_token: "mock-google-oauth", expires_in: 3600 }),
          { status: 200 }
        );
      }

      if (url.endsWith("/accounts:lookup")) {
        const body = JSON.parse(String(init?.body ?? "{}")) as { email: string[] };
        const email = body.email[0];
        const user = registeredFirebaseUsers.get(email);
        if (!user) {
          return new Response(JSON.stringify({}), { status: 200 });
        }
        return new Response(
          JSON.stringify({
            users: [
              {
                localId: user.uid,
                email,
                emailVerified: user.emailVerified,
                customAttributes: JSON.stringify({
                  inviteVerified: user.inviteVerified,
                }),
              },
            ],
          }),
          { status: 200 }
        );
      }

      if (url.endsWith("/accounts")) {
        const body = JSON.parse(String(init?.body ?? "{}")) as { email: string };
        const uid = `uid-${registeredFirebaseUsers.size + 1}`;
        registeredFirebaseUsers.set(body.email, {
          uid,
          emailVerified: true,
          inviteVerified: false,
        });
        return new Response(JSON.stringify({ localId: uid }), { status: 200 });
      }

      if (url.endsWith("/accounts:update")) {
        const body = JSON.parse(String(init?.body ?? "{}")) as {
          localId: string;
          customAttributes: string;
        };
        for (const [email, u] of registeredFirebaseUsers.entries()) {
          if (u.uid === body.localId) {
            const attrs = JSON.parse(body.customAttributes) as {
              inviteVerified?: boolean;
            };
            registeredFirebaseUsers.set(email, {
              ...u,
              emailVerified: true,
              inviteVerified: Boolean(attrs.inviteVerified),
            });
          }
        }
        return new Response(JSON.stringify({ localId: body.localId }), {
          status: 200,
        });
      }

      return new Response("Unhandled mock URL: " + url, { status: 500 });
    }) as typeof fetch;
  }

  function extractOtpFromLastEmail(): string {
    const last = sentEmails[sentEmails.length - 1];
    const match = last?.subject.match(/^(\d{6})\b/);
    if (!match) throw new Error("No 6-digit OTP found in sent email");
    return match[1];
  }

  it("blocks invalid invite codes BEFORE sending any email", async () => {
    const env = createEnv();
    const res = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.10",
          Origin: "https://volunteer.roboref.app",
        },
        body: JSON.stringify({
          mode: "join",
          email: "new.ref@example.co.uk",
          inviteCode: "WRONG-CODE",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      { fetchImpl: createMockFetch(), now: () => new Date(currentTimeMs) }
    );

    assert.equal(res.status, 403);
    assert.equal(sentEmails.length, 0);
  });

  it("completes full invite + 6-digit OTP flow, mints custom token, and prevents OTP replay", async () => {
    const env = createEnv();
    const deps = {
      fetchImpl: createMockFetch(),
      now: () => new Date(currentTimeMs),
    };

    const reqRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.11",
        },
        body: JSON.stringify({
          mode: "join",
          email: "Jane.Ref@example.co.uk",
          inviteCode: "ukvex-2026",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      deps
    );

    assert.equal(reqRes.status, 200);
    assert.equal(sentEmails.length, 1);
    assert.equal(sentEmails[0].to, "jane.ref@example.co.uk");
    assert.deepEqual(sentEmails[0].from, {
      email: "noreply@roboref.app",
      name: "RoboVolunteers",
    });
    const otp = extractOtpFromLastEmail();

    const verifyRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/verify-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.11",
        },
        body: JSON.stringify({
          email: "jane.ref@example.co.uk",
          code: otp,
        }),
      }),
      env,
      deps
    );

    assert.equal(verifyRes.status, 200);
    const data = (await verifyRes.json()) as {
      ok: boolean;
      uid: string;
      customToken: string;
    };
    assert.equal(data.ok, true);
    assert.equal(data.uid, "uid-1");
    assert.equal(data.customToken.split(".").length, 3);

    // Decode JWT payload to verify custom claims
    const payloadJson = JSON.parse(
      Buffer.from(data.customToken.split(".")[1], "base64url").toString("utf8")
    ) as { uid: string; claims: { inviteVerified: boolean } };
    assert.equal(payloadJson.uid, "uid-1");
    assert.equal(payloadJson.claims.inviteVerified, true);

    // Replay with the same OTP must fail (single-use)
    const replayRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/verify-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.11",
        },
        body: JSON.stringify({
          email: "jane.ref@example.co.uk",
          code: otp,
        }),
      }),
      env,
      deps
    );
    assert.equal(replayRes.status, 401);
  });

  it("does not send email or leak account existence for unregistered login emails", async () => {
    const env = createEnv();
    const res = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.12",
        },
        body: JSON.stringify({
          mode: "login",
          email: "stranger@example.com",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      { fetchImpl: createMockFetch(), now: () => new Date(currentTimeMs) }
    );

    assert.equal(res.status, 200);
    assert.equal(sentEmails.length, 0);
  });

  it("enforces 60s cooldown and strict 12 emails/day per-person limit", async () => {
    const env = createEnv();
    registeredFirebaseUsers.set("alex@example.org", {
      uid: "uid-alex",
      emailVerified: true,
      inviteVerified: true,
    });
    const deps = {
      fetchImpl: createMockFetch(),
      now: () => new Date(currentTimeMs),
    };

    const sendRequest = (ipSuffix: number) =>
      handleWorkerRequest(
        new Request("https://roboref.app/api/auth/request-otp", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "CF-Connecting-IP": `198.51.100.${ipSuffix}`,
          },
          body: JSON.stringify({
            mode: "login",
            email: "alex@example.org",
            turnstileToken: "valid-turnstile",
          }),
        }),
        env,
        deps
      );

    // 1st request succeeds
    const r1 = await sendRequest(1);
    assert.equal(r1.status, 200);
    assert.equal(sentEmails.length, 1);

    // Immediate retry within 60s is blocked by cooldown
    currentTimeMs += 15_000;
    const rCooldown = await sendRequest(1);
    assert.equal(rCooldown.status, 429);
    const cooldownJson = (await rCooldown.json()) as { error: string };
    assert.equal(cooldownJson.error, "rate_limit_email_cooldown");
    assert.equal(sentEmails.length, 1);

    // Advance >60s each time up to 12 total emails in the day
    for (let i = 2; i <= 12; i++) {
      currentTimeMs += 65_000;
      const res = await sendRequest(i);
      assert.equal(res.status, 200);
      assert.equal(sentEmails.length, i);
    }

    // 13th email on the same UTC day is rejected by the 12/day per-user limit
    currentTimeMs += 65_000;
    const r13 = await sendRequest(13);
    assert.equal(r13.status, 429);
    const limitJson = (await r13.json()) as { error: string; message: string };
    assert.equal(limitJson.error, "rate_limit_user_daily");
    assert.match(limitJson.message, /12/);
    assert.equal(sentEmails.length, 12);
  });

  it("enforces global daily circuit breaker before calling env.EMAIL.send()", async () => {
    const env = createEnv({ MAX_DAILY_EMAILS_GLOBAL: "2" });
    const deps = {
      fetchImpl: createMockFetch(),
      now: () => new Date(currentTimeMs),
    };

    for (let i = 1; i <= 2; i++) {
      const res = await handleWorkerRequest(
        new Request("https://roboref.app/api/auth/request-otp", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "CF-Connecting-IP": `203.0.113.${70 + i}`,
          },
          body: JSON.stringify({
            mode: "join",
            email: `vol${i}@example.org`,
            inviteCode: "UKVEX-2026",
            turnstileToken: "valid-turnstile",
          }),
        }),
        env,
        deps
      );
      assert.equal(res.status, 200);
    }

    const thirdRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.99",
        },
        body: JSON.stringify({
          mode: "join",
          email: "vol3@example.org",
          inviteCode: "UKVEX-2026",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      deps
    );
    assert.equal(thirdRes.status, 429);
    const errJson = (await thirdRes.json()) as { error: string };
    assert.equal(errJson.error, "rate_limit_global_daily");
    assert.equal(sentEmails.length, 2);
  });

  it("locks out and deletes OTP after 5 wrong verification guesses", async () => {
    const env = createEnv();
    const deps = {
      fetchImpl: createMockFetch(),
      now: () => new Date(currentTimeMs),
    };

    await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.50",
        },
        body: JSON.stringify({
          mode: "join",
          email: "sam@example.org",
          inviteCode: "VEX-REF-UK",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      deps
    );

    const realOtp = extractOtpFromLastEmail();
    const wrongOtp = realOtp === "000000" ? "999999" : "000000";

    for (let attempt = 1; attempt <= 5; attempt++) {
      const badRes = await handleWorkerRequest(
        new Request("https://roboref.app/api/auth/verify-otp", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "CF-Connecting-IP": "203.0.113.50",
          },
          body: JSON.stringify({ email: "sam@example.org", code: wrongOtp }),
        }),
        env,
        deps
      );
      assert.equal(badRes.status, 401);
    }

    // Even the real code on attempt #6 must fail because the OTP was purged
    const sixthRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/verify-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.50",
        },
        body: JSON.stringify({ email: "sam@example.org", code: realOtp }),
      }),
      env,
      deps
    );
    assert.equal(sixthRes.status, 401);
  });

  it("verifies Google Firebase ID Token + invite code on /api/auth/claim-invite and rejects wrong invite or forged token", async () => {
    const env = createEnv({ REQUIRE_TURNSTILE: "false" });
    registeredFirebaseUsers.set("google-vol@example.org", {
      uid: "google-uid-42",
      emailVerified: true,
      inviteVerified: false,
    });

    const deps = {
      fetchImpl: createMockFetch(),
      now: () => new Date(currentTimeMs),
    };

    const validIdToken = await mintMockFirebaseIdToken();

    // 1. Wrong invite code must be rejected with 403 before touching Firebase claims
    const wrongInviteRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/claim-invite", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${validIdToken}`,
          "CF-Connecting-IP": "203.0.113.77",
        },
        body: JSON.stringify({ inviteCode: "WRONG-CODE" }),
      }),
      env,
      deps
    );
    assert.equal(wrongInviteRes.status, 403);
    assert.equal(
      registeredFirebaseUsers.get("google-vol@example.org")?.inviteVerified,
      false
    );

    // 2. Wrong project audience token must be rejected with 401 even with valid invite code
    const wrongAudToken = await mintMockFirebaseIdToken({
      aud: "other-project",
      iss: "https://securetoken.google.com/other-project",
    });
    const wrongAudRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/claim-invite", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${wrongAudToken}`,
          "CF-Connecting-IP": "203.0.113.77",
        },
        body: JSON.stringify({ inviteCode: "UKVEX-2026" }),
      }),
      env,
      deps
    );
    assert.equal(wrongAudRes.status, 401);

    // 3. Valid Google ID token + valid invite code stamps inviteVerified: true and sends 0 emails
    const okRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/claim-invite", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${validIdToken}`,
          Origin: "http://localhost:54321",
          "CF-Connecting-IP": "203.0.113.77",
        },
        body: JSON.stringify({ inviteCode: "ukvex-2026" }),
      }),
      createEnv({
        REQUIRE_TURNSTILE: "false",
        ALLOWED_ORIGINS: "https://volunteer.roboref.app,http://localhost:5000",
      }),
      deps
    );
    assert.equal(okRes.status, 200);
    assert.equal(
      okRes.headers.get("Access-Control-Allow-Origin"),
      "http://localhost:54321"
    );
    const okJson = (await okRes.json()) as {
      ok: boolean;
      uid: string;
      email: string;
    };
    assert.equal(okJson.ok, true);
    assert.equal(okJson.uid, "google-uid-42");
    assert.equal(okJson.email, "google-vol@example.org");
    assert.equal(
      registeredFirebaseUsers.get("google-vol@example.org")?.inviteVerified,
      true
    );
    assert.equal(sentEmails.length, 0);
  });

  it("allows robovolunteers.link, wildcard origins (*.robovolunteers.link, *.workers.dev, *.roboref.app), and local development IPs in CORS", async () => {
    const corsEnv = createEnv({
      ALLOWED_ORIGINS:
        "https://robovolunteers.link,https://*.robovolunteers.link,https://*.roboref.app,https://*.james-pearson.workers.dev,http://localhost:5000",
    });
    const deps = {
      now: () => new Date(currentTimeMs),
    };

    // 0a. Apex robovolunteers.link origin
    const apexRes = await handleWorkerRequest(
      new Request("https://roboref-volunteer-auth-otp.james-pearson.workers.dev/api/auth/request-otp", {
        method: "OPTIONS",
        headers: {
          Origin: "https://robovolunteers.link",
          "Access-Control-Request-Method": "POST",
        },
      }),
      corsEnv,
      deps
    );
    assert.equal(
      apexRes.headers.get("Access-Control-Allow-Origin"),
      "https://robovolunteers.link"
    );

    // 0b. Wildcard robovolunteers.link subdomain (e.g. test.robovolunteers.link)
    const testSubRes = await handleWorkerRequest(
      new Request("https://roboref-volunteer-auth-otp.james-pearson.workers.dev/api/auth/request-otp", {
        method: "OPTIONS",
        headers: {
          Origin: "https://test.robovolunteers.link",
          "Access-Control-Request-Method": "POST",
        },
      }),
      corsEnv,
      deps
    );
    assert.equal(
      testSubRes.headers.get("Access-Control-Allow-Origin"),
      "https://test.robovolunteers.link"
    );

    // 1. Matching wildcard worker subdomain
    const workerRes = await handleWorkerRequest(
      new Request("https://roboref-volunteer-auth-otp.james-pearson.workers.dev/api/auth/request-otp", {
        method: "OPTIONS",
        headers: {
          Origin: "https://roboref-volunteer-hub.james-pearson.workers.dev",
          "Access-Control-Request-Method": "POST",
        },
      }),
      corsEnv,
      deps
    );
    assert.equal(
      workerRes.headers.get("Access-Control-Allow-Origin"),
      "https://roboref-volunteer-hub.james-pearson.workers.dev"
    );

    // 2. Matching wildcard roboref subdomain
    const appRes = await handleWorkerRequest(
      new Request("https://roboref-volunteer-auth-otp.james-pearson.workers.dev/api/auth/request-otp", {
        method: "OPTIONS",
        headers: {
          Origin: "https://volunteer.roboref.app",
          "Access-Control-Request-Method": "POST",
        },
      }),
      corsEnv,
      deps
    );
    assert.equal(
      appRes.headers.get("Access-Control-Allow-Origin"),
      "https://volunteer.roboref.app"
    );

    // 3. Local network dev server (e.g. 192.168.1.100:8080)
    const lanRes = await handleWorkerRequest(
      new Request("https://roboref-volunteer-auth-otp.james-pearson.workers.dev/api/auth/request-otp", {
        method: "OPTIONS",
        headers: {
          Origin: "http://192.168.1.100:8080",
          "Access-Control-Request-Method": "POST",
        },
      }),
      corsEnv,
      deps
    );
    assert.equal(
      lanRes.headers.get("Access-Control-Allow-Origin"),
      "http://192.168.1.100:8080"
    );

    // 4. Unmatched third-party origin falls back to primary domain
    const badRes = await handleWorkerRequest(
      new Request("https://roboref-volunteer-auth-otp.james-pearson.workers.dev/api/auth/request-otp", {
        method: "OPTIONS",
        headers: {
          Origin: "https://malicious-site.example.com",
          "Access-Control-Request-Method": "POST",
        },
      }),
      corsEnv,
      deps
    );
    assert.equal(
      badRes.headers.get("Access-Control-Allow-Origin"),
      "https://robovolunteers.link"
    );
  });

  it("returns 502 email_delivery_failed without committing cooldown when EMAIL.send throws", async () => {
    let shouldFail = true;
    const env = createEnv({
      EMAIL: {
        async send(msg: OutboundEmailPayload) {
          if (shouldFail) {
            throw new TypeError("Invalid EmailAddress: missing required field name");
          }
          sentEmails.push(msg);
          return { messageId: `msg-${sentEmails.length}` };
        },
      },
    });
    const deps = {
      fetchImpl: createMockFetch(),
      now: () => new Date(currentTimeMs),
    };

    const failRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.88",
        },
        body: JSON.stringify({
          mode: "join",
          email: "new.volunteer@example.co.uk",
          inviteCode: "UKVEX-2026",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      deps
    );

    assert.equal(failRes.status, 502);
    const failJson = (await failRes.json()) as { ok: boolean; error: string };
    assert.equal(failJson.ok, false);
    assert.equal(failJson.error, "email_delivery_failed");
    assert.equal(sentEmails.length, 0);

    // Immediate retry must NOT be blocked by a 60s cooldown or daily quota
    shouldFail = false;
    const retryRes = await handleWorkerRequest(
      new Request("https://roboref.app/api/auth/request-otp", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "CF-Connecting-IP": "203.0.113.88",
        },
        body: JSON.stringify({
          mode: "join",
          email: "new.volunteer@example.co.uk",
          inviteCode: "UKVEX-2026",
          turnstileToken: "valid-turnstile",
        }),
      }),
      env,
      deps
    );

    assert.equal(retryRes.status, 200);
    assert.equal(sentEmails.length, 1);
  });
});
