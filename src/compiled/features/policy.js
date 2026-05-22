// @ts-nocheck
'use strict';
// Generated from marrow/features_1_6.marrow — agent_limits policy
// In-memory implementation (no DB — SmallCode is a CLI tool)

const BUDGETS = {
  run_turn: { windowMs: 60000, capCalls: 30, calls: 0, windowStart: 0 },
  per_user_tokens: { windowMs: 3600000, capTokens: 500000, tokens: 0, windowStart: 0 },
};

function resetIfExpired(budget) {
  const now = Date.now();
  if (now - budget.windowStart > budget.windowMs) {
    budget.calls = 0;
    budget.tokens = 0;
    budget.windowStart = now;
  }
}

function assertWithinBudget(action, charge = {}) {
  if (action === 'run_turn') {
    const b = BUDGETS.run_turn;
    resetIfExpired(b);
    if (b.calls + 1 > b.capCalls) {
      throw new Error(`TURN_RATE_LIMIT: exceeded ${b.capCalls} turns per minute`);
    }
  }
  const t = BUDGETS.per_user_tokens;
  resetIfExpired(t);
  if (charge.tokens && t.tokens + charge.tokens > t.capTokens) {
    const retryAfter = Math.ceil((t.windowMs - (Date.now() - t.windowStart)) / 1000);
    throw new Error(`TOKEN_BUDGET_EXCEEDED: retry after ${retryAfter}s`);
  }
}

function chargeBudget(action, charge = {}) {
  if (action === 'run_turn') {
    const b = BUDGETS.run_turn;
    resetIfExpired(b);
    b.calls++;
  }
  if (charge.tokens) {
    const t = BUDGETS.per_user_tokens;
    resetIfExpired(t);
    t.tokens += charge.tokens;
  }
}

function getBudgetState() {
  return {
    run_turn: { ...BUDGETS.run_turn },
    per_user_tokens: { ...BUDGETS.per_user_tokens },
  };
}

module.exports = { assertWithinBudget, chargeBudget, getBudgetState, BUDGETS };
