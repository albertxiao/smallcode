// SmallCode - Budget Policy
// Implements MarrowScript's cost_budgets policy
// Sliding window token/call caps with error/throttle actions

import { EventBus } from "./event_bus"
import { readFile, writeFile, pathExists, mkdirp } from "std/fs"
import { cwd } from "std/env"

const BUDGET_FILE = ".smallcode/budget_state.json"

pub struct BudgetSpec {
  scope: String           // "per_user" | "per_feature"
  feature: String?        // capability name (when scope = per_feature)
  window_ms: Int          // sliding window in milliseconds
  cap_tokens: Int?
  cap_calls: Int?
  cap_usd: Float?
  action: String          // "error" | "throttle"
  error_code: String?
  retry_after_ms: Int?
}

pub struct BudgetState {
  window_start: Int
  tokens_used: Int
  calls_made: Int
  usd_spent: Float
}

pub struct BudgetError {
  code: String
  message: String
  retry_after_ms: Int?
}

pub struct BudgetTracker {
  specs: List<BudgetSpec>
  state: Map<String, BudgetState>  // budget_key → state
  eventBus: EventBus
}

pub impl BudgetTracker {
  pub fn new(eventBus: EventBus): BudgetTracker {
    let tracker = BudgetTracker {
      specs: defaultSpecs(),
      state: {},
      eventBus: eventBus,
    }
    tracker.load()
    return tracker
  }

  // Check if we can proceed (pre-call gate)
  pub fn assertCanSpend(self, tokens: Int, feature: String?): BudgetError? {
    for spec in self.specs {
      // Filter by scope
      if spec.scope == "per_feature" && spec.feature != feature {
        continue
      }

      let key = budgetKey(spec)
      let state = self.getOrCreateState(key, spec)

      // Check against caps
      if spec.cap_tokens && state.tokens_used + tokens > spec.cap_tokens {
        self.eventBus.emit("budget.exceeded", { scope: spec.scope, feature: feature ?? "" })
        return makeBudgetError(spec)
      }
      if spec.cap_calls && state.calls_made + 1 > spec.cap_calls {
        self.eventBus.emit("budget.exceeded", { scope: spec.scope, feature: feature ?? "" })
        return makeBudgetError(spec)
      }
    }
    return null
  }

  // Charge after a successful call
  pub fn charge(self, tokens: Int, feature: String?) {
    for spec in self.specs {
      if spec.scope == "per_feature" && spec.feature != feature {
        continue
      }
      let key = budgetKey(spec)
      let state = self.getOrCreateState(key, spec)
      state.tokens_used += tokens
      state.calls_made += 1
    }
    self.save()
  }

  // Get current usage summary
  pub fn summary(self): String {
    let parts = []
    for spec in self.specs {
      let key = budgetKey(spec)
      let state = self.state.get(key)
      if !state { continue }

      let usage = ""
      if spec.cap_tokens {
        let pct = (state.tokens_used * 100) / spec.cap_tokens
        usage = "${state.tokens_used}/${spec.cap_tokens} tokens (${pct}%)"
      }
      if spec.cap_calls {
        let pct = (state.calls_made * 100) / spec.cap_calls
        usage = "${state.calls_made}/${spec.cap_calls} calls (${pct}%)"
      }

      let scope = if spec.feature { "feature:${spec.feature}" } else { spec.scope }
      parts.push("${scope}: ${usage}")
    }
    return parts.join(" | ")
  }

  // Reset budgets (admin operation)
  pub fn reset(self) {
    self.state = {}
    self.save()
  }

  fn getOrCreateState(self, key: String, spec: BudgetSpec): BudgetState {
    let currentTime = now()

    if self.state.has(key) {
      let state = self.state.get(key)
      // Check if window expired — reset if so
      if currentTime - state.window_start > spec.window_ms {
        let newState = BudgetState { window_start: currentTime, tokens_used: 0, calls_made: 0, usd_spent: 0.0 }
        self.state.set(key, newState)
        return newState
      }
      return state
    }

    let newState = BudgetState { window_start: currentTime, tokens_used: 0, calls_made: 0, usd_spent: 0.0 }
    self.state.set(key, newState)
    return newState
  }

  fn load(self) {
    let path = "${cwd()}/${BUDGET_FILE}"
    if pathExists(path) {
      let content = readFile(path)
      self.state = parseJson(content)
    }
  }

  fn save(self) {
    mkdirp("${cwd()}/.smallcode")
    let path = "${cwd()}/${BUDGET_FILE}"
    writeFile(path, toJson(self.state))
  }
}

fn defaultSpecs(): List<BudgetSpec> {
  return [
    BudgetSpec {
      scope: "per_user",
      feature: null,
      window_ms: 3600000,   // 1 hour
      cap_tokens: 500000,
      cap_calls: null,
      cap_usd: null,
      action: "error",
      error_code: "TOKEN_LIMIT",
      retry_after_ms: null,
    },
    BudgetSpec {
      scope: "per_feature",
      feature: "run_turn",
      window_ms: 60000,     // 1 minute
      cap_tokens: null,
      cap_calls: 30,
      cap_usd: null,
      action: "throttle",
      error_code: null,
      retry_after_ms: 30000,
    },
  ]
}

fn budgetKey(spec: BudgetSpec): String {
  if spec.feature {
    return "${spec.scope}:${spec.feature}"
  }
  return spec.scope
}

fn makeBudgetError(spec: BudgetSpec): BudgetError {
  match spec.action {
    "throttle" => return BudgetError {
      code: "THROTTLED",
      message: "Rate limit reached. Try again in ${(spec.retry_after_ms ?? 30000) / 1000}s.",
      retry_after_ms: spec.retry_after_ms,
    }
    _ => return BudgetError {
      code: spec.error_code ?? "BUDGET_EXCEEDED",
      message: "Budget exceeded for ${spec.scope}.",
      retry_after_ms: null,
    }
  }
}
