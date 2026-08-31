import { Job, getExceptionMessage } from '@first2apply/core';

import { applyAdvancedMatchingFilters } from '../_shared/advancedMatching.ts';
import { CORS_HEADERS } from '../_shared/cors.ts';
import { getEdgeFunctionContext } from '../_shared/edgeFunctions.ts';
import { createLoggerWithMeta } from '../_shared/logger.ts';
import { checkUserSubscription } from '../_shared/subscription.ts';

const CHUNK_SIZE = 5;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const logger = createLoggerWithMeta({
    function: 'rerun-advanced-matching',
  });
  try {
    const context = await getEdgeFunctionContext({
      logger,
      req,
      checkAuthorization: true,
    });
    const { user, supabaseClient, supabaseAdminClient } = context;

    const { hasAdvancedMatching } = await checkUserSubscription({
      supabaseAdminClient,
      userId: user.id,
    });
    if (!hasAdvancedMatching) {
      throw new Error('Advanced matching is only available on the PRO plan.');
    }

    let body: { jobIds?: number[] } = {};
    try {
      body = (await req.json()) ?? {};
    } catch (_) {
      body = {};
    }
    const jobIdsFilter = Array.isArray(body.jobIds) ? body.jobIds : undefined;

    let jobsQuery = supabaseClient.from('jobs').select('*').eq('user_id', user.id).eq('status', 'new');
    if (jobIdsFilter && jobIdsFilter.length > 0) {
      jobsQuery = jobsQuery.in('id', jobIdsFilter);
    }
    const { data: jobs, error: listJobsErr } = await jobsQuery;
    if (listJobsErr) throw listJobsErr;

    const newJobs: Job[] = jobs ?? [];
    logger.info(`re-running advanced matching against ${newJobs.length} jobs`);

    let processed = 0;
    let excluded = 0;

    for (let i = 0; i < newJobs.length; i += CHUNK_SIZE) {
      const chunk = newJobs.slice(i, i + CHUNK_SIZE);
      const results = await Promise.all(
        chunk.map(async (job) => {
          try {
            const { newStatus, excludeReason } = await applyAdvancedMatchingFilters({
              logger,
              supabaseClient,
              supabaseAdminClient,
              job,
            });
            return { job, newStatus, excludeReason };
          } catch (err) {
            logger.error(`failed to re-evaluate job ${job.id}: ${getExceptionMessage(err)}`);
            return null;
          }
        }),
      );

      for (const res of results) {
        if (!res) continue;
        processed += 1;
        if (res.newStatus === 'excluded_by_advanced_matching') {
          const { error: updateErr } = await supabaseClient
            .from('jobs')
            .update({
              status: res.newStatus,
              exclude_reason: res.excludeReason ?? null,
              updated_at: new Date(),
              processed_at: new Date(),
            })
            .eq('id', res.job.id)
            .eq('status', 'new');
          if (updateErr) {
            logger.error(`failed to update job ${res.job.id}: ${updateErr.message}`);
            continue;
          }
          excluded += 1;
        }
      }
    }

    logger.info(`re-run finished. processed=${processed} excluded=${excluded}`);

    return new Response(JSON.stringify({ processed, excluded }), {
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  } catch (error) {
    logger.error(getExceptionMessage(error));
    return new Response(JSON.stringify({ errorMessage: getExceptionMessage(error, true) }), {
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  }
});
