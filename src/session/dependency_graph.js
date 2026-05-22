// SmallCode — Dependency Graph + File Path Validation
//
// Feature 3: Builds a dependency graph from plan steps in pure code (no LLM).
//   - Extracts file mentions from step text
//   - Two steps that touch the same file are dependent
//   - Steps with explicit ordering ("after step N") are dependent
//   - Topological sort produces parallel execution batches
//
// Feature 4: Validates that file paths mentioned in plan steps exist on disk
//   before any tool calls start. Advisory (injects a warning system message)
//   rather than blocking, because new-file creation tasks reference paths that
//   legitimately don't exist yet.

'use strict';

const fs = require('fs');
const path = require('path');

// ─── Path extraction ──────────────────────────────────────────────────────────

// Patterns to extract file path tokens from step text — kept for reference only.
// extractFileMentions() creates fresh instances per call to avoid lastIndex races.
// Ordered by specificity: backtick > quoted > bare path with extension.

// Extensions we care about — skip binary, image, data formats
const SOURCE_EXTENSIONS = new Set([
  'js', 'ts', 'jsx', 'tsx', 'mjs', 'cjs',
  'py', 'rb', 'go', 'rs', 'java', 'kt', 'swift',
  'c', 'cpp', 'cc', 'h', 'hpp',
  'cs', 'php', 'scala', 'ex', 'exs',
  'html', 'css', 'scss', 'sass', 'less',
  'json', 'yaml', 'yml', 'toml', 'xml', 'env',
  'md', 'mdx', 'txt',
  'sh', 'bash', 'zsh', 'fish', 'ps1',
  'sql', 'graphql', 'proto',
  'red', 'mar', 'marrow', 'bone',
]);

// Skip paths that look like URLs or node_modules references
const PATH_SKIP_PATTERNS = [
  /^https?:\/\//,
  /^www\./,
  /node_modules/,
  /\.git\//,
];

/**
 * Extract normalized file path tokens from a step description string.
 * Returns deduplicated array of paths (relative, normalized).
 *
 * NOTE: Creates fresh regex instances per call to avoid lastIndex races
 * when this function is invoked concurrently (parallel executor).
 *
 * @param {string} text
 * @param {string} cwd
 * @returns {string[]}
 */
function extractFileMentions(text, cwd) {
  if (!text || typeof text !== 'string') return [];

  // Fresh regex instances per call — avoids lastIndex race in concurrent calls
  const patterns = [
    /`([^`\s]+\.[a-zA-Z0-9]{1,10})`/g,
    /"([^"\s]+\.[a-zA-Z0-9]{1,10})"/g,
    /'([^'\s]+\.[a-zA-Z0-9]{1,10})'/g,
    /\b((?:[\w./\\-]+\/)?[\w-]+\.[a-zA-Z0-9]{1,10})\b/g,
  ];

  const found = new Set();

  for (const pattern of patterns) {
    let m;
    while ((m = pattern.exec(text)) !== null) {
      const candidate = m[1] || m[0];
      if (!candidate) continue;

      // Check extension
      const ext = candidate.split('.').pop().toLowerCase();
      if (!SOURCE_EXTENSIONS.has(ext)) continue;

      // Skip URLs / node_modules / .git
      if (PATH_SKIP_PATTERNS.some(p => p.test(candidate))) continue;

      // Normalize — strip leading ./ for dedup purposes
      const normalized = candidate.replace(/^\.\//, '');
      found.add(normalized);
    }
  }

  return [...found];
}

// ─── Dependency graph builder ─────────────────────────────────────────────────

/**
 * Build a dependency adjacency map from plan steps.
 *
 * Dependency rules:
 *   1. File conflict: steps i and j both mention the same file → j depends on i
 *      (whichever comes later in the plan depends on the earlier one)
 *   2. Explicit ordering: step j text contains "after step i" or "once step i" →
 *      j depends on i
 *
 * Returns Map<number, Set<number>> where deps.get(j) = set of i's that j depends on.
 *
 * @param {string[]} steps
 * @param {string} cwd
 * @returns {Map<number, Set<number>>}
 */
function buildDependencyGraph(steps, cwd) {
  const deps = new Map();
  for (let i = 0; i < steps.length; i++) deps.set(i, new Set());

  if (!steps || steps.length < 2) return deps;

  // Rule 1: file conflict detection
  const fileMentions = steps.map(s => new Set(extractFileMentions(s, cwd)));

  for (let j = 1; j < steps.length; j++) {
    for (let i = 0; i < j; i++) {
      // If step j and step i share any file mention, j depends on i
      for (const f of fileMentions[j]) {
        if (fileMentions[i].has(f)) {
          deps.get(j).add(i);
          break;
        }
      }
    }
  }

  // Rule 2: explicit ordering mentions ("after step N", "once step N is done")
  for (let j = 0; j < steps.length; j++) {
    const text = steps[j];
    // Match "after step 1", "after step 1 is done", "once step 2 completes", etc.
    const matches = text.matchAll(/\b(?:after|once|when)\s+step\s+(\d+)\b/gi);
    for (const m of matches) {
      const i = parseInt(m[1], 10) - 1; // convert 1-indexed to 0-indexed
      if (i >= 0 && i < steps.length && i !== j) {
        deps.get(j).add(i);
      }
    }
  }

  return deps;
}

// ─── Topological sort → parallel batches ─────────────────────────────────────

/**
 * Convert a dependency graph into parallel execution batches.
 * Each batch contains step indices that have no unresolved dependencies
 * and can run concurrently.
 *
 * Uses Kahn's algorithm (topological BFS).
 *
 * @param {Map<number, Set<number>>} graph  deps.get(j) = set of i's j depends on
 * @param {number} totalSteps
 * @returns {number[][]}  array of batches, each batch is array of step indices
 */
function toParallelBatches(graph, totalSteps) {
  if (!totalSteps || totalSteps === 0) return [];
  if (totalSteps === 1) return [[0]];

  // Build in-degree map (how many deps each step has)
  const inDegree = new Array(totalSteps).fill(0);
  for (let j = 0; j < totalSteps; j++) {
    inDegree[j] = graph.get(j)?.size || 0;
  }

  // Build reverse map: who depends on i → set of j
  const dependents = new Map();
  for (let i = 0; i < totalSteps; i++) dependents.set(i, new Set());
  for (let j = 0; j < totalSteps; j++) {
    for (const i of (graph.get(j) || [])) {
      dependents.get(i).add(j);
    }
  }

  const batches = [];
  const resolved = new Set();

  while (resolved.size < totalSteps) {
    // Find all steps with in-degree 0 (no unresolved deps)
    const batch = [];
    for (let i = 0; i < totalSteps; i++) {
      if (!resolved.has(i) && inDegree[i] === 0) {
        batch.push(i);
      }
    }

    if (batch.length === 0) {
      // Cycle detected — fall back to linear execution for remaining unresolved steps
      const remaining = [];
      for (let i = 0; i < totalSteps; i++) {
        if (!resolved.has(i)) remaining.push(i);
      }
      if (remaining.length > 0) batches.push(remaining);
      break;
    }

    batches.push(batch);

    // Mark resolved, reduce in-degree of dependents
    for (const i of batch) {
      resolved.add(i);
      for (const j of (dependents.get(i) || [])) {
        inDegree[j]--;
      }
    }
  }

  return batches;
}

// ─── File path validation ─────────────────────────────────────────────────────

/**
 * For each file mentioned in plan steps, check if it exists on disk.
 * Only checks paths that look like source files (have source extensions).
 * Does NOT check paths that look like output/new files (the model may be
 * creating them).
 *
 * Returns { found: string[], missing: string[] }
 * Advisory only — caller decides how to handle missing paths.
 *
 * @param {string[]} steps
 * @param {string} cwd
 * @returns {{ found: string[], missing: string[] }}
 */
function validatePlanPaths(steps, cwd) {
  if (!steps || steps.length === 0) return { found: [], missing: [] };

  const allMentioned = new Set();
  for (const step of steps) {
    for (const p of extractFileMentions(step, cwd)) {
      allMentioned.add(p);
    }
  }

  const found = [];
  const missing = [];

  for (const p of allMentioned) {
    const abs = path.isAbsolute(p) ? p : path.resolve(cwd, p);
    // Only flag as missing if the path contains a directory separator or
    // looks like an existing project file — bare filenames like "output.json"
    // or "result.txt" are likely new files being created, not existing files.
    const hasDir = p.includes('/') || p.includes('\\');
    if (hasDir || fs.existsSync(abs)) {
      if (fs.existsSync(abs)) {
        found.push(p);
      } else {
        missing.push(p);
      }
    }
    // else: bare filename with no dir — skip validation (likely new file)
  }

  return { found, missing };
}

/**
 * Build a human-readable summary of the execution plan batches for TUI display.
 * e.g. "3 batches: [0] parallel, [1,2] parallel, [3] sequential"
 *
 * @param {number[][]} batches
 * @returns {string}
 */
function formatBatchSummary(batches) {
  if (!batches || batches.length === 0) return 'no batches';
  const parts = batches.map((b, i) => {
    if (b.length === 1) return `step ${b[0] + 1}`;
    return `steps [${b.map(s => s + 1).join(',')}] parallel`;
  });
  return `${batches.length} batch${batches.length > 1 ? 'es' : ''}: ${parts.join(' → ')}`;
}

module.exports = {
  extractFileMentions,
  buildDependencyGraph,
  toParallelBatches,
  validatePlanPaths,
  formatBatchSummary,
};
