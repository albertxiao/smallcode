// SmallCode — File Snapshot & Auto-Rollback
//
// Sits on top of UndoStack to provide checkpoint-style rollback of file
// edits when verification fails. UndoStack alone is per-edit; this layer
// groups edits into checkpoints that can be rolled back as a unit.
//
// Workflow:
//   1. Before a turn that may make multiple edits, agent calls
//      `snapshot.begin('improvement-loop-attempt-3')` to mark a checkpoint.
//   2. Each subsequent write_file / patch records its before-content
//      against the active checkpoint via `snapshot.note(filePath, before)`.
//   3. If validation fails permanently (exhausted retries), agent calls
//      `snapshot.rollback()` which restores every file to its pre-checkpoint
//      content. New files created during the checkpoint are deleted.
//   4. On success, agent calls `snapshot.commit()` which discards the
//      checkpoint state without modifying files.
//
// We also persist snapshot metadata to `.smallcode/snapshots/<id>.json` so
// the user can inspect or manually rollback even after a crash.
//
// Configuration:
//   SMALLCODE_SNAPSHOT=false           disable entirely
//   SMALLCODE_SNAPSHOT_AUTO_ROLLBACK   auto-rollback on hard validation fail
//   SMALLCODE_SNAPSHOT_DIR             override snapshot persistence dir

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const FILE_MODE = 0o600;
const DIR_MODE = 0o700;

class SnapshotManager {
  constructor(options = {}) {
    this.workdir = options.workdir || process.cwd();
    this.snapshotDir = options.snapshotDir
      || process.env.SMALLCODE_SNAPSHOT_DIR
      || path.join(this.workdir, '.smallcode', 'snapshots');
    this.disabled = options.disable || process.env.SMALLCODE_SNAPSHOT === 'false';
    this.autoRollback = options.autoRollback
      || process.env.SMALLCODE_SNAPSHOT_AUTO_ROLLBACK === 'true';
    this.maxFileSize = options.maxFileSize || 5 * 1024 * 1024; // 5MB per file

    // Active checkpoint state. Only one open at a time — checkpoints don't
    // nest. A new begin() while one is active commits the previous one.
    this.active = null;
  }

  /** Open a new checkpoint. Returns the checkpoint ID. */
  begin(label) {
    if (this.disabled) return null;
    if (this.active) this.commit(); // close any prior checkpoint
    const id = crypto.randomBytes(4).toString('hex');
    this.active = {
      id,
      label: String(label || 'checkpoint').slice(0, 80),
      startedAt: Date.now(),
      // path → { before: string|null, exists: bool }
      // Only the FIRST recording per file is kept (the original state).
      files: new Map(),
    };
    return id;
  }

  /**
   * Snapshot a file's pre-edit content. Idempotent per path within a
   * checkpoint — the FIRST snapshot wins (we want to revert to the state
   * at checkpoint start, not after an intermediate edit).
   *
   * Pass null/undefined for `before` if the file did not exist (we'll detect).
   */
  note(filePath, before) {
    if (this.disabled || !this.active) return;
    const abs = path.resolve(this.workdir, filePath);
    // Containment — only snapshot files inside the workspace root
    const rel = path.relative(this.workdir, abs);
    if (rel.startsWith('..') || path.isAbsolute(rel)) return;
    if (this.active.files.has(abs)) return; // first-snapshot-wins

    let content = before;
    let existed = false;
    if (content === undefined || content === null) {
      try {
        const stat = fs.statSync(abs);
        if (stat.size > this.maxFileSize) {
          // File too large to snapshot — record existence but not content.
          // On rollback we'll bail with a warning instead of corrupting.
          this.active.files.set(abs, { tooLarge: true, existed: true });
          return;
        }
        content = fs.readFileSync(abs, 'utf-8');
        existed = true;
      } catch (e) {
        if (e.code === 'ENOENT') {
          this.active.files.set(abs, { before: null, existed: false });
          return;
        }
        // Other read errors — record existence so we don't try to delete on rollback
        this.active.files.set(abs, { skipped: true, existed: true });
        return;
      }
    } else {
      existed = true;
    }
    this.active.files.set(abs, { before: content, existed });
  }

  /**
   * Roll back every file recorded since the last begin(). Returns a summary.
   * Files snapshotted as nonexistent are deleted. Files with stored content
   * are restored. Files marked tooLarge or skipped emit warnings.
   */
  rollback(reason = 'verification failed') {
    if (this.disabled || !this.active) return { restored: 0, deleted: 0, errors: [] };
    const cp = this.active;
    const restored = [];
    const deleted = [];
    const errors = [];
    const skipped = [];

    for (const [abs, snap] of cp.files.entries()) {
      try {
        if (snap.tooLarge) {
          skipped.push({ path: abs, reason: 'file too large to snapshot' });
          continue;
        }
        if (snap.skipped) {
          skipped.push({ path: abs, reason: 'snapshot read failed' });
          continue;
        }
        if (!snap.existed) {
          // Was new — delete it
          if (fs.existsSync(abs)) {
            fs.unlinkSync(abs);
            deleted.push(abs);
          }
        } else {
          // Restore content
          const dir = path.dirname(abs);
          if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
          fs.writeFileSync(abs, snap.before);
          restored.push(abs);
        }
      } catch (e) {
        errors.push({ path: abs, error: e.message });
      }
    }

    // Persist a record of the rollback
    this._persist(cp, { reason, restored, deleted, errors, skipped, rolledBack: true });
    this.active = null;
    return {
      checkpointId: cp.id,
      label: cp.label,
      restored: restored.length,
      deleted: deleted.length,
      errors,
      skipped,
      reason,
    };
  }

  /** Discard the active checkpoint without restoring anything. */
  commit() {
    if (this.disabled || !this.active) return null;
    const cp = this.active;
    this._persist(cp, { rolledBack: false, committed: true });
    this.active = null;
    return cp.id;
  }

  /** Check if a checkpoint is currently open. */
  isActive() { return !!this.active; }

  /** How many files have been snapshotted in the active checkpoint. */
  size() { return this.active ? this.active.files.size : 0; }

  /** Reset everything — used between agent runs. */
  reset() { this.active = null; }

  // ─── Internal ──────────────────────────────────────────────────────────

  _persist(cp, outcome) {
    if (this.disabled) return;
    try {
      if (!fs.existsSync(this.snapshotDir)) {
        fs.mkdirSync(this.snapshotDir, { recursive: true, mode: DIR_MODE });
      }
      const id = String(cp.id || '').replace(/[^A-Za-z0-9_-]/g, '');
      if (!id) return;
      const filePath = path.join(this.snapshotDir, `${id}.json`);
      // Containment — must stay inside snapshotDir
      if (!filePath.startsWith(this.snapshotDir + path.sep)) return;

      const summary = {
        id: cp.id,
        label: cp.label,
        startedAt: new Date(cp.startedAt).toISOString(),
        endedAt: new Date().toISOString(),
        fileCount: cp.files.size,
        files: [...cp.files.keys()].slice(0, 50), // paths only, not content
        outcome,
      };
      const tmp = filePath + `.tmp.${process.pid}`;
      fs.writeFileSync(tmp, JSON.stringify(summary, null, 2), { mode: FILE_MODE });
      fs.renameSync(tmp, filePath);
    } catch {
      // never fail the agent loop on persistence errors
    }
  }
}

// ─── Singleton ─────────────────────────────────────────────────────────────
// The singleton is lazy — first call with options builds it. Subsequent calls
// reuse it IF the workdir matches. If cwd changed (e.g. bench tasks in temp
// dirs), a fresh instance is created (the old one is abandoned, not committed).

let _instance = null;

function getSnapshotManager(options) {
  const wantedCwd = (options && options.workdir) || process.cwd();
  if (_instance && _instance.workdir === wantedCwd) return _instance;
  // cwd changed — abandon old (any open checkpoint is discarded silently) and rebuild
  _instance = new SnapshotManager({
    workdir: wantedCwd,
    snapshotDir: (options && options.snapshotDir),
    disable: (options && options.disable),
    autoRollback: (options && options.autoRollback),
  });
  return _instance;
}

function resetSnapshotManager() {
  if (_instance) {
    _instance.reset();
    _instance = null;
  }
}

module.exports = {
  SnapshotManager,
  getSnapshotManager,
  resetSnapshotManager,
};
