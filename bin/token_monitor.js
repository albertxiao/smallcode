// SmallCode — Token Usage Monitor
// Tracks and reports token efficiency metrics per turn and session.
// Helps verify context compaction is working correctly.

class TokenMonitor {
  constructor() {
    this.turns = [];
    this.totalPrompt = 0;
    this.totalCompletion = 0;
    this.totalCalls = 0;
    this.compactions = 0;
    this.evictions = 0;
    this._nextCallIsNewTurn = false;
  }

  /**
   * Record a single LLM call's token usage.
   */
  recordCall(promptTokens, completionTokens, metadata = {}) {
    this.totalPrompt += promptTokens || 0;
    this.totalCompletion += completionTokens || 0;
    this.totalCalls++;

    if (!this.turns.length || metadata.newTurn || this._nextCallIsNewTurn) {
      this.turns.push({ calls: 0, promptTokens: 0, completionTokens: 0, toolCalls: 0 });
      this._nextCallIsNewTurn = false;
    }
    const turn = this.turns[this.turns.length - 1];
    turn.calls++;
    turn.promptTokens += promptTokens || 0;
    turn.completionTokens += completionTokens || 0;
    if (metadata.isToolCall) turn.toolCalls++;
  }

  recordCompaction() { this.compactions++; }
  recordEviction() { this.evictions++; }

  /**
   * Get efficiency metrics.
   */
  getMetrics() {
    const avgPromptPerCall = this.totalCalls > 0 ? Math.round(this.totalPrompt / this.totalCalls) : 0;
    const avgCompletionPerCall = this.totalCalls > 0 ? Math.round(this.totalCompletion / this.totalCalls) : 0;
    const totalTokens = this.totalPrompt + this.totalCompletion;

    // Efficiency: ratio of completion (useful output) to prompt (context overhead)
    const efficiency = this.totalPrompt > 0 ? (this.totalCompletion / this.totalPrompt * 100).toFixed(1) : '0';

    return {
      totalCalls: this.totalCalls,
      totalTokens,
      totalPrompt: this.totalPrompt,
      totalCompletion: this.totalCompletion,
      avgPromptPerCall,
      avgCompletionPerCall,
      efficiency: `${efficiency}%`, // higher = more output per context token
      turns: this.turns.length,
      compactions: this.compactions,
      evictions: this.evictions,
    };
  }

  /**
   * Format for display.
   */
  formatShort() {
    const m = this.getMetrics();
    return `${m.totalTokens} tok (${m.totalCalls} calls, ${m.efficiency} eff)`;
  }

  formatFull() {
    const m = this.getMetrics();
    return [
      `Token Usage Report`,
      `  Total: ${m.totalTokens} tokens (${m.totalPrompt} prompt + ${m.totalCompletion} completion)`,
      `  Calls: ${m.totalCalls} (${m.turns} turns)`,
      `  Avg/call: ${m.avgPromptPerCall} prompt, ${m.avgCompletionPerCall} completion`,
      `  Efficiency: ${m.efficiency} (completion / prompt ratio)`,
      `  Compactions: ${m.compactions} | Evictions: ${m.evictions}`,
    ].join('\n');
  }
}

module.exports = { TokenMonitor };
