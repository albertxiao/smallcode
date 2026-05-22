// SmallCode - Model Profiles
// Per-model capability definitions that drive prompt formatting and tool routing

import { readFile, pathExists } from "std/fs"
import { parse as parseToml } from "std/toml"

pub struct ModelProfile {
  name: String
  context_length: Int
  max_output_tokens: Int
  supports_tool_calling: Bool
  tool_format: String           // "native" | "hermes" | "json" | "xml" | "text"
  supports_json_mode: Bool
  supports_system_message: Bool
  template: String              // "chatml" | "llama3" | "mistral" | "gemma" | "phi" | "generic"
  strengths: List<String>
  weaknesses: List<String>
  stop_sequences: List<String>
}

// Built-in profiles for popular small coding models
const BUILTIN_PROFILES: Map<String, ModelProfile> = {
  "qwen2.5-coder-7b": ModelProfile {
    name: "qwen2.5-coder-7b",
    context_length: 32768,
    max_output_tokens: 8192,
    supports_tool_calling: true,
    tool_format: "hermes",
    supports_json_mode: true,
    supports_system_message: true,
    template: "chatml",
    strengths: ["code_completion", "refactoring", "python", "typescript"],
    weaknesses: ["long_planning", "multi_file_coordination"],
    stop_sequences: ["<|endoftext|>", "<|im_end|>"],
  },
  "qwen2.5-coder-14b": ModelProfile {
    name: "qwen2.5-coder-14b",
    context_length: 32768,
    max_output_tokens: 8192,
    supports_tool_calling: true,
    tool_format: "hermes",
    supports_json_mode: true,
    supports_system_message: true,
    template: "chatml",
    strengths: ["code_completion", "refactoring", "debugging", "multi_language"],
    weaknesses: ["long_planning"],
    stop_sequences: ["<|endoftext|>", "<|im_end|>"],
  },
  "qwen3-8b": ModelProfile {
    name: "qwen3-8b",
    context_length: 32768,
    max_output_tokens: 8192,
    supports_tool_calling: true,
    tool_format: "hermes",
    supports_json_mode: true,
    supports_system_message: true,
    template: "chatml",
    strengths: ["reasoning", "code_completion", "instruction_following"],
    weaknesses: ["very_long_context"],
    stop_sequences: ["<|endoftext|>", "<|im_end|>"],
  },
  "deepseek-coder-v2-lite": ModelProfile {
    name: "deepseek-coder-v2-lite",
    context_length: 16384,
    max_output_tokens: 4096,
    supports_tool_calling: false,
    tool_format: "json",
    supports_json_mode: true,
    supports_system_message: true,
    template: "chatml",
    strengths: ["code_completion", "python", "fill_in_middle"],
    weaknesses: ["tool_calling", "long_planning", "multi_step"],
    stop_sequences: ["<|endoftext|>", "<|EOT|>"],
  },
  "codellama-13b": ModelProfile {
    name: "codellama-13b",
    context_length: 16384,
    max_output_tokens: 4096,
    supports_tool_calling: false,
    tool_format: "text",
    supports_json_mode: false,
    supports_system_message: true,
    template: "llama3",
    strengths: ["code_completion", "python", "c_cpp"],
    weaknesses: ["tool_calling", "json_output", "instruction_following"],
    stop_sequences: ["<|eot_id|>"],
  },
  "starcoder2-15b": ModelProfile {
    name: "starcoder2-15b",
    context_length: 16384,
    max_output_tokens: 4096,
    supports_tool_calling: false,
    tool_format: "text",
    supports_json_mode: false,
    supports_system_message: false,
    template: "generic",
    strengths: ["code_completion", "fill_in_middle", "multi_language"],
    weaknesses: ["instruction_following", "tool_calling", "planning"],
    stop_sequences: ["<|endoftext|>"],
  },
  "mistral-nemo-12b": ModelProfile {
    name: "mistral-nemo-12b",
    context_length: 32768,
    max_output_tokens: 8192,
    supports_tool_calling: true,
    tool_format: "native",
    supports_json_mode: true,
    supports_system_message: true,
    template: "mistral",
    strengths: ["instruction_following", "reasoning", "multi_language"],
    weaknesses: ["very_long_code_generation"],
    stop_sequences: ["</s>"],
  },
  "phi-3-mini": ModelProfile {
    name: "phi-3-mini",
    context_length: 4096,
    max_output_tokens: 2048,
    supports_tool_calling: false,
    tool_format: "text",
    supports_json_mode: false,
    supports_system_message: true,
    template: "phi",
    strengths: ["reasoning", "math", "short_tasks"],
    weaknesses: ["long_code", "multi_file", "tool_calling"],
    stop_sequences: ["<|end|>"],
  },
  "granite-code-8b": ModelProfile {
    name: "granite-code-8b",
    context_length: 8192,
    max_output_tokens: 4096,
    supports_tool_calling: false,
    tool_format: "json",
    supports_json_mode: true,
    supports_system_message: true,
    template: "chatml",
    strengths: ["code_completion", "enterprise_languages"],
    weaknesses: ["tool_calling", "long_context"],
    stop_sequences: ["<|endoftext|>"],
  },
  "devstral-small": ModelProfile {
    name: "devstral-small",
    context_length: 32768,
    max_output_tokens: 8192,
    supports_tool_calling: true,
    tool_format: "native",
    supports_json_mode: true,
    supports_system_message: true,
    template: "mistral",
    strengths: ["code_completion", "agentic_coding", "tool_calling"],
    weaknesses: ["very_long_planning"],
    stop_sequences: ["</s>"],
  },
}

// Load a model profile by name
// Checks: custom profile file → built-in profiles → auto-detect defaults
pub fn loadProfile(modelName: String): ModelProfile {
  // Check for custom profile file
  let profilePath = "profiles/${modelName}.toml"
  if pathExists(profilePath) {
    let raw = readFile(profilePath)
    let parsed = parseToml(raw)
    return parsed as ModelProfile
  }

  // Check built-in profiles (match by substring for flexibility)
  for (key, profile) in BUILTIN_PROFILES {
    if modelName.contains(key) || key.contains(modelName) {
      return profile
    }
  }

  // Default fallback profile for unknown models
  return ModelProfile {
    name: modelName,
    context_length: 8192,       // Conservative default
    max_output_tokens: 4096,
    supports_tool_calling: false,
    tool_format: "text",        // Safest default
    supports_json_mode: false,
    supports_system_message: true,
    template: "chatml",         // Most common
    strengths: [],
    weaknesses: ["unknown_capabilities"],
    stop_sequences: [],
  }
}

// Try to auto-detect model capabilities from Ollama model info
pub fn detectFromOllama(modelInfo: Map<String, Any>): ModelProfile? {
  let params = modelInfo.get("parameters")
  if !params { return null }

  // Try to extract context length from model metadata
  let contextLength = 8192
  if params.contains("num_ctx") {
    // Parse from model parameters
    contextLength = 32768  // Most modern models support 32k
  }

  return null  // Only use if we can reliably detect
}
