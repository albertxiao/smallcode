// SmallCode — Tool-Call Deduplication
//
// Small models often loop: they call `read_file` on the same file twice in
// a row, or `search` for the same pattern, or run the same `bash` command.
// This wastes context (each tool result re-enters the conversation) and
// burns latency.
//
// Dedup short-circuits identical consecutive tool calls within a sliding
// window, returning the cached result instead of re-executing. Only applies
// to read-only / pure tools — never to anything with side effects.
//
// Per-session state. Reset between agent runs.
//
// Configuration:
//   SMALLCODE_DEDUP=false     disable entirely
//   SMALLCODE_DEDUP_WINDOW=5  number of recent calls considered for dedup

'use strict';

const crypto = require('crypto');

// Tools we consider safe to dedup. Anything that mutates state (write_file,
// patch, bash, mcp__*) is excluded — even if "the same" command was just
// run, the world may have changed.
const PURE_TOOLS = new Set([
  'read_file',
  'list_files',
  'search',
  'grep',
  'graph_search',
  'explain_symbol',
  'find_by_path',
  'find_by_signature',
  'fuzzy_find_symbol',
  'get_repo_stats',
  'list_projects',
  'memory_load',
  'memory_for_file',
  'memory_for_symbol',
  'memory_list',
]);

class ToolDedup {
  constructor(options = {}) {
    this.windowSize = options.windowSize || parseInt(process.env.SMALLCODE_DEDUP_WINDOW) || 5;
    this.disabled = options.disable || process.env.SMALLCODE_DEDUP === 'false';
    // recent: array of { hash, name, result, ts }
    this.recent = [];
    // stats
    this.hits = 0;
    this.misses = 0;
  }

  /**
   * Compute a stable hash for (toolName, args). Uses sorted JSON to be
   * insensitive to argument-key order.
   */
  _hash(name, args) {
    const norm = JSON.stringify(args || {}, Object.keys(args || {}).sort());
    return crypto.createHash('sha1').update(name + '|' + norm).digest('hex').slice(0, 16);
  }

  /**
   * Check whether (name, args) was just executed. Returns the cached result
   * or null. Only deduplicates pure tools.
   */
  lookup(name, args) {
    if (this.disabled) return null;
    if (!PURE_TOOLS.has(name)) return null;
    const h = this._hash(name, args);
    for (let i = this.recent.length - 1; i >= 0; i--) {
      if (this.recent[i].hash === h) {
        this.hits++;
        // Return a shallow copy so callers can't mutate the cached entry
        return { ...this.recent[i].result };
      }
    }
    this.misses++;
    return null;
  }

  /**
   * Record the (name, args, result) of a just-executed call.
   */
  record(name, args, result) {
    if (this.disabled) return;
    if (!PURE_TOOLS.has(name)) return;
    // Don't cache errors — the model should be allowed to retry
    if (result && result.error) return;
    const h = this._hash(name, args);
    // Move-to-front: drop existing entry with same hash, push fresh
    this.recent = this.recent.filter(r => r.hash !== h);
    this.recent.push({ hash: h, name, result, ts: Date.now() });
    while (this.recent.length > this.windowSize) this.recent.shift();
  }

  /** Wrap a result with a [cached] marker so the model knows it's a hit. */
  static markCached(result) {
    if (!result) return result;
    const copy = { ...result };
    if (typeof copy.result === 'string') {
      copy.result = '[cached — identical call already executed this turn]\n' + copy.result;
    }
    copy._dedupCached = true;
    return copy;
  }

  /** Reset all state. Call between agent runs. */
  reset() {
    this.recent = [];
    this.hits = 0;
    this.misses = 0;
  }

  /** Snapshot stats for logging. */
  stats() {
    return { hits: this.hits, misses: this.misses, windowSize: this.windowSize };
  }
}

let _instance = null;
function getDedup() {
  if (!_instance) _instance = new ToolDedup();
  return _instance;
}
function resetDedup() { if (_instance) _instance.reset(); }

module.exports = { ToolDedup, getDedup, resetDedup, PURE_TOOLS };
