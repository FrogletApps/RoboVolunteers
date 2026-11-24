# RoboVolunteers — Auth OTP Cloudflare Worker

Standalone Cloudflare Worker (`workers/auth-otp/`) providing:
- **Admin Portal & One-Time Invite Codes** backed by Cloudflare KV (`AUTH_OTP_KV`):
  - Manually configured administrators (`ADMIN_EMAILS` secret and/or Firebase Auth `admin: true` custom claim) can generate single-use invite codes (`RV-XXXX-XXXX-XXXX`) with ready-to-share hyperlinks (`https://robovolunteers.link/?invite=...`), optional recipient notes, batch creation, expiry, and revocation.
  - `GET /api/auth/me`: Cryptographically verifies the caller's Firebase ID Token and reports `inviteVerified` and `isAdmin`.
  - `GET /api/admin/invites`, `POST /api/admin/invites`, `POST /api/admin/invites/:id/revoke` (`DELETE /api/admin/invites/:id`): Admin-only endpoints for managing one-time volunteer invite codes.
- **Server-side Invite Code Validation** against one-time KV invite codes (strictly single-use across both Email OTP and Google Sign-In) with optional fallback to static `INVITE_CODES` secret (constant-time comparison).
- **6-Digit Passwordless Email OTP** delivered natively via **Cloudflare Email Service** (`send_email` binding).
- **4-Layer Rate Limiting & Quota Protection** backed by Cloudflare KV (`AUTH_OTP_KV`):
  - **Per-User Cooldown**: Max 1 OTP per 60 seconds (`OTP_COOLDOWN_SECONDS = 60`).
  - **Per-User Daily Cap**: Max **12 emails per 24 hours** per email (`MAX_DAILY_EMAILS_PER_USER = 12`).
  - **Per-IP Cap**: Max 5 requests/minute and 20 requests/hour (`CF-Connecting-IP`).
  - **Global Daily Circuit Breaker**: Hard cap of 150 emails/day (`MAX_DAILY_EMAILS_GLOBAL = 150`).
  - **Pre-Send Gatekeeping**: Cloudflare Turnstile + invite code check (for new users) or Firebase Auth account check (for returning users) *before* `env.EMAIL.send()` is ever called.
- **Firebase Custom Token Minting & Google Invite Claiming**:
  - `POST /api/auth/request-otp` + `POST /api/auth/verify-otp`: Issues `RS256` custom tokens with `{ inviteVerified: true }` and sets persistent Firebase Auth custom claims so device sessions stay logged in indefinitely across restarts.
  - `POST /api/auth/claim-invite`: Cryptographically verifies a caller's Firebase ID Token (RS256 against Google's public JWKS) and invitation code for first-time **Continue with Google** users before stamping `{ inviteVerified: true }` (sends 0 emails).

## Production Deployment Steps

1. **Onboard Sending Domain in Cloudflare**:
   - In Cloudflare Dashboard -> **Compute** -> **Email Service** -> **Email Sending**, onboard `roboref.app` so SPF/DKIM/DMARC records are active.

2. **Create Cloudflare KV Namespace**:
   ```bash
   cd workers/auth-otp
   npx wrangler kv namespace create AUTH_OTP_KV
   ```
   Paste the returned namespace `id` into `wrangler.jsonc`.

3. **Configure Worker Secrets**:
   ```bash
   npx wrangler secret put ADMIN_EMAILS                 # Comma-separated admin emails (e.g. admin1@example.com,admin2@example.com)
   npx wrangler secret put INVITE_CODES                 # Optional static/bootstrap codes (can be left empty once using one-time codes)
   npx wrangler secret put OTP_HMAC_SECRET
   npx wrangler secret put FIREBASE_SERVICE_ACCOUNT_JSON
   npx wrangler secret put TURNSTILE_SECRET_KEY
   ```

   > **Setting up Admins Manually**: Set `ADMIN_EMAILS` via `wrangler secret put ADMIN_EMAILS` with the verified email addresses of your administrators (comma-separated). Updating this secret takes effect immediately without requiring admins to sign out. Firebase Auth custom claim `{"admin": true}` is also honored if set manually via the Firebase Admin SDK.

4. **Deploy**:
   ```bash
   npm install
   npm test
   npx wrangler deploy
   ```
