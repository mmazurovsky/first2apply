import { DbSchema, Job } from '@first2apply/core';
import { SupabaseClient } from '@supabase/supabasefork';

import { ILogger } from './logger.ts';
import { ParsedJob } from './parsers/parserTypes.ts';

/**
 * Insert freshly parsed jobs, skipping any that the user has already seen.
 *
 * Dedup is by content fingerprint (normalized company + title), not by
 * externalId: LinkedIn mints a brand-new posting id for the same job every time
 * it is reposted, and one per city for multi-location roles, so the
 * unique (user_id, externalId) constraint can never catch those.
 *
 * The check is status-agnostic — a job already filed as new, applied, archived,
 * filtered out or deleted blocks re-ingestion — and it runs before the
 * description scrape, so a skipped candidate costs no page download and no LLM
 * call. Skipped candidates are recorded in job_dedup_skips.
 *
 * @returns only the jobs that were actually inserted.
 */
export async function insertJobsDeduped({
  supabaseClient,
  jobs,
  logger,
}: {
  supabaseClient: SupabaseClient<DbSchema, 'public'>;
  jobs: ParsedJob[];
  logger: ILogger;
}): Promise<Job[]> {
  if (jobs.length === 0) return [];

  const { data, error } = await supabaseClient.rpc('insert_jobs_deduped', {
    p_jobs: jobs.map((job) => ({ ...job, tags: job.tags ?? [] })),
  });
  if (error) throw new Error(error.message);

  const insertedJobs = (data ?? []) as Job[];
  logger.info(`insert_jobs_deduped: ${jobs.length} candidates -> ${insertedJobs.length} inserted`);

  return insertedJobs;
}
