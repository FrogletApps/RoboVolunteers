#!/usr/bin/env bash
set -e

ENV_NAME="live"
SKIP_BUILD=false
SKIP_WEB=false
SKIP_WORKER=false
DEPLOY_WORKER=false
DEPLOY_FIRESTORE=true
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env|-e)
      ENV_NAME="$2"
      shift 2
      ;;
    --env=*)
      ENV_NAME="${1#*=}"
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --skip-web)
      SKIP_WEB=true
      shift
      ;;
    --skip-worker)
      SKIP_WORKER=true
      shift
      ;;
    --deploy-worker)
      DEPLOY_WORKER=true
      shift
      ;;
    --deploy-firestore)
      DEPLOY_FIRESTORE=true
      shift
      ;;
    --skip-firestore)
      DEPLOY_FIRESTORE=false
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [ "$ENV_NAME" != "live" ] && [ "$ENV_NAME" != "test" ]; then
  echo "Error: --env must be 'live' or 'test' (got '$ENV_NAME')." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
WORKER_DIR="$ROOT_DIR/workers/auth-otp"
FIREBASE_PROJECT_ALIAS="default"
if [ "$ENV_NAME" = "test" ]; then
  FIREBASE_PROJECT_ALIAS="test"
fi

echo "========================================"
echo " Deploying RoboVolunteers [$ENV_NAME]"
if [ "$ENV_NAME" = "test" ]; then
  echo " Web Worker:   robovolunteers-test (test.robovolunteers.link)"
  echo " Auth Worker:  robovolunteers-auth-otp-test"
  echo " Firebase:     $FIREBASE_PROJECT_ALIAS (robovolunteers-test)"
else
  echo " Web Worker:   roboref-volunteer-hub (robovolunteers.link)"
  echo " Auth Worker:  roboref-volunteer-auth-otp"
  echo " Firebase:     $FIREBASE_PROJECT_ALIAS (volunteer-wrangler)"
fi
echo "========================================"

# Step 1: Worker check
if [ "$SKIP_BUILD" = false ] && [ "$SKIP_WORKER" = false ]; then
  echo ">>> Step 1/4: Verifying & Testing Auth OTP Worker..."
  "$SCRIPT_DIR/build.sh" worker --env "$ENV_NAME"
else
  echo ">>> Step 1/4: Skipping worker check..."
fi

# Optional: Deploy Worker
if [ "$DEPLOY_WORKER" = true ]; then
  echo -e "\n>>> Deploying Auth OTP Worker [$ENV_NAME] to Cloudflare..."
  cd "$WORKER_DIR"
  worker_args=("deploy")
  if [ "$ENV_NAME" = "test" ]; then worker_args+=("--env" "test"); fi
  if [ "$DRY_RUN" = true ]; then worker_args+=("--dry-run"); fi
  npx wrangler "${worker_args[@]}"
fi

# Step 2: Flutter Web build
if [ "$SKIP_BUILD" = false ] && [ "$SKIP_WEB" = false ]; then
  echo -e "\n>>> Step 2/4: Building Flutter Web PWA [$ENV_NAME]..."
  "$SCRIPT_DIR/build.sh" web --env "$ENV_NAME"
else
  echo -e "\n>>> Step 2/4: Skipping web build..."
fi

# Step 3: Cloudflare deploy
echo -e "\n>>> Step 3/4: Deploying Web Assets [$ENV_NAME] to Cloudflare..."
cd "$ROOT_DIR"
deploy_args=("deploy" "--config" "wrangler.jsonc")
if [ "$ENV_NAME" = "test" ]; then deploy_args+=("--env" "test"); fi
if [ "$DRY_RUN" = true ]; then deploy_args+=("--dry-run"); fi
npx wrangler "${deploy_args[@]}"

# Step 4: Firestore deploy (enabled by default; pass --skip-firestore to skip)
if [ "$DEPLOY_FIRESTORE" = true ]; then
  echo -e "\n>>> Step 4/4: Deploying Cloud Firestore Rules & Indexes to Firebase ($FIREBASE_PROJECT_ALIAS)..."
  cd "$ROOT_DIR"
  firestore_args=("-y" "firebase-tools@latest" "deploy" "--only" "firestore" "--project" "$FIREBASE_PROJECT_ALIAS")
  if [ "$DRY_RUN" = true ]; then firestore_args+=("--dry-run"); fi
  npx "${firestore_args[@]}"
else
  echo -e "\n>>> Step 4/4: Skipping Cloud Firestore Rules & Indexes deployment..."
fi

echo -e "\n========================================"
echo " Deployment [$ENV_NAME] completed successfully!"
echo "========================================"
