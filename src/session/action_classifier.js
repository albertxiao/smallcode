// SmallCode — Action Type Classifier (Feature: Query Routing)
//
// Classifies a plan step as 'query' (read-only, no disk writes allowed) or
// 'mutate' (can write). Query steps get a filtered tool set that excludes
// write_file, patch, append_file, create_and_run — preventing "how many lines
// does X have?" from accidentally overwriting a file.
//
// Decision logic:
//   1. If strong mutate signals present → 'mutate'
//   2. If step ends with '?' or starts with interrogative word → 'query'
//   3. If strong query signals present and no mutate signals → 'query'
//   4. Default: 'mutate' (safer — allows writes rather than blocking them)

'use strict';

const MUTATE_SIGNALS = [
  /\b(create|write|add|insert|implement|generate|scaffold|make)\b/i,
  /\b(fix|patch|update|modify|change|replace|refactor|edit|rewrite)\b/i,
  /\b(delete|remove|rename|move|migrate|drop|clean\s*up)\b/i,
  /\b(install|setup|configure|init|bootstrap|deploy)\b/i,
];

const QUERY_SIGNALS = [
  /\b(how\s+many|how\s+much|count|list|show|display|print|output)\b/i,
  /\b(what\s+is|what\s+are|what\s+does|what'?s)\b/i,
  /\b(find|search|look|locate|where\s+is|where\s+are)\b/i,
  /\b(check|verify|confirm|validate|inspect|examine|audit)\b/i,
  /\b(explain|describe|summarize|analyze|review)\b/i,
  /\b(read|view|open|see|cat|show\s+me)\b/i,
  /\b(does|is\s+there|are\s+there|exists?)\b/i,
];

// Write tools that are blocked during query steps
const WRITE_TOOL_NAMES = new Set([
  'write_file',
  'append_file',
  'patch',
  'create_and_run',
  'read_and_patch',
]);

/**
 * Classify a plan step text as 'query' or 'mutate'.
 * Defaults to 'mutate' on ambiguity — safer to allow writes than block.
 *
 * @param {string} stepText
 * @returns {'query' | 'mutate'}
 */
function classifyAction(stepText) {
  if (!stepText || typeof stepText !== 'string') return 'mutate';

  const text = stepText.trim();

  // Strong mutate signal → always mutate regardless of question form
  if (MUTATE_SIGNALS.some(p => p.test(text))) return 'mutate';

  // Ends with question mark → query
  if (text.endsWith('?')) return 'query';

  // Starts with interrogative → query
  if (/^(how|what|where|why|when|which|who|does|is|are|can|could|should)\b/i.test(text)) return 'query';

  // Has query signals and no mutate signals → query
  if (QUERY_SIGNALS.some(p => p.test(text))) return 'query';

  // Default: mutate
  return 'mutate';
}

/**
 * Filter a tool list to only those allowed for the given action type.
 * For 'mutate', returns allTools unchanged.
 * For 'query', removes write-capable tools.
 *
 * @param {'query' | 'mutate'} actionType
 * @param {object[]} allTools - array of OpenAI tool schema objects
 * @returns {object[]}
 */
function getToolsForActionType(actionType, allTools) {
  if (actionType !== 'query') return allTools;
  return allTools.filter(t => {
    const name = t?.function?.name || t?.name;
    return !WRITE_TOOL_NAMES.has(name);
  });
}

/**
 * Return the human-readable reason for tool filtering (for TUI display).
 * @param {'query' | 'mutate'} actionType
 * @returns {string}
 */
function actionTypeLabel(actionType) {
  return actionType === 'query'
    ? 'read-only step — write tools disabled'
    : 'mutate step — all tools available';
}

module.exports = { classifyAction, getToolsForActionType, actionTypeLabel, WRITE_TOOL_NAMES };
