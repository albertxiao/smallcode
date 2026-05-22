// SmallCode — Clarification Loop
// Detects vague/ambiguous prompts and asks the user for clarification
// before wasting tool calls on a misunderstood task.
//
// Triggers ONLY when:
// - Prompt matches a specific vague pattern (not just being short)
// - Multiple interpretations are genuinely possible
// - The last assistant message did NOT end with a question (context-aware guard
//   lives in smallcode.js — if the assistant asked a question, the user's reply
//   is an answer, not a new task, regardless of how short it is)
//
// Does NOT trigger on:
// - Short but actionable commands ("run tests", "fix bug", "add logging")
// - Greetings ("hi", "hello") — model should respond naturally
// - Confirmations ("yes", "no", "ok") — these answer the model's questions
// - Multi-word follow-ups ("go ahead", "read it") — continuation phrases
// - Multi-number selections ("1 and 2") — answering a numbered list

/**
 * Check if a user message is too vague to act on.
 * Returns true if clarification should be requested.
 */
function needsClarification(message) {
  const msg = message.trim();

  // Never trigger on empty (already handled) or file references
  if (!msg || msg.startsWith('@') || msg.startsWith('/')) return false;

  // Never trigger on confirmations (these are answers to prior model questions)
  if (/^(yes|no|ok|sure|go|do it|y|n|yep|nope|yeah|nah)$/i.test(msg)) return false;

  // Never trigger on multi-word continuations and follow-ups
  if (/^(go ahead|go for it|just do it|do that|do both|read it|show me|that one|sounds good|let's do it|let's go|that works)\b/i.test(msg)) return false;

  // Never trigger on multi-number selections ("1 and 2", "1, 2", "both 1 and 2")
  if (/^(both\s+)?\d+(\s*,\s*|\s+and\s+)\d+$/i.test(msg)) return false;

  // Vague patterns that genuinely lack specifics and need clarification
  const vaguePatterns = [
    /^(fix|do|make|change|update|improve)\s+(it|this|that|things?)$/i,
    /^(help|please|can you|could you)$/i,
    /^(make it|do the|fix the)\s+(better|work|thing|stuff)$/i,
    /^(same|again|more|another)$/i,
  ];

  return vaguePatterns.some(p => p.test(msg));
}

/**
 * Generate a clarification prompt to inject into the system message.
 * Tells the model to ask before acting.
 */
function getClarificationInstruction() {
  return `The user's message is vague or very short. Before taking action:
1. State what you THINK they want (your best interpretation)
2. Ask ONE specific clarifying question
3. Do NOT use any tools until the user confirms or clarifies.`;
}

module.exports = { needsClarification, getClarificationInstruction };
