// SmallCode — Smart File-Tree Pruning (Feature #17)
//
// When the model lists files in a project, dump-everything approaches are
// expensive on large repos (1000+ files → massive context blob). This module
// scores and ranks files by relevance so the model sees the most useful subset.
//
// Scoring heuristics (higher = more relevant):
//   +3  recently modified (mtime within last 24h)
//   +2  recently modified (mtime within last 7d)
//   +2  source file extension (.py .js .ts .go .rs .java etc.)
//   +1  test file (test_*.py, *.test.js, *_test.go etc.)
//   +1  config/manifest file (package.json, Cargo.toml, go.mod etc.)
//   -2  generated/build output (dist/, build/, __pycache__/, *.min.js)
//   -3  dependency directory (node_modules/, vendor/, .venv/)
//   +bonus for files matching the current task keywords
//
// Output is capped to MAX_FILES (default 50) sorted by score desc.
//
// Configuration:
//   SMALLCODE_FILETREE_MAX=50    max files to return
//   SMALLCODE_FILETREE_SORT=mtime|score  sort mode (default: score)

'use strict';

const fs = require('fs');
const path = require('path');

const MAX_FILES = parseInt(process.env.SMALLCODE_FILETREE_MAX) || 50;
const SORT_MODE = process.env.SMALLCODE_FILETREE_SORT || 'score';

// Source file extensions that the model can meaningfully read/edit
const SOURCE_EXTS = new Set([
  '.py', '.js', '.ts', '.jsx', '.tsx', '.mjs', '.cjs',
  '.go', '.rs', '.java', '.kt', '.scala', '.swift',
  '.c', '.cpp', '.h', '.hpp', '.cs', '.fs', '.fsx',
  '.rb', '.php', '.lua', '.r', '.jl', '.ex', '.exs',
  '.sh', '.bash', '.zsh', '.fish', '.ps1',
  '.yaml', '.yml', '.toml', '.json', '.xml', '.env',
  '.md', '.txt', '.rst', '.adoc',
  '.html', '.css', '.scss', '.less', '.vue', '.svelte',
  '.sql', '.graphql', '.proto',
]);

// Config/manifest files — always high relevance
const CONFIG_FILES = new Set([
  'package.json', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml',
  'tsconfig.json', 'jsconfig.json', '.eslintrc.json', '.prettierrc',
  'Cargo.toml', 'Cargo.lock', 'go.mod', 'go.sum',
  'pyproject.toml', 'setup.py', 'setup.cfg', 'requirements.txt', 'Pipfile',
  'pom.xml', 'build.gradle', 'build.gradle.kts',
  'Makefile', 'Dockerfile', 'docker-compose.yml', 'docker-compose.yaml',
  '.gitignore', '.gitattributes', 'README.md', 'CHANGELOG.md',
  'Gemfile', 'Gemfile.lock', '.ruby-version', '.nvmrc',
]);

// Patterns that indicate generated/uninteresting output
const SKIP_DIRS = new Set([
  'node_modules', 'vendor', '.git', '.svn', '__pycache__',
  '.venv', 'venv', 'env', '.env',
  'dist', 'build', 'out', 'output', 'target', '.next', '.nuxt',
  'coverage', '.nyc_output', '.pytest_cache', '.mypy_cache',
  'tmp', 'temp', '.tmp', '.cache',
]);

const GENERATED_PATTERNS = [
  /\.min\.(js|css)$/,
  /\.(map|d\.ts)$/,
  /\.pyc$/,
  /package-lock\.json$/,  // large, not useful to read
  /yarn\.lock$/,
  /pnpm-lock\.yaml$/,
];

/**
 * Walk a directory and return scored file entries.
 *
 * @param {string} rootDir     - Directory to walk
 * @param {string} taskHint    - Optional keywords from user task for bonus scoring
 * @param {object} opts
 * @param {number} opts.maxDepth  - Max directory depth (default 6)
 * @param {number} opts.maxFiles  - Max files to collect before scoring (default 2000)
 */
function scoredFileListing(rootDir, taskHint, opts = {}) {
  const maxDepth = opts.maxDepth || 6;
  const maxCollect = opts.maxFiles || 2000;
  const now = Date.now();
  const taskTokens = taskHint
    ? taskHint.toLowerCase().split(/\W+/).filter(t => t.length > 2)
    : [];

  const entries = [];

  function walk(dir, depth) {
    if (depth > maxDepth || entries.length >= maxCollect) return;
    let listing;
    try { listing = fs.readdirSync(dir, { withFileTypes: true }); }
    catch { return; }

    for (const ent of listing) {
      if (entries.length >= maxCollect) break;
      const name = ent.name;

      if (ent.isDirectory()) {
        if (SKIP_DIRS.has(name)) continue;
        // Skip most dot-dirs but allow .marrow (MarrowScript source)
        if (name.startsWith('.') && name !== '.marrow') continue;
        walk(path.join(dir, name), depth + 1);
      } else if (ent.isFile()) {
        const full = path.join(dir, name);
        const rel = path.relative(rootDir, full);
        const ext = path.extname(name).toLowerCase();
        const base = name.toLowerCase();

        let score = 0;

        // Extension scoring
        if (SOURCE_EXTS.has(ext)) score += 2;

        // Config files
        if (CONFIG_FILES.has(name)) score += 1;

        // Test files
        if (/^test_|\.test\.|\.spec\.|_test\./i.test(name)) score += 1;

        // Generated output penalty
        if (GENERATED_PATTERNS.some(p => p.test(name))) score -= 2;

        // Recent modification bonus
        let mtime = 0;
        try {
          const stat = fs.statSync(full);
          mtime = stat.mtimeMs;
          const ageMs = now - mtime;
          if (ageMs < 86400000) score += 3;       // < 24h
          else if (ageMs < 604800000) score += 2;  // < 7d
          else if (ageMs < 2592000000) score += 1; // < 30d
        } catch {}

        // Task keyword bonus
        if (taskTokens.length > 0) {
          const relLower = rel.toLowerCase();
          const hits = taskTokens.filter(t => relLower.includes(t)).length;
          score += Math.min(hits * 2, 4); // cap at +4
        }

        entries.push({ rel, full, name, ext, score, mtime });
      }
    }
  }

  walk(rootDir, 0);
  return entries;
}

/**
 * Get a ranked file listing for injection into the model.
 *
 * @param {string} rootDir    - Directory to list
 * @param {string} taskHint   - User task for bonus scoring
 * @param {object} opts
 * @param {number} opts.max   - Max files to return (default SMALLCODE_FILETREE_MAX)
 */
function getSmartListing(rootDir, taskHint, opts = {}) {
  const max = opts.max || MAX_FILES;
  const entries = scoredFileListing(rootDir, taskHint, opts);

  let sorted;
  if (SORT_MODE === 'mtime') {
    sorted = entries.sort((a, b) => b.mtime - a.mtime);
  } else {
    // score desc, then mtime desc as tiebreaker
    sorted = entries.sort((a, b) => b.score !== a.score ? b.score - a.score : b.mtime - a.mtime);
  }

  return sorted.slice(0, max);
}

/**
 * Format a file listing for the model. Returns a compact string.
 *
 * @param {string} rootDir
 * @param {string} taskHint
 * @param {object} opts
 */
function formatSmartListing(rootDir, taskHint, opts = {}) {
  const max = opts.max || MAX_FILES;
  // Single walk — collect all, then slice for display
  const allEntries = scoredFileListing(rootDir, taskHint, opts);
  const totalCollected = allEntries.length;

  let sorted;
  if (SORT_MODE === 'mtime') {
    sorted = allEntries.sort((a, b) => b.mtime - a.mtime);
  } else {
    sorted = allEntries.sort((a, b) => b.score !== a.score ? b.score - a.score : b.mtime - a.mtime);
  }
  const files = sorted.slice(0, max);

  if (files.length === 0) return 'No source files found.';

  const header = totalCollected > files.length
    ? `Top ${files.length} relevant files (${totalCollected}+ total, use find_files for specific patterns):\n`
    : `${files.length} files:\n`;

  return header + files.map(f => f.rel).join('\n');
}

module.exports = {
  scoredFileListing,
  getSmartListing,
  formatSmartListing,
  MAX_FILES,
  SOURCE_EXTS,
  SKIP_DIRS,
};
