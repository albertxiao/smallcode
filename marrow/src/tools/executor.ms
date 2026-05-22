// SmallCode - Tool Executor
// Manages tool execution lifecycle: timeout, error handling, output capping
// Wires events and handles the approval flow for write operations

import { ToolRegistry, ToolDef, ToolResult, ToolContext } from "./registry"
import { ToolValidator, repairJson } from "./validator"
import { BudgetEngine } from "../context/budget"
import { EventBus } from "../core/event_bus"
import { DiffView, DiffHunk } from "../tui/diff_view"
import { readFile, pathExists } from "std/fs"
import { resolve } from "std/path"

pub struct ToolExecutor {
  registry: ToolRegistry
  budget: BudgetEngine
  validator: ToolValidator
  eventBus: EventBus
  autoApprove: Bool
  diffView: DiffView?
}

pub impl ToolExecutor {
  pub fn new(registry: ToolRegistry, budget: BudgetEngine, eventBus: EventBus, autoApprove: Bool): ToolExecutor {
    return ToolExecutor {
      registry: registry,
      budget: budget,
      validator: ToolValidator.new(),
      eventBus: eventBus,
      autoApprove: autoApprove,
      diffView: null,
    }
  }

  pub fn setDiffView(self, view: DiffView) {
    self.diffView = view
  }

  // Execute a tool call with full lifecycle management
  pub fn execute(self, toolName: String, rawArgs: String, ctx: ToolContext): ExecutionResult {
    // Parse arguments
    let args = repairJson(rawArgs)
    if !args {
      return ExecutionResult {
        output: "",
        error: "Failed to parse tool arguments. Got: ${rawArgs.slice(0, 200)}",
        approved: true,
        retryable: true,
      }
    }

    // Get tool definition
    let tool = self.registry.get(toolName)
    if !tool {
      let available = self.registry.active().map(|t| t.id).join(", ")
      return ExecutionResult {
        output: "",
        error: "Unknown tool '${toolName}'. Available: ${available}",
        approved: true,
        retryable: false,
      }
    }

    // Validate arguments
    let validationError = self.validator.validate(tool, args)
    if validationError {
      return ExecutionResult {
        output: "",
        error: validationError,
        approved: true,
        retryable: true,
      }
    }

    // Approval gate for write operations
    if !self.autoApprove && tool.category == "write" {
      let approved = self.requestApproval(tool, args, ctx)
      if !approved {
        return ExecutionResult {
          output: "(edit rejected by user)",
          error: null,
          approved: false,
          retryable: false,
        }
      }
    }

    // Fire pre-tool hook
    self.eventBus.emit("tool.start", { name: toolName, args: args })

    // Execute
    let result = tool.execute(args, ctx)

    // Truncate output to fit context budget
    if result.output.length > 0 {
      result.output = self.budget.fitToolResult(result.output)
    }

    // Fire post-tool hook
    if result.error {
      self.eventBus.emit("tool.error", { name: toolName, error: result.error })
    } else {
      self.eventBus.emit("tool.complete", {
        name: toolName,
        output_tokens: BudgetEngine.countTokens(result.output),
      })
    }

    return ExecutionResult {
      output: result.output,
      error: result.error,
      approved: true,
      retryable: result.error != null,
    }
  }

  // Request user approval for a write operation
  fn requestApproval(self, tool: ToolDef, args: Map<String, Any>, ctx: ToolContext): Bool {
    if !self.diffView { return true }  // No UI, auto-approve

    match tool.id {
      "patch" => {
        let path = args.get("path") as String
        let oldStr = args.get("old_str") as String
        let newStr = args.get("new_str") as String

        let hunk = DiffHunk {
          path: path,
          startLine: findLineNumber(resolve(ctx.cwd, path), oldStr),
          oldLines: oldStr.split("\n"),
          newLines: newStr.split("\n"),
        }
        return self.diffView.showAndApprove(hunk)
      }
      "write_file" => {
        let path = args.get("path") as String
        let content = args.get("content") as String
        let fullPath = resolve(ctx.cwd, path)

        if pathExists(fullPath) {
          let existing = readFile(fullPath)
          self.diffView.showDiff(path, existing, content)
        } else {
          // New file — show first 20 lines
          let preview = content.split("\n").slice(0, 20).join("\n")
          println("  New file: ${path}")
          println("  ${preview}")
          if content.split("\n").length > 20 {
            println("  ... (${content.split("\n").length - 20} more lines)")
          }
        }

        let hunk = DiffHunk {
          path: path,
          startLine: 1,
          oldLines: if pathExists(fullPath) { ["(existing file will be overwritten)"] } else { [] },
          newLines: ["(${content.split("\n").length} lines)"],
        }
        return self.diffView.showAndApprove(hunk)
      }
      _ => return true
    }
  }
}

pub struct ExecutionResult {
  output: String
  error: String?
  approved: Bool
  retryable: Bool
}

// Find the line number where a string appears in a file
fn findLineNumber(path: String, search: String): Int {
  if !pathExists(path) { return 1 }
  let content = readFile(path)
  let idx = content.indexOf(search)
  if idx == -1 { return 1 }
  return content.slice(0, idx).split("\n").length
}
