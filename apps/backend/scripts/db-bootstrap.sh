#!/usr/bin/env bash
#
# db-bootstrap.sh — idempotent local Supabase bootstrap.
#
# Applies schema from supabase/seed.sql (via `supabase db reset`) and
# populates the public.sites catalog from supabase/sites_rows.csv.
#
# seed.sql is the schema source of truth. Incremental changes to an EXISTING
# database (local or prod) ship as one-shot idempotent scripts in supabase/sql/,
# applied with psql -v ON_ERROR_STOP=1 -f <file>. Every such change must also be
# folded into seed.sql -- the backups in scripts/backup-db.sh are data-only, so
# a column that exists live but not in seed.sql breaks restore.
#
# Safe to re-run: if public.sites already has rows, exits without changes.
#
# WARNING: when sites is empty, this runs `supabase db reset`, which WIPES
# all local data (auth users, jobs, links, notes, etc.). Use only on
# first-time setup or when you intentionally want a clean DB.
#
# Requirements:
#   - Supabase running (`pnpm supabase start` from apps/backend)
#   - psql installed locally (macOS: `brew install libpq` and link, or use Postgres.app)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CSV="$BACKEND_DIR/supabase/sites_rows.csv"

PGHOST=127.0.0.1
PGPORT=54322
PGUSER=postgres
PGPASSWORD=postgres
PGDATABASE=postgres
export PGPASSWORD

cd "$BACKEND_DIR"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql not found in PATH. Install with: brew install libpq && brew link --force libpq" >&2
  exit 1
fi

if [ ! -f "$CSV" ]; then
  echo "sites CSV not found at $CSV" >&2
  exit 1
fi

echo "Checking Supabase status..."
if ! npx supabase status >/dev/null 2>&1; then
  echo "Supabase not running. Start with: cd apps/backend && pnpm supabase start" >&2
  exit 1
fi

SITES_COUNT=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
  "SELECT COUNT(*) FROM public.sites" 2>/dev/null || echo "missing")

if [[ "$SITES_COUNT" =~ ^[0-9]+$ ]] && [ "$SITES_COUNT" -gt 0 ]; then
  echo "sites already populated ($SITES_COUNT rows). Nothing to do."
  exit 0
fi

echo "Applying schema via supabase db reset (this wipes local data)..."
npx supabase db reset

echo "Importing sites_rows.csv..."
# CSV stores urls / queryParamsToRemove / blacklisted_paths as JSON arrays
# (["a","b"]) but the columns are Postgres text[] ({a,b}). Stage to a temp
# table with text columns, then translate [ ] -> { } during insert.
psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 <<SQL
CREATE TEMP TABLE _sites_stage (
  id bigint,
  name text,
  urls text,
  created_at timestamptz,
  "queryParamsToRemove" text,
  logo_url text,
  blacklisted_paths text,
  provider text,
  deprecated boolean,
  incognito_support boolean
);
\copy _sites_stage(id,name,urls,created_at,"queryParamsToRemove",logo_url,blacklisted_paths,provider,deprecated,incognito_support) FROM '$CSV' WITH (FORMAT csv, HEADER true)

INSERT INTO public.sites(id,name,urls,created_at,"queryParamsToRemove",logo_url,blacklisted_paths,provider,deprecated,incognito_support)
SELECT
  id,
  name,
  translate(urls, '[]', '{}')::text[],
  created_at,
  CASE WHEN "queryParamsToRemove" IS NULL THEN NULL ELSE translate("queryParamsToRemove", '[]', '{}')::text[] END,
  logo_url,
  COALESCE(translate(blacklisted_paths, '[]', '{}')::text[], ARRAY['/']::text[]),
  provider,
  deprecated,
  incognito_support
FROM _sites_stage;

SELECT setval(pg_get_serial_sequence('public.sites','id'), (SELECT MAX(id) FROM public.sites));
SQL

echo "Bumping sites_id_seq done."
FINAL=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc "SELECT COUNT(*) FROM public.sites")
echo "Done. sites rows: $FINAL"
