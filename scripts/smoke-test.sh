#!/usr/bin/env bash
#
# Smoke test — is the deployment actually serving?
#
#   ./scripts/smoke-test.sh <web-url> <api-url>
#   ./scripts/smoke-test.sh https://staging.example.com https://api.staging.example.com
#
# Run after every deployment: by CI against the freshly booted stack, and by
# the deploy workflows against staging and production. It is deliberately
# small — six checks that take four seconds — because a smoke test nobody runs
# because it is slow provides no assurance at all.
#
# What it is not: a functional test suite. That lives in the `testing`
# repository and takes twenty minutes. This answers one question — did the
# thing that was just deployed come up? — and answers it fast enough to gate
# a deployment on.

set -euo pipefail

WEB_URL="${1:-http://localhost:8080}"
API_URL="${2:-http://localhost:5001}"
TIMEOUT="${SMOKE_TIMEOUT:-10}"
RETRIES="${SMOKE_RETRIES:-12}"
INTERVAL="${SMOKE_INTERVAL:-5}"

passed=0
failed=0

log()  { printf '  %s\n' "$*"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; failed=$((failed + 1)); }

# Wait for an endpoint to answer at all before asserting anything about it.
# Without this the first check races the container start and the whole run is
# a coin flip.
wait_for() {
  local url="$1" name="$2" attempt=1
  while [ "${attempt}" -le "${RETRIES}" ]; do
    if curl -fsS --max-time "${TIMEOUT}" -o /dev/null "${url}" 2>/dev/null; then
      log "${name} responded after ${attempt} attempt(s)"
      return 0
    fi
    sleep "${INTERVAL}"
    attempt=$((attempt + 1))
  done
  return 1
}

# check <name> <url> <expected-status> [grep-pattern]
check() {
  local name="$1" url="$2" expected="$3" pattern="${4:-}"
  local response status body

  if ! response="$(curl -sS --max-time "${TIMEOUT}" -w '\n%{http_code}' "${url}" 2>&1)"; then
    fail "${name} — request failed: ${response}"
    return
  fi

  status="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [ "${status}" != "${expected}" ]; then
    fail "${name} — expected HTTP ${expected}, got ${status}"
    return
  fi

  if [ -n "${pattern}" ] && ! printf '%s' "${body}" | grep -q "${pattern}"; then
    fail "${name} — HTTP ${expected} but body did not contain '${pattern}'"
    return
  fi

  pass "${name}"
}

printf '\n  Smoke test\n'
printf '  web: %s\n' "${WEB_URL}"
printf '  api: %s\n\n' "${API_URL}"

if ! wait_for "${API_URL}/health" "API"; then
  fail "API never became reachable at ${API_URL}/health"
  printf '\n  \033[31mFAILED\033[0m — the API did not start.\n\n'
  exit 1
fi

# 1. The API is alive and its database connection is up. /health reports both,
#    which is why it is the readiness probe rather than a bare 200 route.
check "API health endpoint reports healthy" "${API_URL}/health" 200

# 2. A real read path through Express, Mongoose and MongoDB. /health can pass
#    while the query layer is broken; this cannot.
check "Course catalogue answers" "${API_URL}/api/courses" 200

# 3. Authentication refuses an unauthenticated request. If this returns 200,
#    the deployment has shipped without its auth middleware — which has
#    happened, and is invisible from any check that only looks for 200s.
check "Protected route refuses an anonymous request" "${API_URL}/api/auth/me" 401

# 4. The web tier is serving.
if ! wait_for "${WEB_URL}/healthz" "Web"; then
  fail "Web tier never became reachable at ${WEB_URL}/healthz"
else
  check "Web health endpoint" "${WEB_URL}/healthz" 200 "ok"

  # 5. The SPA itself, not just nginx. A blank index.html passes a health
  #    check; it does not contain the root div the bundle mounts into.
  check "SPA document is served" "${WEB_URL}/" 200 '<div id="root"'

  # 6. Client-side routing. A missing SPA fallback returns 404 here and breaks
  #    every deep link and every page refresh — the classic broken deployment
  #    that looks fine to whoever only visits the home page.
  check "SPA fallback serves an application route" "${WEB_URL}/courses" 200 '<div id="root"'
fi

printf '\n  %d passed, %d failed\n\n' "${passed}" "${failed}"

if [ "${failed}" -gt 0 ]; then
  printf '  \033[31mSMOKE TEST FAILED\033[0m\n\n'
  exit 1
fi

printf '  \033[32mSMOKE TEST PASSED\033[0m\n\n'
