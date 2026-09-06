#!/usr/bin/env bash
#
# Roll the SRI-KO LMS stack back to the previously deployed image tag.
#
#   ./scripts/rollback.sh <environment> [tag]
#   ./scripts/rollback.sh production
#   ./scripts/rollback.sh production 1.1.4
#
# With no tag, it reads .deployment-history and returns to the previous entry
# for that environment.
#
# The reason this is a script rather than instructions in a runbook: a rollback
# happens when something is already broken, usually to whoever is nearest, and
# often at an hour when nobody is at their best. Every decision that can be
# made now, in a calm room, is one that does not have to be made then.

set -euo pipefail

ENVIRONMENT="${1:-staging}"
TARGET_TAG="${2:-}"

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

HISTORY="${STACK_ROOT}/.deployment-history"
STATE_FILE="${STACK_ROOT}/.deployed-tag"
ENV_FILE="${ENV_FILE:-${STACK_ROOT}/.env}"

[ -f "${COMPOSE_FILE}" ] || die "Compose file not found: ${COMPOSE_FILE}"
[ -f "${ENV_FILE}" ]     || die "Environment file not found: ${ENV_FILE}"

CURRENT_TAG=""
[ -f "${STATE_FILE}" ] && CURRENT_TAG="$(tr -d '\r\n' < "${STATE_FILE}")"

if [ -z "${TARGET_TAG}" ]; then
  [ -f "${HISTORY}" ] || die "No deployment history at ${HISTORY}. Pass the tag to roll back to explicitly."

  # The last entry for this environment that is not what is running now.
  TARGET_TAG="$(awk -v env="${ENVIRONMENT}" -v current="${CURRENT_TAG}" \
    '$2 == env && $3 != current { tag = $3 } END { print tag }' "${HISTORY}")"

  [ -n "${TARGET_TAG}" ] || die "No previous deployment for ${ENVIRONMENT} in the history. Pass the tag explicitly."
fi

[ "${TARGET_TAG}" != "${CURRENT_TAG}" ] || die "${TARGET_TAG} is already what is running."

printf '\n'
info "environment  ${ENVIRONMENT}"
info "current      ${CURRENT_TAG:-unknown}"
info "rolling to   ${TARGET_TAG}"
printf '\n'

# Interactive confirmation for production, skippable with ROLLBACK_YES=1 so the
# automated path in the deploy action is not blocked by a prompt.
if [ "${ENVIRONMENT}" = "production" ] && [ "${ROLLBACK_YES:-}" != "1" ]; then
  read -r -p "Roll production back to ${TARGET_TAG}? [y/N] " reply
  case "${reply}" in
    [yY]|[yY][eE][sS]) ;;
    *) info "cancelled"; exit 0 ;;
  esac
fi

export IMAGE_TAG="${TARGET_TAG}"

compose() {
  docker compose --file "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --project-directory "${STACK_ROOT}" "$@"
}

# Captured before anything is replaced: the rollback destroys the evidence of
# why the rollback was needed, and that evidence is what stops it happening
# again next week.
info "capturing the current logs"
compose logs --no-color --tail=500 \
  > "${STACK_ROOT}/rollback-$(date -u +%Y%m%dT%H%M%SZ).log" 2>&1 || true

info "pulling ${TARGET_TAG}"
compose pull --quiet || die "Could not pull ${TARGET_TAG}. Is the tag still in the registry?"

info "starting"
if ! compose up -d --wait --wait-timeout "${HEALTH_TIMEOUT}" --remove-orphans; then
  red "✗ the rollback target did not become healthy either"
  compose logs --no-color --tail=100
  red "Both ${CURRENT_TAG:-the previous version} and ${TARGET_TAG} are failing."
  red "This is unlikely to be the application. Check the database, the network, and the host's disk."
  exit 1
fi

printf '\n'
compose ps
printf '\n'

printf '%s\n' "${TARGET_TAG}" > "${STATE_FILE}"
printf '%s\t%s\t%s\trollback\n' \
  "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${ENVIRONMENT}" "${TARGET_TAG}" >> "${HISTORY}"

green "✓ ${ENVIRONMENT} rolled back to ${TARGET_TAG}"
printf '\n'
red "Do not stop here. A rollback restores service; it does not fix anything."
info "1. Read the captured log in ${STACK_ROOT}"
info "2. Open an issue with the failure and the tag that caused it"
info "3. Add a test that would have caught it before writing the fix"
printf '\n'
