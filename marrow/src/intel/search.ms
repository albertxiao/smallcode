// SmallCode - Intelligent Code Search
// Combines symbol index, ripgrep, and file discovery into a unified search
// Ranks results by relevance to minimize wasted context

import { CodeIndex, SymbolInfo } from "./graph"
import { exec } from "std/process"
import { cwd } from "std/env"
import { BudgetEngine } from "../context/budget"

pub struct SearchResult {
  path: String
  line: Int
  content: String
  kind: String          // "symbol" | "grep" | "file"
  relevance: Float      // 0.0 - 1.0
}

pub struct CodeSearch {
  index: CodeIndex?
  rootDir: String
}

pub impl CodeSearch {
  pub fn new(index: CodeIndex?): CodeSearch {
    return CodeSearch {
      index: index,
      rootDir: cwd(),
    }
  }

  // Unified search: tries symbol lookup first, falls back to grep
  pub fn search(self, query: String, maxResults: Int = 10): List<SearchResult> {
    let results: List<SearchResult> = []

    // Layer 1: Symbol search (highest relevance)
    if self.index {
      let symbols = self.index.searchSymbols(query, limit: 5)
      for sym in symbols {
        results.push(SearchResult {
          path: sym.file,
          line: sym.line,
          content: sym.signature ?? "${sym.kind} ${sym.name}",
          kind: "symbol",
          relevance: 1.0,
        })
      }
    }

    // Layer 2: Grep search (medium relevance)
    if results.length < maxResults {
      let grepResults = grepSearch(query, maxResults - results.length)
      for gr in grepResults {
        // Deduplicate: skip if we already have this file:line from symbols
        if !results.any(|r| r.path == gr.path && r.line == gr.line) {
          results.push(gr)
        }
      }
    }

    // Sort by relevance
    results.sort(|a, b| b.relevance - a.relevance)
    return results.slice(0, maxResults)
  }

  // Search for files by name pattern
  pub fn findFiles(self, pattern: String, maxResults: Int = 20): List<String> {
    let cmd = "find . -name '${pattern}' -not -path '*/node_modules/*' -not -path '*/.git/*' | head -${maxResults}"
    let result = exec(cmd, { cwd: self.rootDir, timeout: 5000, shell: true })
    
    if result.exitCode != 0 { return [] }
    return result.stdout.split("\n").filter(|l| !l.trim().isEmpty())
  }

  // Find references to a symbol
  pub fn findReferences(self, symbolName: String): List<SearchResult> {
    let cmd = "rg --line-number --word-regexp '${symbolName}' --glob '!node_modules' --glob '!.git' --glob '!dist' | head -20"
    let result = exec(cmd, { cwd: self.rootDir, timeout: 10000, shell: true })
    
    if result.exitCode != 0 { return [] }
    return parseGrepOutput(result.stdout, 0.7)
  }
}

fn grepSearch(query: String, maxResults: Int): List<SearchResult> {
  // Use ripgrep with smart case
  let cmd = "rg --line-number --smart-case --max-count ${maxResults * 2} -C 0 '${escapeRg(query)}' --glob '!node_modules' --glob '!.git' --glob '!dist' --glob '!build' | head -${maxResults * 3}"
  
  let result = exec(cmd, { cwd: cwd(), timeout: 10000, shell: true })
  if result.exitCode != 0 { return [] }

  return parseGrepOutput(result.stdout, 0.6)
}

fn parseGrepOutput(output: String, baseRelevance: Float): List<SearchResult> {
  let results = []
  let lines = output.split("\n").filter(|l| !l.trim().isEmpty())
  
  for line in lines {
    // Format: path:line:content
    let match = line.match("^([^:]+):(\\d+):(.*)$")
    if match {
      results.push(SearchResult {
        path: match[1],
        line: parseInt(match[2]) ?? 1,
        content: match[3].trim().slice(0, 120),
        kind: "grep",
        relevance: baseRelevance,
      })
    }
  }

  return results
}

fn escapeRg(s: String): String {
  // Escape regex special characters for ripgrep
  return s.replace("\\", "\\\\")
    .replace("(", "\\(")
    .replace(")", "\\)")
    .replace("[", "\\[")
    .replace("]", "\\]")
    .replace("{", "\\{")
    .replace("}", "\\}")
    .replace(".", "\\.")
    .replace("+", "\\+")
    .replace("*", "\\*")
    .replace("?", "\\?")
    .replace("^", "\\^")
    .replace("$", "\\$")
    .replace("|", "\\|")
}
