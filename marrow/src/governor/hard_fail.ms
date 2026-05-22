// SmallCode — Hard Fail Enforcement (ARK-inspired)
// NEVER deliver broken code as success.
// If verification fails after max retries, report failure honestly.

import { Verifier, VerificationResult } from "./verifier"
import { ToolScorer } from "./tool_scorer"
import { EventBus } from "../core/event_bus"

pub struct HardFailPolicy {
  maxRetries: Int
  verifier: Verifier
  scorer: ToolScorer
  eventBus: EventBus
  history: List<VerificationResult>
}

pub impl HardFailPolicy {
  pub fn new(eventBus: EventBus, maxRetries: Int = 2): HardFailPolicy {
    return HardFailPolicy {
      maxRetries: maxRetries,
      verifier: Verifier.new(maxRetries),
      scorer: ToolScorer.new(),
      eventBus: eventBus,
      history: [],
    }
  }

  // Verify code after creation/edit. Returns action to take.
  pub fn checkOutput(self, filePath: String, taskType: String, toolUsed: String): GovernorAction {
    let result = self.verifier.verify(filePath)
    self.history.push(result)

    if result.passed {
      // Success — record and proceed
      self.scorer.recordSuccess(toolUsed, taskType, 0)
      self.eventBus.emit("governor.verified", {
        file: filePath,
        confidence: result.confidence,
        compiled: result.compiled,
        executed: result.executed,
      })
      return GovernorAction.Accept { confidence: result.confidence }
    }

    // Failed — should we retry or hard fail?
    if self.verifier.shouldHardFail(self.history) {
      self.scorer.recordFailure(toolUsed, taskType, result.errors.first() ?? "verification failed")
      self.eventBus.emit("governor.hard_fail", {
        file: filePath,
        attempts: self.history.length,
        errors: result.errors,
      })
      return GovernorAction.HardFail {
        reason: formatHardFail(filePath, result, self.history.length),
      }
    }

    // Retry — send errors back to model
    self.eventBus.emit("governor.retry", {
      file: filePath,
      attempt: self.history.length,
      errors: result.errors,
    })
    return GovernorAction.Retry {
      errors: result.errors,
      attempt: self.history.length,
      maxAttempts: self.maxRetries,
      escalate: self.history.length >= 2,  // Use strong model on 2nd+ retry
    }
  }

  // Reset history for new task
  pub fn reset(self) {
    self.history = []
  }

  // Get tool recommendation based on scores
  pub fn recommendTool(self, taskType: String, candidates: List<String>): List<String> {
    // Sort by score, filter out tools that should be avoided
    let scored = candidates
      .filter(|t| !self.scorer.shouldAvoid(t, taskType))
      .map(|t| { tool: t, score: self.scorer.getScore(t, taskType) })
      .sort(|a, b| b.score - a.score)

    return scored.map(|s| s.tool)
  }
}

pub enum GovernorAction {
  Accept { confidence: Float }
  Retry { errors: List<String>, attempt: Int, maxAttempts: Int, escalate: Bool }
  HardFail { reason: String }
}

fn formatHardFail(filePath: String, result: VerificationResult, attempts: Int): String {
  let msg = "⚠️ HARD FAIL: Code in ${filePath} failed verification after ${attempts} attempts.\n"
  msg += "Refusing to deliver broken code.\n\n"
  msg += "Errors:\n"
  for err in result.errors.slice(0, 5) {
    msg += "  • ${err}\n"
  }
  msg += "\nThe code did NOT compile/run successfully. "
  msg += "I will NOT claim this was successful."
  return msg
}
