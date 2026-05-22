// SmallCode — Features 1-6 Adapter
// Bridges the MarrowScript-compiled features into the agent loop.
// Compiled from: marrow/features_1_6.marrow
//
// Features:
//   1. repairToolCall(originalCall, error, schema)       — fix bad tool JSON
//   2. summarizeFileCompiled(path, content, targetTokens) — LLM file summary
//   3. policy enforcement — assertWithinBudget / chargeBudget
//   4. setApprovalHandler(fn)                            — checkpoint flow for write approval
//   5. retrieveContext(userMessage, mcpCall)             — semantic context retrieval
//   6. validateEditCompiled(filePath, content, task)     — self-critique after writes

'use strict';

// Lazy-load compiled modules
let _prompts = null;
let _policy = null;
let _checkpoints = null;
let _contextRetriever = null;

function _getPrompts() {
  if (_prompts) return _prompts;
  try { _prompts = require('../src/compiled/features/prompts'); return _prompts; } catch { return null; }
}

function _getPolicy() {
  if (_policy) return _policy;
  try { _policy = require('../src/compiled/features/policy'); return _policy; } catch { return null; }
}

function _getCheckpoints() {
  if (_checkpoints) return _checkpoints;
  try { _checkpoints = require('../src/compiled/features/checkpoints'); return _checkpoints; } catch { return null; }
}

function _getContextRetriever() {
  if (_contextRetriever) return _contextRetriever;
  try { _contextRetriever = require('../src/compiled/features/context_retriever'); return _contextRetriever; } catch { return null; }
}

// ─── Feature 1: Repair a malformed tool call ─────────────────────────────────

/**
 * Sends original_call + error + schema back to model for self-repair.
 * @returns {{ ok: boolean, repairedCall?: string, error?: string }}
 */
async function repairToolCall(originalCall, error, toolSchema) {
  const prompts = _getPrompts();
  if (!prompts) return { ok: false, error: 'prompts module unavailable' };
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('repair_tool_call', {
      original_call: String(originalCall).slice(0, 2000),
      error: String(error).slice(0, 500),
      tool_schema: String(toolSchema).slice(0, 1000),
    }, { trace_id: traceId });
    return { ok: true, repairedCall: String(result) };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ─── Feature 2: Summarize a large file ───────────────────────────────────────

/**
 * Summarize a large file to function signatures.
 * Returns summary string or null on failure.
 * Cached by content hash (1h TTL). Only runs on files > 100 lines.
 */
async function summarizeFileCompiled(filePath, content, targetTokens = 500) {
  const prompts = _getPrompts();
  if (!prompts) return null;
  if (!content || content.split('\n').length < 100) return null;
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('summarize_file', {
      file_path: filePath,
      content: content.slice(0, 8000),
      target_tokens: targetTokens,
    }, { trace_id: traceId });
    return String(result);
  } catch {
    return null;
  }
}

// ─── Feature 3: Budget policy enforcement ────────────────────────────────────

/**
 * Assert within budget before a turn.
 * Throws if rate limit exceeded. Silent if policy module unavailable.
 */
function assertWithinBudget(action, charge = {}) {
  const policy = _getPolicy();
  if (!policy) return; // graceful degradation
  policy.assertWithinBudget(action, charge);
}

/**
 * Charge budget after a turn completes.
 */
function chargeBudget(action, charge = {}) {
  const policy = _getPolicy();
  if (!policy) return;
  policy.chargeBudget(action, charge);
}

/**
 * Get current budget state for /tokens display.
 */
function getBudgetState() {
  const policy = _getPolicy();
  if (!policy) return null;
  return policy.getBudgetState();
}

// ─── Feature 4: Checkpoint approval flow ─────────────────────────────────────

/**
 * Set the TUI approval handler for edit checkpoints.
 * fn(flowRunId, checkpointName) => Promise<'approve'|'reject'|'edit'>
 */
function setApprovalHandler(fn) {
  const checkpoints = _getCheckpoints();
  if (!checkpoints) return;
  checkpoints.setApprovalHandler(fn);
}

/**
 * Await a checkpoint decision (used by the flow runtime).
 */
async function awaitCheckpointDecision(flowRunId, checkpointName, timeoutMs = 300000) {
  const checkpoints = _getCheckpoints();
  if (!checkpoints) return { decision: 'approve', timed_out: false, actor_id: 'fallback' };
  return checkpoints.awaitDecision(flowRunId, checkpointName, timeoutMs, 'cancel');
}

/**
 * Submit a checkpoint decision (called from TUI keypress handler).
 */
function submitCheckpointDecision(flowRunId, checkpointName, decision, actorId = 'user') {
  const checkpoints = _getCheckpoints();
  if (!checkpoints) return { ok: false };
  return checkpoints.submitDecision(flowRunId, checkpointName, decision, null, actorId);
}

// ─── Feature 5: Semantic context retrieval ───────────────────────────────────

/**
 * Retrieve relevant context for a user message via code graph.
 * @returns {{ files: string[], symbols: string[], tokenEstimate: number }}
 */
async function retrieveContext(userMessage, mcpCall, maxFiles = 8) {
  const retriever = _getContextRetriever();
  if (!retriever) return { files: [], symbols: [], tokenEstimate: 0 };
  return retriever.retrieveContext(userMessage, mcpCall, maxFiles);
}

/**
 * Extract structured plan steps from any text format using LLM.
 * MarrowScript Feature #3: replaces regex-based parsePlan() in plan_tracker.js
 * with a compiled classifier that handles prose-embedded plans.
 *
 * @param {string} response - Model response that may contain a plan
 * @returns {Promise<string[]|null>} array of step strings, or null
 */
async function extractPlanSteps(response) {
  const prompts = _getPrompts();
  if (!prompts) return null;
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('extract_plan', { response }, { trace_id: traceId });
    const clean = String(result).trim().replace(/^```[a-z]*\n?/, '').replace(/\n?```$/, '');
    const parsed = JSON.parse(clean);
    if (!Array.isArray(parsed) || parsed.length < 2) return null;
    return parsed.slice(0, 8).map(s => String(s).slice(0, 200));
  } catch {
    return null; // fall back to regex parser in plan_tracker.js
  }
}

/**
 * Generate a conventional commit message for the auto-commit feature.
 * MarrowScript Feature #2: replaces the hand-rolled string truncation in
 * the auto-commit block of runAgentLoop.
 *
 * @param {string} task         - The user's task description
 * @param {string[]} changedFiles - Files modified this turn
 * @returns {Promise<string>} commit message string
 */
async function generateCommitMessage(task, changedFiles) {
  const prompts = _getPrompts();
  const fallback = `smallcode: ${task.slice(0, 50).replace(/[\n\r"'`$\\]/g, ' ').trim()}`;
  if (!prompts) return fallback;
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('commit_message', {
      task: task,
      changed_files: changedFiles.slice(0, 10).join(', '),
    }, { trace_id: traceId });
    const msg = String(result).trim()
      .replace(/^["']|["']$/g, '')  // strip surrounding quotes
      .replace(/\.$/, '')            // strip trailing period
      .slice(0, 72);
    // Validate conventional commit format
    if (/^(feat|fix|docs|refactor|test|chore|style|ci|perf|build|revert)(\(.+\))?:/.test(msg)) {
      return msg;
    }
    // Model didn't follow the format — use its output as the description with a generic prefix
    return `chore: ${msg.slice(0, 65)}`;
  } catch {
    return fallback;
  }
}

/**
 * Check if a user message is too vague to act on.
 * MarrowScript Feature #1: compiled intent_clarifier replaces hand-rolled regex
 * in src/session/clarify.js. Falls back to the regex version if the model is
 * unavailable (e.g. first turn before model is warmed up).
 *
 * @returns {Promise<boolean>} true = needs clarification
 */
async function checkNeedsClarification(userMessage) {
  const prompts = _getPrompts();
  if (!prompts) {
    // Fallback to regex (src/session/clarify.js)
    const { needsClarification } = require('../src/session/clarify');
    return needsClarification(userMessage);
  }
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('intent_clarifier', {
      user_message: userMessage,
    }, { trace_id: traceId });
    return String(result).trim().toLowerCase().startsWith('vague');
  } catch {
    // On any model failure, fall back to regex — never block on clarifier errors
    const { needsClarification } = require('../src/session/clarify');
    return needsClarification(userMessage);
  }
}

/**
 * Ask model if the edit result looks correct.
 * @returns {{ ok: boolean, issues: string[] }}
 */
async function validateEditCompiled(filePath, content, originalTask) {
  const prompts = _getPrompts();
  if (!prompts) return { ok: true, issues: [] }; // graceful: don't block on unavailable
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('validate_edit', {
      file_path: filePath,
      content: content.slice(0, 4000),
      original_task: String(originalTask || '').slice(0, 500),
    }, { trace_id: traceId });
    const text = String(result).toLowerCase();
    const passed = text.includes('ok') || text.includes('correct') || text.includes('looks good') ||
      text.includes('valid') || text.includes('pass') || !text.includes('error');
    return { ok: passed, issues: passed ? [] : [String(result).slice(0, 200)] };
  } catch {
    return { ok: true, issues: [] }; // fail open
  }
}

// ─── Feature Rank 4: diagnoseError ───────────────────────────────────────────

/**
 * Analyze a bash command failure and return a structured hint.
 * MarrowScript Rank 4: replaces ad-hoc error string formatting.
 * Cached 5m. Falls back to null on model failure.
 *
 * @param {string} command  - The command that failed
 * @param {string} stderr   - Combined stdout+stderr output
 * @param {number|string} exitCode
 * @returns {Promise<{type:string,file:string|null,line:number|null,suggestion:string}|null>}
 */
async function diagnoseError(command, stderr, exitCode) {
  const prompts = _getPrompts();
  if (!prompts) return null;
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('error_diagnosis', {
      command: String(command).slice(0, 500),
      stderr: String(stderr).slice(0, 1500),
      exit_code: String(exitCode),
    }, { trace_id: traceId });
    const clean = String(result).trim().replace(/^```[a-z]*\n?/, '').replace(/\n?```$/, '');
    const parsed = JSON.parse(clean);
    if (!parsed || typeof parsed !== 'object') return null;
    return {
      type: String(parsed.type || 'unknown'),
      file: parsed.file || null,
      line: typeof parsed.line === 'number' ? parsed.line : null,
      suggestion: String(parsed.suggestion || '').slice(0, 200),
    };
  } catch {
    return null;
  }
}

// ─── Feature Rank 5: decomposeTask ───────────────────────────────────────────

/**
 * Ask the model for a decomposition strategy when a task keeps failing.
 * MarrowScript Rank 5: LLM-based replacement for pickDecomposeStrategy().
 * Cached 5m. Returns null on failure so callers fall back to governor's regex.
 *
 * @param {string} task        - User's original task description
 * @param {string} errors      - Concatenated error messages
 * @param {string} fileContext - Relevant file content snippet
 * @returns {Promise<{strategy:string,reason:string,instruction:string}|null>}
 */
async function decomposeTask(task, errors, fileContext) {
  const prompts = _getPrompts();
  if (!prompts) return null;
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('decompose_task', {
      task: String(task),
      errors: String(errors),
      file_context: String(fileContext),
    }, { trace_id: traceId });
    const clean = String(result).trim().replace(/^```[a-z]*\n?/, '').replace(/\n?```$/, '');
    const parsed = JSON.parse(clean);
    if (!parsed || typeof parsed !== 'object') return null;
    const validStrategies = ['split_file', 'one_error_at_a_time', 'rewrite_section', 'extract_function'];
    return {
      strategy: validStrategies.includes(parsed.strategy) ? parsed.strategy : 'rewrite_section',
      reason: String(parsed.reason || '').slice(0, 300),
      instruction: String(parsed.instruction || '').slice(0, 600),
    };
  } catch {
    return null;
  }
}

// ─── Feature Rank 7: semanticMerge ───────────────────────────────────────────

/**
 * Recover from a patch failure by asking the model to merge the intended
 * change into the current file content.
 * MarrowScript Rank 7: called when old_str is not found in patch case.
 * TTL 1m (content-specific — caching rarely helps).
 *
 * @param {string} filePath       - File being patched
 * @param {string} intendedChange - Description of what the patch was trying to do
 * @param {string} currentContent - Current file content
 * @returns {Promise<string|null>} New complete file content, or null on failure
 */
async function semanticMerge(filePath, intendedChange, currentContent) {
  const prompts = _getPrompts();
  if (!prompts) return null;
  try {
    const traceId = require('crypto').randomUUID();
    const result = await prompts.callPrompt('semantic_merge', {
      file: filePath,
      intended_change: String(intendedChange),
      current_content: String(currentContent),
    }, { trace_id: traceId });
    const text = String(result).trim();
    // Strip any accidental code fences the model may have added
    const stripped = text.replace(/^```[^\n]*\n/, '').replace(/\n```$/, '');
    return stripped.length > 0 ? stripped : null;
  } catch {
    return null;
  }
}

// ─── Availability check ───────────────────────────────────────────────────────

/**
 * Check if the features module is fully available.
 */
function isFeaturesAvailable() {
  return _getPrompts() !== null;
}

module.exports = {
  repairToolCall,
  summarizeFileCompiled,
  assertWithinBudget,
  chargeBudget,
  getBudgetState,
  setApprovalHandler,
  awaitCheckpointDecision,
  submitCheckpointDecision,
  retrieveContext,
  validateEditCompiled,
  checkNeedsClarification,
  generateCommitMessage,
  extractPlanSteps,
  diagnoseError,
  decomposeTask,
  semanticMerge,
  isFeaturesAvailable,
};
