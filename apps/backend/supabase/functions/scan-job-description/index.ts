import { Job } from '@first2apply/core';
import { getExceptionMessage } from '@first2apply/core';

import { applyAdvancedMatchingFilters } from '../_shared/advancedMatching.ts';
import { CORS_HEADERS } from '../_shared/cors.ts';
import { getEdgeFunctionContext } from '../_shared/edgeFunctions.ts';
import { parseJobDescriptionUpdates } from '../_shared/jobDescriptionParser.ts';
import { createLoggerWithMeta } from '../_shared/logger.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const logger = createLoggerWithMeta({
    function: 'scan-job-description',
  });
  try {
    const context = await getEdgeFunctionContext({
      logger,
      req,
      checkAuthorization: true,
    });
    const { supabaseClient, supabaseAdminClient } = context;

    const body: {
      jobId: number;
      html: string;
      maxRetries?: number;
      retryCount?: number;
      // 'pipeline' is the batch scan: it categorizes the job exactly once.
      // 'refresh' is the user opening a job that has no description yet: it
      // only fills in content and must never re-categorize or reorder the job.
      mode?: 'pipeline' | 'refresh';
    } = await req.json();
    const { jobId, html, maxRetries, retryCount } = body;
    const mode = body.mode ?? 'pipeline';
    logger.info(`processing job description for ${jobId} (mode: ${mode}) ...`);

    // find the job and its site
    const { data: job, error: findJobErr } = await supabaseClient.from('jobs').select('*').eq('id', jobId).single();
    if (findJobErr) {
      throw findJobErr;
    }
    if (!job) {
      throw new Error(`Job not found: ${jobId}`);
    }

    const { data: site, error: findSiteErr } = await supabaseClient
      .from('sites')
      .select('*')
      .eq('id', job.siteId)
      .single();
    if (findSiteErr) {
      throw findSiteErr;
    }

    const parseDescriptionAndSaveUpdates = async () => {
      let updatedJob: Job = { ...job };

      // parse the job description
      logger.info(`[${site.provider}] parsing job description for ${jobId} ...`);

      // update the job with the description
      const updates = await parseJobDescriptionUpdates({
        site,
        job,
        html,
        ...context,
      });
      const isLastRetry = retryCount === maxRetries;
      updatedJob = {
        ...updatedJob,
        description: updates.description ?? job.description,
        salary: !job.salary ? updates.salary : job.salary,
        tags: Array.from(new Set((job.tags ?? []).concat(updates.tags ?? []))),
      };
      if (!updates.description && isLastRetry) {
        logger.error(
          `[${site.provider}] no JD details extracted from the html of job ${jobId}, this could be a problem with the parser`,
          {
            url: job.externalUrl,
            site: site.provider,
          },
        );

        await supabaseClient.from('html_dumps').insert([{ url: job.externalUrl, html }]);
      }

      if (updates.description) {
        logger.info(`[${site.provider}] finished parsing job description for ${job.title}`, {
          site: site.provider,
        });
      }

      if (!updatedJob.description) {
        // use original description to avoid empty descriptions
        updatedJob.description = job.description;
      }

      if (mode === 'refresh') {
        // The job has already been categorized. Fill in the content the user
        // came to read and nothing else - no status, no updated_at (which would
        // teleport the job to the top of its tab), and no advanced matching
        // (which would burn tokens and could silently re-exclude a job the user
        // is actively reading).
        const { error: refreshJobErr } = await supabaseClient
          .from('jobs')
          .update({
            description: updatedJob.description,
            salary: updatedJob.salary,
            tags: updatedJob.tags,
          })
          .eq('id', jobId);
        if (refreshJobErr) {
          throw refreshJobErr;
        }

        return { updatedJob, parseFailed: !updatedJob.description };
      }

      const { newStatus, excludeReason } = await applyAdvancedMatchingFilters({
        logger,
        job: { ...updatedJob, status: 'new' },
        supabaseClient,
        supabaseAdminClient,
      });

      updatedJob = {
        ...updatedJob,
        status: newStatus,
        exclude_reason: excludeReason,
      };

      logger.info(`[${site.provider}] ${updatedJob.status} ${job.title}`);

      // Exactly-once: only a row still awaiting categorization matches. A job
      // that already left 'processing' (or that a racing worker already
      // stamped) matches zero rows and is left completely untouched - no status
      // change, no updated_at bump, no reordering of the New tab.
      const { error: updateJobErr } = await supabaseClient
        .from('jobs')
        .update({
          description: updatedJob.description,
          salary: updatedJob.salary,
          tags: updatedJob.tags,
          status: updatedJob.status,
          updated_at: new Date(),
          processed_at: new Date(),
          exclude_reason: updatedJob.exclude_reason,
        })
        .eq('id', jobId)
        .eq('status', 'processing')
        .is('processed_at', null);
      if (updateJobErr) {
        throw updateJobErr;
      }

      const parseFailed = !updatedJob.description;

      return { updatedJob, parseFailed };
    };

    // Let's add a timeout of 20 seconds on the parsing operation, but without failing it
    // This means it will still work in the background, but the client will not wait for it.
    const timeoutPromise = new Promise<{
      updatedJob: Job;
      parseFailed: boolean;
    }>((resolve) => {
      setTimeout(() => {
        resolve({
          updatedJob: job,
          parseFailed: false,
        });
      }, 30_000);
    });

    const { updatedJob, parseFailed } = await Promise.race([parseDescriptionAndSaveUpdates(), timeoutPromise]);

    return new Response(JSON.stringify({ job: updatedJob, parseFailed }), {
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
    });
  } catch (error) {
    logger.error(getExceptionMessage(error));
    return new Response(JSON.stringify({ errorMessage: getExceptionMessage(error, true) }), {
      headers: { 'Content-Type': 'application/json', ...CORS_HEADERS },
      // until this is fixed: https://github.com/supabase/functions-js/issues/45
      // we have to return 200 and handle the error on the client side
      // status: 500,
    });
  }
});
