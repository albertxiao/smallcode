// SmallCode - Symbols Tool
// Code graph-based symbol search
// Uses tree-sitter indexing for fast, accurate symbol lookup

import { ToolResult, ToolContext } from "../registry"
import { CodeIndex } from "../../intel/graph"

// Shared code index
let index: CodeIndex? = null

pub fn setIndex(idx: CodeIndex) {
  index = idx
}

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let query = args.get("query") as String

  if !index {
    // Fallback to grep-based symbol search if no index available
    return grepFallback(query, ctx)
  }

  let results = index.searchSymbols(query, limit: 10)

  if results.isEmpty() {
    return ToolResult {
      output: "No symbols found matching '${query}'",
      metadata: { matches: 0 },
      error: null,
    }
  }

  let output = results.map(|r| {
    let location = "${r.file}:${r.line}"
    return "${r.kind} ${r.name} — ${location}"
  }).join("\n")

  return ToolResult {
    output: "Found ${results.length} symbols:\n${output}",
    metadata: { matches: results.length },
    error: null,
  }
}

// Fallback: use ripgrep to find function/class definitions
fn grepFallback(query: String, ctx: ToolContext): ToolResult {
  import { exec } from "std/process"

  // Search for common definition patterns
  let patterns = [
    "fn ${query}",
    "pub fn ${query}",
    "function ${query}",
    "class ${query}",
    "struct ${query}",
    "interface ${query}",
    "const ${query}",
    "def ${query}",
  ]

  let rgPattern = patterns.join("|")
  let cmd = "rg --line-number --max-count 10 '${rgPattern}' --glob '!node_modules' --glob '!.git'"

  let result = exec(cmd, { cwd: ctx.cwd, timeout: 10000, shell: true })

  if result.exitCode != 0 || result.stdout.trim().isEmpty() {
    return ToolResult {
      output: "No symbol definitions found for '${query}'",
      metadata: { matches: 0 },
      error: null,
    }
  }

  return ToolResult {
    output: result.stdout.trim(),
    metadata: { matches: result.stdout.split("\n").length },
    error: null,
  }
}
