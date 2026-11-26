# RoboVolunteers

[![Platform - Flutter](https://img.shields.io/badge/Platform-Flutter%20%7C%20Dart-02569B?logo=flutter)](https://flutter.dev)
[![UI - Material 3](https://img.shields.io/badge/UI-Material%20Design%203-7B1FA2)](https://m3.material.io)
[![State - Riverpod](https://img.shields.io/badge/State-Riverpod%202.x-0553B1)](https://riverpod.dev)

**RoboVolunteers** is an unofficial volunteer management and event coordination application built specifically for VEX Robotics competitions (**V5RC**, **VIQRC**, and **VEX U**), initially focused on the **United Kingdom**.

It allows invited volunteers to authenticate via **Continue with Google** or passwordless **6-digit Email OTP**, declare their certified qualifications, keep personal contact details strictly isolated from public rosters, and mark themselves as **Available** or **Confirmed** for UK events fetched directly from the official **VEX Events API** (`events.vex.com`).

---

## ✨ Key Features

- 🔐 **Passwordless Auth (Google + 6-Digit Email OTP) & Persistent Sessions**:
  - Invite-only new volunteer onboarding verified server-side against **one-time invite codes** (stored in Cloudflare KV) and optional legacy static `INVITE_CODES` secrets for both Google Sign-In and Email OTP.
  - Native **Cloudflare Email Service** (`send_email`) delivery protected by 4-layer rate limiting (60s cooldown, **12 emails/day per user**, per-IP cap, Cloudflare Turnstile, and a global daily circuit breaker).
  - Persistent device sessions via **Firebase Authentication** (`Persistence.LOCAL` on Web, Keychain on iOS, Keystore on Android) so volunteers stay signed in across weeks/months until explicit logout.
- 🛡️ **Admin Portal & One-Time Invite Links**:
  - Manually configured administrators (`ADMIN_EMAILS` Cloudflare Worker dashboard variable/secret or Firebase Auth `admin: true` claim) get access to the in-app **Admin Portal**.
  - Generate single-use invite codes (`RV-XXXX-XXXX-XXXX`) individually or in batches with optional notes and expiry dates, copy ready-to-share registration hyperlinks (`https://robovolunteers.link/?invite=...`) that automatically pre-fill the New Volunteer flow, track redemptions, and revoke unused codes.
- 🛡️ **Zero-PII Roster Architecture**:
  - Personal contact details (`email`, `phone`) are isolated in owner-only `volunteer_private/{uid}` documents in **Cloud Firestore** (`firestore.rules`) and are never exposed on `volunteers/{uid}` or `event_signups` documents.
- 🏅 **Qualification Management**:
  - Track official volunteer roles: **Head Referee**, **Field Referee**, **Judge Advisor**, **Judge**, and **Other** (Field Queuer, TM Operator, Robot Inspection, Emcee).
- 📅 **Per-Event Availability & Confirmation Tracking**:
  - Volunteers can mark themselves as **Available** or **Confirmed**, pick qualified roles, or withdraw at any time with live updates.
- 🌐 **UK VEX Events Integration**:
  - Queries upcoming UK tournaments from the official **VEX Events API** (`events.vex.com/api/v2/events`) with search by name, venue, city, or SKU (`RE-V5RC-...`, `RE-VIQRC-...`).

---

## 🏗 Architecture & Tech Stack

| Component | Technology | Description |
| :--- | :--- | :--- |
| **Client Framework** | **Flutter** (Dart ^3.5.0) | Cross-platform client for Web, Android, and iOS |
| **State Management** | **Riverpod** 2.x | Reactive auth gating, state, and dependency injection |
| **Web Hosting** | **Cloudflare Workers Static Assets** | Edge-cached SPA hosting (`wrangler.jsonc`, `app/web/_headers`) with unlimited free bandwidth |
| **Identity & Sessions** | **Firebase Authentication** | Custom-token & Google Sign-In with long-lived remembered device sessions |
| **Database & Rules** | **Cloud Firestore** | Real-time rosters & strict `firestore.rules` PII isolation |
| **Auth Edge Worker** | **Cloudflare Workers + KV + Email Service** | Standalone `workers/auth-otp/` invite validator, rate limiter & 6-digit OTP sender |
| **External API** | **VEX Events API v2** | `events.vex.com` event data and schedule ingestion |

---

## 🚀 Getting Started

### 1. Cloudflare Auth OTP Worker (`workers/auth-otp/`)
See [workers/auth-otp/README.md](workers/auth-otp/README.md) to configure the `AUTH_OTP_KV` namespace, onboard `roboref.app` in Cloudflare Email Service, set `ADMIN_EMAILS` / `INVITE_CODES` / `OTP_HMAC_SECRET` / `FIREBASE_SERVICE_ACCOUNT_JSON` / `TURNSTILE_SECRET_KEY` secrets, and deploy:
```bash
cd workers/auth-otp
npm test
npx wrangler deploy
```

### 2. Firebase & Flutter Application (`app/`)
1. Provision a Firebase project (London `europe-west2` Firestore region), deploy `firestore.rules` and indexes:
   ```bash
   npx -y firebase-tools@latest deploy --only firestore
   ```
2. Configure your local Firebase API key (kept out of git) and install dependencies inside `app/`:
   ```bash
   cp app/firebase.env.example.json app/firebase.env.json
   # Edit app/firebase.env.json and paste your Firebase Web API key
   cd app
   flutter pub get
   ```
   *(For CI/CD or one-off builds, you can also set the `FIREBASE_API_KEY` environment variable instead of creating `app/firebase.env.json`.)*
3. Run tests and code analysis:
   ```bash
   flutter analyze
   flutter test
   ```

### 3. Build & Deploy Scripts (`scripts/` & `npm`)

Just like the main RoboRef repository, automated date-based versioning (`YYYY.M.D`) and Git commit count build numbers are integrated into cross-platform build and deploy scripts:

#### Fast Build (`scripts/build.ps1` or `scripts/build.sh`)
```powershell
# Build Flutter Web (with Wasm + CanvasKit fallback, versioned YYYY.M.D+commitCount)
.\scripts\build.ps1 web

# Verify & test the Auth OTP Worker
.\scripts\build.ps1 worker

# Build all targets (Worker verification + Web bundle)
.\scripts\build.ps1 all
```

#### One-Command Deploy (`scripts/deploy.ps1` or `scripts/deploy.sh`)
```powershell
# Verify worker, compile web app, deploy to Cloudflare, and deploy Firestore rules & indexes
.\scripts\deploy.ps1

# Dry-run validation without publishing
.\scripts\deploy.ps1 -DryRun

# Deploy web app, Auth OTP Cloudflare Worker, and Firestore rules & indexes
.\scripts\deploy.ps1 -DeployWorker

# Deploy to the isolated test environment (test.robovolunteers.link, robovolunteers-test, robovolunteers-auth-otp-test, RoboVolunteers-Test Firebase)
.\scripts\deploy.ps1 -Env test -DeployWorker

# Skip deploying Firestore rules & indexes
.\scripts\deploy.ps1 -SkipFirestore

# Deploy using existing build artifacts (fast deploy)
.\scripts\deploy.ps1 -SkipWebBuild
```

Or using root `npm` shortcuts:
```bash
npm run build              # Builds Flutter Web bundle (live)
npm run build:test         # Builds Flutter Web bundle (test)
npm run deploy             # Runs scripts/deploy.ps1 (live)
npm run deploy:test        # Runs scripts/deploy.ps1 -Env test
npm run deploy:test:all    # Deploys test web app, test Auth OTP worker, and test Firestore rules
npm run deploy:worker      # Deploys workers/auth-otp (live)
npm run deploy:worker:test # Deploys workers/auth-otp (test)
npm run test:worker        # Runs worker unit tests
```

#### Test / Staging Environment Setup (`RoboVolunteers-Test`)
An isolated `test` environment is configured across Firebase (`.firebaserc` alias `test` → `robovolunteers-test`), Cloudflare Web Hosting (`wrangler.jsonc` → `robovolunteers-test` on `test.robovolunteers.link`), and the Auth OTP Worker (`workers/auth-otp/wrangler.jsonc` → `robovolunteers-auth-otp-test`):
1. Create Firebase project `RoboVolunteers-Test` (ID `robovolunteers-test`, `europe-west2` Firestore), enable Google Sign-In, authorize `test.robovolunteers.link` and `robovolunteers-test.<subdomain>.workers.dev`, and deploy rules:
   ```bash
   npm run deploy:firestore:test
   ```
2. Create a separate Cloudflare KV namespace for the test Auth OTP worker (`cd workers/auth-otp && npx wrangler kv namespace create AUTH_OTP_KV --env test`), paste its ID into `env.test.kv_namespaces[0].id` in `workers/auth-otp/wrangler.jsonc`, and set test secrets (`FIREBASE_SERVICE_ACCOUNT_JSON` from `RoboVolunteers-Test`, `OTP_HMAC_SECRET`, `ADMIN_EMAILS`, etc.) using `npx wrangler secret put <NAME> --env test`.
3. Copy `app/firebase.test.env.example.json` to `app/firebase.test.env.json` (gitignored) and fill in your `RoboVolunteers-Test` web app config.
4. Build and deploy everything to test:
   ```bash
   npm run deploy:test:all
   ```

#### Authorizing Domains in Firebase Auth
Make sure to authorize your Cloudflare domain(s) (e.g. `robovolunteers.link`, `test.robovolunteers.link`, `roboref-volunteer-hub.<subdomain>.workers.dev`, and `robovolunteers-test.<subdomain>.workers.dev`) under **Firebase Console → Authentication → Settings → Authorized domains** so Google Sign-In popups work.
`robovolunteers.link` (live) and `test.robovolunteers.link` (test) are attached as Cloudflare custom domains via `"routes"` in `wrangler.jsonc`.

---

## 📂 Project Structure

```text
RoboVolunteers/
├── app/                                    # Flutter Web / Android / iOS application
│   ├── lib/
│   │   ├── firebase_options.dart           # Firebase platform config (--dart-define or flutterfire)
│   │   ├── features/
│   │   │   ├── auth_invites/               # Passwordless 6-digit OTP login, onboarding & Firebase Auth state
│   │   │   ├── profile/                    # Qualifications & PII-isolated profile model
│   │   │   ├── events/                     # UK VEX Events search, filter, VEX Events API client
│   │   │   └── volunteering/               # Firestore event signups & roster screen
│   │   └── main.dart                       # Persistent session initialization & reactive auth router
│   ├── web/
│   │   ├── _headers                        # Cloudflare edge security & cache revalidation headers
│   │   ├── .assetsignore                   # Excludes internal Flutter build metadata from CDN upload
│   │   ├── index.html                      # Flutter Web entry shell
│   │   └── manifest.json                   # PWA manifest
│   └── test/                               # Unit & widget test suites
├── scripts/                                # Build & deployment automation (PowerShell & Bash)
│   ├── build.ps1 / build.sh                # Date-based versioning (YYYY.M.D+commitCount) & build pipeline
│   └── deploy.ps1 / deploy.sh              # Cloudflare Workers static assets & worker deployment pipeline
├── workers/
│   └── auth-otp/                           # Standalone Cloudflare Worker (OTP + Invite Gate + Rate Limiter)
├── firestore.rules                         # Hardened Cloud Firestore Security Rules
├── firestore.indexes.json                  # Firestore index definitions
├── firebase.json                           # Cloud Firestore rules & indexes configuration
├── package.json                            # Root npm shortcuts for build, deploy, & worker tests
└── wrangler.jsonc                          # Cloudflare Workers Static Assets SPA hosting configuration
```