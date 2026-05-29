import { parseEnv } from './env.ts';

import { getExceptionMessage } from '@first2apply/core';
import { SupabaseClient } from '@supabase/supabasefork';
import OpenAI from 'openai';

import { ILogger } from './logger.ts';

// Type for OpenAI API response with usage information
type OpenAIResponse = {
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
  };
};

const env = parseEnv();

const SUPPORTED_MODELS = ['deepseek/deepseek-v4-flash'] as const;
type SupportedModel = (typeof SUPPORTED_MODELS)[number];

// TODO: confirm OpenRouter pricing for deepseek-v4-flash before relying on cost figures.
const COST_PER_MODEL: Record<SupportedModel, { input: number; output: number }> = {
  'deepseek/deepseek-v4-flash': { input: 0.27, output: 1.1 },
};

export type OpenRouterConfig = {
  apiKey: string;
};

/**
 * Build a new OpenRouter client (OpenAI-compatible).
 */
export function buildOpenAiClient({ modelName }: { modelName?: SupportedModel } = {}) {
  const openAi = new OpenAI({
    apiKey: env.openRouterConfig.apiKey,
    baseURL: 'https://openrouter.ai/api/v1',
  });

  const model = modelName ?? 'deepseek/deepseek-v4-flash';
  if (!(model in COST_PER_MODEL)) {
    throw new Error(`Unsupported model: ${model}`);
  }
  console.log(`Using model ${model} for OpenRouter calls.`);
  const { input, output } = COST_PER_MODEL[model];
  const llmConfig = {
    model,
    costPerMillionInputTokens: input,
    costPerMillionOutputTokens: output,
  };

  return { openAi, llmConfig };
}

export type LLMConfig = {
  model: string;
  costPerMillionInputTokens: number;
  costPerMillionOutputTokens: number;
};

function computeLlmApiCallCost({ llmConfig, response }: { llmConfig: LLMConfig; response: OpenAIResponse }) {
  const inputTokensUsed = response.usage?.prompt_tokens ?? 0;
  const outputTokensUsed = response.usage?.completion_tokens ?? 0;
  const cost =
    (llmConfig.costPerMillionInputTokens / 1_000_000) * inputTokensUsed +
    (llmConfig.costPerMillionOutputTokens / 1_000_000) * outputTokensUsed;

  return { cost, inputTokensUsed, outputTokensUsed };
}

export async function logAiUsage({
  logger,
  supabaseAdminClient,
  forUserId,
  llmConfig,
  response,
}: {
  logger: ILogger;
  supabaseAdminClient: SupabaseClient;
  forUserId: string;
  llmConfig: LLMConfig;
  response: OpenAIResponse;
}) {
  const { cost, inputTokensUsed, outputTokensUsed } = computeLlmApiCallCost({
    llmConfig,
    response,
  });

  // persist the cost of the OpenAI API call
  const { error: countUsageError } = await supabaseAdminClient.rpc('log_ai_usage', {
    for_user_id: forUserId,
    cost_increment: cost,
    input_tokens_increment: inputTokensUsed,
    output_tokens_increment: outputTokensUsed,
  });
  if (countUsageError) {
    logger.error(getExceptionMessage(countUsageError));
  }
}
