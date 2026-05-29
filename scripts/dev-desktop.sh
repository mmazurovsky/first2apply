#!/usr/bin/env bash
# Launch First 2 Apply desktop app + local Supabase backend.
# Usage: ./scripts/dev-desktop.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/apps/backend"
LOG_DIR="$ROOT_DIR/.dev-logs"
FUNCTIONS_LOG="$LOG_DIR/functions.log"

mkdir -p "$LOG_DIR"

FUNCTIONS_PID=""

cleanup() {
  echo ""
  echo "[dev-desktop] shutting down..."
  if [[ -n "$FUNCTIONS_PID" ]] && kill -0 "$FUNCTIONS_PID" 2>/dev/null; then
    kill "$FUNCTIONS_PID" 2>/dev/null || true
    wait "$FUNCTIONS_PID" 2>/dev/null || true
  fi
  echo "[dev-desktop] supabase containers left running. stop with: cd apps/backend && pnpm supabase stop"
}
trap cleanup EXIT INT TERM

cd "$ROOT_DIR"

if ! command -v pnpm >/dev/null 2>&1; then
  echo "[dev-desktop] pnpm not found. Install: https://pnpm.io/" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[dev-desktop] Docker not running. Start Docker Desktop and retry." >&2
  exit 1
fi

# kill stale electron-forge webpack logger holding port 9000 (EADDRINUSE on relaunch)
STALE_PID="$(lsof -ti :9000 2>/dev/null || true)"
if [[ -n "$STALE_PID" ]]; then
  echo "[dev-desktop] freeing port 9000 (stale pid: $STALE_PID)..."
  kill -9 $STALE_PID 2>/dev/null || true
fi

echo "[dev-desktop] starting supabase..."
(cd "$BACKEND_DIR" && pnpm supabase start)

echo "[dev-desktop] serving edge functions (log: $FUNCTIONS_LOG)..."
(cd "$BACKEND_DIR" && pnpm supabase functions serve) > "$FUNCTIONS_LOG" 2>&1 &
FUNCTIONS_PID=$!

sleep 2
if ! kill -0 "$FUNCTIONS_PID" 2>/dev/null; then
  echo "[dev-desktop] edge functions failed to start. See $FUNCTIONS_LOG" >&2
  exit 1
fi

echo "[dev-desktop] launching desktop app..."
pnpm nx start first2apply-desktop

echo ""
echo "[dev-desktop] desktop app launched. Keep this window open while using the app."
echo "[dev-desktop] Press Ctrl+C (or close this window) to stop edge functions."
# Block so terminal stays attached; Electron dies via SIGHUP if this script exits.
while true; do sleep 3600; done
