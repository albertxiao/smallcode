// SmallCode — Multi-Model Chaining (Feature #15)
//
// Routes specific sub-tasks to cheaper/faster models, then passes results
// forward to the main executor model. Unlike the escalation engine (failure
// path: local → cloud), chaining is a SUCCESS path:
//
//   1B classifier → 4B planner → 8B executor
//
// This means the expensive model only runs on the hard parts.
//
// Chain config in smallcode.toml / .env:
//   SMALLCODE_CHAIN=true              enable chaining
//   SMALLCODE_CHAIN_CLASSIFIER=<name> model for task classification (tiny)
//   SMALLCODE_CHAIN_PLANNER=<name>    model for plan generation (small)
//   SMALLCODE_CHAIN_EXECUTOR=<name>   model for code execution (main)
//   SMALLCODE_CHAIN_BASE_URL=<url>    shared base URL (defaults to SMALLCODE_BASE_URL)
//
// Each chain step gets its own base URL override (useful for running different
// models on different LM Studio instances or ports):
//   SMALLCODE_CHAIN_CLASSIFIER_URL=<url>
//   SMALLCODE_CHAIN_PLANNER_URL=<url>
//   SMALLCODE_CHAIN_EXECUTOR_URL=<url>
//
// How it works:
//   - On a new user turn, if chaining is enabled AND the task looks multi-step,
//     we first call the PLANNER model with a minimal prompt to get a numbered plan.
//   - The plan is injected as a system message for the EXECUTOR model.
//   - On simple tasks (fast complexity), we skip directly to the executor.
//   - The planner call uses a stripped-down context (no tools, no history) so
//     it's fast and cheap — typically 500-1000 tokens total.
//
// If any chain step fails (model unavailable, timeout), we fall through to the
// executor directly — chaining is best-effort, never blocking.

'use strict';


// ─── Config ────────────────────────────────────────────────────────────────

let _chainConfig = null;

function getChainConfig() {
  // Cache after first read — env vars don't change mid-run
  if (_chainConfig) return _chainConfig;
  _chainConfig = {
    enabled: process.env.SMALLCODE_CHAIN === 'true',
    classifier: process.env.SMALLCODE_CHAIN_CLASSIFIER || null,
    planner: process.env.SMALLCODE_CHAIN_PLANNER || null,
    executor: process.env.SMALLCODE_CHAIN_EXECUTOR || null,
    baseUrl: process.env.SMALLCODE_CHAIN_BASE_URL
          || process.env.SMALLCODE_BASE_URL
          || 'http://localhost:1234/v1',
    classifierUrl: process.env.SMALLCODE_CHAIN_CLASSIFIER_URL || null,
    plannerUrl: process.env.SMALLCODE_CHAIN_PLANNER_URL || null,
    executorUrl: process.env.SMALLCODE_CHAIN_EXECUTOR_URL || null,
  };
  return _chainConfig;
}

// ─── Planner call ──────────────────────────────────────────────────────────

/**
 * Call the planner model to get a lightweight numbered plan for a task.
 * Returns a plan string or null if planning should be skipped.
 *
 * @param {string} task     - The user's task description
 * @param {object} config   - SmallCode config (for API key etc.)
 */
async function callPlanner(task, config) {
  const chain = getChainConfig();
  if (!chain.enabled || !chain.planner) return null;

  const baseUrl = chain.plannerUrl || chain.baseUrl;
  const url = `${baseUrl}/chat/completions`;
  const apiKey = process.env.OPENAI_API_KEY || process.env.ANTHROPIC_API_KEY || config?.model?.apiKey;
  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`;

  const body = {
    model: chain.planner,
    temperature: 0.1,
    max_tokens: 512,
    messages: [
      {
        role: 'system',
        content: `You are a task planner. Given a coding task, output ONLY a numbered list of 2-6 concrete steps. No explanations. Just the numbered plan.`,
      },
      {
        role: 'user',
        content: `Task: ${task.slice(0, 800)}`,
      },
    ],
  };

  try {
    // Use native fetch (Node 18+) or fall back to node-fetch v2 (CommonJS).
    // node-fetch v3 is ESM-only and won't work with require().
    let fetcher = globalThis.fetch;
    if (!fetcher) {
      try { fetcher = require('node-fetch'); } catch {}
    }
    if (!fetcher) return null;

    const resp = await Promise.race([
      fetcher(url, { method: 'POST', headers, body: JSON.stringify(body) }),
      new Promise((_, rej) => setTimeout(() => rej(new Error('planner timeout')), 15000)),
    ]);
    if (!resp.ok) return null;
    const data = await resp.json();
    const content = data?.choices?.[0]?.message?.content || '';
    if (!content || content.length < 10) return null;

    // Validate it looks like a plan (has at least one numbered line)
    if (!/^\s*\d+[\.\)]/m.test(content)) return null;

    return content.trim();
  } catch {
    return null; // planner unavailable — fall through to executor
  }
}

/**
 * Get the executor model name for a task, respecting chain config.
 * Falls back to config.model.name if no chain configured.
 *
 * @param {string} task     - User task (for complexity estimation)
 * @param {object} config   - SmallCode config
 */
function getExecutorModel(task, config) {
  const chain = getChainConfig();
  if (!chain.enabled) return config.model.name;
  if (!chain.executor) return config.model.name;
  return chain.executor;
}

/**
 * Get the base URL for the executor, respecting chain config.
 */
function getExecutorUrl(config) {
  const chain = getChainConfig();
  if (!chain.enabled || !chain.executorUrl) {
    return config.model.baseUrl || chain.baseUrl;
  }
  return chain.executorUrl;
}

/**
 * Format a planner-produced plan for injection into the system prompt.
 * Returns '' if plan is null.
 */
function formatPlannerInjection(plan) {
  if (!plan) return '';
  return `\n\nPRE-ANALYZED PLAN (from lightweight planner model):\n${plan}\n\nExecute these steps in order.`;
}

module.exports = {
  callPlanner,
  getChainConfig,
  getExecutorModel,
  getExecutorUrl,
  formatPlannerInjection,
};
