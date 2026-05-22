// SmallCode - @file References
// Allows users to reference files in their input with @filename syntax
// Referenced files get auto-loaded into context before the model sees the message

import { readFile, pathExists, glob } from "std/fs"
import { resolve, relative } from "std/path"
import { cwd } from "std/env"
import { BudgetEngine } from "../context/budget"

pub struct Reference {
  original: String      // The @token from user input
  path: String          // Resolved file path
  content: String       // File content (or summary if too large)
  tokens: Int
}

pub struct ParsedInput {
  message: String            // User message with @refs stripped
  references: List<Reference>
  contextBlock: String       // Formatted context to inject before the message
}

pub fn parseReferences(input: String, budget: BudgetEngine): ParsedInput {
  let refs = []
  let cleanedMessage = input

  // Find all @path references
  let pattern = "@([\\w./\\-]+\\.\\w+)"
  let matches = input.matchAll(pattern)

  for match in matches {
    let refPath = match[1]
    let fullPath = resolve(cwd(), refPath)

    if pathExists(fullPath) {
      let content = readFile(fullPath)
      let tokens = BudgetEngine.countTokens(content)

      // Summarize if too large for budget
      if tokens > 500 {
        let lines = content.split("\n")
        if lines.length > 50 {
          // Show first 30 + last 10 lines
          content = lines.slice(0, 30).join("\n") + "\n... (${lines.length - 40} lines omitted)\n" + lines.slice(lines.length - 10).join("\n")
          tokens = BudgetEngine.countTokens(content)
        }
      }

      refs.push(Reference {
        original: "@${refPath}",
        path: refPath,
        content: content,
        tokens: tokens,
      })

      // Remove the @ref from the message (leave just the filename)
      cleanedMessage = cleanedMessage.replace("@${refPath}", refPath)
    }
  }

  // Also handle @dir/ references (list files in directory)
  let dirPattern = "@([\\w./\\-]+)/"
  let dirMatches = input.matchAll(dirPattern)
  for match in dirMatches {
    let dirPath = match[1]
    let fullDir = resolve(cwd(), dirPath)
    if pathExists(fullDir) {
      let files = glob("*", { cwd: fullDir })
      let listing = files.slice(0, 30).join("\n")
      refs.push(Reference {
        original: "@${dirPath}/",
        path: dirPath,
        content: "Directory listing:\n${listing}",
        tokens: BudgetEngine.countTokens(listing),
      })
      cleanedMessage = cleanedMessage.replace("@${dirPath}/", dirPath)
    }
  }

  // Build context block
  let contextBlock = ""
  if refs.length > 0 {
    let parts = refs.map(|r| "<file path=\"${r.path}\">\n${r.content}\n</file>")
    contextBlock = parts.join("\n\n")
  }

  return ParsedInput {
    message: cleanedMessage.trim(),
    references: refs,
    contextBlock: contextBlock,
  }
}

// Autocomplete: suggest files matching a partial @path
pub fn suggestFiles(partial: String): List<String> {
  if partial.isEmpty() { return [] }

  let pattern = "${partial}*"
  let matches = glob(pattern, {
    cwd: cwd(),
    ignore: ["node_modules/**", ".git/**", "dist/**"],
  })

  return matches.slice(0, 10)
}
