// SmallCode — Evidence Store
//
// Automated capture of "what was tried, what worked, what failed" per task.
// Distinct from manual memory (decisions/conventions): evidence is auto-derived
// from the trace recorder at task end. Stored in the existing memory MCP module
// (budget-aware-mcp) under `type: 'context'` with `tag: 'evidence'` so it:
//
//   1. Doesn't hog the live system prompt — only loads when relevant via
//      memoryStore.loadForTask (FTS5 + staleness decay + token budget).
//   2. Is searchable via the existing memory_load / memory_for_file tools.
//   3. Survives across sessions and is git-ignorable along with .memory/.
//
// The summarizer extracts:
//   - failed commands (non-zero exit) and their error message tail
//   - successful commands of value (build/test/lint passes)
//   - files created or edited
//   - validation outcomes (lint/compile pass/fail)
//   - net duration
//
// We deliberately do NOT store full trace contents — those are 5-50KB each.
// Evidence is a 1-3KB digest meant to be re-injected into context.

'use strict';

const path = require('path');

// Tools whose results we surface in evidence (rest are noise)
const INTERESTING_TOOLS = new Set([
  'bash', 'write_file', 'patch', 'create_file',
  'search', 'graph_search',
  // exclude pure read tools — too noisy and not actionable as evidence
]);

// Patterns that indicate failure even when exit code looks OK
const FAILURE_HINTS = [
  /\b(error|failed?|exception|traceback|fatal|panic)\b/i,
  /\bcannot\s+find\b/i,
  /\bnot\s+found\b/i,
  /\bsegfault\b/i,
  /\bsyntaxerror\b/i,
];

/**
 * Summarize a finished trace into an evidence digest.
 * Returns null if the trace has nothing worth storing (no tools, all reads).
 *
 * @param {object} trace - Output of TraceRecorder (from this.current snapshot)
 * @param {object} options
 * @param {number} options.maxBodyChars - Max body size (default 1500)
 */
function summarizeTrace(trace, options = {}) {
  if (!trace || !Array.isArray(trace.steps) || trace.steps.length === 0) return null;

  const maxBodyChars = options.maxBodyChars || 1500;

  // Categorize steps
  const failures = [];
  const successes = [];
  const filesEdited = new Set();
  let validations = 0;
  let validationsFailed = 0;

  for (const step of trace.steps) {
    if (step.type === 'tool_call') {
      if (!INTERESTING_TOOLS.has(step.name)) continue;

      // Track file mutations
      if (step.name === 'write_file' || step.name === 'patch') {
        try {
          const args = typeof step.args === 'object' ? step.args : null;
          if (args && args.path) filesEdited.add(args.path);
        } catch {}
      }

      // Detect failure: explicit error field, non-zero exit hint in result, or
      // failure-keyword regex
      const result = String(step.result || '');
      const lowered = result.toLowerCase();
      const isFailure =
        lowered.includes('error: ') ||
        lowered.includes('exit code') && !lowered.includes('exit code 0') ||
        FAILURE_HINTS.some(p => p.test(result));

      const summary = compactStep(step, isFailure);
      if (!summary) continue;
      if (isFailure) failures.push(summary);
      else successes.push(summary);
    } else if (step.type === 'validation') {
      validations++;
      if (!step.passed) validationsFailed++;
    }
  }

  // Skip empty trace (no actionable evidence)
  if (failures.length === 0 && successes.length === 0 && filesEdited.size === 0) {
    return null;
  }

  // Dedupe consecutive identical step summaries — small models loop, and
  // 10x "patch foo.py → ok" is noise, not evidence.
  const dedupedFailures = dedupeAdjacent(failures);
  const dedupedSuccesses = dedupeAdjacent(successes);

  // Build a tight markdown body
  const lines = [];
  lines.push(`Task: ${truncate(trace.prompt || '', 200)}`);
  if (filesEdited.size > 0) {
    lines.push(`Files: ${[...filesEdited].slice(0, 10).join(', ')}`);
  }
  if (failures.length > 0) {
    lines.push(`\nFailed steps:`);
    for (const f of dedupedFailures.slice(0, 5)) lines.push(`- ${f}`);
  }
  if (successes.length > 0) {
    lines.push(`\nSuccessful steps:`);
    for (const s of dedupedSuccesses.slice(0, 5)) lines.push(`- ${s}`);
  }
  if (validations > 0) {
    lines.push(`\nValidations: ${validations - validationsFailed}/${validations} passed`);
  }
  if (trace.durationMs) {
    lines.push(`\nDuration: ${(trace.durationMs / 1000).toFixed(1)}s`);
  }

  let body = lines.join('\n');
  if (body.length > maxBodyChars) {
    body = body.slice(0, maxBodyChars) + '\n[...truncated]';
  }

  // Title: first 80 chars of the prompt, sanitized for use as a memory title
  const title = truncate(
    (trace.prompt || 'task').replace(/\s+/g, ' ').trim(),
    80
  );

  // Tags: 'evidence' marker + outcome class + per-file basenames
  const tags = ['evidence'];
  if (failures.length === 0 && validationsFailed === 0) tags.push('success');
  else if (failures.length > 0) tags.push('partial-failure');
  if (validationsFailed > 0) tags.push('validation-failed');

  return {
    type: 'context',
    title,
    content: body,
    tags,
    files: [...filesEdited].slice(0, 20),
    symbols: [],
  };
}

/**
 * Persist evidence to a memory store. Returns the stored memory object or
 * null if storage failed or trace was uninteresting.
 *
 * @param {object} memoryStore - The MemoryStore instance from budget-aware-mcp
 * @param {object} trace - Trace from TraceRecorder
 * @param {object} options
 */
function recordEvidence(memoryStore, trace, options = {}) {
  if (!memoryStore || typeof memoryStore.remember !== 'function') return null;
  if (process.env.SMALLCODE_EVIDENCE_DISABLE === 'true') return null;
  const summary = summarizeTrace(trace, options);
  if (!summary) return null;

  try {
    // budget-aware-mcp signature: remember({ type, title, content, tags, files, symbols })
    // Local fallback memory.js signature: remember(type, title, content, opts)
    // We try the object form first; on TypeError fall back to positional.
    let result;
    try {
      result = memoryStore.remember(summary);
    } catch (e) {
      // Positional fallback
      result = memoryStore.remember(summary.type, summary.title, summary.content, {
        tags: summary.tags,
        files: summary.files,
      });
    }
    return result;
  } catch {
    return null;
  }
}

// ─── Helpers ───────────────────────────────────────────────────────────────

function compactStep(step, isFailure) {
  const name = step.name;
  let detail = '';
  try {
    const args = typeof step.args === 'object' ? step.args : null;
    if (args) {
      if (args.command) detail = `\`${truncate(args.command, 80)}\``;
      else if (args.path) detail = args.path;
      else if (args.pattern) detail = `pattern: ${truncate(args.pattern, 50)}`;
    }
  } catch {}

  // Append a short error/result tail when failure
  if (isFailure) {
    const result = String(step.result || '');
    const tail = extractErrorTail(result);
    if (tail) detail += ` → ${tail}`;
  }

  return `${name}${detail ? ' ' + detail : ''}`.slice(0, 200);
}

function extractErrorTail(result) {
  // Take the most informative error line: prefer specific named errors
  // (ImportError, SyntaxError, traceback messages) over generic ones
  // (Exit code, "failed").
  const lines = result.split('\n').map(l => l.trim()).filter(Boolean);
  const SPECIFIC = /\b(?:[A-Z]\w+(?:Error|Exception)|Traceback|cannot\s+find|not\s+found|undefined|undeclared)\b/;
  const GENERIC = /\bexit\s+code\b|\bfailed\b/i;

  // Pass 1: most informative specific error
  for (let i = lines.length - 1; i >= 0; i--) {
    if (SPECIFIC.test(lines[i])) return truncate(lines[i], 120);
  }
  // Pass 2: any failure hint
  for (let i = lines.length - 1; i >= 0; i--) {
    if (FAILURE_HINTS.some(p => p.test(lines[i])) && !GENERIC.test(lines[i])) {
      return truncate(lines[i], 120);
    }
  }
  // Pass 3: generic exit code line is better than nothing
  for (let i = lines.length - 1; i >= 0; i--) {
    if (FAILURE_HINTS.some(p => p.test(lines[i]))) return truncate(lines[i], 120);
  }
  return lines.length ? truncate(lines[lines.length - 1], 120) : '';
}

function truncate(s, n) {
  if (typeof s !== 'string') return '';
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

function dedupeAdjacent(arr) {
  if (!arr || arr.length === 0) return arr;
  const out = [];
  let prev = null;
  let runCount = 0;
  for (const item of arr) {
    if (item === prev) {
      runCount++;
      continue;
    }
    if (runCount > 0) out[out.length - 1] = `${prev} (×${runCount + 1})`;
    out.push(item);
    prev = item;
    runCount = 0;
  }
  if (runCount > 0) out[out.length - 1] = `${prev} (×${runCount + 1})`;
  return out;
}

module.exports = {
  summarizeTrace,
  recordEvidence,
  INTERESTING_TOOLS,
};
