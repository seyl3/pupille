#!/bin/bash
# End-to-end runner: boots a real backend against real Postgres (with a throwaway App Attest
# test root pinned, since there's no physical iPhone to produce a real Apple-issued cert — see
# docs/WORKLOG.md), then drives it with the fake-phone client. Exits with fake-phone's exit code.
#
# Requires: DATABASE_URL pointing at a real, migrated Postgres database.
# Usage: DATABASE_URL=postgresql://postgres@/pupille_test?host=/tmp&port=5433 ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$HERE/../../backend"
TEST_ROOT_DIR="$HERE/.test-root"
PORT="${PORT:-8787}"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "DATABASE_URL is required (a real, reachable Postgres instance — see docs/WORKLOG.md)" >&2
  exit 1
fi

echo "== generating fake-phone test root (App Attest stand-in, NOT Apple) =="
npx tsx "$HERE/src/generateTestRoot.ts" "$TEST_ROOT_DIR"

echo "== applying schema =="
(cd "$BACKEND_DIR" && DATABASE_URL="$DATABASE_URL" npx tsx src/db/migrate.ts)

echo "== starting backend on :$PORT =="
export PUPILLE_WORLD_API_FIXTURE_MODE=1
export PUPILLE_APP_ATTEST_TEST_ROOT_PEM
PUPILLE_APP_ATTEST_TEST_ROOT_PEM="$(cat "$TEST_ROOT_DIR/test-root-cert.pem")"
export PORT
(cd "$BACKEND_DIR" && DATABASE_URL="$DATABASE_URL" npx tsx src/index.ts > /tmp/pupille-fake-phone-backend.log 2>&1) &
BACKEND_PID=$!
trap 'kill $BACKEND_PID 2>/dev/null || true' EXIT

echo "== waiting for backend to become healthy =="
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$PORT/healthz" > /dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! curl -sf "http://localhost:$PORT/healthz" > /dev/null 2>&1; then
  echo "backend never became healthy; log:" >&2
  cat /tmp/pupille-fake-phone-backend.log >&2
  exit 1
fi

echo "== running fake-phone =="
export PUPILLE_BACKEND_URL="http://localhost:$PORT"
export PUPILLE_TEST_ROOT_DIR="$TEST_ROOT_DIR"
(cd "$HERE" && npx tsx src/main.ts)
STATUS=$?

exit $STATUS
