// SmallCode - Session Module
// Orchestrates the conversation loop: user input → model → tool calls → response
// This is the main execution engine that ties everything together

import { Config } from "./config"
import { EventBus } from "./event_bus"
import { ModelAdapter, ChatMessage, ToolCall, CompletionRequest, CompletionResponse } from "../model/adapter"
import { ToolRouter, ParsedToolCall } from "../tools/router"
import { ToolRegistry, ToolResult, ToolContext } from "../tools/registry"
import { BudgetEngine } from "../context/budget"
import { Compactor, Message } from "../context/compactor"
import { WorkingMemory } from "../context/working_memory"
import { StreamHandler } from "../model/streaming"
import { ToolValidator, repairJson } from "../tools/validator"
import { cwd } from "std/env"

const MAX_TOOL_LOOPS = 15      // Max tool calls per turn before forcing a response
const MAX_RETRIES = 2          // Max retries for failed tool calls

pub struct Session {
  config: Config
  model: ModelAdapter
  router: ToolRouter
  budget: BudgetEngine
  compactor: Compactor
  memory: WorkingMemory
  eventBus: EventBus
  validator: ToolValidator
  systemPrompt: String
  turnCount: Int
  toolCallCount: Int
  running: Bool
}

pub impl Session {
  pub fn new(
    config: Config,
    model: ModelAdapter,
    router: ToolRouter,
    budget: BudgetEngine,
    eventBus: EventBus,
  ): Session {
    let compactor = Compactor.new(budget)
    let memory = WorkingMemory.new(config.context.working_memory_tokens)
    memory.load()

    // Configure budget with model's context length
    let profile = model.profile()
    budget.setModelContext(profile.context_length)
    budget.setEventBus(eventBus)

    // Configure router based on model capabilities
    router.configure(profile)

    // Build system prompt
    let systemPrompt = buildSystemPrompt(config, router, profile)
    budget.registerSystemPrompt(systemPrompt)

    return Session {
      config: config,
      model: model,
      router: router,
      budget: budget,
      compactor: compactor,
      memory: memory,
      eventBus: eventBus,
      validator: ToolValidator.new(),
      systemPrompt: systemPrompt,
      turnCount: 0,
      toolCallCount: 0,
      running: false,
    }
  }

  // Run a single user message through the full cycle
  pub fn runOnce(self, userMessage: String): String {
    self.running = true
    self.turnCount += 1
    self.toolCallCount = 0
    self.compactor.nextTurn()

    // Add user message to conversation
    self.compactor.add("user", userMessage)

    // Execute the agent loop
    let response = self.agentLoop()

    self.running = false
    return response
  }

  // The main agent loop: model generates → tool calls → feed results → repeat
  fn agentLoop(self): String {
    let finalResponse = ""

    while self.toolCallCount < MAX_TOOL_LOOPS {
      // Build messages for the model
      let messages = self.buildMessages()

      // Get model response
      let request = CompletionRequest {
        messages: messages,
        tools: self.router.getSchemas(null),
        temperature: 0.1,  // Low temperature for coding tasks
        max_tokens: self.model.profile().max_output_tokens,
        stop: self.model.profile().stop_sequences,
        stream: true,
      }

      self.eventBus.emit("model.request", { turn: self.turnCount, tool_calls: self.toolCallCount })

      let response = self.model.completeStream(request, StreamHandler.new(
        onToken: |token| { self.eventBus.emit("model.token", { token: token }) },
        onComplete: || { self.eventBus.emit("model.complete", {}) },
        onEarlyStop: || { self.eventBus.emit("model.early_stop", {}) },
        maxOutputTokens: self.model.profile().max_output_tokens,
      ))

      // Update token usage if available
      if response.usage {
        self.budget.addConversationTokens(response.usage.completion_tokens)
      }

      // Check for tool calls
      let toolCalls = response.tool_calls

      // For text-mode models, try parsing tool calls from content
      if toolCalls.isEmpty() && response.content.length > 0 {
        let parsed = self.router.parseFromText(response.content)
        if parsed {
          toolCalls = [ToolCall {
            id: "parsed_${self.toolCallCount}",
            name: parsed.name,
            arguments: toJson(parsed.arguments),
          }]
          // Strip the tool call from the display content
          finalResponse = stripToolCall(response.content)
        } else {
          // No tool call — this is the final response
          finalResponse = response.content
          self.compactor.add("assistant", finalResponse)
          break
        }
      }

      if toolCalls.isEmpty() {
        // Model finished without tool calls
        finalResponse = response.content
        self.compactor.add("assistant", finalResponse)
        break
      }

      // Process tool calls
      self.compactor.add("assistant", response.content)

      for call in toolCalls {
        self.toolCallCount += 1
        self.eventBus.emit("tool.start", { name: call.name, id: call.id })

        // Parse arguments
        let args = repairJson(call.arguments)
        if !args {
          // Failed to parse — send error back to model
          let errorMsg = "Failed to parse arguments for tool '${call.name}'. Expected valid JSON."
          self.compactor.add("tool", errorMsg)
          self.eventBus.emit("tool.error", { name: call.name, error: "parse_failed" })
          continue
        }

        // Execute tool
        let ctx = ToolContext {
          cwd: cwd(),
          budget: self.budget,
          sessionId: "session_${self.turnCount}",
        }

        let result = self.router.execute(call.name, args, ctx)

        // Handle result
        if result.error {
          let errorOutput = "Error: ${result.error}"
          if result.output.length > 0 {
            errorOutput += "\n${result.output}"
          }
          self.compactor.add("tool", errorOutput)
          self.eventBus.emit("tool.error", { name: call.name, error: result.error })

          // Check if we should provide repair hint
          let tool = self.router.registry.get(call.name)
          if tool && !self.validator.shouldGiveUp() {
            let hint = self.validator.repairHint(tool, result.error)
            self.compactor.add("system", hint)
          }
        } else {
          self.compactor.add("tool", result.output)
          self.validator.resetRepairs()
          self.eventBus.emit("tool.complete", { name: call.name, output_tokens: BudgetEngine.countTokens(result.output) })
        }
      }

      // Check if we're running low on context
      if self.budget.available() < 500 {
        self.compactor.compact()
      }
    }

    if self.toolCallCount >= MAX_TOOL_LOOPS {
      finalResponse += "\n\n[Reached tool call limit (${MAX_TOOL_LOOPS}). Stopping.]"
    }

    // Save working memory at end of turn
    self.memory.save()

    return finalResponse
  }

  // Build the full message list for the model
  fn buildMessages(self): List<ChatMessage> {
    let messages: List<ChatMessage> = []

    // System prompt
    messages.push(ChatMessage {
      role: "system",
      content: self.systemPrompt,
      tool_calls: null,
      tool_call_id: null,
      name: null,
    })

    // Working memory (if not empty)
    let memContent = self.memory.get()
    if !memContent.isEmpty() {
      messages.push(ChatMessage {
        role: "system",
        content: memContent,
        tool_calls: null,
        tool_call_id: null,
        name: null,
      })
    }

    // Conversation history
    let history = self.compactor.getContext()
    for msg in history {
      messages.push(ChatMessage {
        role: msg.role,
        content: msg.content,
        tool_calls: null,
        tool_call_id: null,
        name: null,
      })
    }

    return messages
  }

  // Get session stats
  pub fn stats(self): Map<String, Any> {
    return {
      turns: self.turnCount,
      tool_calls_this_turn: self.toolCallCount,
      context_usage: self.budget.formatUsage(),
      memory_tokens: self.memory.tokenCount(),
      model: self.model.name(),
    }
  }

  // Reset session (new conversation)
  pub fn reset(self) {
    self.compactor.clear()
    self.turnCount = 0
    self.toolCallCount = 0
    self.budget.reset()
    self.budget.registerSystemPrompt(self.systemPrompt)
  }
}

// Build the system prompt — kept minimal to save context for small models
fn buildSystemPrompt(config: Config, router: ToolRouter, profile: ModelProfile): String {
  let parts = []

  parts.push("You are SmallCode, a coding assistant. You help users by reading, editing, and creating code files.")
  parts.push("")
  parts.push("Rules:")
  parts.push("- Use tools to interact with the codebase. Do not guess file contents.")
  parts.push("- Use the 'patch' tool for edits (search and replace). Avoid rewriting entire files.")
  parts.push("- Read files before editing them.")
  parts.push("- Keep responses concise and focused on the task.")
  parts.push("- If unsure, use the 'memory' tool to track your progress.")

  // Add tool routing instructions
  let toolPrompt = router.systemPrompt()
  if !toolPrompt.isEmpty() {
    parts.push("")
    parts.push(toolPrompt)
  }

  // Add model-specific notes based on weaknesses
  if profile.weaknesses.contains("long_planning") {
    parts.push("")
    parts.push("Note: For complex multi-step tasks, break them into small steps and use the 'plan' tool to track progress.")
  }

  return parts.join("\n")
}

// Strip tool call markup from response content for display
fn stripToolCall(content: String): String {
  // Remove <tool_call>...</tool_call> blocks
  let stripped = content.replaceAll("<tool_call>[\\s\\S]*?</tool_call>", "")
  // Remove ```json tool blocks
  stripped = stripped.replaceAll("```json\\s*\\{[^}]*\"tool\"[^}]*\\}\\s*```", "")
  // Remove TOOL_CALL blocks
  stripped = stripped.replaceAll("TOOL_CALL\\s*\\n[\\s\\S]*?(?:\\n\\n|$)", "")
  return stripped.trim()
}
