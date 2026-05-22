// SmallCode — Programmatic API
// Clean interface for embedding SmallCode in other tools, CI pipelines, and frameworks.
//
// Usage:
//   const { SmallCode } = require('smallcode');
//   const agent = new SmallCode({ model: 'gemma-4-e4b', baseUrl: 'http://...' });
//   const result = await agent.run("fix the bug in main.ts");
//   console.log(result.response, result.toolCalls, result.files);
//
// Events:
//   agent.on('tool_start', ({ name, args }) => ...)
//   agent.on('tool_end', ({ name, result, ms }) => ...)
//   agent.on('token', (text) => ...)
//   agent.on('error', (err) => ...)

import { EventBus } from "../core/event_bus"
import { Session } from "../core/session"
import { ToolRegistry } from "../tools/registry"
import { BudgetEngine } from "../context/budget"
import { EarlyStopDetector } from "../governor/early_stop"
import { getProfile } from "../model/profiles"

pub struct SmallCodeConfig {
  model: String
  baseUrl: String
  provider: String               // "openai" | "ollama" | "anthropic"
  apiKey: String?                // for cloud/authenticated endpoints
  contextWindow: Int?            // auto-detected if not set
  maxToolCalls: Int?             // default: 50
  timeout: Int?                  // per-call timeout in ms, default: 120000
  cwd: String?                   // working directory, default: process.cwd()
  tools: List<String>?           // restrict available tools
  verbose: Bool?                 // emit detailed events
}

pub struct RunResult {
  response: String               // final assistant text
  toolCalls: List<ToolCallRecord>
  filesCreated: List<String>
  filesEdited: List<String>
  tokensUsed: TokenUsage
  duration: Int                  // total ms
  success: Bool
  error: String?
}

pub struct ToolCallRecord {
  name: String
  args: Map<String, Any>
  result: String
  error: String?
  durationMs: Int
}

pub struct TokenUsage {
  input: Int
  output: Int
  total: Int
}

pub struct SmallCode {
  config: SmallCodeConfig
  events: EventBus
  earlyStop: EarlyStopDetector
  profile: ModelProfile
}

pub impl SmallCode {
  pub fn new(config: SmallCodeConfig): SmallCode {
    let profile = getProfile(config.model, config.contextWindow ?? 0)
    let earlyStop = EarlyStopDetector.new()
    let events = EventBus.new()

    return SmallCode {
      config: config,
      events: events,
      earlyStop: earlyStop,
      profile: profile,
    }
  }

  // Run a single prompt and return structured results
  pub async fn run(self, prompt: String): RunResult {
    let startTime = now()
    self.earlyStop.newTurn()

    let result = RunResult {
      response: "",
      toolCalls: [],
      filesCreated: [],
      filesEdited: [],
      tokensUsed: TokenUsage { input: 0, output: 0, total: 0 },
      duration: 0,
      success: false,
      error: null,
    }

    // Run agent loop, collecting results
    // ... (delegates to internal loop)

    result.duration = now() - startTime
    result.success = result.error == null
    return result
  }

  // Subscribe to events
  pub fn on(self, event: String, handler: Fn) {
    self.events.subscribe(event, handler)
  }

  // Get detected model profile
  pub fn getProfile(self): ModelProfile {
    return self.profile
  }
}
