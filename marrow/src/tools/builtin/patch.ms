// SmallCode - Patch Tool (Search & Replace)
// Primary edit primitive — safer than full file rewrites for small models
// Mirrors the concept from OpenCode's edit.ts but simplified

import { ToolResult, ToolContext } from "../registry"
import { readFile, writeFile, pathExists } from "std/fs"
import { resolve, relative } from "std/path"

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let path = args.get("path") as String
  let oldStr = args.get("old_str") as String
  let newStr = args.get("new_str") as String

  let fullPath = resolve(ctx.cwd, path)
  let displayPath = relative(ctx.cwd, fullPath)

  // Verify file exists
  if !pathExists(fullPath) {
    return ToolResult {
      output: "",
      metadata: null,
      error: "File not found: ${displayPath}",
    }
  }

  let content = readFile(fullPath)

  // Find the old string
  let occurrences = countOccurrences(content, oldStr)

  if occurrences == 0 {
    // Try fuzzy matching (whitespace normalization)
    let normalizedContent = normalizeWhitespace(content)
    let normalizedOld = normalizeWhitespace(oldStr)
    
    if countOccurrences(normalizedContent, normalizedOld) > 0 {
      return ToolResult {
        output: "",
        metadata: null,
        error: "old_str not found exactly, but a whitespace-normalized match exists. Please check indentation and line endings in your old_str.",
      }
    }

    // Show nearby content for context
    let hint = findSimilarSection(content, oldStr)
    let errorMsg = "old_str not found in ${displayPath}."
    if hint {
      errorMsg += " Did you mean:\n${hint}"
    }
    return ToolResult { output: "", metadata: null, error: errorMsg }
  }

  if occurrences > 1 {
    return ToolResult {
      output: "",
      metadata: null,
      error: "old_str matches ${occurrences} locations in ${displayPath}. Please include more context to make it unique.",
    }
  }

  // Perform the replacement
  let newContent = content.replace(oldStr, newStr)
  writeFile(fullPath, newContent)

  // Generate a compact diff summary
  let oldLines = oldStr.split("\n").length
  let newLines = newStr.split("\n").length
  let lineNum = content.slice(0, content.indexOf(oldStr)).split("\n").length

  let summary = "Edited ${displayPath}: replaced ${oldLines} lines with ${newLines} lines at line ${lineNum}"

  return ToolResult {
    output: summary,
    metadata: { path: displayPath, line: lineNum, old_lines: oldLines, new_lines: newLines },
    error: null,
  }
}

fn countOccurrences(text: String, search: String): Int {
  if search.isEmpty() { return 0 }
  let count = 0
  let pos = 0
  while true {
    let idx = text.indexOf(search, from: pos)
    if idx == -1 { break }
    count += 1
    pos = idx + 1
  }
  return count
}

fn normalizeWhitespace(text: String): String {
  return text
    .replace("\r\n", "\n")
    .split("\n")
    .map(|line| line.trimEnd())
    .join("\n")
}

// Find the most similar section in the file to help the model correct its old_str
fn findSimilarSection(content: String, target: String): String? {
  let targetLines = target.split("\n")
  if targetLines.isEmpty() { return null }

  let firstLine = targetLines[0].trim()
  if firstLine.isEmpty() { return null }

  let contentLines = content.split("\n")
  
  // Search for the first line of target
  for (i, line) in contentLines.enumerate() {
    if line.trim().contains(firstLine) || firstLine.contains(line.trim()) {
      // Found a potential match — show surrounding context
      let start = max(0, i - 1)
      let end = min(contentLines.length, i + targetLines.length + 1)
      let snippet = contentLines.slice(start, end)
        .enumerate()
        .map(|(j, l)| "${start + j + 1}│ ${l}")
        .join("\n")
      return snippet
    }
  }

  return null
}

fn max(a: Int, b: Int): Int { if a > b { return a } else { return b } }
fn min(a: Int, b: Int): Int { if a < b { return a } else { return b } }
