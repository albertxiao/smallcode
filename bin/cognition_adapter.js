// SmallCode — Cognition Adapter
// Bridges the existing JS runtime to the MarrowScript-compiled cognition layer.
// The compiled cognition layer lives in src/compiled/ and is generated from
// marrow/smallcode_cognition.marrow.
//
// Falls back to the hand-rolled regex classifier if the compiled layer
// fails to load (e.g. tsc hasn't run, env vars not set).

let _cognitionMod = null;
let _cognitionFailed = false;

function _getCognition() {
  if (_cognitionMod) return _cognitionMod;
  if (_cognitionFailed) return null;
  try {
    _cognitionMod = require('../src/compiled/cognition');
    return _cognitionMod;
  } catch (err) {
    _cognitionFailed = true;
    return null;
  }
}

/**
 * Classify a user message into a task type using the compiled MarrowScript prompt.
 * Falls back to regex classifier if the compiled layer is unavailable.
 *
 * @param {string} userMessage - The user's input
 * @param {object} options - { fallback: function(msg) -> string }
 * @returns {Promise<string>} task type (coding | editing | search | shell | explanation | multi_step | debugging | backend)
 */
async function classifyTaskCompiled(userMessage, options = {}) {
  const cognition = _getCognition();
  if (!cognition) {
    return options.fallback ? options.fallback(userMessage) : 'coding';
  }
  try {
    const result = await cognition.callPrompt('classify_task_type', { user_message: userMessage });
    if (typeof result === 'string') {
      const cleaned = result.trim().toLowerCase().replace(/[.,!?]+$/, '');
      const valid = ['coding', 'editing', 'search', 'shell', 'explanation', 'multi_step', 'debugging', 'backend'];
      if (valid.includes(cleaned)) return cleaned;
    }
    return options.fallback ? options.fallback(userMessage) : 'coding';
  } catch (err) {
    return options.fallback ? options.fallback(userMessage) : 'coding';
  }
}

/**
 * Compress conversation history using the compiled MarrowScript prompt.
 *
 * @param {string} history - serialized history
 * @param {number} maxTokens - target compression size
 * @returns {Promise<string|null>} compressed summary or null on failure
 */
async function compressHistoryCompiled(history, maxTokens = 500) {
  const cognition = _getCognition();
  if (!cognition) return null;
  try {
    const result = await cognition.callPrompt('compress_history', { history, max_tokens: maxTokens });
    return typeof result === 'string' ? result : null;
  } catch (err) {
    return null;
  }
}

/**
 * Route a task to a model tier based on complexity.
 * Uses the compiled MarrowScript coding_router which deterministically
 * selects TinyClassifier (≤0.3), SmallCoder (≤0.6), or MediumCoder (default).
 *
 * @param {number} complexity - 0.0 to 1.0 complexity estimate
 * @returns {object|null} { model_id, tier, model } or null if router unavailable
 */
function routeToTier(complexity) {
  const cognition = _getCognition();
  if (!cognition) return null;
  try {
    const router = cognition.getRouter ? cognition.getRouter('coding_router') : null;
    if (!router) return null;
    return router.route({ complexity: typeof complexity === 'number' ? complexity : 0.5 });
  } catch {
    return null;
  }
}

/**
 * Estimate task complexity from a user message (0.0 = trivial, 1.0 = highly complex).
 * Replaces the hand-rolled estimateComplexity in src/model/router.js.
 */
function estimateComplexity(message) {
  if (!message || typeof message !== 'string') return 0.5;
  const msg = message.toLowerCase();
  const len = msg.length;

  const strongPatterns = [
    /\b(refactor|redesign|architect|rewrite|migrate|convert)\b/,
    /\b(multi.?file|multiple files|across files|all files)\b/,
    /\b(system|framework|infrastructure|full.?stack)\b/,
    /\b(test suite|integration test|e2e)\b/,
    /\b(and then|step \d|first.*then.*finally)\b/,
  ];
  if (strongPatterns.some(p => p.test(msg)) || len > 500) return 0.8;

  const fastPatterns = [
    /\b(fix typo|rename|add comment|format|lint)\b/,
    /\b(what is|explain|show me|read)\b/,
    /\b(simple|quick|small|minor)\b/,
  ];
  if (fastPatterns.some(p => p.test(msg)) && len < 100) return 0.2;

  return 0.5;
}

/**
 * Whether the compiled cognition layer is available.
 */
function isCompiledCognitionAvailable() {
  return _getCognition() !== null;
}

/**
 * Get the compiled OpenAI-compatible provider for making LLM calls.
 * Returns the provider instance or null if not available.
 * Gives all calls: SSRF guard, auth headers, logprob confidence, structured errors.
 */
function getCompiledProvider() {
  const cognition = _getCognition();
  if (!cognition || !cognition.getModel) return null;
  try {
    const model = cognition.getModel('SmallCoder');
    return model ? model.provider : null;
  } catch {
    return null;
  }
}

module.exports = {
  classifyTaskCompiled,
  compressHistoryCompiled,
  routeToTier,
  estimateComplexity,
  getCompiledProvider,
  isCompiledCognitionAvailable,
};
