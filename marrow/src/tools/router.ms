// SmallCode - 2-Stage Tool Router
// The key optimization for small models: reduces schema context overhead by 50%+
//
// Stage 1: Model picks a CATEGORY (read/write/search/run/plan/web)
//   - Only category descriptions in context (~200 tokens)
// Stage 2: System injects only that category's tool schemas
//   - Model makes specific tool call with full schema available
//
// For models WITH native tool calling:
//   - Uses tool_choice to guide selection
// For models WITHOUT native tool calling:
//   - Uses text-based routing with pattern matching

import { ToolRegistry, ToolDef, ToolResult, ToolContext } from "./registry"
import { BudgetEngine } from "../context/budget"
import { ModelProfile } from "../model/profiles"
import { ToolValidator } from "./validator"

pub struct ToolRouter {
  registry: ToolRegistry
  budget: BudgetEngine
  validator: ToolValidator
  mode: String                  // "two_stage" | "direct" | "text"
}

pub impl ToolRouter {
  pub fn new(registry: ToolRegistry, budget: BudgetEngine): ToolRouter {
    return ToolRouter {
      registry: registry,
      budget: budget,
      validator: ToolValidator.new(),
      mode: "two_stage",  // default, overridden based on model profile
    }
  }

  // Configure routing mode based on model capabilities
  pub fn configure(self, profile: ModelProfile) {
    if profile.supports_tool_calling && profile.context_length >= 16384 {
      // Model can handle full schema set — use direct mode
      self.mode = "direct"
    } else if profile.supports_tool_calling {
      // Model has tool calling but limited context — use 2-stage
      self.mode = "two_stage"
    } else {
      // No native tool calling — use text-based routing
      self.mode = "text"
    }
  }

  // Get the system prompt addition for tool routing (Stage 1)
  pub fn systemPrompt(self): String {
    match self.mode {
      "direct" => return self.directSystemPrompt()
      "two_stage" => return self.twoStageSystemPrompt()
      "text" => return self.textSystemPrompt()
      _ => return self.twoStageSystemPrompt()
    }
  }

  // Get tool schemas for the model based on current routing stage
  pub fn getSchemas(self, category: String?): List<Map<String, Any>> {
    match self.mode {
      "direct" => {
        // Full schema set
        return self.registry.schemas(null)
      }
      "two_stage" => {
        if !category {
          // Stage 1: return category selector "tool"
          return [categoryTool()]
        }
        // Stage 2: return tools for selected category
        let tools = self.registry.byCategory(category)
        return self.registry.schemas(tools.map(|t| t.id))
      }
      "text" => {
        // Text mode: schemas embedded in system prompt, not as tool definitions
        return []
      }
      _ => return []
    }
  }

  // Route and execute a tool call
  pub fn execute(self, toolName: String, args: Map<String, Any>, ctx: ToolContext): ToolResult {
    let tool = self.registry.get(toolName)
    if !tool {
      return ToolResult {
        output: "",
        metadata: null,
        error: "Unknown tool: '${toolName}'. Available: ${self.registry.active().map(|t| t.id).join(", ")}",
      }
    }

    // Validate arguments
    let validationError = self.validator.validate(tool, args)
    if validationError {
      return ToolResult {
        output: "",
        metadata: null,
        error: validationError,
      }
    }

    // Execute with budget awareness
    let result = tool.execute(args, ctx)

    // Truncate output to fit context budget
    if result.output && result.output.length > 0 {
      result.output = self.budget.fitToolResult(result.output)
    }

    return result
  }

  // Parse a tool call from model output (for text-based mode)
  pub fn parseFromText(self, text: String): ParsedToolCall? {
    // Try multiple formats in order of preference

    // Format 1: JSON tool call
    let jsonMatch = extractJson(text, "tool")
    if jsonMatch {
      return jsonMatch
    }

    // Format 2: Hermes-style <tool_call> XML
    let hermesMatch = extractHermes(text)
    if hermesMatch {
      return hermesMatch
    }

    // Format 3: TOOL_CALL text format
    let textMatch = extractTextFormat(text)
    if textMatch {
      return textMatch
    }

    // Format 4: XML <use_tool> format
    let xmlMatch = extractXml(text)
    if xmlMatch {
      return xmlMatch
    }

    return null
  }

  // --- Private helpers ---

  fn directSystemPrompt(self): String {
    return "You have tools available. Use them to complete the user's request. Call tools as needed."
  }

  fn twoStageSystemPrompt(self): String {
    let categories = self.registry.categoryDescriptions()
    return "You have tools available in these categories:
${categories}

First indicate which category you need, then I'll show you the available tools for that category."
  }

  fn textSystemPrompt(self): String {
    // For models without native tool calling, embed everything in system prompt
    let tools = self.registry.active()
    let toolDescs = tools.map(|t| {
      let params = t.parameters.map(|p| {
        let req = if p.required { " (required)" } else { "" }
        return "    ${p.name}: ${p.description}${req}"
      }).join("\n")
      return "  ${t.id}: ${t.description}\n${params}"
    }).join("\n\n")

    return "You have tools available. To use a tool, write a tool call in this format:

<tool_call>
{\"name\": \"tool_name\", \"arguments\": {\"param\": \"value\"}}
</tool_call>

Available tools:
${toolDescs}

Use tools as needed to complete the user's request. Wait for tool results before continuing."
  }
}

pub struct ParsedToolCall {
  name: String
  arguments: Map<String, Any>
}

// Category selector pseudo-tool (for 2-stage routing)
fn categoryTool(): Map<String, Any> {
  return {
    name: "select_category",
    description: "Select the tool category you need for your next action",
    parameters: {
      type: "object",
      properties: {
        category: {
          type: "string",
          enum: ["read", "write", "search", "run", "plan", "web"],
          description: "The category of tool you need",
        },
        reason: {
          type: "string",
          description: "Brief reason for needing this category",
        },
      },
      required: ["category"],
    },
  }
}

// --- Text parsing helpers ---

fn extractJson(text: String, key: String): ParsedToolCall? {
  // Look for {"tool": "...", "args": {...}} or {"name": "...", "arguments": {...}}
  let patterns = [
    "\\{[^}]*\"tool\"\\s*:\\s*\"([^\"]+)\"[^}]*\"args\"\\s*:\\s*(\\{[^}]*\\})",
    "\\{[^}]*\"name\"\\s*:\\s*\"([^\"]+)\"[^}]*\"arguments\"\\s*:\\s*(\\{[^}]*\\})",
  ]

  for pattern in patterns {
    let match = text.match(pattern)
    if match {
      try {
        let args = parseJson(match[2])
        return ParsedToolCall { name: match[1], arguments: args }
      } catch {
        continue
      }
    }
  }

  // Try to find any JSON block that looks like a tool call
  let jsonBlocks = text.matchAll("```json\\s*\\n([\\s\\S]*?)\\n```")
  for block in jsonBlocks {
    try {
      let parsed = parseJson(block[1])
      if parsed.tool || parsed.name {
        return ParsedToolCall {
          name: parsed.tool ?? parsed.name,
          arguments: parsed.args ?? parsed.arguments ?? {},
        }
      }
    } catch {
      continue
    }
  }

  return null
}

fn extractHermes(text: String): ParsedToolCall? {
  let match = text.match("<tool_call>\\s*\\n?([\\s\\S]*?)\\n?</tool_call>")
  if !match { return null }

  try {
    let parsed = parseJson(match[1])
    return ParsedToolCall {
      name: parsed.name,
      arguments: parsed.arguments ?? {},
    }
  } catch {
    return null
  }
}

fn extractTextFormat(text: String): ParsedToolCall? {
  // TOOL_CALL\nname: xxx\nparam: value
  let match = text.match("TOOL_CALL\\s*\\n\\s*name:\\s*(.+?)\\n([\\s\\S]*?)(?:\\n\\n|$)")
  if !match { return null }

  let name = match[1].trim()
  let argsText = match[2]

  // Parse key: value pairs
  let args = {}
  let lines = argsText.split("\n")
  for line in lines {
    let parts = line.split(":", limit: 2)
    if parts.length == 2 {
      args.set(parts[0].trim(), parts[1].trim())
    }
  }

  return ParsedToolCall { name: name, arguments: args }
}

fn extractXml(text: String): ParsedToolCall? {
  let match = text.match("<use_tool>\\s*<name>(.+?)</name>\\s*<args>([\\s\\S]*?)</args>\\s*</use_tool>")
  if !match { return null }

  try {
    let args = parseJson(match[2])
    return ParsedToolCall { name: match[1], arguments: args }
  } catch {
    return null
  }
}
