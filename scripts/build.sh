#!/usr/bin/env bash
set -e

TARGET="${1:-web}"
shift || true

# Get current date formatted as YYYY.M.D (e.g., 2026.11.3)
VERSION_NAME="$(date +'%Y.%-m.%-d')"

# Get commit count from git
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo "1")"

echo "========================================"
echo " Building RoboVolunteers ($TARGET)"
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

  flutter build "$flutter_target" --build-name="$VERSION_NAME" --build-number="$BUILD_NUMBER" "${extra_flags[@]}" "$@"
  echo ">>> Flutter client ($flutter_target) build completed successfully."
}

case "$TARGET" in
  worker|server)
    build_worker
    ;;
  all)
    build_worker
    build_flutter web "$@"
    ;;
  *)
    build_flutter "$TARGET" "$@"
    ;;
esac
