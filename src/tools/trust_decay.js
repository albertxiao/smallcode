// SmallCode — Per-Tool Trust Score Decay (Feature 13)
//
// The existing tool_scores.json (from ToolScorer) tracks historical
// success/fail rates per tool. This module adds WITHIN-SESSION decay:
// a tool that fails N consecutive times in the current run gets demoted
// in the schema list injected to the model — it moves to the back, or is
// dropped entirely from the 2-stage router after a hard-fail threshold.
//
// This prevents the model from looping on a broken MCP tool, a search
// that returns nothing useful, or a bash command that keeps crashing.
//
// Per-session state. Reset between agent runs.
//
// Configuration:
//   SMALLCODE_TRUST_DECAY=false     disable entirely
//   SMALLCODE_TRUST_WARN=3          consecutive fails before soft-demote
//   SMALLCODE_TRUST_DROP=5          consecutive fails before hard-drop from schema list
//   SMALLCODE_TRUST_RESET=true      reset decay counter on any success (default true)

'use strict';

const WARN_THRESHOLD = parseInt(process.env.SMALLCODE_TRUST_WARN) || 3;
const DROP_THRESHOLD = parseInt(process.env.SMALLCODE_TRUST_DROP) || 5;
const RESET_ON_SUCCESS = process.env.SMALLCODE_TRUST_RESET !== 'false';

class TrustDecayTracker {
  constructor(options = {}) {
    this.disabled = options.disable || process.env.SMALLCODE_TRUST_DECAY === 'false';
    this.warnThreshold = options.warnThreshold || WARN_THRESHOLD;
    this.dropThreshold = options.dropThreshold || DROP_THRESHOLD;
    this.resetOnSuccess = options.resetOnSuccess !== undefined ? options.resetOnSuccess : RESET_ON_SUCCESS;
    // toolName → { consecutiveFails, totalFails, totalCalls }
    this.scores = new Map();
  }

  /** Record a tool outcome. */
  record(toolName, success) {
    if (this.disabled || !toolName) return;
    if (!this.scores.has(toolName)) {
      this.scores.set(toolName, { consecutiveFails: 0, totalFails: 0, totalCalls: 0 });
    }
    const s = this.scores.get(toolName);
    s.totalCalls++;
    if (success) {
      if (this.resetOnSuccess) s.consecutiveFails = 0;
      // Don't touch totalFails — it tracks historical
    } else {
      s.consecutiveFails++;
      s.totalFails++;
    }
  }

  /**
   * Get the trust level for a tool.
   * Returns: 'ok' | 'warn' | 'drop'
   */
  level(toolName) {
    if (this.disabled || !this.scores.has(toolName)) return 'ok';
    const s = this.scores.get(toolName);
    if (s.consecutiveFails >= this.dropThreshold) return 'drop';
    if (s.consecutiveFails >= this.warnThreshold) return 'warn';
    return 'ok';
  }

  /** Returns true if this tool should be excluded from the schema list. */
  isDrop(toolName) { return this.level(toolName) === 'drop'; }

  /** Returns true if this tool should be de-prioritized. */
  isWarn(toolName) { return this.level(toolName) === 'warn'; }

  /**
   * Filter a tools array to remove dropped tools and move warned tools to
   * the back of the list.
   *
   * @param {object[]} tools - Array of tool definition objects (with .function.name)
   * @returns {object[]} Reordered tools array
   */
  filterAndSort(tools) {
    if (this.disabled || !Array.isArray(tools)) return tools;
    const ok = [];
    const warned = [];
    for (const t of tools) {
      const name = t && t.function && t.function.name;
      const lvl = this.level(name);
      if (lvl === 'drop') continue; // exclude
      if (lvl === 'warn') warned.push(t);
      else ok.push(t);
    }
    return [...ok, ...warned];
  }

  /**
   * Format a log line listing any demoted tools for debug output.
   */
  summary() {
    const dropped = [];
    const warned = [];
    for (const [name, s] of this.scores) {
      if (s.consecutiveFails >= this.dropThreshold) dropped.push(`${name}(×${s.consecutiveFails})`);
      else if (s.consecutiveFails >= this.warnThreshold) warned.push(`${name}(×${s.consecutiveFails})`);
    }
    if (dropped.length === 0 && warned.length === 0) return null;
    const parts = [];
    if (dropped.length) parts.push(`dropped: ${dropped.join(', ')}`);
    if (warned.length) parts.push(`warned: ${warned.join(', ')}`);
    return parts.join('; ');
  }

  /** Reset all session state. */
  reset() { this.scores.clear(); }
}

// ─── Singleton ─────────────────────────────────────────────────────────────

let _instance = null;

function getTrustDecay() {
  if (!_instance) _instance = new TrustDecayTracker();
  return _instance;
}

function resetTrustDecay() {
  if (_instance) _instance.reset();
  _instance = null;
}

module.exports = {
  TrustDecayTracker,
  getTrustDecay,
  resetTrustDecay,
  WARN_THRESHOLD,
  DROP_THRESHOLD,
};
