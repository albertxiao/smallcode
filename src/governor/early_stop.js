// SmallCode — Early-Stop Detection (Runtime)
// Detects degenerate model behavior: repetition loops, patch spirals, greeting regression
// Compiled from: src/governor/early_stop.ms

class EarlyStopDetector {
  constructor(config = {}) {
    this.repetitionThreshold = config.repetitionThreshold || 3;
    this.repetitionWindowChars = config.repetitionWindowChars || 200;
    this.maxPatchFailures = config.maxPatchFailures || 4;
    this.maxResponseTokens = config.maxResponseTokens || 8192;
    this.enableGreetingDetection = config.enableGreetingDetection !== false;

    this.patchFailures = {};  // filePath → consecutive failure count
  }

  /**
   * Check streaming buffer for repetition loops.
   * Call this with the accumulated output during streaming.
   * Returns a StopSignal if repetition detected, null otherwise.
   *
   * Optimized: only inspects the TAIL of the buffer (last repetitionWindowChars)
   * to avoid O(n²) scanning of the entire output on every token.
   */
  checkRepetition(buffer) {
    if (buffer.length < this.repetitionWindowChars * 2) return null;

    // Only examine the tail — no need to re-scan the entire buffer
    const tail = buffer.slice(-this.repetitionWindowChars);
    for (const windowSize of [50, 80, 120]) {
      if (tail.length < windowSize * this.repetitionThreshold) continue;

      // Check if the last windowSize chars repeat multiple times in the tail
      const pattern = tail.slice(-windowSize);
      let count = 0;
      let searchFrom = 0;
      while (true) {
        const idx = tail.indexOf(pattern, searchFrom);
        if (idx === -1) break;
        count++;
        searchFrom = idx + 1;
        if (count >= this.repetitionThreshold) break; // early exit
      }

      if (count >= this.repetitionThreshold) {
        return {
          reason: 'repetition_loop',
          message: `Model repeating itself (${windowSize}-char pattern ${count}x). Stopping.`,
          action: 'inject_correction',
          injection: '[SYSTEM] You are repeating the same output in a loop. STOP. Take a different approach or state what is blocking you.',
        };
      }
    }
    return null;
  }

  /**
   * Track patch tool results. Returns a StopSignal if the model is stuck
   * in a patch spiral (repeatedly failing OR making no-op patches on the same file).
   * Tracks both failures and total attempts per file per turn.
   */
  recordPatchResult(filePath, success, oldStr, newStr) {
    // Track total attempts (success or fail) per file
    if (!this._patchAttempts) this._patchAttempts = {};
    this._patchAttempts[filePath] = (this._patchAttempts[filePath] || 0) + 1;

    // Detect no-op patch (old_str === new_str, or patch "succeeded" but content unchanged)
    const isNoOp = success && oldStr && newStr && oldStr === newStr;

    if (success && !isNoOp) {
      // Real successful patch — reduce failure count but don't fully reset
      if (this.patchFailures[filePath]) {
        this.patchFailures[filePath] = Math.max(0, this.patchFailures[filePath] - 1);
      }
      return null;
    }

    // Count failures (including no-ops which indicate confusion)
    this.patchFailures[filePath] = (this.patchFailures[filePath] || 0) + 1;
    const failCount = this.patchFailures[filePath];
    const totalAttempts = this._patchAttempts[filePath];

    // Trigger on: 4+ failures OR 6+ total attempts on same file (model is spinning)
    if (failCount >= this.maxPatchFailures || totalAttempts >= 6) {
      delete this.patchFailures[filePath];
      delete this._patchAttempts[filePath];
      return {
        reason: 'patch_spiral',
        message: `Patch stuck on ${filePath} (${failCount} failures, ${totalAttempts} attempts). Switching to rewrite.`,
        action: 'rewrite_file',
        injection: `[SYSTEM] You have attempted to patch ${filePath} ${totalAttempts} times (${failCount} failures). The file is likely corrupted or your patches don't match. STOP using patch. Instead:
1. Use read_file to see the current state
2. Decide what the ENTIRE file should contain
3. Use write_file to rewrite it completely from scratch
Do NOT attempt another patch on this file.`,
      };
    }
    return null;
  }

  /**
   * Detect if model output is a greeting (lost context mid-task).
   */
  checkGreeting(content, hasToolCallsThisTurn) {
    if (!this.enableGreetingDetection || !hasToolCallsThisTurn) return null;

    const lc = content.toLowerCase();
    const greetingPatterns = [
      'how can i help',
      'what would you like',
      'what can i do for you',
      'how can i assist',
      "hello! i'm ready",
      'hi there! what',
    ];

    if (!greetingPatterns.some(p => lc.includes(p))) return null;

    return {
      reason: 'greeting_regression',
      message: 'Model output a greeting mid-task (lost context).',
      action: 'inject_correction',
      injection: '[SYSTEM] You output a greeting instead of completing the task. Look at the conversation above — there is still work to do. Continue where you left off. Do NOT restart the conversation.',
    };
  }

  /**
   * Reset patch failure tracking (call at start of new user turn).
   * Also clears the per-attempt counter so failure scoreboards don't grow
   * unbounded when many distinct files are touched across a long session.
   */
  newTurn() {
    this.patchFailures = {};
    this._patchAttempts = {};
  }
}

module.exports = { EarlyStopDetector };
