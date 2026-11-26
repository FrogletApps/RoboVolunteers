#!/usr/bin/env bash
set -e

TARGET="web"
ENV_NAME="live"
EXTRA_ARGS=()
HAS_TARGET=false

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
    *)
      if [ "$HAS_TARGET" = false ] && [[ "$1" != -* ]]; then
        TARGET="$1"
        HAS_TARGET=true
      else
        EXTRA_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ "$ENV_NAME" != "live" ] && [ "$ENV_NAME" != "test" ]; then
  echo "Error: --env must be 'live' or 'test' (got '$ENV_NAME')." >&2
  exit 1
fi

# Get current date formatted as YYYY.M.D (e.g., 2026.11.3)
VERSION_NAME="$(date +'%Y.%-m.%-d')"

# Get commit count from git
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "1")"

echo "========================================"
echo " Building RoboVolunteers ($TARGET) [$ENV_NAME]"
echo " Version Name: $VERSION_NAME"
echo " Build Number: $BUILD_NUMBER"
echo " Full Version: $VERSION_NAME+$BUILD_NUMBER"
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$SCRIPT_DIR/../workers/auth-otp"
APP_DIR="$SCRIPT_DIR/../app"

build_worker() {
  echo -e "\n>>> Building & Testing Auth OTP Worker..."
  cd "$WORKER_DIR"
  if [ ! -d "node_modules" ]; then
    echo "Installing worker dependencies (npm install)..."
    npm install
  fi
  echo "Running worker typecheck..."
  npm run typecheck
  echo "Running worker unit tests..."
  npm test
  echo ">>> Auth OTP Worker verification & tests completed successfully."
}

build_flutter() {
  local flutter_target="$1"
  shift || true
  echo -e "\n>>> Building Flutter Client ($flutter_target)..."
  cd "$APP_DIR"

  local extra_flags=()
  if [ "$flutter_target" = "web" ]; then
    local has_wasm=false
    for arg in "$@"; do
      if [ "$arg" = "--wasm" ] || [ "$arg" = "--no-wasm" ]; then
        has_wasm=true
        break
      fi
    done
    if [ "$has_wasm" = false ]; then
      extra_flags+=("--wasm")
    fi
  fi

  local has_firebase_define=false
  for arg in "$@"; do
    case "$arg" in
      --dart-define-from-file*|*FIREBASE_API_KEY=*)
        has_firebase_define=true
        break
        ;;
    esac
  done

  if [ "$has_firebase_define" = false ]; then
    if [ "$ENV_NAME" = "test" ]; then
      if [ -f "$APP_DIR/firebase.test.env.json" ]; then
        echo "Using test Firebase config from app/firebase.test.env.json"
        extra_flags+=("--dart-define-from-file=$APP_DIR/firebase.test.env.json")
      elif [ -f "$SCRIPT_DIR/../firebase.test.env.json" ]; then
        echo "Using test Firebase config from firebase.test.env.json"
        extra_flags+=("--dart-define-from-file=$SCRIPT_DIR/../firebase.test.env.json")
      else
        echo "Error: Missing test Firebase config. Copy app/firebase.test.env.example.json to app/firebase.test.env.json and fill in your RoboVolunteers-Test Firebase project values." >&2
        exit 1
      fi
    else
      if [ -f "$APP_DIR/firebase.env.json" ]; then
        echo "Using Firebase config from app/firebase.env.json"
        extra_flags+=("--dart-define-from-file=$APP_DIR/firebase.env.json")
      elif [ -f "$SCRIPT_DIR/../firebase.env.json" ]; then
        echo "Using Firebase config from firebase.env.json"
        extra_flags+=("--dart-define-from-file=$SCRIPT_DIR/../firebase.env.json")
      elif [ -n "${FIREBASE_API_KEY:-}" ]; then
        echo "Using FIREBASE_API_KEY from environment"
        extra_flags+=("--dart-define=FIREBASE_API_KEY=$FIREBASE_API_KEY")
      else
        echo "Error: Missing Firebase API key. Copy app/firebase.env.example.json to app/firebase.env.json and set FIREBASE_API_KEY, or set the FIREBASE_API_KEY environment variable." >&2
        exit 1
      fi
    fi
  fi

  flutter build "$flutter_target" --build-name="$VERSION_NAME" --build-number="$BUILD_NUMBER" "${extra_flags[@]}" "$@"
  echo ">>> Flutter client ($flutter_target) build completed successfully."
}

case "$TARGET" in
  worker|server)
    build_worker
    ;;
  all)
    build_worker
    build_flutter web "${EXTRA_ARGS[@]}"
    ;;
  *)
    build_flutter "$TARGET" "${EXTRA_ARGS[@]}"
    ;;
esac
