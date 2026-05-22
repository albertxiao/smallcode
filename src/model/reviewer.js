// SmallCode — Reviewer Agent (Feature #18)
//
// A second model call that critiques the executor's most recent assistant
// message before it's acted upon. Catches obvious issues the writer missed:
//   - Missing error handling in generated code
//   - Wrong function/variable names vs the task
//   - Incomplete implementations ("TODO" left in)
//   - Contradicting the user's requirements
//
// Runs ASYNC and non-blocking — the executor keeps going while the reviewer
// thinks. The reviewer result is injected as a follow-up system note if it
// finds a real problem. If no problem, silent.
//
// Designed to be cheap: uses the same model or a smaller one, with a very
// short prompt (task + response summary) and tiny token budget (256 tokens).
// Typical reviewer call cost: 500-1000 tokens total.
//
// Configuration:
//   SMALLCODE_REVIEWER=true              enable reviewer
//   SMALLCODE_REVIEWER_MODEL=<name>      reviewer model (defaults to main model)
//   SMALLCODE_REVIEWER_URL=<url>         reviewer endpoint (defaults to main)
//   SMALLCODE_REVIEWER_THRESHOLD=0.7     confidence threshold to inject (0-1)
//   SMALLCODE_REVIEWER_MAX_TOKENS=256    reviewer response token cap
//
// The reviewer only fires when:
//   1. A write_file or patch tool was called this turn
//   2. The response is longer than 50 chars (skip trivial one-liners)
//   3. The executor model finished (not mid-stream)

'use strict';

const THRESHOLD = parseFloat(process.env.SMALLCODE_REVIEWER_THRESHOLD) || 0.7;
const MAX_TOKENS = parseInt(process.env.SMALLCODE_REVIEWER_MAX_TOKENS) || 256;

let _reviewerConfig = null;
function getReviewerConfig(mainConfig) {
  if (_reviewerConfig) return _reviewerConfig;
  _reviewerConfig = {
    enabled: process.env.SMALLCODE_REVIEWER === 'true',
    model: process.env.SMALLCODE_REVIEWER_MODEL || mainConfig?.model?.name,
    baseUrl: process.env.SMALLCODE_REVIEWER_URL || mainConfig?.model?.baseUrl || 'http://localhost:1234/v1',
  };
  return _reviewerConfig;
}

/**
 * Async reviewer call. Returns { ok, issues, confidence } or null on failure.
 *
 * @param {string} task         - Original user task
 * @param {string} response     - The executor's response to review
 * @param {string[]} editedFiles - Files that were written/patched this turn
 * @param {object} mainConfig   - SmallCode config (for API key + model)
 */
async function reviewResponse(task, response, editedFiles, mainConfig) {
  const cfg = getReviewerConfig(mainConfig);
  if (!cfg.enabled || !cfg.model) return null;
  if (!response || response.length < 50) return null;

  const apiKey = process.env.OPENAI_API_KEY || process.env.ANTHROPIC_API_KEY || mainConfig?.model?.apiKey;
  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) headers['Authorization'] = `Bearer ${apiKey}`;

  const filesNote = editedFiles.length > 0
    ? `Files modified: ${editedFiles.slice(0, 5).join(', ')}.`
    : '';

  const reviewPrompt = `You are a code reviewer. Given a task and an AI assistant's response, identify ONLY critical issues (missing error handling, wrong logic, incomplete implementation, contradicts requirements). Be terse. If the response looks correct, say "LGTM".

Task: ${task.slice(0, 300)}
${filesNote}
Response summary: ${response.slice(0, 500)}

Critical issues (or "LGTM"):`;

  const body = {
    model: cfg.model,
    temperature: 0.1,
    max_tokens: MAX_TOKENS,
    messages: [
      { role: 'user', content: reviewPrompt },
    ],
  };

  try {
    const fetcher = globalThis.fetch || (() => { try { return require('node-fetch'); } catch { return null; } })();
    if (!fetcher) return null;

    const resp = await Promise.race([
      fetcher(`${cfg.baseUrl}/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
      }),
      new Promise((_, rej) => setTimeout(() => rej(new Error('reviewer timeout')), 20000)),
    ]);
    if (!resp.ok) return null;

    const data = await resp.json();
    const content = (data?.choices?.[0]?.message?.content || '').trim();
    if (!content || content.length < 3) return null;

    // Parse the response
    const isLgtm = /^lgtm\.?$/i.test(content) || /looks? (good|correct|fine)/i.test(content);
    if (isLgtm) return { ok: true, issues: [], confidence: 0.9 };

    // Extract issues — anything that isn't LGTM
    const issues = content
      .split(/[\n•\-]+/)
      .map(l => l.trim())
      .filter(l => l.length > 10 && !/^(lgtm|looks? good|no issues)/i.test(l));

    if (issues.length === 0) return { ok: true, issues: [], confidence: 0.8 };

    return {
      ok: false,
      issues,
      confidence: 0.8,
      raw: content,
    };
  } catch {
    return null; // reviewer unavailable — never block
  }
}

/**
 * Format a reviewer result for injection into conversation history.
 * Returns '' if no injection needed.
 */
function formatReviewerInjection(result) {
  if (!result || result.ok) return '';
  if (result.confidence < THRESHOLD) return '';
  if (!result.issues || result.issues.length === 0) return '';

  const top = result.issues.slice(0, 2);
  return `[REVIEWER] Potential issues in the response above:\n${top.map(i => `- ${i}`).join('\n')}\n\nAddress these before finalizing.`;
}

module.exports = {
  reviewResponse,
  formatReviewerInjection,
  getReviewerConfig,
};
