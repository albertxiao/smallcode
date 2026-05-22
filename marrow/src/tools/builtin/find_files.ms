// SmallCode - Find Files Tool
// Glob-based file discovery, respecting .gitignore

import { ToolResult, ToolContext } from "../registry"
import { glob } from "std/fs"
import { resolve, relative } from "std/path"

const MAX_RESULTS = 50

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let pattern = args.get("pattern") as String

  let matches = glob(pattern, {
    cwd: ctx.cwd,
    ignore: ["node_modules/**", ".git/**", "dist/**", "build/**", "__pycache__/**"],
    dot: false,
  })

  if matches.isEmpty() {
    return ToolResult {
      output: "No files found matching '${pattern}'",
      metadata: { matches: 0 },
      error: null,
    }
  }

  let total = matches.length
  let displayed = matches.slice(0, MAX_RESULTS)
  let output = displayed.map(|m| relative(ctx.cwd, m)).join("\n")

  if total > MAX_RESULTS {
    output += "\n\n[... ${total - MAX_RESULTS} more files not shown]"
  }

  return ToolResult {
    output: "Found ${total} files:\n${output}",
    metadata: { matches: total },
    error: null,
  }
}
