#!/usr/bin/env bash
#
# Snapshot the MongoDB database.
#
#   ./scripts/backup-mongo.sh
#   MONGODB_URI=mongodb://... BACKUP_LABEL=pre-v1.0.0 ./scripts/backup-mongo.sh
#
# Called before every production deployment, and worth running on a schedule.
# NFR-02 asks for availability and data integrity; a deployment that can lose
# data and cannot restore it satisfies neither.
#
# The restore command is printed at the end on purpose. A backup nobody knows
# how to restore is a file, not a backup.

set -euo pipefail

MONGODB_URI="${MONGODB_URI:-}"
BACKUP_DIR="${BACKUP_DIR:-/opt/sri-ko-lms/backups}"
BACKUP_LABEL="${BACKUP_LABEL:-scheduled}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m──\033[0m %s\n' "$*"; }
die()   { red "✗ $*"; exit 1; }

[ -n "${MONGODB_URI}" ] || die "MONGODB_URI is not set."

command -v mongodump >/dev/null 2>&1 || \
  die "mongodump is not installed. Install the MongoDB Database Tools, or run this through the mongo container."

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
name="sriko-${BACKUP_LABEL}-${timestamp}"
archive="${BACKUP_DIR}/${name}.gz"

mkdir -p "${BACKUP_DIR}"

info "dumping to ${archive}"

# --gzip --archive writes one file rather than a directory tree: easier to
# copy off the host, and it either restores completely or not at all.
if ! mongodump --uri="${MONGODB_URI}" --gzip --archive="${archive}" --quiet; then
  rm -f "${archive}"
  die "mongodump failed. Nothing was written."
fi

size="$(du -h "${archive}" | cut -f1)"

# A dump that fails halfway leaves a truncated gzip stream. Verifying it now
# is the difference between finding out at backup time and finding out during
# a restore.
info "verifying the archive"
gzip -t "${archive}" 2>/dev/null || die "The archive is corrupt. Do not rely on it."

# A near-empty archive usually means the URI pointed at the wrong database —
# which looks like a successful backup until the day it is needed.
bytes="$(stat -c%s "${archive}" 2>/dev/null || stat -f%z "${archive}")"
if [ "${bytes}" -lt 1024 ]; then
  die "The archive is only ${bytes} bytes. Check that MONGODB_URI names the right database."
fi

green "✓ ${name} (${size})"

if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
  info "copying off-host to s3://${BACKUP_S3_BUCKET}"
  # A backup that lives only on the machine it protects is not a backup: the
  # failure that destroys the host destroys it too.
  aws s3 cp "${archive}" "s3://${BACKUP_S3_BUCKET}/mongodb/${name}.gz" --only-show-errors \
    || red "::warning:: off-host copy failed — the local snapshot is still on disk"
fi

info "pruning snapshots older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name 'sriko-*.gz' -type f -mtime "+${RETENTION_DAYS}" -print -delete || true

printf '\n'
info "restore this snapshot with:"
printf '\n    mongorestore --uri="$MONGODB_URI" --gzip --archive=%s --drop\n\n' "${archive}"
red "  --drop replaces the target database. Restore into a scratch database first and check it."
printf '\n'
