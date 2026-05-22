// SmallCode - File Summarizer
// Generates compact file summaries for context injection
// Critical for staying within budget on large codebases

import { readFile } from "std/fs"
import { extname } from "std/path"
import { BudgetEngine } from "../context/budget"
import { CodeIndex, SymbolInfo } from "./graph"

pub struct FileSummary {
  path: String
  lineCount: Int
  language: String
  imports: List<String>
  exports: List<String>
  symbols: List<SymbolSummary>
  tokenCost: Int
}

pub struct SymbolSummary {
  name: String
  kind: String
  line: Int
  signature: String
}

pub struct Summarizer {
  index: CodeIndex?
  maxTokens: Int
}

pub impl Summarizer {
  pub fn new(index: CodeIndex?, maxTokens: Int = 500): Summarizer {
    return Summarizer { index: index, maxTokens: maxTokens }
  }

  // Generate a compact summary of a file
  pub fn summarize(self, path: String): FileSummary {
    let content = readFile(path)
    let lines = content.split("\n")
    let ext = extname(path)
    let language = langFromExt(ext)

    let imports = extractImports(lines, ext)
    let exports = extractExports(lines, ext)

    // Use code index if available, otherwise extract via regex
    let symbols = if self.index {
      self.index.symbolsInFile(path).map(|s| SymbolSummary {
        name: s.name,
        kind: s.kind,
        line: s.line,
        signature: s.signature ?? s.name,
      })
    } else {
      extractSymbolSummaries(lines, ext)
    }

    let summary = FileSummary {
      path: path,
      lineCount: lines.length,
      language: language,
      imports: imports,
      exports: exports,
      symbols: symbols,
      tokenCost: 0,
    }

    summary.tokenCost = BudgetEngine.countTokens(self.format(summary))
    return summary
  }

  // Format a summary for injection into model context
  pub fn format(self, summary: FileSummary): String {
    let parts = []
    parts.push("${summary.path} (${summary.lineCount} lines, ${summary.language})")

    if summary.imports.length > 0 {
      let importStr = summary.imports.slice(0, 10).join(", ")
      if summary.imports.length > 10 {
        importStr += " (+${summary.imports.length - 10} more)"
      }
      parts.push("  imports: ${importStr}")
    }

    if summary.exports.length > 0 {
      parts.push("  exports: ${summary.exports.join(", ")}")
    }

    for sym in summary.symbols.slice(0, 20) {
      parts.push("  ${sym.kind} ${sym.signature} (line ${sym.line})")
    }
    if summary.symbols.length > 20 {
      parts.push("  ... (+${summary.symbols.length - 20} more symbols)")
    }

    return parts.join("\n")
  }

  // Summarize multiple files into a project overview
  pub fn projectOverview(self, files: List<String>, maxTokens: Int): String {
    let parts = []
    let tokenBudget = maxTokens
    
    for file in files {
      let summary = self.summarize(file)
      let formatted = self.format(summary)
      let cost = BudgetEngine.countTokens(formatted)
      
      if tokenBudget - cost < 0 { break }
      
      parts.push(formatted)
      tokenBudget -= cost
    }

    return parts.join("\n\n")
  }
}

fn extractImports(lines: List<String>, ext: String): List<String> {
  let imports = []
  for line in lines {
    let trimmed = line.trim()
    match ext {
      ".ms" | ".ts" | ".js" => {
        if trimmed.startsWith("import ") {
          // Extract module name
          let match = trimmed.match("from\\s+[\"']([^\"']+)[\"']")
          if match { imports.push(match[1]) }
          else {
            let match2 = trimmed.match("import\\s+[\"']([^\"']+)[\"']")
            if match2 { imports.push(match2[1]) }
          }
        }
      }
      ".py" => {
        if trimmed.startsWith("import ") || trimmed.startsWith("from ") {
          let match = trimmed.match("(?:from\\s+|import\\s+)(\\S+)")
          if match { imports.push(match[1]) }
        }
      }
      ".rs" => {
        if trimmed.startsWith("use ") {
          let match = trimmed.match("use\\s+(\\S+)")
          if match { imports.push(match[1].replace(";", "")) }
        }
      }
      ".go" => {
        if trimmed.startsWith("import ") || (trimmed.startsWith("\"") && trimmed.endsWith("\"")) {
          let match = trimmed.match("\"([^\"]+)\"")
          if match { imports.push(match[1]) }
        }
      }
      _ => {}
    }
  }
  return imports
}

fn extractExports(lines: List<String>, ext: String): List<String> {
  let exports = []
  for line in lines {
    let trimmed = line.trim()
    match ext {
      ".ms" => {
        if trimmed.startsWith("pub fn ") {
          let match = trimmed.match("pub fn\\s+(\\w+)")
          if match { exports.push(match[1]) }
        } else if trimmed.startsWith("pub struct ") || trimmed.startsWith("pub enum ") {
          let match = trimmed.match("pub\\s+\\w+\\s+(\\w+)")
          if match { exports.push(match[1]) }
        }
      }
      ".ts" | ".js" => {
        if trimmed.startsWith("export ") {
          let match = trimmed.match("export\\s+(?:default\\s+)?(?:function|class|const|let|var|interface|type|enum)\\s+(\\w+)")
          if match { exports.push(match[1]) }
        }
      }
      _ => {}
    }
  }
  return exports
}

fn extractSymbolSummaries(lines: List<String>, ext: String): List<SymbolSummary> {
  let symbols = []
  for (i, line) in lines.enumerate() {
    let trimmed = line.trim()

    // Function definitions
    let fnMatch = trimmed.match("^(?:pub\\s+|export\\s+|async\\s+)*(?:fn|function|def|func)\\s+(\\w+)")
    if fnMatch {
      symbols.push(SymbolSummary {
        name: fnMatch[1],
        kind: "fn",
        line: i + 1,
        signature: trimmed.slice(0, 80),
      })
      continue
    }

    // Class/struct definitions
    let classMatch = trimmed.match("^(?:pub\\s+|export\\s+)?(?:class|struct|interface|enum)\\s+(\\w+)")
    if classMatch {
      symbols.push(SymbolSummary {
        name: classMatch[1],
        kind: "type",
        line: i + 1,
        signature: trimmed.slice(0, 80),
      })
    }
  }
  return symbols
}

fn langFromExt(ext: String): String {
  match ext {
    ".ms" => "marrowscript"
    ".ts" => "typescript"
    ".js" => "javascript"
    ".py" => "python"
    ".rs" => "rust"
    ".go" => "go"
    ".c" | ".h" => "c"
    ".cpp" | ".cc" => "c++"
    ".java" => "java"
    ".rb" => "ruby"
    _ => "unknown"
  }
}
