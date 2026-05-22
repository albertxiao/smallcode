// @ts-nocheck
'use strict';
// MarrowScript Feature Rank 3 — verify_and_fix
// Encapsulates the improvement loop from smallcode.js into a reusable module.
// Handles: self-critique, runValidation, fix prompts, decompose, escalation, auto-rollback.
//
// Exported:
//   verifyAndFixCompiled(filePath, userMessage, conversationHistory, config, context)
//   => Promise<{ handled: bool, newHistory: array, shouldBreak: bool }>

const fs = require('fs');
const path = require('path');

/**
 * Run the improvement loop for a just-written or patched file.
 *
 * @param {string} filePath
 * @param {string} userMessage
 * @param {Array}  conversationHistory  — mutated in place AND returned
 * @param {object} config
 * @param {object} context
 *   context.improvementAttempts    — shared attempts map (mutated)
 *   context.MAX_IMPROVE_ITERATIONS — number
 *   context.escalationEngine       — EscalationEngine | null
 *   context.ALL_TOOLS              — tool schemas array
 *   context._fullscreenRef         — TUI reference | null
 *   context._testRunnerDetector    — detector | null
 *   context.executeTool            — async fn(name, args) => result
 *   context.runValidation          — fn(filePath) => { passed, errors }
 *   context.tui                    — tui module
 *   context.validateEditFn         — async fn(path, content, task) | null
 * @returns {Promise<{ handled: boolean, newHistory: Array, shouldBreak: boolean }>}
 */
async function verifyAndFixCompiled(filePath, userMessage, conversationHistory, config, context) {
  const {
    improvementAttempts,
    MAX_IMPROVE_ITERATIONS,
    escalationEngine,
    ALL_TOOLS,
    _fullscreenRef,
    _testRunnerDetector,
    executeTool,
    runValidation,
    tui,
    validateEditFn,
  } = context;

  // ── Self-critique (validate_edit) ────────────────────────────────────────
  try {
    if (validateEditFn && filePath) {
      const fullPath = path.resolve(process.cwd(), filePath);
      const written = fs.existsSync(fullPath)
        ? fs.readFileSync(fullPath, 'utf-8')
        : '';
      const critique = await validateEditFn(filePath, written, userMessage);
      if (!critique.ok && critique.issues && critique.issues.length > 0) {
        if (_fullscreenRef) _fullscreenRef.addTool('critique', 'err', critique.issues[0].slice(0, 80));
        conversationHistory.push({
          role: 'user',
          content: `[SEMANTIC-REVIEW] Potential issue in ${filePath}: ${critique.issues[0]}`,
        });
      }
    }
  } catch {} // never block on self-critique

  // ── Syntax / compile validation ──────────────────────────────────────────
  const validation = runValidation(filePath);

  if (!validation || validation.passed) {
    // Passed — reset counter if we had been retrying
    if (improvementAttempts[filePath] > 0) {
      try { tui && console.log(tui.improvementFixed(filePath, improvementAttempts[filePath])); } catch {}
      improvementAttempts[filePath] = 0;
    }
    return { handled: false, newHistory: conversationHistory, shouldBreak: false };
  }

  // Validation failed
  if (!improvementAttempts[filePath]) improvementAttempts[filePath] = 0;
  improvementAttempts[filePath]++;

  const attempt = improvementAttempts[filePath];

  // Track attempt history
  const historyKey = `__history:${filePath}`;
  if (!improvementAttempts[historyKey]) improvementAttempts[historyKey] = [];
  improvementAttempts[historyKey].push({ attempt, errors: validation.errors.slice(0, 3) });

  if (attempt <= MAX_IMPROVE_ITERATIONS) {
    try { tui && console.log(tui.improvementLoop(validation.errors, attempt, MAX_IMPROVE_ITERATIONS)); } catch {}

    const history = improvementAttempts[historyKey];
    const historyStr = history.length > 1
      ? `\n\nPrevious attempts (${history.length - 1} failed):\n`
        + history.slice(0, -1).map((h, i) => `  Attempt ${i + 1}: ${h.errors[0] || 'unknown error'}`).join('\n')
      : '';

    let fixPrompt;
    if (attempt <= 2) {
      let testHint = '';
      try {
        if (_testRunnerDetector) {
          const r = _testRunnerDetector.detect();
          if (r) testHint = `\n\nAfter fixing, run \`${r.command}\` to verify.`;
        }
      } catch {}
      fixPrompt = `[AUTO-VALIDATE] Errors in ${filePath} (attempt ${attempt}/${MAX_IMPROVE_ITERATIONS}):\n${validation.errors.join('\n')}${historyStr}${testHint}\n\nFix these errors. Do NOT repeat the same approach that failed before.`;
    } else {
      let fileContent = '';
      try { fileContent = fs.readFileSync(path.resolve(process.cwd(), filePath), 'utf-8'); } catch {}
      const maxFileChars = Math.min(8000, Math.floor(((config?.context?.detected_window || 32768) * 0.15) * 4));
      const cappedFile = fileContent.length > maxFileChars
        ? fileContent.slice(0, maxFileChars) + `\n... (${Math.ceil((fileContent.length - maxFileChars) / 4)} more tokens truncated)`
        : fileContent;
      fixPrompt = `[AUTO-VALIDATE] After ${attempt} attempts, ${filePath} still has errors.${historyStr}\n\nFULL FILE CONTENT:\n\`\`\`\n${cappedFile}\n\`\`\`\n\nERRORS:\n${validation.errors.join('\n')}\n\nRead the FULL file above carefully. Fix ALL errors. Do NOT repeat previous failed approaches.`;
    }

    conversationHistory.push({ role: 'user', content: fixPrompt });
    return { handled: true, newHistory: conversationHistory, shouldBreak: false };
  }

  // ── Exceeded iterations — DECOMPOSE ──────────────────────────────────────
  improvementAttempts[filePath] = 0;

  let fileContent = '';
  try { fileContent = fs.readFileSync(path.resolve(process.cwd(), filePath), 'utf-8'); } catch {}

  // Try LLM-based decompose strategy first
  let strategy;
  try {
    const { decomposeTask } = require('../../../bin/features_adapter');
    if (decomposeTask) {
      const errStr = validation.errors.join('\n');
      const fileCtx = fileContent.slice(0, 1000);
      const result = await decomposeTask(userMessage, errStr, fileCtx);
      if (result) {
        strategy = {
          type: result.strategy,
          reason: result.reason,
          instruction: result.instruction,
        };
      }
    }
  } catch {}

  // Fall back to governor's regex-based strategy
  if (!strategy) {
    try {
      const { pickDecomposeStrategy } = require('../../../bin/governor');
      strategy = pickDecomposeStrategy(fileContent, validation.errors, filePath);
    } catch {
      strategy = {
        type: 'rewrite_section',
        reason: 'Could not determine strategy.',
        instruction: `Fix ${filePath} from scratch. Errors:\n${validation.errors.join('\n')}`,
      };
    }
  }

  const decomposeKey = `__decompose:${filePath}`;
  if (!improvementAttempts[decomposeKey]) improvementAttempts[decomposeKey] = 0;
  improvementAttempts[decomposeKey]++;

  if (improvementAttempts[decomposeKey] >= 2 && escalationEngine && escalationEngine.canEscalate()) {
    // Decompose exhausted — ESCALATE
    console.log(`  \x1b[35m⬆ ESCALATING to ${escalationEngine.provider} (${escalationEngine.model}) — local model exhausted\x1b[0m`);

    const maxEscFileChars = 12000;
    const cappedEscFile = fileContent.length > maxEscFileChars
      ? fileContent.slice(0, maxEscFileChars) + `\n... (truncated, ${fileContent.split('\n').length} lines total)`
      : fileContent;

    const escalationPrompt = `Fix these errors in ${filePath}. The code:\n\`\`\`\n${cappedEscFile}\n\`\`\`\n\nErrors:\n${validation.errors.join('\n')}\n\nPrevious attempts failed. Fix it correctly.`;
    const escalationMessages = [
      ...conversationHistory.slice(-6),
      { role: 'user', content: escalationPrompt },
    ];

    const escalatedResponse = await escalationEngine.escalate(escalationMessages, ALL_TOOLS);

    if (escalatedResponse && !escalatedResponse.error) {
      if (escalatedResponse.tool_calls) {
        conversationHistory.push(escalatedResponse);
        for (const tc of escalatedResponse.tool_calls) {
          const eName = tc.function.name;
          let eArgs;
          try { eArgs = JSON.parse(tc.function.arguments); } catch { eArgs = {}; }
          try { process.stdout.write(`  \x1b[35m⬆\x1b[0m `); if (tui) process.stdout.write(tui.toolStart(eName)); } catch {}
          const eResult = await executeTool(eName, eArgs);
          if (eResult.error) {
            try { if (tui) console.log(tui.toolError(eResult.error)); } catch {}
          } else {
            try { if (tui) console.log(tui.toolSuccess(`${eResult.action || ''} ${eResult.path || ''}`, 0)); } catch {}
          }
          conversationHistory.push({ role: 'tool', tool_call_id: tc.id, content: eResult.result || eResult.error || '' });
        }
      } else if (escalatedResponse.content) {
        conversationHistory.push({ role: 'assistant', content: escalatedResponse.content });
        try { if (tui) process.stdout.write(tui.renderMarkdown(escalatedResponse.content)); } catch {}
      }
      improvementAttempts[decomposeKey] = 0;
    } else {
      const errMsg = escalatedResponse?.error || 'No response';
      console.log(`  \x1b[31m✗ Escalation failed: ${errMsg}\x1b[0m`);

      // Auto-rollback (opt-in via SMALLCODE_SNAPSHOT_AUTO_ROLLBACK=true)
      try {
        const { getSnapshotManager } = require('../../session/snapshot');
        const snap = getSnapshotManager();
        if (snap.autoRollback && snap.isActive()) {
          const r = snap.rollback('escalation+improvement-loop exhausted');
          console.log(`  \x1b[33m↶ Auto-rollback: restored ${r.restored}, deleted ${r.deleted}\x1b[0m`);
          conversationHistory.push({
            role: 'user',
            content: `[AUTO-ROLLBACK] All edits in this turn have been reverted because validation kept failing. Re-read files before retrying.`,
          });
        }
      } catch {}

      conversationHistory.push({
        role: 'user',
        content: `[ESCALATION FAILED] Even the stronger model couldn't fix this. Deliver the best version you have and explain what's still broken.`,
      });
    }
  } else {
    // First decompose — try local model with new strategy
    console.log(`  \x1b[33m◇ DECOMPOSE: ${strategy.reason}\x1b[0m`);
    console.log(`  \x1b[90m  Strategy: ${strategy.type}\x1b[0m`);
    conversationHistory.push({
      role: 'user',
      content: `[DECOMPOSE] After ${MAX_IMPROVE_ITERATIONS} failed fix attempts, changing strategy.\n\n${strategy.instruction}`,
    });
  }

  return { handled: true, newHistory: conversationHistory, shouldBreak: false };
}

module.exports = { verifyAndFixCompiled };
