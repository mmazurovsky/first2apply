-- ============================================================================
-- 2026-08-19  Job deduplication + idempotent processing
--
-- Problem: LinkedIn mints a brand-new posting id for the same job (reposts over
-- time, and one posting per city), so unique (user_id, "externalId") can never
-- catch it. 37% of rows were duplicates.
--
-- This script is idempotent and safe to re-run. Apply with:
--   psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -v ON_ERROR_STOP=1 \
--        -f apps/backend/supabase/sql/2026-08-19-job-dedup.sql
--
-- Schema changes here are mirrored into supabase/seed.sql, which is the source
-- of truth for `supabase db reset` AND for restoring the data-only backups.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Fix the broken Delete action.
--    'deleted' is in the TS JobStatus union but was never added to the PG enum,
--    so every Delete click failed with 22P02 and the job stayed in 'new'.
--    Must be a standalone top-level statement (the value is unusable until the
--    adding transaction commits).
-- ---------------------------------------------------------------------------
alter type public."Job Status" add value if not exists 'deleted';


-- ---------------------------------------------------------------------------
-- 1. Fingerprint normalizers
-- ---------------------------------------------------------------------------

-- Unicode fold: lowercase, decompose to NFD and strip combining marks, then
-- map the ligatures/strokes that NFD does not decompose.
-- NOTE: normalize() MUST run before f2a_squash strips non-alphanumerics --
-- the reverse order turns 'fuer' (u-umlaut) into 'f r'.
create or replace function public.f2a_fold(txt text)
returns text language sql immutable parallel safe as $fn$
  select translate(
           replace(
             regexp_replace(normalize(lower(coalesce(txt, '')), NFD), '[\u0300-\u036f]', '', 'g'),
             'ß', 'ss'),
           'øđłþæœ', 'odltao');
$fn$;

-- Collapse to a canonical space-separated token string.
-- Keeps + and # so "C++", "C#" and ".NET" stay meaningful.
create or replace function public.f2a_squash(txt text)
returns text language sql immutable parallel safe as $fn$
  select btrim(
    regexp_replace(
      regexp_replace(coalesce(txt, ''), '[^a-z0-9+#]+', ' ', 'g'),
      '\s+', ' ', 'g'));
$fn$;

-- Title normalizer: strips gender markers and work-mode noise.
-- Uses \m / \M (word boundaries) rather than (^|[^a-z0-9]) -- the latter
-- consumes the boundary character, so adjacent markers escape under the g flag.
create or replace function public.f2a_norm_title(txt text)
returns text language sql immutable parallel safe as $fn$
  select public.f2a_squash(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          public.f2a_fold(txt),
          -- (a) bracketed / pipe-delimited noise segments
          '[\(\[\|][^\)\]\|]*(all genders?|m/w/d|w/m/d|m/f/d|f/m/d|d/f/m|m/w/x|m/f/x|w/m/x|f/m/x|d/m/w|m/w/divers|divers|gn\*?|remote|hybrid|onsite|on-site|100% remote)[^\)\]\|]*([\)\]\|]|$)',
          ' ', 'g'),
        -- (b) bare gender markers with no brackets
        '\m(m/w/d|w/m/d|m/f/d|f/m/d|m/w/x|m/f/x|w/m/x|f/m/x|gn)\M',
        ' ', 'g'),
      -- (c) standalone work-mode words anywhere
      '\m(remote|remotely|hybrid|onsite|on-site)\M',
      ' ', 'g'));
$fn$;

-- Company normalizer. Deliberately NO legal-suffix stripping (GmbH/SE/Inc/Ltd):
-- LinkedIn company names are already stable per employer, so it buys little,
-- and a \mco\M rule would maul "FetchJobs.co".
create or replace function public.f2a_norm_company(txt text)
returns text language sql immutable parallel safe as $fn$
  select public.f2a_squash(public.f2a_fold(txt));
$fn$;

create or replace function public.f2a_norm_location(txt text)
returns text language sql immutable parallel safe as $fn$
  select public.f2a_squash(public.f2a_fold(txt));
$fn$;


-- ---------------------------------------------------------------------------
-- 2. Columns, trigger, indexes
-- ---------------------------------------------------------------------------
alter table public.jobs
  add column if not exists dedup_key             text,
  add column if not exists dedup_key_loc         text,
  add column if not exists processed_at          timestamptz,
  add column if not exists processing_started_at timestamptz;

-- Trigger rather than GENERATED ... STORED: a generated column pins its
-- expression at DDL time, so CREATE OR REPLACE on a normalizer would leave
-- stored values stale with no error. It also cannot reference another
-- generated column, so dedup_key_loc could not reuse dedup_key.
create or replace function public.update_job_dedup_keys()
returns trigger language plpgsql as $fn$
declare
  k text;
begin
  k := public.f2a_norm_company(new."companyName") || '|' || public.f2a_norm_title(new.title);
  new.dedup_key     := k;
  new.dedup_key_loc := k || '|' || public.f2a_norm_location(new.location);
  return new;
end;
$fn$;

drop trigger if exists trigger_update_job_dedup_keys on public.jobs;
create trigger trigger_update_job_dedup_keys
before insert or update of title, "companyName", location on public.jobs
for each row execute function public.update_job_dedup_keys();

create index if not exists jobs_user_dedup_key_idx
  on public.jobs (user_id, dedup_key);
create index if not exists jobs_user_dedup_key_loc_idx
  on public.jobs (user_id, dedup_key_loc);


-- ---------------------------------------------------------------------------
-- 3. Per-user escape hatch
-- ---------------------------------------------------------------------------
alter table public.advanced_matching
  add column if not exists dedup_mode text not null default 'company_title';

alter table public.advanced_matching
  drop constraint if exists advanced_matching_dedup_mode_check;
alter table public.advanced_matching
  add constraint advanced_matching_dedup_mode_check
  check (dedup_mode in ('off', 'company_title', 'company_title_location'));


-- ---------------------------------------------------------------------------
-- 4. Audit trail for suppressed candidates
--    "Never insert" leaves no record, so keep every skipped candidate's URL.
-- ---------------------------------------------------------------------------
create table if not exists public.job_dedup_skips (
  id bigint generated by default as identity,
  user_id uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  dedup_key text not null,
  "externalId" text not null,
  "externalUrl" text not null,
  title text not null,
  "companyName" text not null,
  location text null,
  link_id bigint null,
  kept_job_id bigint null,
  constraint job_dedup_skips_pkey primary key (id),
  constraint job_dedup_skips_user_id_fkey
    foreign key (user_id) references auth.users (id) on delete restrict
) tablespace pg_default;

create index if not exists job_dedup_skips_user_created_idx
  on public.job_dedup_skips (user_id, created_at desc);

alter table public.job_dedup_skips enable row level security;

drop policy if exists "enable all for users based on user_id" on public.job_dedup_skips;
create policy "enable all for users based on user_id" on public.job_dedup_skips
  as permissive for all to authenticated
  using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ---------------------------------------------------------------------------
-- 5. Deduplicating ingestion RPC
--    Replaces the .upsert() in scan-urls and create-link.
-- ---------------------------------------------------------------------------
create or replace function public.insert_jobs_deduped(p_jobs jsonb)
returns setof public.jobs
language plpgsql
security invoker
as $fn$
declare
  v_user uuid := auth.uid();
  v_mode text;
begin
  if v_user is null then
    raise exception 'not authenticated';
  end if;

  select am.dedup_mode into v_mode
  from public.advanced_matching am
  where am.user_id = v_user;
  v_mode := coalesce(v_mode, 'company_title');

  -- Serialize ingestion per user so the read-existing / insert-new pair below is
  -- atomic w.r.t. sibling scan-urls invocations (jobScanner fans out over links
  -- under Promise.all). xact-scoped, so PostgREST's per-request transaction
  -- releases it automatically.
  perform pg_advisory_xact_lock(hashtextextended(v_user::text, 42));

  return query
  with payload as (
    select
      j ->> 'externalId'                as external_id,
      j ->> 'externalUrl'               as external_url,
      (j ->> 'siteId')::bigint          as site_id,
      j ->> 'title'                     as title,
      j ->> 'companyName'               as company_name,
      nullif(j ->> 'companyLogo', '')   as company_logo,
      nullif(j ->> 'location', '')      as location,
      nullif(j ->> 'salary', '')        as salary,
      nullif(j ->> 'jobType', '')       as job_type,
      coalesce((select array_agg(t)
                from jsonb_array_elements_text(coalesce(j -> 'tags', '[]'::jsonb)) t),
               '{}'::text[])            as tags,
      nullif(j ->> 'link_id', '')::bigint as link_id,
      ord
    from jsonb_array_elements(p_jobs) with ordinality as e(j, ord)
    where j ->> 'externalId' is not null
      and j ->> 'title' is not null
      and j ->> 'companyName' is not null
  ),
  keyed as (
    select p.*,
      case
        when v_mode = 'company_title_location' then
          public.f2a_norm_company(p.company_name) || '|' || public.f2a_norm_title(p.title)
            || '|' || public.f2a_norm_location(p.location)
        else
          public.f2a_norm_company(p.company_name) || '|' || public.f2a_norm_title(p.title)
      end as eff_key
    from payload p
  ),
  -- Intra-batch dedup. The 25-city fan-out arrives in ONE payload, so this is
  -- what collapses it; the cross-batch check below cannot see uncommitted rows.
  ranked as (
    select k.*, row_number() over (partition by k.eff_key order by k.ord) as rn
    from keyed k
  ),
  -- Cross-batch dedup: status-agnostic, so new / applied / archived / filtered
  -- out / deleted all block re-ingestion. This is the core requirement.
  matched as (
    select r.*,
      (select ej.id from public.jobs ej
        where ej.user_id = v_user
          and (case when v_mode = 'company_title_location'
                    then ej.dedup_key_loc else ej.dedup_key end) = r.eff_key
        order by ej.id
        limit 1) as kept_job_id
    from ranked r
  ),
  survivors as (
    select * from matched
    where v_mode = 'off'
       or (rn = 1 and kept_job_id is null)
  ),
  skipped as (
    select * from matched
    where v_mode <> 'off'
      and (rn > 1 or kept_job_id is not null)
  ),
  -- Data-modifying CTEs always run to completion even when unreferenced.
  log_skips as (
    insert into public.job_dedup_skips (
      user_id, dedup_key, "externalId", "externalUrl",
      title, "companyName", location, link_id, kept_job_id)
    select v_user, s.eff_key, s.external_id, s.external_url,
           s.title, s.company_name, s.location, s.link_id, s.kept_job_id
    from skipped s
    returning 1
  )
  insert into public.jobs (
    user_id, "externalId", "externalUrl", "siteId", title, "companyName",
    "companyLogo", location, salary, "jobType", tags, link_id, status
  )
  select v_user, s.external_id, s.external_url, s.site_id, s.title, s.company_name,
         s.company_logo, s.location, s.salary, s.job_type, s.tags, s.link_id,
         'processing'::public."Job Status"
  from survivors s
  on conflict (user_id, "externalId") do nothing
  returning *;
end;
$fn$;

grant execute on function public.insert_jobs_deduped(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Atomic claim for the description-scan pipeline
--    Replaces listJobs({ status: 'processing' }), which re-handed the same
--    leftovers to every cron tick.
-- ---------------------------------------------------------------------------
create or replace function public.claim_jobs_for_processing(
  p_limit int default 300,
  p_stale_after interval default '15 minutes'
)
returns setof public.jobs
language plpgsql
security invoker
as $fn$
begin
  return query
  update public.jobs j
  set processing_started_at = now()
  where j.id in (
    select id from public.jobs
    where user_id = auth.uid()
      and status = 'processing'
      and (processing_started_at is null
           or processing_started_at < now() - p_stale_after)
    order by created_at asc
    limit p_limit
    for update skip locked
  )
  returning j.*;
end;
$fn$;

grant execute on function public.claim_jobs_for_processing(int, interval) to authenticated;


-- ---------------------------------------------------------------------------
-- 7. Backfill fingerprints for existing rows.
--    RE-RUN THIS BLOCK any time a f2a_norm_* function is tuned -- that is the
--    whole reason dedup_key is trigger-maintained rather than GENERATED.
--    (To force a full recompute: update public.jobs set dedup_key = null;)
--    Batched, mirroring the job_search_vector backfill already in seed.sql.
-- ---------------------------------------------------------------------------
do $do$
declare n int;
begin
  loop
    update public.jobs j
    set dedup_key     = public.f2a_norm_company(j."companyName") || '|' || public.f2a_norm_title(j.title),
        dedup_key_loc = public.f2a_norm_company(j."companyName") || '|' || public.f2a_norm_title(j.title)
                        || '|' || public.f2a_norm_location(j.location)
    where j.id in (select id from public.jobs where dedup_key is null limit 5000);
    get diagnostics n = row_count;
    exit when n = 0;
    raise notice 'backfilled % rows', n;
  end loop;
end
$do$;


-- ---------------------------------------------------------------------------
-- 8. Backfill processed_at. Anything not currently 'processing' has by
--    definition already been categorized.
-- ---------------------------------------------------------------------------
update public.jobs
set processed_at = coalesce(updated_at, created_at)
where processed_at is null
  and status <> 'processing';


-- ---------------------------------------------------------------------------
-- 9. Collapse existing duplicates -- IN THE NEW TAB ONLY.
--    Other tabs are deliberately left untouched.
--
--    Keeper priority never demotes something the user acted on:
--      applied > archived > new > excluded, then newest first (freshest URL).
--    Losers move to excluded_by_advanced_matching with a legible reason --
--    jobSummary.tsx already renders exclude_reason for that status, so the user
--    sees "Duplicate of job #1234" for free. Nothing is destroyed; reverse with
--      update public.jobs set status = 'new', exclude_reason = null
--      where exclude_reason like 'Duplicate of job #%';
--
--    Idempotent: after the first pass those rows are no longer status='new'.
-- ---------------------------------------------------------------------------
with ranked as (
  select id,
         row_number() over (
           partition by user_id, dedup_key
           order by case status
                      when 'applied'  then 0
                      when 'archived' then 1
                      when 'new'      then 2
                      when 'excluded_by_advanced_matching' then 3
                      else 4
                    end,
                    created_at desc, id desc) as rn,
         first_value(id) over (
           partition by user_id, dedup_key
           order by case status
                      when 'applied'  then 0
                      when 'archived' then 1
                      when 'new'      then 2
                      when 'excluded_by_advanced_matching' then 3
                      else 4
                    end,
                    created_at desc, id desc) as keeper_id,
         status
  from public.jobs
)
update public.jobs j
set status         = 'excluded_by_advanced_matching',
    exclude_reason = 'Duplicate of job #' || r.keeper_id || ' (same company + title)',
    processed_at   = coalesce(j.processed_at, now())
from ranked r
where j.id = r.id
  and r.rn > 1
  and j.status = 'new';
