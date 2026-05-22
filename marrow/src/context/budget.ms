// SmallCode - Context Budget Engine
// The core differentiator: manages what the model sees within tight token limits

import { EventBus } from "../core/event_bus"

// Approximate token counting (4 chars ≈ 1 token for English/code)
const CHARS_PER_TOKEN = 4

pub struct BudgetConfig {
  max_budget_pct: Int       // % of context window for tool results + content
  working_memory_tokens: Int
  summary_threshold: Int    // line count above which files get summarized
}

pub struct TokenAllocation {
  system_prompt: Int
  working_memory: Int
  conversation: Int
  tool_results: Int
  available: Int
}

pub struct BudgetEngine {
  config: BudgetConfig
  model_context_length: Int
  current_usage: TokenUsage
  eventBus: EventBus?
}

struct TokenUsage {
  system_prompt: Int
  working_memory: Int
  conversation: Int
  tool_results: Int
}

pub impl BudgetEngine {
  pub fn new(config: BudgetConfig): BudgetEngine {
    return BudgetEngine {
      config: config,
      model_context_length: 0,  // set when model connects
      current_usage: TokenUsage { system_prompt: 0, working_memory: 0, conversation: 0, tool_results: 0 },
      eventBus: null,
    }
  }

  pub fn setModelContext(self, context_length: Int) {
    self.model_context_length = context_length
  }

  pub fn setEventBus(self, bus: EventBus) {
    self.eventBus = bus
  }

  // Get the total token budget available for dynamic content
  pub fn totalBudget(self): Int {
    return (self.model_context_length * self.config.max_budget_pct) / 100
  }

  // Get remaining available tokens
  pub fn available(self): Int {
    let used = self.current_usage.system_prompt
      + self.current_usage.working_memory
      + self.current_usage.conversation
      + self.current_usage.tool_results
    return max(0, self.totalBudget() - used)
  }

  // Get current allocation breakdown
  pub fn allocation(self): TokenAllocation {
    return TokenAllocation {
      system_prompt: self.current_usage.system_prompt,
      working_memory: self.current_usage.working_memory,
      conversation: self.current_usage.conversation,
      tool_results: self.current_usage.tool_results,
      available: self.available(),
    }
  }

  // Count tokens in a string (approximate)
  pub fn countTokens(text: String): Int {
    return (text.length + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN
  }

  // Register system prompt usage
  pub fn registerSystemPrompt(self, text: String) {
    self.current_usage.system_prompt = countTokens(text)
  }

  // Register working memory usage
  pub fn registerWorkingMemory(self, text: String) {
    self.current_usage.working_memory = countTokens(text)
  }

  // Check if content fits within budget
  pub fn canFit(self, text: String): Bool {
    return countTokens(text) <= self.available()
  }

  // Add conversation message, return whether it fit
  pub fn addConversationTokens(self, tokens: Int): Bool {
    if self.current_usage.conversation + tokens > self.totalBudget() {
      return false
    }
    self.current_usage.conversation += tokens
    return true
  }

  // Add tool result, truncating if needed
  pub fn fitToolResult(self, text: String, maxPct: Int = 40): String {
    let maxTokens = (self.totalBudget() * maxPct) / 100
    let available = min(maxTokens, self.available())
    let tokens = countTokens(text)

    if tokens <= available {
      self.current_usage.tool_results += tokens
      return text
    }

    // Truncate to fit
    let maxChars = available * CHARS_PER_TOKEN
    let truncated = text.slice(0, maxChars)
    let suffix = "\n\n[... truncated ${tokens - available} tokens to fit context budget]"
    self.current_usage.tool_results += available
    return truncated + suffix
  }

  // Determine if a file should be summarized (by line count)
  pub fn shouldSummarize(self, lineCount: Int): Bool {
    return lineCount > self.config.summary_threshold
  }

  // Get max lines we can afford to show from a file
  pub fn maxAffordableLines(self): Int {
    let availableChars = self.available() * CHARS_PER_TOKEN
    // Assume ~60 chars per line average for code
    return availableChars / 60
  }

  // Evict old content to make room (returns tokens freed)
  pub fn evict(self, needed: Int): Int {
    let freed = 0

    // Priority 1: Evict old tool results
    if self.current_usage.tool_results > 0 {
      let evictable = min(self.current_usage.tool_results, needed - freed)
      self.current_usage.tool_results -= evictable
      freed += evictable
    }

    // Priority 2: Evict old conversation
    if freed < needed && self.current_usage.conversation > 0 {
      let evictable = min(self.current_usage.conversation / 2, needed - freed)
      self.current_usage.conversation -= evictable
      freed += evictable
    }

    if self.eventBus {
      self.eventBus.emit("context.eviction", { freed: freed, needed: needed })
    }

    return freed
  }

  // Reset for new turn (clear tool results, keep conversation)
  pub fn newTurn(self) {
    self.current_usage.tool_results = 0
  }

  // Full reset
  pub fn reset(self) {
    self.current_usage = TokenUsage { system_prompt: 0, working_memory: 0, conversation: 0, tool_results: 0 }
  }

  // Get usage as percentage
  pub fn usagePct(self): Int {
    let total = self.current_usage.system_prompt
      + self.current_usage.working_memory
      + self.current_usage.conversation
      + self.current_usage.tool_results
    if self.model_context_length == 0 { return 0 }
    return (total * 100) / self.model_context_length
  }

  // Format usage for status bar display
  pub fn formatUsage(self): String {
    let pct = self.usagePct()
    let total = self.current_usage.system_prompt
      + self.current_usage.working_memory
      + self.current_usage.conversation
      + self.current_usage.tool_results
    return "${total}/${self.model_context_length} tokens (${pct}%)"
  }
}

fn max(a: Int, b: Int): Int {
  if a > b { return a }
  return b
}

fn min(a: Int, b: Int): Int {
  if a < b { return a }
  return b
}
