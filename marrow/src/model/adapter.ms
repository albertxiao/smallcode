// SmallCode - Model Adapter Layer
// Abstract interface to LLM providers with profile-based optimization

import { ModelConfig } from "../core/config"
import { ModelProfile, loadProfile } from "./profiles"
import { formatMessages } from "./templates"
import { StreamHandler } from "./streaming"

// Standard message format used internally
pub struct ChatMessage {
  role: String        // "system" | "user" | "assistant" | "tool"
  content: String
  tool_calls: List<ToolCall>?
  tool_call_id: String?
  name: String?       // tool name for tool results
}

pub struct ToolCall {
  id: String
  name: String
  arguments: String   // JSON string (or best-effort from model)
}

pub struct ToolSchema {
  name: String
  description: String
  parameters: Map<String, Any>  // JSON Schema
}

pub struct CompletionRequest {
  messages: List<ChatMessage>
  tools: List<ToolSchema>?
  temperature: Float
  max_tokens: Int?
  stop: List<String>?
  stream: Bool
}

pub struct CompletionResponse {
  content: String
  tool_calls: List<ToolCall>
  finish_reason: String     // "stop" | "tool_calls" | "length" | "early_stop"
  usage: TokenUsage?
}

pub struct TokenUsage {
  prompt_tokens: Int
  completion_tokens: Int
  total_tokens: Int
}

// Abstract model adapter interface
pub trait ModelAdapter {
  fn complete(self, request: CompletionRequest): CompletionResponse
  fn completeStream(self, request: CompletionRequest, handler: StreamHandler): CompletionResponse
  fn profile(self): ModelProfile
  fn name(self): String
  fn isAvailable(self): Bool
}

// Create the appropriate adapter based on config
pub fn createAdapter(config: ModelConfig): ModelAdapter {
  let profile = loadProfile(config.name)

  // Override profile with explicit config values
  if config.context_length {
    profile.context_length = config.context_length
  }
  if config.tool_format {
    profile.tool_format = config.tool_format
  }

  match config.provider {
    "ollama" => return OllamaAdapter.new(config, profile)
    "openai" => return OpenAIAdapter.new(config, profile)
    "anthropic" => return AnthropicAdapter.new(config, profile)
    "llamacpp" => return LlamaCppAdapter.new(config, profile)
    _ => {
      // Default to OpenAI-compatible for unknown providers
      println("[warn] Unknown provider '${config.provider}', using OpenAI-compatible adapter")
      return OpenAIAdapter.new(config, profile)
    }
  }
}

// Adapter for Ollama (local models)
pub struct OllamaAdapter {
  config: ModelConfig
  profile: ModelProfile
  baseUrl: String
}

pub impl OllamaAdapter {
  pub fn new(config: ModelConfig, profile: ModelProfile): OllamaAdapter {
    let baseUrl = env("OLLAMA_HOST") ?? "http://localhost:11434"
    return OllamaAdapter { config: config, profile: profile, baseUrl: baseUrl }
  }
}

impl ModelAdapter for OllamaAdapter {
  fn complete(self, request: CompletionRequest): CompletionResponse {
    let url = "${self.baseUrl}/api/chat"

    // Format messages according to model's preferred template
    let body = {
      model: self.config.name,
      messages: formatForOllama(request.messages, self.profile),
      stream: false,
      options: {
        temperature: request.temperature,
        num_ctx: self.profile.context_length,
      },
    }

    // Include tools if model supports tool calling
    if request.tools && self.profile.supports_tool_calling {
      body.tools = request.tools.map(|t| {
        return {
          type: "function",
          function: {
            name: t.name,
            description: t.description,
            parameters: t.parameters,
          }
        }
      })
    }

    if request.max_tokens {
      body.options.num_predict = request.max_tokens
    }

    let response = httpPost(url, body)
    return parseOllamaResponse(response)
  }

  fn completeStream(self, request: CompletionRequest, handler: StreamHandler): CompletionResponse {
    let url = "${self.baseUrl}/api/chat"

    let body = {
      model: self.config.name,
      messages: formatForOllama(request.messages, self.profile),
      stream: true,
      options: {
        temperature: request.temperature,
        num_ctx: self.profile.context_length,
      },
    }

    if request.tools && self.profile.supports_tool_calling {
      body.tools = request.tools.map(|t| {
        return { type: "function", function: { name: t.name, description: t.description, parameters: t.parameters } }
      })
    }

    let accumulated = ""
    let toolCalls = []

    httpPostStream(url, body, |chunk| {
      let parsed = parseJson(chunk)
      if parsed.message && parsed.message.content {
        accumulated += parsed.message.content
        handler.onToken(parsed.message.content)

        // Early-stop detection
        if handler.shouldStop(accumulated) {
          handler.onEarlyStop()
          return false  // signal to stop streaming
        }
      }
      if parsed.message && parsed.message.tool_calls {
        for tc in parsed.message.tool_calls {
          toolCalls.push(ToolCall {
            id: tc.id ?? "call_${toolCalls.length}",
            name: tc.function.name,
            arguments: toJson(tc.function.arguments),
          })
        }
      }
      if parsed.done {
        handler.onComplete()
        return false
      }
      return true  // continue streaming
    })

    return CompletionResponse {
      content: accumulated,
      tool_calls: toolCalls,
      finish_reason: if toolCalls.length > 0 { "tool_calls" } else { "stop" },
      usage: null,
    }
  }

  fn profile(self): ModelProfile { return self.profile }
  fn name(self): String { return "${self.config.provider}/${self.config.name}" }
  fn isAvailable(self): Bool {
    // Check if Ollama is running and model exists
    try {
      let response = httpGet("${self.baseUrl}/api/tags")
      let models = parseJson(response).models
      return models.any(|m| m.name.contains(self.config.name))
    } catch {
      return false
    }
  }
}

// OpenAI-compatible adapter (covers OpenAI, OpenRouter, vLLM, etc.)
pub struct OpenAIAdapter {
  config: ModelConfig
  profile: ModelProfile
  baseUrl: String
  apiKey: String
}

pub impl OpenAIAdapter {
  pub fn new(config: ModelConfig, profile: ModelProfile): OpenAIAdapter {
    let baseUrl = match config.provider {
      "openai" => env("OPENAI_BASE_URL") ?? "https://api.openai.com/v1",
      "openrouter" => "https://openrouter.ai/api/v1",
      _ => env("OPENAI_BASE_URL") ?? "https://api.openai.com/v1",
    }
    let apiKey = match config.provider {
      "openai" => env("OPENAI_API_KEY") ?? "",
      "openrouter" => env("OPENROUTER_API_KEY") ?? "",
      _ => env("OPENAI_API_KEY") ?? "",
    }
    return OpenAIAdapter { config: config, profile: profile, baseUrl: baseUrl, apiKey: apiKey }
  }
}

impl ModelAdapter for OpenAIAdapter {
  fn complete(self, request: CompletionRequest): CompletionResponse {
    let url = "${self.baseUrl}/chat/completions"

    let body = {
      model: self.config.name,
      messages: request.messages.map(|m| {
        return { role: m.role, content: m.content }
      }),
      temperature: request.temperature,
      stream: false,
    }

    if request.tools && self.profile.supports_tool_calling {
      body.tools = request.tools.map(|t| {
        return { type: "function", function: { name: t.name, description: t.description, parameters: t.parameters } }
      })
    }
    if request.max_tokens {
      body.max_tokens = request.max_tokens
    }

    let response = httpPost(url, body, headers: { "Authorization": "Bearer ${self.apiKey}" })
    let parsed = parseJson(response)
    let choice = parsed.choices[0]

    let toolCalls = []
    if choice.message.tool_calls {
      for tc in choice.message.tool_calls {
        toolCalls.push(ToolCall {
          id: tc.id,
          name: tc.function.name,
          arguments: tc.function.arguments,
        })
      }
    }

    return CompletionResponse {
      content: choice.message.content ?? "",
      tool_calls: toolCalls,
      finish_reason: choice.finish_reason,
      usage: if parsed.usage {
        TokenUsage {
          prompt_tokens: parsed.usage.prompt_tokens,
          completion_tokens: parsed.usage.completion_tokens,
          total_tokens: parsed.usage.total_tokens,
        }
      } else { null },
    }
  }

  fn completeStream(self, request: CompletionRequest, handler: StreamHandler): CompletionResponse {
    // SSE streaming for OpenAI-compatible APIs
    let url = "${self.baseUrl}/chat/completions"
    let body = {
      model: self.config.name,
      messages: request.messages.map(|m| { return { role: m.role, content: m.content } }),
      temperature: request.temperature,
      stream: true,
    }
    if request.tools && self.profile.supports_tool_calling {
      body.tools = request.tools.map(|t| {
        return { type: "function", function: { name: t.name, description: t.description, parameters: t.parameters } }
      })
    }

    let accumulated = ""
    let toolCalls = []

    httpPostSSE(url, body, headers: { "Authorization": "Bearer ${self.apiKey}" }, |event| {
      if event.data == "[DONE]" {
        handler.onComplete()
        return false
      }
      let chunk = parseJson(event.data)
      let delta = chunk.choices[0].delta
      if delta.content {
        accumulated += delta.content
        handler.onToken(delta.content)
        if handler.shouldStop(accumulated) {
          handler.onEarlyStop()
          return false
        }
      }
      if delta.tool_calls {
        // Accumulate tool call deltas
        for tc in delta.tool_calls {
          if tc.index >= toolCalls.length {
            toolCalls.push(ToolCall { id: tc.id ?? "", name: "", arguments: "" })
          }
          if tc.function.name { toolCalls[tc.index].name = tc.function.name }
          if tc.function.arguments { toolCalls[tc.index].arguments += tc.function.arguments }
        }
      }
      return true
    })

    return CompletionResponse {
      content: accumulated,
      tool_calls: toolCalls,
      finish_reason: if toolCalls.length > 0 { "tool_calls" } else { "stop" },
      usage: null,
    }
  }

  fn profile(self): ModelProfile { return self.profile }
  fn name(self): String { return "${self.config.provider}/${self.config.name}" }
  fn isAvailable(self): Bool { return !self.apiKey.isEmpty() }
}

// Anthropic adapter
pub struct AnthropicAdapter {
  config: ModelConfig
  profile: ModelProfile
  apiKey: String
}

pub impl AnthropicAdapter {
  pub fn new(config: ModelConfig, profile: ModelProfile): AnthropicAdapter {
    let apiKey = env("ANTHROPIC_API_KEY") ?? ""
    return AnthropicAdapter { config: config, profile: profile, apiKey: apiKey }
  }
}

impl ModelAdapter for AnthropicAdapter {
  fn complete(self, request: CompletionRequest): CompletionResponse {
    let url = "https://api.anthropic.com/v1/messages"

    // Separate system message from conversation
    let systemMsg = request.messages.find(|m| m.role == "system")
    let convMsgs = request.messages.filter(|m| m.role != "system")

    let body = {
      model: self.config.name,
      messages: convMsgs.map(|m| { return { role: m.role, content: m.content } }),
      max_tokens: request.max_tokens ?? self.profile.max_output_tokens,
      temperature: request.temperature,
    }

    if systemMsg {
      body.system = systemMsg.content
    }

    if request.tools {
      body.tools = request.tools.map(|t| {
        return { name: t.name, description: t.description, input_schema: t.parameters }
      })
    }

    let response = httpPost(url, body, headers: {
      "x-api-key": self.apiKey,
      "anthropic-version": "2023-06-01",
    })
    let parsed = parseJson(response)

    let content = ""
    let toolCalls = []
    for block in parsed.content {
      if block.type == "text" {
        content += block.text
      }
      if block.type == "tool_use" {
        toolCalls.push(ToolCall {
          id: block.id,
          name: block.name,
          arguments: toJson(block.input),
        })
      }
    }

    return CompletionResponse {
      content: content,
      tool_calls: toolCalls,
      finish_reason: parsed.stop_reason,
      usage: if parsed.usage {
        TokenUsage {
          prompt_tokens: parsed.usage.input_tokens,
          completion_tokens: parsed.usage.output_tokens,
          total_tokens: parsed.usage.input_tokens + parsed.usage.output_tokens,
        }
      } else { null },
    }
  }

  fn completeStream(self, request: CompletionRequest, handler: StreamHandler): CompletionResponse {
    // Anthropic streaming implementation
    // Similar to complete but with SSE events
    // Simplified - full implementation would handle content_block_delta events
    return self.complete(request)  // Fallback to non-streaming for now
  }

  fn profile(self): ModelProfile { return self.profile }
  fn name(self): String { return "anthropic/${self.config.name}" }
  fn isAvailable(self): Bool { return !self.apiKey.isEmpty() }
}

// llama.cpp server adapter
pub struct LlamaCppAdapter {
  config: ModelConfig
  profile: ModelProfile
  baseUrl: String
}

pub impl LlamaCppAdapter {
  pub fn new(config: ModelConfig, profile: ModelProfile): LlamaCppAdapter {
    let baseUrl = env("LLAMACPP_URL") ?? "http://localhost:8080"
    return LlamaCppAdapter { config: config, profile: profile, baseUrl: baseUrl }
  }
}

impl ModelAdapter for LlamaCppAdapter {
  fn complete(self, request: CompletionRequest): CompletionResponse {
    // llama.cpp uses /v1/chat/completions (OpenAI-compatible)
    let url = "${self.baseUrl}/v1/chat/completions"
    let body = {
      messages: request.messages.map(|m| { return { role: m.role, content: m.content } }),
      temperature: request.temperature,
      stream: false,
    }
    if request.max_tokens { body.max_tokens = request.max_tokens }

    let response = httpPost(url, body)
    let parsed = parseJson(response)
    let choice = parsed.choices[0]

    return CompletionResponse {
      content: choice.message.content ?? "",
      tool_calls: [],
      finish_reason: choice.finish_reason ?? "stop",
      usage: null,
    }
  }

  fn completeStream(self, request: CompletionRequest, handler: StreamHandler): CompletionResponse {
    // Same as OpenAI streaming since llama.cpp is compatible
    let url = "${self.baseUrl}/v1/chat/completions"
    let body = {
      messages: request.messages.map(|m| { return { role: m.role, content: m.content } }),
      temperature: request.temperature,
      stream: true,
    }

    let accumulated = ""
    httpPostSSE(url, body, headers: {}, |event| {
      if event.data == "[DONE]" { handler.onComplete(); return false }
      let chunk = parseJson(event.data)
      let delta = chunk.choices[0].delta
      if delta.content {
        accumulated += delta.content
        handler.onToken(delta.content)
        if handler.shouldStop(accumulated) { handler.onEarlyStop(); return false }
      }
      return true
    })

    return CompletionResponse {
      content: accumulated,
      tool_calls: [],
      finish_reason: "stop",
      usage: null,
    }
  }

  fn profile(self): ModelProfile { return self.profile }
  fn name(self): String { return "llamacpp/${self.config.name}" }
  fn isAvailable(self): Bool {
    try { httpGet("${self.baseUrl}/health"); return true }
    catch { return false }
  }
}

// Helper to format messages for Ollama's API
fn formatForOllama(messages: List<ChatMessage>, profile: ModelProfile): List<Map<String, Any>> {
  return messages.map(|m| {
    let msg = { role: m.role, content: m.content }
    if m.tool_calls && m.tool_calls.length > 0 {
      msg.tool_calls = m.tool_calls.map(|tc| {
        return { id: tc.id, function: { name: tc.name, arguments: parseJson(tc.arguments) } }
      })
    }
    if m.tool_call_id {
      msg.tool_call_id = m.tool_call_id
    }
    return msg
  })
}
