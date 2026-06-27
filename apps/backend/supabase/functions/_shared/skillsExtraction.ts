import { DbSchema, Job, getExceptionMessage, throwError } from '@first2apply/core';
import { SupabaseClient } from '@supabase/supabasefork';
import { z } from 'zod';

import { ILogger } from './logger.ts';
import { buildOpenAiClient, logAiUsage } from './openAI.ts';

export const SKILLS_NOTE_MARKER = '## 🛠️ Skills (auto-generated)';

const SkillsFormat = z.object({
  technical: z.array(z.string()).default([]),
  other: z.array(z.string()).default([]),
});

/**
 * Delete any auto-generated skills note for a job (matched by marker; user's
 * manual notes are left untouched).
 */
export async function deleteSkillsNote({
  supabaseAdminClient,
  jobId,
}: {
  supabaseAdminClient: SupabaseClient<DbSchema, 'public'>;
  jobId: number;
}): Promise<void> {
  const { error } = await supabaseAdminClient
    .from('notes')
    .delete()
    .eq('job_id', jobId)
    .ilike('text', `${SKILLS_NOTE_MARKER}%`);
  if (error) {
    throw error;
  }
}

/**
 * Extract tech skills, software skills and explicit requirements from a job
 * description via a second LLM request and save them as a note on the job.
 *
 * Returns the saved note text, or null when no note was created (no
 * description, no skills extracted, or a swallowed error).
 *
 * Best-effort: any failure is logged and swallowed so it never flips a kept
 * job's status or fails the scan/rerun. Skips jobs that already have an
 * auto-generated skills note.
 */
export async function extractAndSaveSkillsNote({
  logger,
  supabaseAdminClient,
  job,
}: {
  logger: ILogger;
  supabaseAdminClient: SupabaseClient<DbSchema, 'public'>;
  job: Job;
}): Promise<string | null> {
  try {
    if (!job.description) {
      return null;
    }

    // delete any existing auto-generated skills note so a rerun refreshes it
    await deleteSkillsNote({ supabaseAdminClient, jobId: job.id });

    logger.info(`extracting skills from job ${job.id} description ...`);
    const { llmConfig, openAi } = buildOpenAiClient();

    const response = await openAi.chat.completions.create({
      model: llmConfig.model,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: generateUserPrompt({ job }) },
      ],
      max_completion_tokens: 1500,
      response_format: { type: 'json_object' },
    });

    const choice = response.choices[0];
    if (choice.finish_reason !== 'stop') {
      throw new Error(`OpenAI response did not finish: ${choice.finish_reason}`);
    }
    const skills = SkillsFormat.parse(
      JSON.parse(choice.message.content ?? throwError('missing content')),
    );

    // persist the cost of the OpenAI API call
    await logAiUsage({
      logger,
      supabaseAdminClient,
      forUserId: job.user_id,
      llmConfig,
      response,
    });

    const text = formatSkillsNote(skills);
    if (!text) {
      logger.info(`no skills extracted for job ${job.id}, skipping note`);
      return null;
    }

    const { error: insertErr } = await supabaseAdminClient.from('notes').insert({
      user_id: job.user_id,
      job_id: job.id,
      text,
      files: [],
    });
    if (insertErr) {
      throw insertErr;
    }

    logger.info(`saved skills note for job ${job.id}`);
    return text;
  } catch (error) {
    logger.error(`failed to extract skills for job ${job.id}: ${getExceptionMessage(error)}`);
    return null;
  }
}

/**
 * Build the markdown note from the extracted skills. Returns an empty string
 * when nothing was extracted so the caller can skip creating a note.
 */
function formatSkillsNote(skills: z.infer<typeof SkillsFormat>): string {
  const sections: string[] = [];

  const renderLine = (heading: string, items: string[]) => {
    const cleaned = items.map((i) => i.trim()).filter((i) => i.length > 0);
    if (cleaned.length === 0) {
      return;
    }
    sections.push(`**${heading}:** ${cleaned.join(', ')}`);
  };

  renderLine('Technical', skills.technical);
  renderLine('Other', skills.other);

  if (sections.length === 0) {
    return '';
  }

  return `${SKILLS_NOTE_MARKER}\n\n${sections.join('\n\n')}`;
}

function generateUserPrompt({ job }: { job: Job }) {
  return `Extract the skills and requirements mentioned in this job posting.

Job Title: ${job.title}
Tags: ${job?.tags?.join(', ') ?? 'None'}
Job Description:
${job.description}`;
}

const SYSTEM_PROMPT = `You analyze a job description and extract what the job asks for.

Always output in English. If the description is in another language, translate the extracted items to English.

Return two lists:
- technical: programming languages, frameworks, libraries, software, and tools the job requires (e.g. "React", "Kubernetes", "Jira", "AWS"). Order from MOST important to LEAST important for this job.
- other: other explicit requirements, such as spoken/written/communication language, relocation, salary, work conditions, on-site/remote, working hours, work authorization or visa, security clearance.

Rules:
- Only include items that are explicitly stated in the description. If something is not mentioned, omit it — do not infer or invent.
- Each item must be concise: 1-3 words, no description sentences. Do not include duplicates.
- If a category has nothing, return an empty array for it.

Reply with a JSON object containing exactly these fields:
- technical: string[]
- other: string[]`;
