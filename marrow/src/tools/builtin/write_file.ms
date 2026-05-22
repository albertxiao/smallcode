// SmallCode - Write File Tool
// Creates or overwrites a file with given content

import { ToolResult, ToolContext } from "../registry"
import { writeFile, pathExists, mkdirp } from "std/fs"
import { resolve, relative, dirname } from "std/path"

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let path = args.get("path") as String
  let content = args.get("content") as String

  let fullPath = resolve(ctx.cwd, path)
  let displayPath = relative(ctx.cwd, fullPath)

  // Ensure parent directory exists
  let dir = dirname(fullPath)
  mkdirp(dir)

  let existed = pathExists(fullPath)
  let action = if existed { "Updated" } else { "Created" }

  // Write the file
  writeFile(fullPath, content)

  let lines = content.split("\n").length
  let summary = "${action} ${displayPath} (${lines} lines)"

  return ToolResult {
    output: summary,
    metadata: { path: displayPath, lines: lines, created: !existed },
    error: null,
  }
}
