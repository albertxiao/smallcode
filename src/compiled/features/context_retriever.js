// @ts-nocheck
'use strict';
// Generated from marrow/features_1_6.marrow — retrieve_context capability
// Uses code-graph-mcp for semantic slice (max 8 files, 2 hops)

/**
 * Retrieve relevant context for a user message via code graph walk.
 * Zero LLM calls — pure graph traversal.
 *
 * @param {string} userMessage - The user's message/task
 * @param {function} mcpCall - mcpCall(tool, args) from mcp_bridge.js
 * @param {number} maxFiles - Max files to include (default 8)
 * @returns {{ files: string[], symbols: string[], tokenEstimate: number }}
 */
async function retrieveContext(userMessage, mcpCall, maxFiles = 8) {
  if (!mcpCall || !userMessage) return { files: [], symbols: [], tokenEstimate: 0 };

  try {
    // Extract keywords from user message for graph search
    const keywords = extractKeywords(userMessage);
    if (keywords.length === 0) return { files: [], symbols: [], tokenEstimate: 0 };

    const results = [];
    // Search top 3 keywords to avoid over-fetching
    for (const kw of keywords.slice(0, 3)) {
      try {
        const r = await mcpCall('tools/call', { name: 'search_graph', arguments: { query: kw, max_tokens: 2000 } });
        if (r && !r.error) results.push(r);
      } catch {}
    }

    if (results.length === 0) return { files: [], symbols: [], tokenEstimate: 0 };

    // Deduplicate and extract file paths from results
    const fileSet = new Set();
    const symbolSet = new Set();
    for (const r of results) {
      // Handle MCP tools/call format: { content: [{ text: '...' }] }
      let text;
      if (r && r.content && Array.isArray(r.content)) {
        text = r.content.map(c => c.text || '').join('\n');
      } else {
        text = typeof r === 'string' ? r : JSON.stringify(r);
      }
      // Extract file paths from graph results
      const pathMatches = text.match(/[a-zA-Z0-9_\-/\\]+\.(ts|js|py|rs|go|java|c|cpp|md)/g) || [];
      for (const p of pathMatches.slice(0, maxFiles)) fileSet.add(p);
      // Extract symbol names (capitalized words or function patterns)
      const symMatches = text.match(/\b[A-Z][a-zA-Z0-9]+\b|\bfunction\s+(\w+)/g) || [];
      for (const s of symMatches.slice(0, 20)) symbolSet.add(s.replace(/^function\s+/, ''));
    }

    const files = [...fileSet].slice(0, maxFiles);
    const symbols = [...symbolSet].slice(0, 20);
    const tokenEstimate = files.length * 50 + symbols.length * 10;

    return { files, symbols, tokenEstimate };
  } catch {
    return { files: [], symbols: [], tokenEstimate: 0 };
  }
}

/**
 * Extract search keywords from a user message.
 * Filters stop words, returns camelCase and PascalCase words preferentially.
 */
function extractKeywords(message) {
  const STOP = new Set([
    'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been', 'being',
    'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would', 'could', 'should',
    'may', 'might', 'shall', 'can', 'need', 'dare', 'ought', 'used', 'it', 'its',
    'this', 'that', 'these', 'those', 'i', 'me', 'my', 'we', 'our', 'you', 'your',
    'he', 'she', 'they', 'them', 'their', 'what', 'which', 'who', 'whom', 'when',
    'where', 'why', 'how', 'all', 'both', 'each', 'few', 'more', 'most', 'other',
    'some', 'such', 'no', 'nor', 'not', 'only', 'own', 'same', 'so', 'than', 'too',
    'very', 'just', 'in', 'on', 'at', 'by', 'for', 'with', 'about', 'against',
    'to', 'from', 'up', 'down', 'of', 'off', 'out', 'over', 'under', 'into', 'and',
    'or', 'but', 'if', 'then', 'else', 'file', 'files', 'code', 'function', 'class',
    'please', 'make', 'show', 'tell', 'give', 'get', 'set', 'run', 'use', 'add',
    'fix', 'find', 'look', 'check', 'help', 'want', 'need', 'try', 'let', 'create',
  ]);

  const words = message.split(/[\s,.\-_/\\()[\]{}'"`!?;:]+/);
  const keywords = [];

  // Prefer CamelCase/PascalCase first (likely symbol names)
  for (const w of words) {
    if (w.length >= 3 && /[A-Z]/.test(w) && !STOP.has(w.toLowerCase())) {
      keywords.push(w);
    }
  }

  // Then add other meaningful lowercase words
  for (const w of words) {
    if (w.length >= 4 && !/[A-Z]/.test(w) && !STOP.has(w.toLowerCase()) && !keywords.includes(w)) {
      keywords.push(w.toLowerCase());
    }
  }

  return keywords.slice(0, 5);
}

module.exports = { retrieveContext, extractKeywords };
