// SmallCode — Knowledge Injection
//
// Loads short reference docs from a `knowledge/` directory and injects only
// the most relevant ones into the system prompt based on keywords in the
// user's last message. Designed for small models that benefit from having
// algorithm cheat sheets, syntax reminders, or domain notes inline rather
// than reasoning everything from first principles.
//
// Layout:
//   knowledge/
//     algorithms/binary-search.md
//     syntax/python-fstrings.md
//     conventions/git-commit-style.md
//     ...
//
// Each .md file is a focused 100-500 word note. The first line should be a
// `# Title` and the rest should be content. Optional front-matter with
// `keywords:` controls when it gets injected (otherwise we infer from filename
// + first heading).
//
// Configuration:
//   SMALLCODE_KNOWLEDGE_DIR=./knowledge   path to knowledge directory
//   SMALLCODE_KNOWLEDGE_MAX_TOKENS=1500   per-message injection cap
//   SMALLCODE_KNOWLEDGE_DISABLE=true      turn off entirely
//
// Selection algorithm:
//   1. Parse user message into normalized words
//   2. Score each .md file by keyword overlap (filename + frontmatter + heading)
//   3. Pick top-K such that total chars stay under the budget
//
// We deliberately do NOT use embeddings here — keeping the implementation
// fully local and dependency-free. Filename + heading match is good enough
// for the cheat-sheet use case.

'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_MAX_TOKENS = parseInt(process.env.SMALLCODE_KNOWLEDGE_MAX_TOKENS) || 1500;
const DEFAULT_DIR_NAMES = ['knowledge', '.knowledge', 'docs/knowledge'];

class KnowledgeLoader {
  constructor(options = {}) {
    this.rootDir = options.rootDir || process.cwd();
    this.dirOverride = options.dir || process.env.SMALLCODE_KNOWLEDGE_DIR;
    this.maxTokens = options.maxTokens || DEFAULT_MAX_TOKENS;
    this.disabled = options.disable || process.env.SMALLCODE_KNOWLEDGE_DISABLE === 'true';
    this._index = null; // lazy-loaded
    this._dir = null;
  }

  /**
   * Resolve which directory we're loading from. First match wins.
   * Returns null if no knowledge directory exists.
   */
  _resolveDir() {
    if (this._dir !== null) return this._dir;
    if (this.disabled) return (this._dir = null);

    const candidates = this.dirOverride
      ? [this.dirOverride]
      : DEFAULT_DIR_NAMES.map(n => path.join(this.rootDir, n));

    for (const c of candidates) {
      try {
        const stat = fs.statSync(c);
        if (stat.isDirectory()) return (this._dir = c);
      } catch {}
    }
    return (this._dir = null);
  }

  /**
   * Walk the knowledge directory and build an in-memory index of available
   * notes. Each entry: { path, name, keywords[], heading, contentFn }.
   * contentFn is a thunk so we don't read every file at startup.
   */
  _buildIndex() {
    if (this._index) return this._index;
    const dir = this._resolveDir();
    if (!dir) return (this._index = []);

    const entries = [];
    const walk = (sub) => {
      let listing;
      try { listing = fs.readdirSync(sub, { withFileTypes: true }); }
      catch { return; }
      for (const ent of listing) {
        const full = path.join(sub, ent.name);
        if (ent.isDirectory()) walk(full);
        else if (ent.isFile() && /\.(md|txt)$/i.test(ent.name)) {
          entries.push(this._parseEntry(full, dir));
        }
      }
    };
    walk(dir);
    this._index = entries.filter(Boolean);
    return this._index;
  }

  /**
   * Parse a single knowledge file's metadata without loading its full content.
   * We still read the file once to extract heading + front-matter — these are
   * tiny so it's cheap. Full content is loaded later only for selected files.
   */
  _parseEntry(filePath, rootDir) {
    let stat;
    try { stat = fs.statSync(filePath); } catch { return null; }
    // Hard cap on file size — we don't want a rogue 50MB file blowing up memory
    if (stat.size > 100 * 1024) return null;

    let head;
    try { head = fs.readFileSync(filePath, 'utf-8'); }
    catch { return null; }

    const rel = path.relative(rootDir, filePath);
    const name = path.basename(filePath, path.extname(filePath));
    // Slug components from path become keywords (binary-search.md → ["binary","search"])
    const pathTokens = rel.toLowerCase().split(/[\\/_\-.\s]+/).filter(Boolean);

    // Optional YAML-ish front-matter: --- ... ---
    let keywords = [];
    let heading = '';
    let body = head;
    const fmMatch = head.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
    if (fmMatch) {
      const fm = fmMatch[1];
      body = fmMatch[2];
      const kwMatch = fm.match(/keywords?:\s*(.+)/i);
      if (kwMatch) {
        keywords = kwMatch[1]
          .replace(/^\[|\]$/g, '')
          .split(/[,\s]+/)
          .map(s => s.trim().toLowerCase().replace(/^['"]|['"]$/g, ''))
          .filter(Boolean);
      }
    }
    const hMatch = body.match(/^#\s+(.+)/m);
    if (hMatch) heading = hMatch[1].trim();

    // Combine all keyword sources
    const allKeywords = new Set([
      ...pathTokens,
      ...keywords,
      ...heading.toLowerCase().split(/\W+/).filter(t => t.length > 2),
      name.toLowerCase(),
    ]);

    return {
      path: filePath,
      relPath: rel,
      name,
      heading,
      keywords: [...allKeywords],
      size: stat.size,
      _bodyCache: body, // already-read; keep for tiny files
    };
  }

  /**
   * Tokenize a query into normalized lowercase words ≥ 3 chars.
   */
  _tokenize(text) {
    if (!text || typeof text !== 'string') return [];
    return text.toLowerCase()
      .split(/\W+/)
      .filter(w => w.length >= 3 && !STOP_WORDS.has(w));
  }

  /**
   * Score an entry against a query. Higher = more relevant.
   * Heuristic: each matched keyword = 1 point. Heading match = +2 bonus.
   * Filename match = +1 bonus.
   */
  _scoreEntry(entry, queryTokens) {
    if (queryTokens.length === 0) return 0;
    let score = 0;
    const querySet = new Set(queryTokens);
    for (const kw of entry.keywords) {
      if (querySet.has(kw)) score += 1;
    }
    if (entry.heading) {
      const headTokens = this._tokenize(entry.heading);
      for (const t of headTokens) if (querySet.has(t)) score += 2;
    }
    if (querySet.has(entry.name.toLowerCase())) score += 1;
    return score;
  }

  /**
   * Pick the most relevant knowledge notes for the given query, fitting under
   * the token budget. Returns an array of { name, content, relPath }.
   */
  selectForQuery(query, opts = {}) {
    if (this.disabled) return [];
    const index = this._buildIndex();
    if (index.length === 0) return [];
    const queryTokens = this._tokenize(query);
    if (queryTokens.length === 0) return [];

    const scored = index
      .map(e => ({ e, score: this._scoreEntry(e, queryTokens) }))
      .filter(s => s.score > 0)
      .sort((a, b) => b.score - a.score);

    const maxChars = (opts.maxTokens || this.maxTokens) * 4;
    const out = [];
    let used = 0;
    for (const { e, score } of scored) {
      const body = e._bodyCache !== undefined ? e._bodyCache : (() => {
        try { return fs.readFileSync(e.path, 'utf-8'); } catch { return ''; }
      })();
      // Skip front-matter if present
      const cleaned = body.replace(/^---\n[\s\S]*?\n---\n/, '').trim();
      if (!cleaned) continue;
      // Per-entry hard cap to prevent one note swallowing the whole budget
      const truncated = cleaned.length > 1500
        ? cleaned.slice(0, 1500) + '\n[...truncated]'
        : cleaned;
      if (used + truncated.length > maxChars) {
        if (out.length === 0) {
          // Always include at least the top hit, but truncated to fit
          const fit = truncated.slice(0, Math.max(0, maxChars - 100));
          out.push({ name: e.name, content: fit, relPath: e.relPath, score });
        }
        break;
      }
      out.push({ name: e.name, content: truncated, relPath: e.relPath, score });
      used += truncated.length;
    }
    return out;
  }

  /**
   * Format selected entries as a system-prompt block. Returns '' if nothing
   * matches.
   */
  formatForPrompt(query, opts = {}) {
    const entries = this.selectForQuery(query, opts);
    if (entries.length === 0) return '';
    let out = '\n\nRelevant reference notes:\n';
    for (const e of entries) {
      out += `\n--- ${e.relPath} ---\n${e.content}\n`;
    }
    return out;
  }

  /**
   * Drop the cached index — next call rebuilds. Useful in tests or after
   * editing knowledge files.
   */
  invalidate() { this._index = null; this._dir = null; }
}

// Common English stop words so a query like "how do I sort an array" doesn't
// pull every note that happens to contain "do" or "an".
const STOP_WORDS = new Set([
  'the', 'and', 'for', 'with', 'this', 'that', 'from', 'have', 'has', 'had',
  'are', 'was', 'were', 'will', 'would', 'should', 'could', 'can', 'may',
  'how', 'what', 'when', 'where', 'why', 'which', 'who', 'whom',
  'into', 'onto', 'about', 'over', 'under', 'between', 'through',
  'all', 'any', 'some', 'each', 'every', 'both', 'either', 'neither',
  'not', 'only', 'just', 'also', 'too', 'very', 'much', 'many',
  'one', 'two', 'three', 'first', 'second', 'last', 'next', 'previous',
  'use', 'used', 'using', 'make', 'made', 'get', 'got', 'set', 'put',
  'you', 'your', 'they', 'them', 'their', 'these', 'those',
]);

let _instance = null;

/**
 * Get the singleton loader. Most callers should use this.
 */
function getKnowledgeLoader(options) {
  if (!_instance) _instance = new KnowledgeLoader(options);
  return _instance;
}

function resetKnowledgeLoader() { _instance = null; }

module.exports = {
  KnowledgeLoader,
  getKnowledgeLoader,
  resetKnowledgeLoader,
  DEFAULT_MAX_TOKENS,
};
