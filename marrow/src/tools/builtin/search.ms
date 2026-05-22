// SmallCode - Search Tool (ripgrep wrapper)
// Returns compact results to minimize context usage

import { ToolResult, ToolContext } from "../registry"
import { exec } from "std/process"
import { resolve } from "std/path"

const MAX_RESULTS = 10
const CONTEXT_LINES = 2

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let pattern = args.get("pattern") as String
  let searchPath = args.get("path") as String? ?? "."
  let include = args.get("include") as String?

  let fullPath = resolve(ctx.cwd, searchPath)

  // Build ripgrep command
  let cmd = "rg --line-number --max-count ${MAX_RESULTS * 2} -C ${CONTEXT_LINES}"
  
  if include {
    cmd += " --glob '${include}'"
  }
  
  // Add common exclusions
  cmd += " --glob '!node_modules' --glob '!.git' --glob '!dist' --glob '!build'"
  cmd += " '${escapeShell(pattern)}' '${fullPath}'"

  let result = exec(cmd, { cwd: ctx.cwd, timeout: 10000, shell: true })

  if result.exitCode == 1 {
    // No matches
    return ToolResult {
      output: "No matches found for '${pattern}' in ${searchPath}",
      metadata: { matches: 0 },
      error: null,
    }
  }

  if result.exitCode != 0 && result.exitCode != 1 {
    return ToolResult {
      output: "",
      metadata: null,
      error: "Search failed: ${result.stderr}",
    }
  }

  // Parse and format results compactly
  let output = result.stdout
  let lines = output.split("\n").filter(|l| !l.isEmpty())
  
  // Cap at MAX_RESULTS matches
  let matchCount = lines.filter(|l| l.contains(":") && !l.startsWith("--")).length
  
  if matchCount > MAX_RESULTS {
    // Truncate
    let truncated = takeFirstNMatches(lines, MAX_RESULTS)
    output = truncated.join("\n")
    output += "\n\n[${matchCount - MAX_RESULTS} more matches not shown]"
  } else {
    output = lines.join("\n")
  }

  return ToolResult {
    output: output,
    metadata: { matches: matchCount, pattern: pattern },
    error: null,
  }
}

fn takeFirstNMatches(lines: List<String>, n: Int): List<String> {
  let result = []
  let count = 0
  for line in lines {
    if line.startsWith("--") {
      // Separator between match groups
      if count >= n { break }
      result.push(line)
    } else if line.contains(":") {
      count += 1
      if count > n { break }
      result.push(line)
    } else {
      result.push(line)
    }
  }
  return result
}

fn escapeShell(s: String): String {
  return s.replace("'", "'\\''")
}
