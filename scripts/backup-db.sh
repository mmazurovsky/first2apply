#!/usr/bin/env bash
#
# backup-db.sh — snapshot the local Supabase postgres before it can be wiped.
#
# Data-only dump of the public + auth schemas via the container's own pg_dump
# (pg15), written to a gitignored host dir and rotated to the newest 10.
# Restore with scripts/restore-db.sh.
#
# Safe to call from shutdown hooks: if Docker/the container is down it prints a
# notice and exits 0 — never blocks app/session teardown.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="supabase_db_first2apply"
BACKUP_DIR="$ROOT_DIR/apps/backend/supabase/.temp/backups"
KEEP=10

# container up? (Docker down or stopped -> nothing to back up)
if ! docker exec "$CONTAINER" true >/dev/null 2>&1; then
  echo "[backup-db] $CONTAINER not running — skipping backup."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/f2a-$STAMP.sql"
TMP="$OUT.tmp"

echo "[backup-db] dumping public+auth -> $OUT"
docker exec "$CONTAINER" pg_dump -U postgres -d postgres \
  --data-only --disable-triggers -n public -n auth > "$TMP"
mv "$TMP" "$OUT"

# rotate: keep newest $KEEP, drop the rest
ls -t "$BACKUP_DIR"/f2a-*.sql 2>/dev/null | tail -n +$((KEEP + 1)) | xargs rm -f -- 2>/dev/null || true

echo "[backup-db] done: $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
