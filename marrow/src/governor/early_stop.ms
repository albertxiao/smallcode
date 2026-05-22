// SmallCode — Early-Stop Detection Engine
// Detects degenerate model behavior and terminates generation early to save tokens.
//
// Triggers:
//   1. Repetition loops: same token sequence appears 3+ times
//   2. Patch spiral: model repeatedly fails to match old_str (stuck on corrupted file)
//   3. Greeting regression: model outputs greeting mid-task (lost context)
//   4. Output explosion: response exceeds 2x expected length without tool calls
//
// Actions:
//   - On repetition: stop generation, inject "you are repeating yourself"
//   - On patch spiral: rewrite file from scratch instead of patching
//   - On greeting: re-inject last user request
//   - On explosion: truncate and re-prompt with "be concise"

import { EventBus } from "../core/event_bus"

pub struct EarlyStopConfig {
  repetitionThreshold: Int       // how many times a sequence repeats before stop (default: 3)
  repetitionWindowChars: Int     // character window to check for repeats (default: 200)
  maxPatchFailures: Int          // consecutive patch failures before file rewrite (default: 4)
  maxResponseTokens: Int         // hard cap on response length (default: model.max_output)
  enableGreetingDetection: Bool  // detect mid-task greetings (default: true)
}

pub struct EarlyStopDetector {
  config: EarlyStopConfig
  patchFailures: Map<String, Int>    // filePath → consecutive failures
  lastToolResults: List<String>      // sliding window of recent results
}

pub impl EarlyStopDetector {
  pub fn new(config: EarlyStopConfig?): EarlyStopDetector {
    let c = config ?? EarlyStopConfig {
      repetitionThreshold: 3,
      repetitionWindowChars: 200,
      maxPatchFailures: 4,
      maxResponseTokens: 8192,
      enableGreetingDetection: true,
    }
    return EarlyStopDetector {
      config: c,
      patchFailures: {},
      lastToolResults: [],
    }
  }

  // Check streaming tokens for repetition
  pub fn checkRepetition(self, buffer: String): StopSignal? {
    if buffer.length < self.config.repetitionWindowChars * 2 {
      return null
    }

    // Check last N chars for repeating patterns (50-char windows)
    let tail = buffer.slice(-self.config.repetitionWindowChars)
    for windowSize in [50, 80, 120] {
      if tail.length < windowSize * self.config.repetitionThreshold {
        continue
      }
      let pattern = tail.slice(0, windowSize)
      let count = 0
      let searchFrom = 0
      while true {
        let idx = tail.indexOf(pattern, searchFrom)
        if idx == -1 { break }
        count += 1
        searchFrom = idx + 1
      }
      if count >= self.config.repetitionThreshold {
        return StopSignal {
          reason: "repetition_loop",
          message: "Model is repeating itself (same ${windowSize}-char pattern ${count}x). Stopping.",
          action: "inject_correction",
          injection: "[SYSTEM] You are repeating the same output in a loop. STOP. Take a different approach or state what is blocking you.",
        }
      }
    }
    return null
  }

  // Track patch failures and detect spiral
  pub fn recordPatchResult(self, filePath: String, success: Bool): StopSignal? {
    if success {
      self.patchFailures.delete(filePath)
      return null
    }

    let count = (self.patchFailures.get(filePath) ?? 0) + 1
    self.patchFailures.set(filePath, count)

    if count >= self.config.maxPatchFailures {
      self.patchFailures.delete(filePath)
      return StopSignal {
        reason: "patch_spiral",
        message: "Patch failed ${count}x on ${filePath}. File may be corrupted. Switching to rewrite.",
        action: "rewrite_file",
        injection: "[SYSTEM] You have failed to patch ${filePath} ${count} times. The file is likely corrupted from previous bad patches. Use write_file to rewrite it completely from scratch. Read it first, understand what it should be, then write the correct version.",
      }
    }
    return null
  }

  // Detect greeting regression (model lost context)
  pub fn checkGreeting(self, content: String, hasToolCallsThisTurn: Bool): StopSignal? {
    if !self.config.enableGreetingDetection { return null }
    if !hasToolCallsThisTurn { return null }

    let lc = content.toLowerCase()
    let greetingPatterns = [
      "how can i help",
      "what would you like",
      "what can i do for you",
      "how can i assist",
      "hello! i'm ready",
      "hi there! what",
    ]

    let isGreeting = greetingPatterns.any(|p| lc.contains(p))
    if !isGreeting { return null }

    return StopSignal {
      reason: "greeting_regression",
      message: "Model output a greeting mid-task (likely lost context).",
      action: "inject_correction",
      injection: "[SYSTEM] You output a greeting instead of completing the task. Look at the conversation above — there is still work to do. Continue where you left off. Do NOT restart the conversation.",
    }
  }

  // Reset state for a new turn
  pub fn newTurn(self) {
    self.patchFailures = {}
    self.lastToolResults = []
  }
}

pub struct StopSignal {
  reason: String       // "repetition_loop" | "patch_spiral" | "greeting_regression" | "output_explosion"
  message: String      // human-readable explanation
  action: String       // "inject_correction" | "rewrite_file" | "truncate" | "abort"
  injection: String    // message to inject into conversation
}
