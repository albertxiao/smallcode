// SmallCode — Model Escalation Engine (MarrowScript source)
// When local model hard fails AND decompose fails, escalate to a stronger model.
// This is opt-in: users must configure an API key for Claude/OpenAI/DeepSeek.
//
// Flow:
//   local model → retry → decompose → retry → ESCALATE → stronger model
//
// The escalation model receives full context of what was attempted and what failed.

import { exec } from "std/process"
import { EventBus } from "../core/event_bus"

// Supported escalation providers
pub enum EscalationProvider {
  Anthropic   // Claude (Sonnet, Haiku, Opus)
  OpenAI      // GPT-4o, GPT-4o-mini
  DeepSeek    // DeepSeek Coder
}

pub struct EscalationConfig {
  enabled: Bool
  provider: EscalationProvider?
  api_key: String?
  model: String?
  base_url: String?
  max_per_session: Int
  confirm_before_escalate: Bool
}

pub struct EscalationResult {
  success: Bool
  response: String?
  tool_calls: List<ToolCall>?
  error: String?
  tokens_used: Int
  cost_estimate_usd: Float
}

struct ToolCall {
  id: String
  name: String
  arguments: String
}

pub struct EscalationEngine {
  config: EscalationConfig
  escalation_count: Int
  eventBus: EventBus
}

pub impl EscalationEngine {
  pub fn new(config: EscalationConfig, eventBus: EventBus): EscalationEngine {
    return EscalationEngine {
      config: config,
      escalation_count: 0,
      eventBus: eventBus,
    }
  }

  // Check if escalation is available
  pub fn canEscalate(self): Bool {
    if !self.config.enabled { return false }
    if self.config.api_key == null { return false }
    if self.escalation_count >= self.config.max_per_session { return false }
    return true
  }

  // Get human-readable status
  pub fn status(self): String {
    if !self.config.enabled {
      return "disabled (no API key)"
    }
    let provName = match self.config.provider {
      Anthropic => "Claude"
      OpenAI => "OpenAI"
      DeepSeek => "DeepSeek"
      _ => "unknown"
    }
    return "${provName} (${self.config.model ?? "default"}) — ${self.escalation_count}/${self.config.max_per_session} used"
  }

  // Perform escalation
  pub fn escalate(self, messages: List<Message>, tools: List<ToolDef>): EscalationResult {
    if !self.canEscalate() {
      return EscalationResult {
        success: false,
        response: null,
        tool_calls: null,
        error: "Escalation not available",
        tokens_used: 0,
        cost_estimate_usd: 0.0,
      }
    }

    self.escalation_count++
    self.eventBus.emit("escalation.start", {
      provider: self.config.provider,
      model: self.config.model,
      attempt: self.escalation_count,
    })

    // The actual API call is handled by the JS runtime (escalation.js)
    // This .ms file declares the contract and flow control
    let result = self._callProvider(messages, tools)

    self.eventBus.emit("escalation.complete", {
      success: result.success,
      tokens_used: result.tokens_used,
      cost: result.cost_estimate_usd,
    })

    return result
  }

  fn _callProvider(self, messages: List<Message>, tools: List<ToolDef>): EscalationResult {
    // Delegated to JS runtime — this is the type contract
    return EscalationResult {
      success: false,
      response: null,
      tool_calls: null,
      error: "Not implemented in .ms — see bin/escalation.js",
      tokens_used: 0,
      cost_estimate_usd: 0.0,
    }
  }
}

// Message type (shared with conversation history)
struct Message {
  role: String    // "system" | "user" | "assistant" | "tool"
  content: String?
  tool_calls: List<ToolCall>?
  tool_call_id: String?
}
