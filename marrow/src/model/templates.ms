// SmallCode - Chat Templates
// Model-specific message formatting for models that need special templates
// Critical for local models that don't always handle OpenAI format natively

import { ChatMessage } from "./adapter"
import { ModelProfile } from "./profiles"

// Format messages according to model's template requirement
pub fn formatMessages(messages: List<ChatMessage>, profile: ModelProfile): String {
  match profile.template {
    "chatml" => return formatChatML(messages)
    "llama3" => return formatLlama3(messages)
    "mistral" => return formatMistral(messages)
    "gemma" => return formatGemma(messages)
    "phi" => return formatPhi(messages)
    "generic" => return formatGeneric(messages)
    _ => return formatChatML(messages)  // Default
  }
}

// Format tool call as text (for models without native tool calling)
pub fn formatToolCallAsText(name: String, args: Map<String, Any>): String {
  return "<tool_call>\n{\"name\": \"${name}\", \"arguments\": ${toJson(args)}}\n</tool_call>"
}

// Format tool result as text
pub fn formatToolResultAsText(name: String, result: String): String {
  return "<tool_result name=\"${name}\">\n${result}\n</tool_result>"
}

// Generate tool use instructions for models without native tool calling
pub fn toolInstructionPrompt(tools: List<Map<String, Any>>, format: String): String {
  match format {
    "hermes" => return hermesToolPrompt(tools)
    "json" => return jsonToolPrompt(tools)
    "xml" => return xmlToolPrompt(tools)
    "text" => return textToolPrompt(tools)
    _ => return jsonToolPrompt(tools)
  }
}

// --- Template Formatters ---

fn formatChatML(messages: List<ChatMessage>): String {
  let parts = []
  for msg in messages {
    parts.push("<|im_start|>${msg.role}")
    parts.push(msg.content)
    parts.push("<|im_end|>")
  }
  parts.push("<|im_start|>assistant")
  return parts.join("\n")
}

fn formatLlama3(messages: List<ChatMessage>): String {
  let parts = ["<|begin_of_text|>"]
  for msg in messages {
    parts.push("<|start_header_id|>${msg.role}<|end_header_id|>\n\n${msg.content}<|eot_id|>")
  }
  parts.push("<|start_header_id|>assistant<|end_header_id|>\n\n")
  return parts.join("")
}

fn formatMistral(messages: List<ChatMessage>): String {
  let parts = []
  let isFirst = true
  for msg in messages {
    if msg.role == "system" {
      if isFirst {
        // Mistral puts system in first user message
        parts.push("[INST] ${msg.content}")
        isFirst = false
      }
    } else if msg.role == "user" {
      if isFirst {
        parts.push("[INST] ${msg.content} [/INST]")
        isFirst = false
      } else {
        parts.push("[INST] ${msg.content} [/INST]")
      }
    } else if msg.role == "assistant" {
      parts.push(msg.content)
    }
  }
  return parts.join("\n")
}

fn formatGemma(messages: List<ChatMessage>): String {
  let parts = []
  for msg in messages {
    if msg.role == "user" || msg.role == "system" {
      parts.push("<start_of_turn>user\n${msg.content}<end_of_turn>")
    } else if msg.role == "assistant" {
      parts.push("<start_of_turn>model\n${msg.content}<end_of_turn>")
    }
  }
  parts.push("<start_of_turn>model\n")
  return parts.join("\n")
}

fn formatPhi(messages: List<ChatMessage>): String {
  let parts = []
  for msg in messages {
    if msg.role == "system" {
      parts.push("<|system|>\n${msg.content}<|end|>")
    } else if msg.role == "user" {
      parts.push("<|user|>\n${msg.content}<|end|>")
    } else if msg.role == "assistant" {
      parts.push("<|assistant|>\n${msg.content}<|end|>")
    }
  }
  parts.push("<|assistant|>\n")
  return parts.join("\n")
}

fn formatGeneric(messages: List<ChatMessage>): String {
  // Simple concatenation for models without special templates
  let parts = []
  for msg in messages {
    if msg.role == "system" {
      parts.push("### System:\n${msg.content}\n")
    } else if msg.role == "user" {
      parts.push("### User:\n${msg.content}\n")
    } else if msg.role == "assistant" {
      parts.push("### Assistant:\n${msg.content}\n")
    }
  }
  parts.push("### Assistant:\n")
  return parts.join("")
}

// --- Tool Format Prompts ---

fn hermesToolPrompt(tools: List<Map<String, Any>>): String {
  let toolDescs = tools.map(|t| {
    return "{\"type\": \"function\", \"function\": {\"name\": \"${t.name}\", \"description\": \"${t.description}\", \"parameters\": ${toJson(t.parameters)}}}"
  }).join(",\n")

  return "You are a function calling AI. You have access to the following tools:

<tools>
[${toolDescs}]
</tools>

To call a tool, respond with:
<tool_call>
{\"name\": \"tool_name\", \"arguments\": {\"arg1\": \"value1\"}}
</tool_call>

You can call multiple tools. After tool results are returned, continue with your response."
}

fn jsonToolPrompt(tools: List<Map<String, Any>>): String {
  let toolList = tools.map(|t| "- ${t.name}: ${t.description}").join("\n")
  let schemas = tools.map(|t| "### ${t.name}\n${toJson(t.parameters)}").join("\n\n")

  return "You have tools available. To use a tool, output valid JSON in this format:
```json
{\"tool\": \"tool_name\", \"args\": {\"param\": \"value\"}}
```

Available tools:
${toolList}

Schemas:
${schemas}

After receiving tool results, continue your response."
}

fn xmlToolPrompt(tools: List<Map<String, Any>>): String {
  let toolList = tools.map(|t| "<tool name=\"${t.name}\">${t.description}</tool>").join("\n")

  return "You have tools available:
${toolList}

To use a tool, write:
<use_tool>
<name>tool_name</name>
<args>{\"param\": \"value\"}</args>
</use_tool>

Wait for the result before continuing."
}

fn textToolPrompt(tools: List<Map<String, Any>>): String {
  let toolList = tools.map(|t| "TOOL: ${t.name}\n  DESC: ${t.description}\n  PARAMS: ${t.parameters.keys().join(", ")}").join("\n\n")

  return "You can use these tools by writing TOOL_CALL on its own line followed by the tool name and arguments.

${toolList}

Example:
TOOL_CALL
name: read_file
path: src/main.ms

The system will execute the tool and show you the result. Then continue your work."
}
