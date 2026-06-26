#!/usr/bin/env bash
#
# restore-db.sh — restore a local Supabase dump made by backup-db.sh.
#
# Usage:
#   bash scripts/restore-db.sh            # restore newest dump
#   bash scripts/restore-db.sh <file.sql> # restore a specific dump
#
# Restores into a DB that already has schema (run `pnpm supabase start` first so
# migrations/seed recreate empty tables), then loads rows data-only.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="supabase_db_first2apply"
BACKUP_DIR="$ROOT_DIR/apps/backend/supabase/.temp/backups"

DUMP="${1:-}"
if [ -z "$DUMP" ]; then
  DUMP="$(ls -t "$BACKUP_DIR"/f2a-*.sql 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$DUMP" ] || [ ! -f "$DUMP" ]; then
  echo "[restore-db] no dump found. Looked in: $BACKUP_DIR" >&2
  exit 1
fi

if ! docker exec "$CONTAINER" true >/dev/null 2>&1; then
  echo "[restore-db] $CONTAINER not running. Start with: cd apps/backend && pnpm supabase start" >&2
  exit 1
fi

echo "[restore-db] restoring $DUMP"
docker exec -i "$CONTAINER" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$DUMP"

echo "[restore-db] row counts after restore:"
docker exec "$CONTAINER" psql -U postgres -d postgres -tA -c \
  "select 'auth.users='||count(*) from auth.users
   union all select 'public.links='||count(*) from public.links
   union all select 'public.jobs='||count(*) from public.jobs;"
echo "[restore-db] done."
