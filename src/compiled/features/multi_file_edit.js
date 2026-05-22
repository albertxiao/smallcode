// @ts-nocheck
'use strict';
// MarrowScript Feature Rank 6 — multi_file_edit
// Coordination layer for agent turns that edit 3+ files simultaneously.
// Injects a structured coordination header into conversation history so the
// model tracks which files still need editing and doesn't drift.
//
// Export:
//   coordinateMultiFileEdit(task, files, conversationHistory, executeTool, snapshotManager)
//   => Promise<{ plan: string[], injected: boolean }>

/**
 * Coordinate a multi-file edit by opening a snapshot checkpoint and injecting
 * a coordination header into the conversation.
 *
 * @param {string}   task                - The user's task description
 * @param {string[]} files               - Files being edited this turn
 * @param {Array}    conversationHistory - Mutated in place
 * @param {Function} executeTool         - async (name, args) => result (for read_file)
 * @param {object}   snapshotManager     - { begin(label): void } | null
 * @returns {Promise<{ plan: string[], injected: boolean }>}
 */
async function coordinateMultiFileEdit(task, files, conversationHistory, executeTool, snapshotManager) {
  if (!files || files.length < 3) {
    return { plan: [], injected: false };
  }

  // Open a snapshot checkpoint so all these writes are grouped together
  try {
    if (snapshotManager && typeof snapshotManager.begin === 'function') {
      snapshotManager.begin(`multi-file-${Date.now()}`);
    }
  } catch {}

  // Build a clear coordination plan
  const plan = files.map((f, i) => `${i + 1}. Edit ${f}`);

  // Only inject if there isn't already a multi-file coordination message in recent history
  const recent = conversationHistory.slice(-6);
  const alreadyInjected = recent.some(
    m => typeof m.content === 'string' && m.content.includes('[MULTI-FILE-EDIT]'),
  );

  if (!alreadyInjected) {
    const header = [
      `[MULTI-FILE-EDIT] This turn requires coordinated changes to ${files.length} files.`,
      ``,
      `Files to edit:`,
      ...plan,
      ``,
      `Complete ALL files before responding. Do not skip any. Check each file for cross-file consistency (imports, exports, shared types).`,
    ].join('\n');

    conversationHistory.push({ role: 'system', content: header });
    return { plan, injected: true };
  }

  return { plan, injected: false };
}

module.exports = { coordinateMultiFileEdit };
