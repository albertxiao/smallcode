// SmallCode — File State Tracker (Feature #16: Diff-based context)
//
// Tracks the last-known content of files the model has read this session.
// When the model reads a file it's already seen, we can return a compact diff
// instead of the full content — saving significant context on multi-edit sessions.
//
// Example: model reads foo.py (200 lines), edits it, reads it again.
// Without this: 200 lines sent twice = 400 lines of context.
// With this: 200 lines + 12-line diff = 212 lines of context.
//
// The diff is a unified diff (standard format most models understand from
// training data). We deliberately keep the diff SMALL: only changed hunks
// with 3 lines of context. If the diff is larger than the full content, we
// send the full content anyway.
//
// Configuration:
//   SMALLCODE_DIFF_CONTEXT=true     enable diff mode (default: false, opt-in)
//   SMALLCODE_DIFF_CONTEXT_LINES=3  lines of context around each hunk
//   SMALLCODE_DIFF_MAX_RATIO=0.7    if diff > X% of full content, send full

'use strict';

const crypto = require('crypto');

const CONTEXT_LINES = parseInt(process.env.SMALLCODE_DIFF_CONTEXT_LINES) || 3;
const MAX_RATIO = parseFloat(process.env.SMALLCODE_DIFF_MAX_RATIO) || 0.7;

class FileStateTracker {
  constructor() {
    // path → { content: string, hash: string, readCount: number }
    this.known = new Map();
    this.disabled = process.env.SMALLCODE_DIFF_CONTEXT !== 'true';
  }

  /** Hash content for fast change detection. */
  _hash(content) {
    return crypto.createHash('md5').update(content).digest('hex').slice(0, 8);
  }

  /**
   * Record that the model has read a file. Returns:
   *   { mode: 'full', content }         — first time, or diff disabled
   *   { mode: 'diff', diff, unchanged } — seen before and content changed
   *   { mode: 'unchanged' }             — seen before and content is same
   *
   * @param {string} filePath  - Canonical absolute path
   * @param {string} content   - Current file content
   */
  record(filePath, content) {
    if (this.disabled) {
      // Still track state so writes stay accurate
      this.known.set(filePath, { content, hash: this._hash(content), readCount: 1 });
      return { mode: 'full', content };
    }

    const hash = this._hash(content);
    const prior = this.known.get(filePath);

    if (!prior) {
      // First read
      this.known.set(filePath, { content, hash, readCount: 1 });
      return { mode: 'full', content };
    }

    if (prior.hash === hash) {
      // Unchanged
      prior.readCount++;
      return { mode: 'unchanged', readCount: prior.readCount };
    }

    // Content changed — compute diff
    // Guard: skip diff for very large files to avoid O(n*m) DP memory use
    const lineCount = content.split('\n').length;
    if (lineCount > 2000) {
      this.known.set(filePath, { content, hash, readCount: prior.readCount + 1 });
      return { mode: 'full', content };
    }
    const diff = computeUnifiedDiff(prior.content, content, filePath, CONTEXT_LINES);
    const ratio = content.length > 0 ? diff.length / content.length : 1;

    // Update state
    this.known.set(filePath, { content, hash, readCount: prior.readCount + 1 });

    if (ratio > MAX_RATIO || diff.length === 0) {
      // Diff is too large or empty — send full content
      return { mode: 'full', content };
    }

    return { mode: 'diff', diff, fullLength: content.split('\n').length };
  }

  /** Record a write so the tracker knows the new state. */
  recordWrite(filePath, content) {
    const hash = this._hash(content);
    const prior = this.known.get(filePath);
    this.known.set(filePath, {
      content,
      hash,
      readCount: prior ? prior.readCount : 0,
    });
  }

  /** Clear all state — call between agent runs. */
  reset() { this.known.clear(); }

  /** How many files are being tracked. */
  size() { return this.known.size; }
}

// ─── Unified diff ──────────────────────────────────────────────────────────

/**
 * Compute a simplified unified diff between two texts.
 * Uses the Myers diff algorithm (line-level).
 * Returns a string in unified diff format, or '' if no changes.
 */
function computeUnifiedDiff(oldText, newText, filePath, contextLines) {
  const oldLines = oldText.split('\n');
  const newLines = newText.split('\n');

  const hunks = myersDiff(oldLines, newLines, contextLines);
  if (hunks.length === 0) return '';

  const name = filePath.split(/[\\/]/).pop() || filePath;
  let out = `--- ${name} (before)\n+++ ${name} (after)\n`;
  for (const hunk of hunks) {
    out += formatHunk(hunk);
  }
  return out;
}

/**
 * Myers diff at line level. Returns array of hunks:
 *   { oldStart, oldLen, newStart, newLen, lines: ['+'/'-'/' ' + text][] }
 */
function myersDiff(oldLines, newLines, contextLines) {
  const n = oldLines.length;
  const m = newLines.length;

  // Short-circuit for identical content
  if (oldLines.join('\n') === newLines.join('\n')) return [];

  // LCS-based diff — produces edit operations
  const ops = lcsEditScript(oldLines, newLines);

  // Group into hunks with context
  const hunks = [];
  let i = 0;
  while (i < ops.length) {
    if (ops[i].op === '=') { i++; continue; }
    // Start of a change region — collect surrounding context
    const start = i;
    let end = i;
    while (end < ops.length && (ops[end].op !== '=' || end - i < contextLines)) {
      end++;
    }
    // Look for adjacent changes within contextLines distance
    while (end < ops.length) {
      const nextChange = ops.slice(end).findIndex(o => o.op !== '=');
      if (nextChange === -1 || nextChange > contextLines * 2) break;
      end += nextChange + 1;
      while (end < ops.length && (ops[end].op !== '=' || end - start < contextLines)) end++;
    }

    // Build hunk
    const hunkOps = ops.slice(Math.max(0, start - contextLines), Math.min(ops.length, end + contextLines));
    const hunk = buildHunk(hunkOps, oldLines, newLines);
    if (hunk) hunks.push(hunk);
    i = end + contextLines;
  }

  return hunks;
}

function lcsEditScript(a, b) {
  // Simple O(nd) diff — adequate for file-size diffs
  const ops = [];
  let i = 0, j = 0;
  const n = a.length, m = b.length;

  // Use standard DP LCS
  const dp = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let x = n - 1; x >= 0; x--) {
    for (let y = m - 1; y >= 0; y--) {
      if (a[x] === b[y]) dp[x][y] = dp[x + 1][y + 1] + 1;
      else dp[x][y] = Math.max(dp[x + 1][y], dp[x][y + 1]);
    }
  }

  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) {
      ops.push({ op: '=', oldIdx: i, newIdx: j, text: a[i] });
      i++; j++;
    } else if (j < m && (i >= n || dp[i][j + 1] >= dp[i + 1][j])) {
      ops.push({ op: '+', newIdx: j, text: b[j] });
      j++;
    } else {
      ops.push({ op: '-', oldIdx: i, text: a[i] });
      i++;
    }
  }
  return ops;
}

function buildHunk(ops, oldLines, newLines) {
  if (!ops || ops.length === 0) return null;
  let oldStart = -1, newStart = -1;
  let oldCount = 0, newCount = 0; // tracks position within hunk for start calculation
  let oldLen = 0, newLen = 0;     // counts lines in the hunk
  const lines = [];

  for (const op of ops) {
    if (op.op === '=') {
      if (oldStart === -1) {
        oldStart = (op.oldIdx !== undefined ? op.oldIdx : oldCount) + 1;
        newStart = (op.newIdx !== undefined ? op.newIdx : newCount) + 1;
      }
      lines.push(' ' + op.text);
      oldLen++; newLen++;
    } else if (op.op === '-') {
      if (oldStart === -1) {
        oldStart = (op.oldIdx !== undefined ? op.oldIdx : oldCount) + 1;
        // newStart: deletion happens at the current new-file position
        newStart = newCount + 1;
      }
      lines.push('-' + op.text);
      oldLen++;
    } else if (op.op === '+') {
      if (oldStart === -1) {
        // insertion at the current old-file position
        oldStart = oldCount + 1;
        newStart = (op.newIdx !== undefined ? op.newIdx : newCount) + 1;
      }
      lines.push('+' + op.text);
      newLen++;
    }
  }

  if (oldStart === -1) return null;
  return { oldStart, oldLen, newStart, newLen, lines };
}

function formatHunk(hunk) {
  const header = `@@ -${hunk.oldStart},${hunk.oldLen} +${hunk.newStart},${hunk.newLen} @@\n`;
  return header + hunk.lines.join('\n') + '\n';
}

// ─── Singleton ─────────────────────────────────────────────────────────────

let _instance = null;
function getFileStateTracker() {
  if (!_instance) _instance = new FileStateTracker();
  return _instance;
}
function resetFileStateTracker() { if (_instance) _instance.reset(); _instance = null; }

module.exports = {
  FileStateTracker,
  getFileStateTracker,
  resetFileStateTracker,
  computeUnifiedDiff,
};
