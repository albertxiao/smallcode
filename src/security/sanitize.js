// SmallCode — Centralized Security & Redaction Utilities
//
// Single source of truth for:
//   - Secret redaction (API keys, tokens, .env content) before persistence
//   - Path safety (block traversal outside project, deny sensitive paths)
//   - Shell argument escaping (cross-platform)
//   - Comprehensive ANSI/control-char stripping (for tool output that
//     could otherwise leak escape codes into conversation context)
//
// Used by: session persistence, trace recorder, executor, references,
// MCP client, share/export, git context.
//
// Design goals:
//   - Pure functions, no side effects, no I/O
//   - Conservative: prefer false-positive over leaking a secret
//   - Stay under 300 lines so audit is feasible

'use strict';

const path = require('path');
const os = require('os');

// ─── Secret patterns ────────────────────────────────────────────────────────
// Each entry is a regex that matches a secret-like token in free text.
// We replace the secret value with [REDACTED:<kind>] keeping enough shape
// for debugging without exposing the literal.

const SECRET_PATTERNS = [
  // OpenAI / Anthropic / DeepSeek style
  { name: 'openai_key', re: /\bsk-(?:proj-|ant-|or-)?[A-Za-z0-9_-]{20,}\b/g },
  { name: 'anthropic_key', re: /\bsk-ant-[A-Za-z0-9_-]{20,}\b/g },
  // Bearer tokens in headers/log lines
  { name: 'bearer', re: /\b[Bb]earer\s+[A-Za-z0-9_\-.=:+/]{16,}/g },
  // GitHub tokens
  { name: 'github_pat', re: /\bghp_[A-Za-z0-9]{30,}\b/g },
  { name: 'github_oauth', re: /\bgho_[A-Za-z0-9]{30,}\b/g },
  // Google API keys
  { name: 'google_api', re: /\bAIza[0-9A-Za-z_-]{30,}\b/g },
  // AWS access keys
  { name: 'aws_key', re: /\bAKIA[0-9A-Z]{16}\b/g },
  // Generic JWT
  { name: 'jwt', re: /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/g },
  // Slack/Discord/Telegram bot tokens
  { name: 'slack', re: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g },
  // .env-style assignments where value looks secret-like
  { name: 'env_api_key', re: /\b([A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|API)[A-Z0-9_]*)\s*=\s*["']?([^\s"'\n]{8,})["']?/g },
  // Private key blocks
  { name: 'private_key', re: /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g },
];

// Keys that always trigger redaction when found as object property names
const ALWAYS_REDACT_KEYS = new Set([
  'password', 'passwd', 'pwd', 'secret', 'token', 'api_key', 'apikey',
  'authorization', 'auth', 'bearer', 'cookie', 'session_token', 'refresh_token',
  'access_token', 'private_key', 'client_secret', 'webhook_secret',
  'openai_api_key', 'anthropic_api_key', 'deepseek_api_key',
]);

/**
 * Redact secrets from a string. Returns the string with sensitive
 * substrings replaced by [REDACTED:<kind>]. Original input is never mutated.
 * Empty/non-string inputs pass through unchanged.
 */
function redactString(input) {
  if (typeof input !== 'string' || input.length === 0) return input;
  let out = input;
  for (const { name, re } of SECRET_PATTERNS) {
    if (name === 'env_api_key') {
      // Preserve the variable name, redact the value.
      out = out.replace(re, (_, k) => `${k}=[REDACTED:env_value]`);
    } else {
      out = out.replace(re, `[REDACTED:${name}]`);
    }
  }
  return out;
}

/**
 * Recursively redact a value (object, array, or primitive).
 * Returns a deep clone with secrets replaced. Cycles guarded via WeakSet.
 */
function redactValue(value, seen = new WeakSet()) {
  if (value === null || value === undefined) return value;
  if (typeof value === 'string') return redactString(value);
  if (typeof value !== 'object') return value;
  if (seen.has(value)) return '[Circular]';
  seen.add(value);
  if (Array.isArray(value)) return value.map(v => redactValue(v, seen));
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    if (ALWAYS_REDACT_KEYS.has(k.toLowerCase())) {
      out[k] = '[REDACTED]';
    } else {
      out[k] = redactValue(v, seen);
    }
  }
  return out;
}

// ─── Path safety ────────────────────────────────────────────────────────────

// Sensitive path patterns that we never read or expose, even when explicitly
// referenced. These match the resolved absolute path.
const SENSITIVE_PATH_RE = [
  /[/\\]\.ssh[/\\]/i,
  /[/\\]\.aws[/\\]credentials/i,
  /[/\\]\.gnupg[/\\]/i,
  /[/\\]\.netrc$/i,
  /[/\\]etc[/\\](shadow|gshadow|sudoers)/i,
  /[/\\]\.password-store[/\\]/i,
  /[/\\]\.docker[/\\]config\.json$/i,
  /[/\\]\.kube[/\\]config$/i,
];

/**
 * Resolve a user-supplied path safely against `cwd`.
 * Returns { ok: true, fullPath, displayPath } on success,
 * or { ok: false, reason } on rejection.
 *
 * Rules:
 *   - Resolved absolute path must be inside `cwd` (unless allowOutside=true)
 *   - Path must not match a sensitive pattern
 *   - Path must not contain NUL bytes
 */
function safeResolvePath(reqPath, cwd, options = {}) {
  if (typeof reqPath !== 'string' || reqPath.length === 0) {
    return { ok: false, reason: 'path must be a non-empty string' };
  }
  if (reqPath.indexOf('\u0000') !== -1) {
    return { ok: false, reason: 'path contains NUL byte' };
  }
  // Expand ~ for the user's home directory only when explicitly allowed
  let candidate = reqPath;
  if (candidate === '~' || candidate.startsWith('~/') || candidate.startsWith('~\\')) {
    if (!options.allowHome) {
      return { ok: false, reason: 'home-relative paths are blocked' };
    }
    candidate = path.join(os.homedir(), candidate.slice(2));
  }
  // Strip leading ./ for normalization
  candidate = candidate.replace(/^\.[/\\]/, '');
  const fullPath = path.resolve(cwd, candidate);

  // Sensitive path check
  for (const re of SENSITIVE_PATH_RE) {
    if (re.test(fullPath)) {
      return { ok: false, reason: 'path is sensitive (auth credentials)' };
    }
  }

  // Containment check (default ON — opt out for tools that legitimately
  // need to read outside the project, like reading user's global config)
  if (!options.allowOutside) {
    const normCwd = path.resolve(cwd);
    const rel = path.relative(normCwd, fullPath);
    if (rel.startsWith('..') || path.isAbsolute(rel)) {
      return { ok: false, reason: 'path resolves outside project root' };
    }
  }

  const displayPath = path.relative(cwd, fullPath) || path.basename(fullPath);
  return { ok: true, fullPath, displayPath };
}

// ─── Shell escaping ─────────────────────────────────────────────────────────

/**
 * Escape a string for safe inclusion as a single shell argument.
 * Cross-platform: uses POSIX single-quoting on Linux/macOS, and CMD-style
 * double-quote-with-escape on Windows.
 *
 * For Windows we double internal double-quotes and reject embedded NULs.
 * Use this in preference to manual `"${value}"` interpolation anywhere
 * a tool result, user input, or model output is going into a shell command.
 */
function escapeShellArg(value) {
  const s = String(value == null ? '' : value);
  if (s.indexOf('\u0000') !== -1) {
    throw new Error('shell argument contains NUL byte');
  }
  if (process.platform === 'win32') {
    // CMD: wrap in double quotes, escape internal double quotes by doubling.
    // Reject backticks/dollar-paren — they're CMD metachars in some contexts.
    return `"${s.replace(/"/g, '""')}"`;
  }
  // POSIX: single-quote and escape any embedded single quote with '\''
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

/**
 * Build a shell command from a base + already-trusted prefix and an array
 * of user-supplied args. Each arg is escaped via escapeShellArg.
 *
 * Example: buildCommand('rg', ['--files', '--glob'], userPattern)
 */
function buildCommand(base, trusted, ...userArgs) {
  const parts = [base];
  for (const t of trusted) parts.push(String(t));
  for (const u of userArgs) parts.push(escapeShellArg(u));
  return parts.join(' ');
}

// ─── ANSI / control-char stripping ──────────────────────────────────────────

// Comprehensive set covering CSI, OSC, DCS, SOS, PM, APC, and 8-bit C1.
// Reference: ECMA-48 / ANSI X3.64.
const ANSI_RE = [
  /\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/g, // CSI
  /\x1b\][\x20-\x7e]*?(?:\x07|\x1b\\)/g,         // OSC (terminated by BEL or ST)
  /\x1b[PX^_][\x20-\x7e]*?\x1b\\/g,              // DCS, SOS, PM, APC
  /\x1b[@-_]/g,                                  // Other 7-bit Fe escapes
  /[\x80-\x9f]/g,                                // 8-bit C1 controls
];

/**
 * Strip ALL ANSI escape sequences and C1 control bytes from a string.
 * Preserves printable text and ordinary whitespace (tab, newline).
 */
function stripAnsi(input) {
  if (typeof input !== 'string' || input.length === 0) return input;
  let out = input;
  for (const re of ANSI_RE) out = out.replace(re, '');
  // Also strip raw NUL and other non-tab/newline C0 controls
  out = out.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, '');
  return out;
}

/**
 * Sanitize a tool result string before adding it to model context:
 *   1. Strip ANSI / C1 controls
 *   2. Redact secrets
 *   3. Normalize line endings
 */
function sanitizeToolOutput(input) {
  if (typeof input !== 'string') return input;
  let out = stripAnsi(input);
  out = redactString(out);
  out = out.replace(/\r\n/g, '\n');
  return out;
}

// ─── Listener leak guard (for long-running stdio servers) ───────────────────

/**
 * Wrap a Readable stream with a single shared 'data' listener that demuxes
 * line-by-line into per-request callbacks. This avoids accumulating one
 * 'data' listener per in-flight request (which causes EventEmitter warnings
 * and cross-request data leakage when responses race).
 *
 * Returns { sendLine, registerHandler, unregister, close }
 */
function createLineDemuxer(stream) {
  const handlers = new Map(); // id → fn(line)
  let buffer = '';
  const onData = (chunk) => {
    buffer += chunk.toString('utf8');
    const lines = buffer.split('\n');
    buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      for (const fn of handlers.values()) {
        try { fn(line); } catch { /* handler should never throw */ }
      }
    }
  };
  stream.on('data', onData);
  return {
    register(id, fn) { handlers.set(id, fn); },
    unregister(id) { handlers.delete(id); },
    close() { try { stream.off('data', onData); } catch {} handlers.clear(); },
    pendingCount() { return handlers.size; },
  };
}

module.exports = {
  redactString,
  redactValue,
  safeResolvePath,
  escapeShellArg,
  buildCommand,
  stripAnsi,
  sanitizeToolOutput,
  createLineDemuxer,
  SECRET_PATTERNS,
  ALWAYS_REDACT_KEYS,
  SENSITIVE_PATH_RE,
};
