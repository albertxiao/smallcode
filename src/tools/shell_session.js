// SmallCode — Persistent Shell Session
// Maintains a long-lived shell process so `bash` calls retain state
// (cwd, env vars, shell variables, sourced scripts, etc.) across calls.
//
// Without this, each `bash` call is a fresh process — `cd src` followed by
// `ls` in the next call shows the original cwd, not src/. This causes constant
// confusion on multi-step tasks.
//
// Implementation:
//   - Linux/macOS: spawn a single bash subprocess with a stable stdin/stdout.
//     Each command is wrapped with sentinels to delimit output and capture
//     exit code. Shell state (cwd, env) persists across commands naturally.
//   - Windows: spawn cmd.exe with the same sentinel approach.
//
// Each command is given a unique sentinel so we can demux concurrent calls
// (though in practice the agent loop is sequential, this is defensive).
//
// Safety:
//   - Per-command timeout (default 30s) — kills the command via SIGTERM,
//     not the whole shell. Shell stays alive.
//   - Output sanitization (strip ANSI/control, redact secrets) before return.
//   - Optional cwd containment: if SMALLCODE_SHELL_CONTAIN=true, refuse any
//     `cd` that would escape the original project root.

'use strict';

const { spawn } = require('child_process');
const crypto = require('crypto');
const path = require('path');
const { sanitizeToolOutput } = require('../security/sanitize');

// Sentinel pattern: marks the end of a command's output and carries its exit
// code. Chosen to be highly unlikely to appear in normal output.
const SENTINEL_PREFIX = '__SMALLCODE_END_';

class ShellSession {
  constructor(options = {}) {
    this.cwd = options.cwd || process.cwd();
    this.timeout = options.timeout || 30000;
    this.containCwd = options.containCwd || process.env.SMALLCODE_SHELL_CONTAIN === 'true';
    this.rootDir = path.resolve(this.cwd);
    this.maxOutputBytes = options.maxOutputBytes || 1024 * 1024; // 1MB

    this.proc = null;
    this.buffer = '';
    this.queue = []; // pending commands { sentinel, resolve, timer }
    this.starting = null;
    this._dead = false;
  }

  /**
   * Spawn the shell subprocess. Idempotent — safe to call multiple times.
   */
  async start() {
    if (this.proc && !this._dead) return true;
    if (this.starting) return this.starting;

    this.starting = (async () => {
      const isWin = process.platform === 'win32';
      // Use bash on POSIX (more predictable than sh), cmd.exe on Windows.
      // We could prefer pwsh on Windows but cmd.exe is universally available.
      const shellCmd = isWin ? 'cmd.exe' : (process.env.SHELL && /bash|zsh/.test(process.env.SHELL) ? process.env.SHELL : 'bash');
      const shellArgs = isWin ? ['/Q', '/K', 'echo off & prompt $G'] : ['--norc', '--noprofile', '-i'];

      try {
        this.proc = spawn(shellCmd, shellArgs, {
          cwd: this.cwd,
          env: { ...process.env, PS1: '', PROMPT_COMMAND: '' },
          stdio: ['pipe', 'pipe', 'pipe'],
          shell: false,
        });
        // Unref so this child process doesn't keep the parent's event loop
        // alive after all other work is done (e.g. on --non-interactive exit).
        // We still clean up explicitly via process.on('exit') and SIGINT.
        try { this.proc.unref(); } catch {}
      } catch (err) {
        this._dead = true;
        return false;
      }

      this.proc.on('error', () => { this._dead = true; });
      this.proc.on('exit', () => { this._dead = true; this._failPending('shell exited'); });

      // Demux output via sentinel matching
      const onChunk = (chunk) => {
        this.buffer += chunk.toString('utf8');
        // Hard cap to prevent runaway commands from OOMing us.
        // Be careful not to slice mid-sentinel, otherwise the head command
        // never completes. Trim from the start, keep the tail intact.
        if (this.buffer.length > this.maxOutputBytes * 4) {
          // Look for the head's sentinel — if present, keep everything from
          // before it minus the excess. Otherwise just keep the tail.
          if (this.queue.length > 0) {
            const head = this.queue[0];
            const idx = this.buffer.lastIndexOf(SENTINEL_PREFIX);
            // If we have any sentinel prefix in the tail, slice up to it
            if (idx > 0 && this.buffer.length - idx < 256) {
              // Keep the tail starting from the most recent SENTINEL_PREFIX
              const trimAmount = this.buffer.length - this.maxOutputBytes * 2;
              if (trimAmount > 0 && trimAmount < idx) {
                this.buffer = this.buffer.slice(trimAmount);
              }
            } else {
              this.buffer = this.buffer.slice(-this.maxOutputBytes * 2);
            }
          } else {
            this.buffer = this.buffer.slice(-this.maxOutputBytes * 2);
          }
        }
        this._drain();
      };
      this.proc.stdout.on('data', onChunk);
      this.proc.stderr.on('data', onChunk);

      return true;
    })();

    const ok = await this.starting;
    this.starting = null;
    return ok;
  }

  /**
   * Run a command in the persistent shell. Returns { stdout, exitCode, timedOut }.
   * Output is sanitized (ANSI stripped, secrets redacted) before returning.
   */
  async run(command) {
    if (this._dead) {
      // Auto-restart on dead shell
      const ok = await this.start();
      if (!ok) return { stdout: '', exitCode: -1, timedOut: false, error: 'shell unavailable' };
    }
    if (!this.proc) {
      const ok = await this.start();
      if (!ok) return { stdout: '', exitCode: -1, timedOut: false, error: 'shell failed to start' };
    }

    // Optional containment: parse cwd-changing commands and reject ones that
    // would leave the project root. We strip leading `;` `&` `&&` so chained
    // commands are inspected too. Catches:
    //   cd ../../etc
    //   cd "../../etc"
    //   cd '..'
    //   pushd ..
    //   ; cd ..
    //   && cd ..
    //   bash -c "cd .."          (refused outright — sub-shells bypass our wrapper)
    //   sh -c '...'              (same)
    if (this.containCwd) {
      // Reject sub-shell escapes — we cannot track cwd through them
      if (/\b(?:bash|sh|zsh|ksh|fish|pwsh|powershell|cmd)\s+-c\b/.test(command)) {
        return { stdout: `(refused: -c sub-shells bypass cwd containment)\n`, exitCode: 1, timedOut: false };
      }
      // Iterate every cd / pushd / chdir (chained or not)
      const cdRe = /(?:^|[;&|])\s*(?:cd|pushd|chdir)\s+([^\s;&|]+)/g;
      let cdMatch;
      let simulatedCwd = this.cwd;
      while ((cdMatch = cdRe.exec(command))) {
        const target = cdMatch[1].replace(/^['"]|['"]$/g, '');
        const resolved = path.isAbsolute(target) ? target : path.resolve(simulatedCwd, target);
        const rel = path.relative(this.rootDir, resolved);
        if (rel.startsWith('..') || path.isAbsolute(rel)) {
          return { stdout: `(cd refused: target outside project root)\n`, exitCode: 1, timedOut: false };
        }
        simulatedCwd = resolved;
      }
    }

    const sentinel = SENTINEL_PREFIX + crypto.randomBytes(8).toString('hex');
    const isWin = process.platform === 'win32';

    // Wrap the command so we can detect end-of-output and capture exit code.
    // POSIX: `; printf "\n__SENTINEL__%d__\n" $?`
    // Windows cmd: `& echo __SENTINEL__%errorlevel%__`
    const wrapped = isWin
      ? `${command}\r\n@echo ${sentinel}_%errorlevel%_\r\n`
      : `${command}\nprintf '\\n${sentinel}_%d_\\n' $?\n`;

    return new Promise((resolve) => {
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        // On timeout we mark the shell dead and reset it — the next command
        // will spawn a fresh shell. Half-measures (writing \n, sending SIGINT)
        // leave the buffer in indeterminate states and our sentinel may never
        // arrive, hanging the queue forever. Better to nuke and restart.
        try {
          if (this.proc) {
            try { this.proc.kill('SIGKILL'); } catch { try { this.proc.kill(); } catch {} }
          }
        } catch {}
        this._dead = true;
        // Resolve the timed-out command and fail all pending.
        // _drain won't see a sentinel because the shell is dead.
        const idx = this.queue.findIndex(q => q.sentinel === sentinel);
        if (idx >= 0) {
          const entry = this.queue.splice(idx, 1)[0];
          clearTimeout(entry.timer);
          resolve({ stdout: '', exitCode: -1, timedOut: true, error: 'timeout — shell reset' });
        }
        this._failPending('timeout — shell reset');
      }, this.timeout);

      this.queue.push({ sentinel, resolve, timer, isWin, timedOut: () => timedOut });
      try {
        this.proc.stdin.write(wrapped);
      } catch (e) {
        clearTimeout(timer);
        const idx = this.queue.findIndex(q => q.sentinel === sentinel);
        if (idx >= 0) this.queue.splice(idx, 1);
        resolve({ stdout: '', exitCode: -1, timedOut: false, error: e.message });
      }
    });
  }

  /**
   * Get the shell's current working directory.
   * Runs `pwd` (POSIX) or `cd` (Windows) — useful for status display.
   */
  async pwd() {
    const isWin = process.platform === 'win32';
    const r = await this.run(isWin ? 'cd' : 'pwd');
    return r.stdout.trim().split('\n')[0] || this.cwd;
  }

  /**
   * Reset the shell — kill the current process and spawn a fresh one.
   * Useful when the shell gets stuck (e.g. an interactive prompt).
   */
  async reset() {
    this.stop();
    this._dead = false;
    this.buffer = '';
    return await this.start();
  }

  /**
   * Stop the shell process. Idempotent.
   */
  stop() {
    this._failPending('shell stopped');
    if (this.proc) {
      try { this.proc.kill(); } catch {}
      this.proc = null;
    }
    this._dead = true;
  }

  // ─── Internal ──────────────────────────────────────────────────────────

  _drain() {
    // Iterative — avoids recursion stack growth when many sentinels arrive
    // back-to-back (e.g. fast-running queued commands).
    while (this.queue.length > 0) {
      const head = this.queue[0];
      const re = new RegExp(`${head.sentinel}_(-?\\d+)_`);
      const match = this.buffer.match(re);
      if (!match) return;

      const sentinelStart = match.index;
      let stdout = this.buffer.slice(0, sentinelStart);
      stdout = stdout.replace(/\r?\n$/, '');
      const exitCode = parseInt(match[1], 10);

      const sentinelEnd = sentinelStart + match[0].length;
      this.buffer = this.buffer.slice(sentinelEnd).replace(/^\r?\n/, '');

      const cleanOutput = sanitizeToolOutput(stdout);

      clearTimeout(head.timer);
      this.queue.shift();
      head.resolve({
        stdout: cleanOutput,
        exitCode,
        timedOut: head.timedOut(),
      });
    }
  }

  _failPending(reason) {
    while (this.queue.length > 0) {
      const q = this.queue.shift();
      clearTimeout(q.timer);
      q.resolve({ stdout: '', exitCode: -1, timedOut: false, error: reason });
    }
  }
}

// ─── Module-level singleton (one shell per SmallCode process) ────────────

let _instance = null;

function getShell(options) {
  if (!_instance) _instance = new ShellSession(options);
  return _instance;
}

function resetShell() {
  if (_instance) {
    _instance.stop();
    _instance = null;
  }
}

// Clean up on process exit. Use a global flag so re-requires of this module
// (e.g. after `delete require.cache`) don't stack additional listeners.
if (!global.__SMALLCODE_SHELL_EXIT_REGISTERED__) {
  global.__SMALLCODE_SHELL_EXIT_REGISTERED__ = true;
  const cleanup = () => { if (_instance) try { _instance.stop(); } catch {} };
  process.on('exit', cleanup);
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);
}

module.exports = { ShellSession, getShell, resetShell };
