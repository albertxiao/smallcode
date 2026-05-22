// SmallCode — Read-Before-Write Tracker
//
// Small models tend to overwrite files they haven't read, especially when
// the user says something ambiguous like "fix the bug" — they'll happily
// guess what was in the file and write a "fix" that wipes legitimate code.
//
// This module tracks which paths the model has read in the current session
// and warns when the model attempts to `write_file` to an existing file
// without having read it first.
//
// We do NOT block — small models sometimes legitimately rewrite files
// (e.g. when they were just created in this session, or when the prompt
// explicitly says "replace"). Instead we:
//   1. Return a guard error on the FIRST untracked write to an existing file.
//      The model can retry. This forces a read in 90% of cases.
//   2. If the model's next action is a read of the same path, lift the guard.
//   3. After lift, the write goes through normally.
//
// Per-session state. Reset between agent runs.
//
// Configuration:
//   SMALLCODE_WRITE_GUARD=false   disable entirely
//   SMALLCODE_WRITE_GUARD_STRICT=true  block forever instead of one-shot warn

'use strict';

const path = require('path');
const fs = require('fs');

class ReadTracker {
  constructor() {
    this.readPaths = new Set();      // canonical absolute paths read this session
    this.writtenPaths = new Set();   // paths created/written this session
    this.warnedPaths = new Set();    // paths we already issued a guard warning for
    this.disabled = process.env.SMALLCODE_WRITE_GUARD === 'false';
    this.strict = process.env.SMALLCODE_WRITE_GUARD_STRICT === 'true';
  }

  /** Canonicalize a path for tracking. */
  _canon(p, cwd) {
    if (!p) return null;
    try {
      const abs = path.isAbsolute(p) ? p : path.resolve(cwd || process.cwd(), p);
      // Don't realpath — symlinks shouldn't change identity for this purpose
      return path.normalize(abs);
    } catch {
      return null;
    }
  }

  /** Mark a path as read. */
  recordRead(filePath, cwd) {
    if (this.disabled) return;
    const c = this._canon(filePath, cwd);
    if (!c) return;
    this.readPaths.add(c);
    // Reading after a warning lifts the warning (but doesn't auto-clear written)
    this.warnedPaths.delete(c);
  }

  /** Mark a path as written (so write→write doesn't trigger guard). */
  recordWrite(filePath, cwd) {
    if (this.disabled) return;
    const c = this._canon(filePath, cwd);
    if (!c) return;
    this.writtenPaths.add(c);
    this.readPaths.add(c); // we know its content because we just wrote it
  }

  /**
   * Check whether a write should be guarded. Returns:
   *   { ok: true } — write is fine
   *   { ok: false, reason: '...', warning: true } — first warning, model can retry after read
   *   { ok: false, reason: '...', blocked: true } — strict mode, hard block
   */
  checkWrite(filePath, cwd) {
    if (this.disabled) return { ok: true };
    const c = this._canon(filePath, cwd);
    if (!c) return { ok: true };

    let exists = false;
    try { exists = fs.existsSync(c); } catch {}
    if (!exists) return { ok: true }; // creating new file — always fine

    // We've read or written it earlier this session — fine
    if (this.readPaths.has(c) || this.writtenPaths.has(c)) return { ok: true };

    // First-time untracked write to existing file
    if (this.strict) {
      return {
        ok: false,
        blocked: true,
        reason: `Refused: write_file to existing file '${path.relative(cwd || process.cwd(), c) || c}' without prior read_file. Read the file first to see what's there.`,
      };
    }

    // One-shot warning: first time refuse, second time allow with note
    if (this.warnedPaths.has(c)) {
      // Already warned once — let it through but mark as written
      this.recordWrite(filePath, cwd);
      return { ok: true, withWarning: 'overwriting unread file (second attempt)' };
    }
    this.warnedPaths.add(c);
    return {
      ok: false,
      warning: true,
      reason: `Refused: write_file would overwrite existing '${path.relative(cwd || process.cwd(), c) || c}' you haven't read. Call read_file first to see its current content, OR if you intend to fully replace it, retry — second attempt is allowed.`,
    };
  }

  /** Reset all tracking — call between agent runs. */
  reset() {
    this.readPaths.clear();
    this.writtenPaths.clear();
    this.warnedPaths.clear();
  }
}

let _instance = null;
function getReadTracker() {
  if (!_instance) _instance = new ReadTracker();
  return _instance;
}
function resetReadTracker() { if (_instance) _instance.reset(); }

module.exports = { ReadTracker, getReadTracker, resetReadTracker };
