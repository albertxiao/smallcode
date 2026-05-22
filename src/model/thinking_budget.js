// SmallCode — Thinking Budget Control
//
// Modern reasoning models (Qwen3, DeepSeek R1, GPT-5 reasoning, Claude with
// thinking) emit "thinking" tokens before their final answer. These tokens
// are wrapped in `<think>...</think>`, `<reasoning>...</reasoning>`, or
// embedded in a separate field depending on the provider.
//
// Without a budget, a small reasoning model can spend 8000 tokens "thinking"
// about a trivial rename, blowing through context and adding minutes of
// latency. This module provides:
//
//   - `applyThinkingBudget(body, budget)` — mutates the request body to
//     advise the provider on a thinking-token cap. Different providers use
//     different field names; we set them all defensively.
//
//   - `extractThinking(content)` — splits a response into { thinking, answer }
//     so we can show the answer to the model's next turn while logging the
//     thinking separately.
//
//   - `truncateThinking(content, maxThinkingChars)` — emergency cap: if the
//     model emitted way more thinking than budgeted, replace the middle of
//     the thinking block with [...truncated...] before adding to history.
//
// Configuration:
//   SMALLCODE_THINKING_BUDGET=2000    Soft cap (tokens) advised to the model
//   SMALLCODE_THINKING_DISABLE=true   Disable thinking entirely (for repair)
//   SMALLCODE_THINKING_HARD_CAP=8000  Hard cap (chars) — emergency truncation

'use strict';

const DEFAULT_BUDGET_TOKENS = parseInt(process.env.SMALLCODE_THINKING_BUDGET) || 2000;
const HARD_CAP_CHARS = parseInt(process.env.SMALLCODE_THINKING_HARD_CAP) || 32000;

// Patterns for detecting and stripping thinking blocks from model output.
// Models use various conventions — we handle the common ones.
const THINK_PATTERNS = [
  /<think>([\s\S]*?)<\/think>/g,
  /<thinking>([\s\S]*?)<\/thinking>/g,
  /<reasoning>([\s\S]*?)<\/reasoning>/g,
  /<reflection>([\s\S]*?)<\/reflection>/g,
];

/**
 * Apply thinking budget to a chat completion request body.
 * Only injects fields that are appropriate for the target provider.
 * OpenAI's API rejects unknown top-level fields with 400 errors.
 *
 * @param {object} body    - The request body about to be sent
 * @param {object} options
 * @param {number}  options.tokens  - Token budget for thinking (0 = disabled)
 * @param {boolean} options.disable - Disable thinking entirely
 * @param {string}  options.baseUrl - Endpoint URL (used to detect provider)
 */
function applyThinkingBudget(body, options = {}) {
  const opts = { ...options };
  const tokens = opts.disable
    ? 0
    : (typeof opts.tokens === 'number' ? opts.tokens : DEFAULT_BUDGET_TOKENS);

  if (process.env.SMALLCODE_THINKING_DISABLE === 'true') {
    opts.disable = true;
  }

  const baseUrl = String(opts.baseUrl || '').toLowerCase();

  // Detect provider from URL so we only send fields that provider accepts.
  // OpenAI's production API rejects unknown top-level parameters with HTTP 400.
  // LM Studio accepts unknown fields silently but logs warnings about
  // "No valid custom reasoning fields" if reasoning_effort is sent for a model
  // that doesn't support it — wasting cycles on translation attempts.
  const isOpenAICloud = baseUrl.includes('api.openai.com') || baseUrl.includes('openrouter.ai');
  const isAnthropic = baseUrl.includes('anthropic.com') || baseUrl.includes('claude');
  // LM Studio defaults to localhost:1234, often exposed on LAN as 192.168.x.x or 10.x.x.x
  // We can't reliably distinguish LM Studio from raw llama.cpp, so we use the
  // model name as a stronger signal for whether reasoning fields are appropriate.
  const isLocalLlamaCpp = !isOpenAICloud && !isAnthropic;

  // Anthropic-style: { thinking: { type: "enabled", budget_tokens: N } }
  // Send to: Anthropic itself (where it's the actual API) or local reasoning models.
  // Skip for non-reasoning local models — LM Studio logs warnings about
  // "no valid custom reasoning fields" otherwise, and the model can't use it anyway.
  if (isAnthropic || (isLocalLlamaCpp && /(o1|o3|qwen3|qwq|deepseek-r|claude-3-7|claude-4)/.test(String(body.model || '').toLowerCase()))) {
    body.thinking = opts.disable
      ? { type: 'disabled' }
      : { type: 'enabled', budget_tokens: Math.max(0, tokens) };
  }

  // OpenAI o1/o3-style reasoning_effort — only for actual reasoning models.
  // GPT-5.5, gpt-4o, and most local models do NOT support it. LM Studio logs
  // warnings when we send it to a non-reasoning model. Only send when the
  // model name strongly suggests it's a reasoning variant.
  const modelName = String(body.model || '').toLowerCase();
  const isReasoningModel = /(^|[\/\-_])(o1|o3|o4|qwen3|qwq|deepseek-r|deepseek-v3-reason|claude-3-7|claude-4)/.test(modelName);
  if (isReasoningModel) {
    if (!opts.disable) {
      if (tokens <= 500) body.reasoning_effort = 'low';
      else if (tokens <= 3000) body.reasoning_effort = 'medium';
      else body.reasoning_effort = 'high';
    } else {
      body.reasoning_effort = 'low';
    }
  }

  // Qwen/llama.cpp-style fields — local only, never send to OpenAI/Anthropic cloud.
  // Only send when model name suggests it actually understands these fields.
  if (isLocalLlamaCpp && isReasoningModel) {
    body.chat_template_kwargs = body.chat_template_kwargs || {};
    body.chat_template_kwargs.enable_thinking = !opts.disable;
    if (!opts.disable) {
      body.chat_template_kwargs.thinking_budget = tokens;
    }
    body.enable_thinking = !opts.disable;
  }

  return body;
}

/**
 * Extract thinking from a model response. Returns { thinking, answer }.
 * If no thinking tags found, returns { thinking: '', answer: content }.
 */
function extractThinking(content) {
  if (typeof content !== 'string') return { thinking: '', answer: content };
  let thinking = '';
  let answer = content;
  for (const pattern of THINK_PATTERNS) {
    answer = answer.replace(pattern, (_match, inner) => {
      thinking += inner + '\n';
      return ''; // strip the thinking block from the answer
    });
  }
  return { thinking: thinking.trim(), answer: answer.trim() };
}

/**
 * Hard-cap thinking content — if the model ignored the soft budget and emitted
 * way too many thinking tokens, replace the middle of the thinking block with
 * an ellipsis marker. Keeps the start and end so we can debug what it was
 * trying to do without storing 50KB of "let me reconsider" loops.
 *
 * Returns the modified content (with thinking blocks truncated in place).
 */
function truncateThinking(content, maxChars = HARD_CAP_CHARS) {
  if (typeof content !== 'string' || content.length === 0) return content;
  let out = content;
  for (const pattern of THINK_PATTERNS) {
    out = out.replace(pattern, (match, inner) => {
      if (inner.length <= maxChars) return match;
      // Keep first 40% + last 20% of the thinking, ellipsize the middle
      const headLen = Math.floor(maxChars * 0.6);
      const tailLen = Math.floor(maxChars * 0.3);
      const head = inner.slice(0, headLen);
      const tail = inner.slice(inner.length - tailLen);
      const truncatedBytes = inner.length - headLen - tailLen;
      // Re-wrap with the same outer tags as the matched block
      const tagMatch = match.match(/^<(\w+)>/);
      const tag = tagMatch ? tagMatch[1] : 'think';
      return `<${tag}>${head}\n\n[...thinking truncated: ${truncatedBytes} chars omitted...]\n\n${tail}</${tag}>`;
    });
  }
  return out;
}

/**
 * Decide whether thinking should be disabled for a particular call.
 * Used by the improvement loop: after a failed attempt, the repair call
 * benefits from disabling thinking entirely — the model already overthought
 * the first time, we want a fast, deterministic fix.
 *
 * @param {object} ctx - { isRepair: bool, attempt: number, budget: number }
 */
function shouldDisableThinking(ctx = {}) {
  if (process.env.SMALLCODE_THINKING_DISABLE === 'true') return true;
  // On repair attempts (attempt > 1), disable thinking — the model already
  // overthought the original solution. A fast, low-creativity retry is better.
  if (ctx.isRepair && ctx.attempt > 1) return true;
  // Budget of 0 = explicit disable
  if (typeof ctx.budget === 'number' && ctx.budget === 0) return true;
  return false;
}

/**
 * Estimate how many tokens were spent on thinking in a response.
 * Useful for logging and budget tracking. Returns 0 if no thinking found.
 */
function estimateThinkingTokens(content) {
  if (typeof content !== 'string') return 0;
  let totalChars = 0;
  for (const pattern of THINK_PATTERNS) {
    const matches = content.match(pattern);
    if (matches) {
      for (const m of matches) totalChars += m.length;
    }
  }
  // Rough: 4 chars per token
  return Math.ceil(totalChars / 4);
}

module.exports = {
  applyThinkingBudget,
  extractThinking,
  truncateThinking,
  shouldDisableThinking,
  estimateThinkingTokens,
  DEFAULT_BUDGET_TOKENS,
  HARD_CAP_CHARS,
};
