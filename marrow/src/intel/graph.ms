// SmallCode - Code Graph / Intelligence
// Tree-sitter based code indexer for symbol-level search
// Embedded directly (no MCP overhead) for speed with local models

import { readFile, glob } from "std/fs"
import { resolve, relative, extname } from "std/path"

pub struct SymbolInfo {
  name: String
  kind: String          // "function" | "class" | "struct" | "interface" | "enum" | "const" | "method"
  file: String
  line: Int
  signature: String?
  exported: Bool
}

pub struct CodeIndex {
  symbols: List<SymbolInfo>
  fileIndex: Map<String, List<SymbolInfo>>   // file path → symbols in that file
  nameIndex: Map<String, List<SymbolInfo>>   // symbol name → locations
  rootDir: String
  indexed: Bool
}

pub impl CodeIndex {
  pub fn new(rootDir: String): CodeIndex {
    return CodeIndex {
      symbols: [],
      fileIndex: {},
      nameIndex: {},
      rootDir: rootDir,
      indexed: false,
    }
  }

  // Index the entire project
  pub fn indexProject(self) {
    let files = glob("**/*.{ms,ts,js,py,rs,go,c,cpp,h,java,rb}", {
      cwd: self.rootDir,
      ignore: ["node_modules/**", ".git/**", "dist/**", "build/**", "target/**"],
    })

    for file in files {
      let fullPath = resolve(self.rootDir, file)
      self.indexFile(file, fullPath)
    }

    self.indexed = true
  }

  // Index a single file
  pub fn indexFile(self, relativePath: String, fullPath: String) {
    let content = readFile(fullPath)
    let ext = extname(relativePath)
    let symbols = extractSymbols(content, ext, relativePath)

    self.fileIndex.set(relativePath, symbols)
    for sym in symbols {
      self.symbols.push(sym)
      if !self.nameIndex.has(sym.name) {
        self.nameIndex.set(sym.name, [])
      }
      self.nameIndex.get(sym.name).push(sym)
    }
  }

  // Search symbols by name (fuzzy)
  pub fn searchSymbols(self, query: String, limit: Int = 10): List<SymbolInfo> {
    let queryLower = query.toLowerCase()
    let results = []

    // Exact match first
    if self.nameIndex.has(query) {
      results.append(self.nameIndex.get(query))
    }

    // Then prefix match
    if results.length < limit {
      for (name, syms) in self.nameIndex {
        if name.toLowerCase().startsWith(queryLower) && !results.any(|r| r.name == name) {
          results.append(syms.slice(0, limit - results.length))
        }
        if results.length >= limit { break }
      }
    }

    // Then substring match
    if results.length < limit {
      for (name, syms) in self.nameIndex {
        if name.toLowerCase().contains(queryLower) && !results.any(|r| r.name == name) {
          results.append(syms.slice(0, limit - results.length))
        }
        if results.length >= limit { break }
      }
    }

    return results.slice(0, limit)
  }

  // Get all symbols in a file
  pub fn symbolsInFile(self, path: String): List<SymbolInfo> {
    return self.fileIndex.get(path) ?? []
  }

  // Get stats
  pub fn stats(self): String {
    let fileCount = self.fileIndex.size()
    let symCount = self.symbols.length
    return "${symCount} symbols across ${fileCount} files"
  }
}

// Extract symbols from source code using regex patterns
// Not as accurate as tree-sitter but fast and works for most cases
fn extractSymbols(content: String, ext: String, filePath: String): List<SymbolInfo> {
  let lines = content.split("\n")
  let symbols = []

  let patterns = getPatternsForExt(ext)

  for (i, line) in lines.enumerate() {
    let trimmed = line.trim()

    for pattern in patterns {
      let match = trimmed.match(pattern.regex)
      if match {
        symbols.push(SymbolInfo {
          name: match[pattern.nameGroup],
          kind: pattern.kind,
          file: filePath,
          line: i + 1,
          signature: trimmed.slice(0, 120),  // Cap signature length
          exported: trimmed.startsWith("pub ") || trimmed.startsWith("export "),
        })
        break  // Only match first pattern per line
      }
    }
  }

  return symbols
}

struct SymbolPattern {
  regex: String
  nameGroup: Int
  kind: String
}

fn getPatternsForExt(ext: String): List<SymbolPattern> {
  match ext {
    ".ms" => return [
      SymbolPattern { regex: "^(?:pub\\s+)?fn\\s+(\\w+)", nameGroup: 1, kind: "function" },
      SymbolPattern { regex: "^(?:pub\\s+)?struct\\s+(\\w+)", nameGroup: 1, kind: "struct" },
      SymbolPattern { regex: "^(?:pub\\s+)?enum\\s+(\\w+)", nameGroup: 1, kind: "enum" },
      SymbolPattern { regex: "^(?:pub\\s+)?trait\\s+(\\w+)", nameGroup: 1, kind: "interface" },
      SymbolPattern { regex: "^(?:pub\\s+)?type\\s+(\\w+)", nameGroup: 1, kind: "type" },
      SymbolPattern { regex: "^(?:pub\\s+)?const\\s+(\\w+)", nameGroup: 1, kind: "const" },
    ]
    ".ts" | ".js" => return [
      SymbolPattern { regex: "^(?:export\\s+)?(?:async\\s+)?function\\s+(\\w+)", nameGroup: 1, kind: "function" },
      SymbolPattern { regex: "^(?:export\\s+)?class\\s+(\\w+)", nameGroup: 1, kind: "class" },
      SymbolPattern { regex: "^(?:export\\s+)?interface\\s+(\\w+)", nameGroup: 1, kind: "interface" },
      SymbolPattern { regex: "^(?:export\\s+)?enum\\s+(\\w+)", nameGroup: 1, kind: "enum" },
      SymbolPattern { regex: "^(?:export\\s+)?const\\s+(\\w+)\\s*=", nameGroup: 1, kind: "const" },
      SymbolPattern { regex: "^(?:export\\s+)?type\\s+(\\w+)", nameGroup: 1, kind: "type" },
    ]
    ".py" => return [
      SymbolPattern { regex: "^(?:async\\s+)?def\\s+(\\w+)", nameGroup: 1, kind: "function" },
      SymbolPattern { regex: "^class\\s+(\\w+)", nameGroup: 1, kind: "class" },
    ]
    ".rs" => return [
      SymbolPattern { regex: "^(?:pub\\s+)?(?:async\\s+)?fn\\s+(\\w+)", nameGroup: 1, kind: "function" },
      SymbolPattern { regex: "^(?:pub\\s+)?struct\\s+(\\w+)", nameGroup: 1, kind: "struct" },
      SymbolPattern { regex: "^(?:pub\\s+)?enum\\s+(\\w+)", nameGroup: 1, kind: "enum" },
      SymbolPattern { regex: "^(?:pub\\s+)?trait\\s+(\\w+)", nameGroup: 1, kind: "interface" },
      SymbolPattern { regex: "^(?:pub\\s+)?type\\s+(\\w+)", nameGroup: 1, kind: "type" },
    ]
    ".go" => return [
      SymbolPattern { regex: "^func\\s+(?:\\(\\w+\\s+\\*?\\w+\\)\\s+)?(\\w+)", nameGroup: 1, kind: "function" },
      SymbolPattern { regex: "^type\\s+(\\w+)\\s+struct", nameGroup: 1, kind: "struct" },
      SymbolPattern { regex: "^type\\s+(\\w+)\\s+interface", nameGroup: 1, kind: "interface" },
    ]
    _ => return [
      SymbolPattern { regex: "^(?:pub\\s+|export\\s+)?(?:fn|function|def|func)\\s+(\\w+)", nameGroup: 1, kind: "function" },
      SymbolPattern { regex: "^(?:pub\\s+|export\\s+)?(?:struct|class)\\s+(\\w+)", nameGroup: 1, kind: "class" },
    ]
  }
}
