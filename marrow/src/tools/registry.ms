// SmallCode - Tool Registry
// Registers and manages all available tools
// Much simpler than OpenCode's Effect-based registry — just a map of tools

import { ToolsConfig } from "../core/config"
import { BudgetEngine } from "../context/budget"

pub struct ToolDef {
  id: String
  category: String            // "read" | "write" | "search" | "run" | "plan" | "web"
  description: String
  parameters: List<ToolParam>
  execute: fn(Map<String, Any>, ToolContext) -> ToolResult
}

pub struct ToolParam {
  name: String
  type: String        // "string" | "int" | "bool" | "list"
  description: String
  required: Bool
  default: Any?
}

pub struct ToolContext {
  cwd: String
  budget: BudgetEngine
  sessionId: String
}

pub struct ToolResult {
  output: String
  metadata: Map<String, Any>?
  error: String?
}

pub struct ToolRegistry {
  tools: Map<String, ToolDef>
  enabled: List<String>
  disabled: List<String>
}

pub impl ToolRegistry {
  pub fn new(config: ToolsConfig): ToolRegistry {
    let registry = ToolRegistry {
      tools: {},
      enabled: config.enabled,
      disabled: config.disabled,
    }

    // Register all built-in tools
    registry.registerBuiltins()
    return registry
  }

  // Register a tool
  pub fn register(self, tool: ToolDef) {
    self.tools.set(tool.id, tool)
  }

  // Get a tool by ID
  pub fn get(self, id: String): ToolDef? {
    return self.tools.get(id)
  }

  // Get all active tools (enabled and not disabled)
  pub fn active(self): List<ToolDef> {
    return self.tools.values()
      .filter(|t| self.enabled.contains(t.id) && !self.disabled.contains(t.id))
      .toList()
  }

  // Get tools by category
  pub fn byCategory(self, category: String): List<ToolDef> {
    return self.active().filter(|t| t.category == category)
  }

  // Get all categories
  pub fn categories(self): List<String> {
    return self.active().map(|t| t.category).unique()
  }

  // Get tool schemas formatted for the model
  pub fn schemas(self, toolIds: List<String>?): List<Map<String, Any>> {
    let tools = if toolIds {
      toolIds.filterMap(|id| self.get(id))
    } else {
      self.active()
    }

    return tools.map(|t| {
      let properties = {}
      let required = []

      for param in t.parameters {
        properties.set(param.name, {
          type: param.type,
          description: param.description,
        })
        if param.required {
          required.push(param.name)
        }
      }

      return {
        name: t.id,
        description: t.description,
        parameters: {
          type: "object",
          properties: properties,
          required: required,
        },
      }
    })
  }

  // Get compact category descriptions (for 2-stage routing)
  pub fn categoryDescriptions(self): String {
    let cats = {
      "read": "Read files, view code, inspect content",
      "write": "Create or edit files (patch, write)",
      "search": "Find files or search code content",
      "run": "Execute shell commands",
      "plan": "Manage tasks, working memory, planning",
      "web": "Search the internet, fetch URLs",
    }

    return cats.entries()
      .filter(|(cat, _)| self.byCategory(cat).length > 0)
      .map(|(cat, desc)| "- ${cat}: ${desc}")
      .join("\n")
  }

  fn registerBuiltins(self) {
    // These are imported from builtin/*.ms
    // Registered in dependency order

    self.register(ToolDef {
      id: "read_file",
      category: "read",
      description: "Read file contents. Shows signatures for large files, full content for small ones. Use start_line/end_line for specific ranges.",
      parameters: [
        ToolParam { name: "path", type: "string", description: "File path to read", required: true, default: null },
        ToolParam { name: "start_line", type: "int", description: "Start line (1-indexed)", required: false, default: null },
        ToolParam { name: "end_line", type: "int", description: "End line (1-indexed)", required: false, default: null },
      ],
      execute: builtinReadFile,
    })

    self.register(ToolDef {
      id: "write_file",
      category: "write",
      description: "Create a new file or overwrite an existing one with the given content.",
      parameters: [
        ToolParam { name: "path", type: "string", description: "File path to write", required: true, default: null },
        ToolParam { name: "content", type: "string", description: "Full file content", required: true, default: null },
      ],
      execute: builtinWriteFile,
    })

    self.register(ToolDef {
      id: "patch",
      category: "write",
      description: "Edit a file by replacing a specific string with new content. The old_str must match exactly one location in the file.",
      parameters: [
        ToolParam { name: "path", type: "string", description: "File to edit", required: true, default: null },
        ToolParam { name: "old_str", type: "string", description: "Exact text to find and replace", required: true, default: null },
        ToolParam { name: "new_str", type: "string", description: "Replacement text", required: true, default: null },
      ],
      execute: builtinPatch,
    })

    self.register(ToolDef {
      id: "bash",
      category: "run",
      description: "Execute a shell command and return its output. Commands time out after configured seconds.",
      parameters: [
        ToolParam { name: "command", type: "string", description: "Shell command to execute", required: true, default: null },
        ToolParam { name: "cwd", type: "string", description: "Working directory (optional)", required: false, default: null },
      ],
      execute: builtinBash,
    })

    self.register(ToolDef {
      id: "search",
      category: "search",
      description: "Search file contents using regex pattern (ripgrep). Returns matching lines with context.",
      parameters: [
        ToolParam { name: "pattern", type: "string", description: "Regex pattern to search for", required: true, default: null },
        ToolParam { name: "path", type: "string", description: "Directory or file to search in", required: false, default: "." },
        ToolParam { name: "include", type: "string", description: "File glob pattern to include", required: false, default: null },
      ],
      execute: builtinSearch,
    })

    self.register(ToolDef {
      id: "find_files",
      category: "search",
      description: "Find files matching a glob pattern. Returns file paths.",
      parameters: [
        ToolParam { name: "pattern", type: "string", description: "Glob pattern (e.g. '**/*.ms', 'src/**')", required: true, default: null },
      ],
      execute: builtinFindFiles,
    })

    self.register(ToolDef {
      id: "symbols",
      category: "search",
      description: "Search for code symbols (functions, classes, structs) by name. Uses the code index.",
      parameters: [
        ToolParam { name: "query", type: "string", description: "Symbol name or partial match", required: true, default: null },
      ],
      execute: builtinSymbols,
    })

    self.register(ToolDef {
      id: "memory",
      category: "plan",
      description: "Read or write your working memory scratchpad. Use to track state across turns.",
      parameters: [
        ToolParam { name: "action", type: "string", description: "'read', 'write', 'append', or 'clear'", required: true, default: null },
        ToolParam { name: "content", type: "string", description: "Content to write/append (required for write/append)", required: false, default: null },
      ],
      execute: builtinMemory,
    })

    self.register(ToolDef {
      id: "plan",
      category: "plan",
      description: "Read or update the task plan (TODO.md). Use to track multi-step work.",
      parameters: [
        ToolParam { name: "action", type: "string", description: "'read', 'add', 'complete', or 'clear'", required: true, default: null },
        ToolParam { name: "task", type: "string", description: "Task description (for 'add') or task number (for 'complete')", required: false, default: null },
      ],
      execute: builtinPlan,
    })

    self.register(ToolDef {
      id: "web_search",
      category: "web",
      description: "Search the internet for information.",
      parameters: [
        ToolParam { name: "query", type: "string", description: "Search query", required: true, default: null },
      ],
      execute: builtinWebSearch,
    })

    self.register(ToolDef {
      id: "web_fetch",
      category: "web",
      description: "Fetch content from a URL.",
      parameters: [
        ToolParam { name: "url", type: "string", description: "URL to fetch", required: true, default: null },
      ],
      execute: builtinWebFetch,
    })

    self.register(ToolDef {
      id: "bone_compile",
      category: "write",
      description: "Compile a .bone file into a complete Node.js/TypeScript backend. Creates routes, models, auth, events, migrations, SDK, admin panel, Docker, and CI from a single declarative file.",
      parameters: [
        ToolParam { name: "path", type: "string", description: "Path to the .bone file", required: true, default: null },
        ToolParam { name: "target", type: "string", description: "Target: express (default), nakama, prisma, sqlite", required: false, default: "express" },
      ],
      execute: builtinBoneCompile,
    })

    self.register(ToolDef {
      id: "bone_check",
      category: "write",
      description: "Validate a .bone file without generating code. Reports type errors and constraint violations.",
      parameters: [
        ToolParam { name: "path", type: "string", description: "Path to the .bone file to validate", required: true, default: null },
      ],
      execute: builtinBoneCheck,
    })
  }
}

// Placeholder execute functions — actual implementations in builtin/*.ms
fn builtinReadFile(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinWriteFile(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinPatch(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinBash(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinSearch(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinFindFiles(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinSymbols(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinMemory(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinPlan(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinWebSearch(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinWebFetch(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinBoneCompile(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
fn builtinBoneCheck(args: Map<String, Any>, ctx: ToolContext): ToolResult { return ToolResult { output: "", metadata: null, error: null } }
