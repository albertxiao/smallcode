// SmallCode - Web Fetch Tool
// Fetches and extracts readable content from URLs
// Strips HTML to plain text to save context tokens

import { ToolResult, ToolContext } from "../registry"
import { exec } from "std/process"
import { BudgetEngine } from "../../context/budget"

const MAX_CONTENT_CHARS = 4000  // ~1000 tokens

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let url = args.get("url") as String

  // Validate URL
  if !url.startsWith("http://") && !url.startsWith("https://") {
    return ToolResult { output: "", metadata: null, error: "URL must start with http:// or https://" }
  }

  // Fetch with curl, strip HTML with basic sed/grep pipeline
  let cmd = "curl -sL --max-time 15 --max-filesize 1048576 '${url}' | sed 's/<script[^>]*>.*<\\/script>//g' | sed 's/<style[^>]*>.*<\\/style>//g' | sed 's/<[^>]*>//g' | sed '/^$/d' | head -100"

  let result = exec(cmd, { cwd: ctx.cwd, timeout: 20000, shell: true })

  if result.exitCode != 0 {
    return ToolResult {
      output: "",
      metadata: null,
      error: "Failed to fetch URL: ${result.stderr.slice(0, 200)}",
    }
  }

  let content = result.stdout.trim()
  if content.isEmpty() {
    return ToolResult {
      output: "(page returned no readable text content)",
      metadata: { url: url },
      error: null,
    }
  }

  // Truncate to budget
  if content.length > MAX_CONTENT_CHARS {
    content = content.slice(0, MAX_CONTENT_CHARS) + "\n\n[... content truncated to fit context budget]"
  }

  // Clean up excessive whitespace
  content = content.replaceAll("\\s{3,}", "\n\n").trim()

  return ToolResult {
    output: "Content from ${url}:\n\n${content}",
    metadata: { url: url, chars: content.length },
    error: null,
  }
}
