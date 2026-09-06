#!/usr/bin/env bash
#
# Deploy the SRI-KO LMS stack on this host.
#
#   ./scripts/deploy.sh <environment> [image-tag]
#   ./scripts/deploy.sh staging
#   IMAGE_TAG=1.2.3 ./scripts/deploy.sh production
#
# Normally the deploy workflows call the composite action, which does this over
# SSH. This script is what runs on the host, and it is also the manual path:
# when GitHub Actions is down, or the demonstration is in ninety minutes and
# nobody has time to debug a workflow, somebody needs to be able to deploy from
# a terminal without reconstructing the steps from memory.
#
# It records the tag it deployed, so scripts/rollback.sh has something to go
# back to.

set -euo pipefail

# ── Arguments ───────────────────────────────────────────────────────────────

ENVIRONMENT="${1:-staging}"
IMAGE_TAG="${2:-${IMAGE_TAG:-}}"

STACK_ROOT="${STACK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m──\033[0m %s\n' "$*"; }
die()   { red "✗ $*"; exit 1; }

case "${ENVIRONMENT}" in
  staging)    COMPOSE_FILE="${STACK_ROOT}/compose/docker-compose.staging.yml" ;;
  production) COMPOSE_FILE="${STACK_ROOT}/compose/docker-compose.prod.yml" ;;
  *) die "Unknown environment '${ENVIRONMENT}'. Use 'staging' or 'production'." ;;
esac

[ -n "${IMAGE_TAG}" ] || die "No image tag. Pass one as the second argument or set IMAGE_TAG."
[ -f "${COMPOSE_FILE}" ] || die "Compose file not found: ${COMPOSE_FILE}"

# A moving tag cannot be rolled back to, because it will point somewhere else
# by the time anyone tries.
if [ "${ENVIRONMENT}" = "production" ]; then
  case "${IMAGE_TAG}" in
    latest|main|master|develop|staging)
      die "Refusing to deploy the moving tag '${IMAGE_TAG}' to production. Use a version or a sha- tag."
      ;;
  esac
fi

ENV_FILE="${ENV_FILE:-${STACK_ROOT}/.env}"
[ -f "${ENV_FILE}" ] || die "Environment file not found: ${ENV_FILE} (copy .env.example and fill it in)"

STATE_FILE="${STACK_ROOT}/.deployed-tag"

printf '\n'
info "environment  ${ENVIRONMENT}"
info "tag          ${IMAGE_TAG}"
info "compose      ${COMPOSE_FILE}"
printf '\n'

# ── Preconditions ───────────────────────────────────────────────────────────

command -v docker >/dev/null 2>&1 || die "docker is not installed."
docker compose version >/dev/null 2>&1 || die "docker compose v2 is not available."
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running, and is this user in the docker group?)"

# Refusing to start a deployment that cannot finish. Filling the disk during a
# pull leaves both the old and the new stack broken.
available_kb="$(df -Pk "${STACK_ROOT}" | awk 'NR==2 {print $4}')"
if [ "${available_kb}" -lt 2097152 ]; then
  die "Less than 2 GB free on $(df -Ph "${STACK_ROOT}" | awk 'NR==2 {print $6}'). Free space before deploying."
fi

PREVIOUS_TAG=""
[ -f "${STATE_FILE}" ] && PREVIOUS_TAG="$(tr -d '\r\n' < "${STATE_FILE}")"
info "currently deployed: ${PREVIOUS_TAG:-nothing recorded}"

export IMAGE_TAG

compose() {
  docker compose --file "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --project-directory "${STACK_ROOT}" "$@"
}

# ── Deploy ──────────────────────────────────────────────────────────────────

info "validating the compose configuration"
compose config --quiet || die "The compose configuration is not valid. Nothing was changed."

info "pulling ${IMAGE_TAG}"
# Pulled first so the gap between stopping the old container and starting the
# new one is not spent downloading.
compose pull --quiet || die "Pull failed. Nothing was changed."

info "starting"
if ! compose up -d --wait --wait-timeout "${HEALTH_TIMEOUT}" --remove-orphans; then
  red "✗ the stack did not become healthy within ${HEALTH_TIMEOUT}s"
  printf '\n── logs ──\n'
  compose logs --no-color --tail=100
  printf '\n'
  if [ -n "${PREVIOUS_TAG}" ]; then
    red "Roll back with:  ./scripts/rollback.sh ${ENVIRONMENT}"
  fi
  exit 1
fi

printf '\n'
compose ps
printf '\n'

# ── Verify ──────────────────────────────────────────────────────────────────

if [ -n "${SMOKE_TEST_URL:-}" ]; then
  info "smoke test"
  if ! "${STACK_ROOT}/scripts/smoke-test.sh" "${SMOKE_TEST_URL}" "${SMOKE_TEST_API_URL:-${SMOKE_TEST_URL}/api}"; then
    red "✗ smoke test failed"
    if [ -n "${PREVIOUS_TAG}" ]; then
      red "Roll back with:  ./scripts/rollback.sh ${ENVIRONMENT}"
    fi
    exit 1
  fi
fi

# ── Record ──────────────────────────────────────────────────────────────────

# Written last, so the recorded tag is always one that was observed healthy.
printf '%s\n' "${IMAGE_TAG}" > "${STATE_FILE}"
printf '%s\t%s\t%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${ENVIRONMENT}" "${IMAGE_TAG}" \
  >> "${STACK_ROOT}/.deployment-history"

# A week of images kept, so a rollback to last week does not need a pull.
docker image prune -af --filter 'until=168h' >/dev/null 2>&1 || true

printf '\n'
green "✓ ${ENVIRONMENT} is running ${IMAGE_TAG}"
[ -n "${PREVIOUS_TAG}" ] && info "previous: ${PREVIOUS_TAG} (roll back with ./scripts/rollback.sh ${ENVIRONMENT})"
printf '\n'
