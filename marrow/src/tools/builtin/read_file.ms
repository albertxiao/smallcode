// SmallCode - Read File Tool
// Budget-aware file reading with automatic summarization

import { ToolResult, ToolContext } from "../registry"
import { FileCache } from "../../context/file_cache"
import { readFile as fsRead, pathExists } from "std/fs"
import { resolve, relative } from "std/path"

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let path = args.get("path") as String
  let startLine = args.get("start_line") as Int?
  let endLine = args.get("end_line") as Int?

  // Resolve relative to cwd
  let fullPath = resolve(ctx.cwd, path)
  let displayPath = relative(ctx.cwd, fullPath)

  // Check existence
  if !pathExists(fullPath) {
    return ToolResult {
      output: "",
      metadata: null,
      error: "File not found: ${displayPath}",
    }
  }

  // Read content
  let content = fsRead(fullPath)
  let lines = content.split("\n")
  let totalLines = lines.length

  // Line range specified — return exact range
  if startLine || endLine {
    let start = max(1, startLine ?? 1) - 1
    let end = min(totalLines, endLine ?? totalLines)
    let slice = lines.slice(start, end)
    let numbered = slice.enumerate().map(|(i, line)| {
      let lineNum = start + i + 1
      return "${padLeft(toString(lineNum), 4)}│ ${line}"
    }).join("\n")

    return ToolResult {
      output: "${displayPath} (lines ${start+1}-${end} of ${totalLines}):\n${numbered}",
      metadata: { path: displayPath, lines: totalLines, range: [start+1, end] },
      error: null,
    }
  }

  // No range — use budget-aware approach
  let maxLines = ctx.budget.maxAffordableLines()

  if totalLines <= ctx.budget.config.summary_threshold {
    // Small file: show everything with line numbers
    let numbered = lines.enumerate().map(|(i, line)| {
      return "${padLeft(toString(i + 1), 4)}│ ${line}"
    }).join("\n")

    return ToolResult {
      output: "${displayPath} (${totalLines} lines):\n${numbered}",
      metadata: { path: displayPath, lines: totalLines },
      error: null,
    }
  }

  // Large file: show signature summary
  let summary = summarize(fullPath, content)
  return ToolResult {
    output: "${displayPath} (${totalLines} lines, showing signatures — use start_line/end_line for details):\n${summary}",
    metadata: { path: displayPath, lines: totalLines, summarized: true },
    error: null,
  }
}

fn summarize(path: String, content: String): String {
  let lines = content.split("\n")
  let result = []
  
  for (i, line) in lines.enumerate() {
    let trimmed = line.trim()
    
    // Include structural elements
    if trimmed.startsWith("import ") || trimmed.startsWith("from ") ||
       trimmed.startsWith("pub fn ") || trimmed.startsWith("fn ") ||
       trimmed.startsWith("pub struct ") || trimmed.startsWith("struct ") ||
       trimmed.startsWith("pub class ") || trimmed.startsWith("class ") ||
       trimmed.startsWith("pub trait ") || trimmed.startsWith("trait ") ||
       trimmed.startsWith("pub enum ") || trimmed.startsWith("enum ") ||
       trimmed.startsWith("pub type ") || trimmed.startsWith("type ") ||
       trimmed.startsWith("export ") || trimmed.startsWith("function ") ||
       trimmed.startsWith("const ") || trimmed.startsWith("pub const ") ||
       trimmed.startsWith("interface ") || trimmed.startsWith("module ") {
      result.push("${padLeft(toString(i + 1), 4)}│ ${line}")
    }
  }
  
  if result.isEmpty() {
    // Fallback: first 20 + last 5 lines
    result.push("   │ (no recognized structure, showing head/tail)")
    for i in range(0, min(20, lines.length)) {
      result.push("${padLeft(toString(i + 1), 4)}│ ${lines[i]}")
    }
    result.push("   │ ...")
    for i in range(max(0, lines.length - 5), lines.length) {
      result.push("${padLeft(toString(i + 1), 4)}│ ${lines[i]}")
    }
  }
  
  return result.join("\n")
}

fn padLeft(s: String, width: Int): String {
  while s.length < width { s = " ${s}" }
  return s
}

fn max(a: Int, b: Int): Int { if a > b { return a } else { return b } }
fn min(a: Int, b: Int): Int { if a < b { return a } else { return b } }
