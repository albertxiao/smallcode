// SmallCode - Memory Tool
// Read/write persistent working memory scratchpad
// Allows the model to maintain state across conversation turns

import { ToolResult, ToolContext } from "../registry"
import { WorkingMemory } from "../../context/working_memory"

// The working memory instance (shared across tool invocations)
let memory: WorkingMemory? = null

pub fn setMemoryInstance(mem: WorkingMemory) {
  memory = mem
}

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  if !memory {
    return ToolResult { output: "", metadata: null, error: "Working memory not initialized" }
  }

  let action = args.get("action") as String
  let content = args.get("content") as String?

  match action {
    "read" => {
      let current = memory.get()
      if current.isEmpty() {
        return ToolResult {
          output: "(working memory is empty)",
          metadata: { tokens: 0 },
          error: null,
        }
      }
      return ToolResult {
        output: current,
        metadata: { tokens: memory.tokenCount() },
        error: null,
      }
    }
    "write" => {
      if !content {
        return ToolResult { output: "", metadata: null, error: "Content required for 'write' action" }
      }
      memory.set(content)
      memory.save()
      return ToolResult {
        output: "Working memory updated (${memory.tokenCount()} tokens)",
        metadata: { tokens: memory.tokenCount() },
        error: null,
      }
    }
    "append" => {
      if !content {
        return ToolResult { output: "", metadata: null, error: "Content required for 'append' action" }
      }
      memory.append(content)
      memory.save()
      return ToolResult {
        output: "Appended to working memory (${memory.tokenCount()} tokens)",
        metadata: { tokens: memory.tokenCount() },
        error: null,
      }
    }
    "clear" => {
      memory.clear()
      memory.save()
      return ToolResult {
        output: "Working memory cleared",
        metadata: { tokens: 0 },
        error: null,
      }
    }
    _ => {
      return ToolResult {
        output: "",
        metadata: null,
        error: "Unknown action '${action}'. Use: read, write, append, clear",
      }
    }
  }
}
