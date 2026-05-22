// SmallCode - File Cache
// Caches file contents with automatic summarization for large files
// Key to keeping context small: show signatures, not full files

import { BudgetEngine } from "./budget"
import { readFile } from "std/fs"

pub struct CachedFile {
  path: String
  content: String?      // Full content (null if too large to keep)
  summary: String       // Signature-level summary (always available)
  lineCount: Int
  lastModified: Int
  tokens: Int           // Token cost of the summary
}

pub struct FileCache {
  entries: Map<String, CachedFile>
  budget: BudgetEngine
  summaryThreshold: Int
}

pub impl FileCache {
  pub fn new(budget: BudgetEngine, summaryThreshold: Int): FileCache {
    return FileCache {
      entries: {},
      budget: budget,
      summaryThreshold: summaryThreshold,
    }
  }

  // Get file content, respecting budget constraints
  // Returns summary for large files, full content for small ones
  pub fn get(self, path: String): String {
    if self.entries.has(path) {
      let cached = self.entries.get(path)
      // If we have full content and it fits, return it
      if cached.content && self.budget.canFit(cached.content) {
        return cached.content
      }
      // Otherwise return summary
      return cached.summary
    }

    // Not cached - load and cache
    return self.load(path)
  }

  // Get file content within a specific line range
  pub fn getRange(self, path: String, startLine: Int, endLine: Int): String {
    let content = readFile(path)
    let lines = content.split("\n")
    let start = max(0, startLine - 1)
    let end = min(lines.length, endLine)
    let slice = lines.slice(start, end)
    return slice.enumerate().map(|(i, line)| "${start + i + 1}│ ${line}").join("\n")
  }

  // Force full content (for when model explicitly requests it)
  pub fn getFull(self, path: String): String {
    let content = readFile(path)
    let lines = content.split("\n")
    // Still truncate to what budget allows
    let maxLines = self.budget.maxAffordableLines()
    if lines.length > maxLines {
      let truncated = lines.slice(0, maxLines).join("\n")
      return "${truncated}\n\n[... truncated at line ${maxLines}/${lines.length}, use line range to see more]"
    }
    return content
  }

  // Load and cache a file
  fn load(self, path: String): String {
    let content = readFile(path)
    let lines = content.split("\n")
    let lineCount = lines.length

    let entry = CachedFile {
      path: path,
      content: null,
      summary: "",
      lineCount: lineCount,
      lastModified: 0, // TODO: get mtime
      tokens: 0,
    }

    if lineCount <= self.summaryThreshold {
      // Small file: keep full content
      entry.content = content
      entry.summary = content
      entry.tokens = BudgetEngine.countTokens(content)
    } else {
      // Large file: generate signature summary
      entry.summary = summarizeFile(path, content)
      entry.tokens = BudgetEngine.countTokens(entry.summary)
    }

    self.entries.set(path, entry)
    return entry.summary
  }

  // Invalidate cache for a file (after edit)
  pub fn invalidate(self, path: String) {
    self.entries.remove(path)
  }

  // Clear entire cache
  pub fn clear(self) {
    self.entries = {}
  }

  // Get cache stats
  pub fn stats(self): String {
    let count = self.entries.size()
    let totalTokens = self.entries.values().map(|e| e.tokens).sum()
    return "${count} files cached (${totalTokens} tokens)"
  }
}

// Generate a signature-level summary of a file
// Extracts: imports, class/struct definitions, function signatures, exported constants
fn summarizeFile(path: String, content: String): String {
  let lines = content.split("\n")
  let summary = []
  let lineCount = lines.length

  summary.push("// ${path} (${lineCount} lines)")
  summary.push("")

  let inBlock = false
  let braceDepth = 0

  for (i, line) in lines.enumerate() {
    let trimmed = line.trim()

    // Always include imports
    if trimmed.startsWith("import ") || trimmed.startsWith("from ") {
      summary.push(line)
      continue
    }

    // Include exports
    if trimmed.startsWith("export ") || trimmed.startsWith("pub ") {
      summary.push(line)
      continue
    }

    // Include struct/class/interface declarations
    if trimmed.startsWith("struct ") || trimmed.startsWith("class ") ||
       trimmed.startsWith("interface ") || trimmed.startsWith("enum ") ||
       trimmed.startsWith("pub struct ") || trimmed.startsWith("pub class ") {
      summary.push(line)
      continue
    }

    // Include function signatures (first line only)
    if trimmed.startsWith("fn ") || trimmed.startsWith("pub fn ") ||
       trimmed.startsWith("function ") || trimmed.startsWith("async fn ") ||
       trimmed.startsWith("const ") && trimmed.contains("=>") {
      // Just the signature, not the body
      let sig = line
      if !trimmed.contains("{") && !trimmed.contains("=>") {
        // Multi-line signature - include params
        summary.push(sig)
      } else if trimmed.endsWith("{") {
        summary.push(sig.replace(" {", ""))
      } else {
        summary.push(sig)
      }
      continue
    }

    // Include type definitions
    if trimmed.startsWith("type ") || trimmed.startsWith("pub type ") {
      summary.push(line)
      continue
    }

    // Include constants
    if trimmed.startsWith("const ") && !trimmed.contains("=>") {
      summary.push(line)
      continue
    }
  }

  if summary.length <= 2 {
    // Fallback: show first 20 lines + last 5 lines
    summary = ["// ${path} (${lineCount} lines)", ""]
    summary.append(lines.slice(0, 20))
    summary.push("// ... (${lineCount - 25} lines omitted)")
    summary.append(lines.slice(lineCount - 5))
  }

  return summary.join("\n")
}

fn max(a: Int, b: Int): Int { if a > b { return a } else { return b } }
fn min(a: Int, b: Int): Int { if a < b { return a } else { return b } }
