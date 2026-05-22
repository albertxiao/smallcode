// SmallCode - Web Search Tool
// Lightweight web search using DuckDuckGo instant answers or SearXNG
// Keeps results compact for context budget

import { ToolResult, ToolContext } from "../registry"
import { exec } from "std/process"
import { BudgetEngine } from "../../context/budget"

const MAX_RESULTS = 5

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let query = args.get("query") as String

  // Try DuckDuckGo HTML (no API key needed)
  let cmd = "curl -s 'https://html.duckduckgo.com/html/?q=${encodeUri(query)}' | grep -oP '<a rel=\"nofollow\" class=\"result__a\" href=\"[^\"]+\">[^<]+</a>' | head -${MAX_RESULTS}"
  
  let result = exec(cmd, { cwd: ctx.cwd, timeout: 15000, shell: true })

  if result.exitCode != 0 || result.stdout.trim().isEmpty() {
    // Fallback: try using curl with DuckDuckGo API
    let apiCmd = "curl -s 'https://api.duckduckgo.com/?q=${encodeUri(query)}&format=json&no_redirect=1'"
    let apiResult = exec(apiCmd, { cwd: ctx.cwd, timeout: 10000, shell: true })
    
    if apiResult.exitCode == 0 && apiResult.stdout.length > 10 {
      try {
        let data = parseJson(apiResult.stdout)
        if data.AbstractText && data.AbstractText.length > 0 {
          return ToolResult {
            output: "Answer: ${data.AbstractText}\nSource: ${data.AbstractSource} (${data.AbstractURL})",
            metadata: { source: "duckduckgo_instant" },
            error: null,
          }
        }
      } catch {}
    }

    return ToolResult {
      output: "No search results found for '${query}'. Try a different query.",
      metadata: { matches: 0 },
      error: null,
    }
  }

  // Parse HTML results into clean format
  let output = parseSearchResults(result.stdout)
  
  return ToolResult {
    output: "Search results for '${query}':\n${output}",
    metadata: { matches: MAX_RESULTS },
    error: null,
  }
}

fn parseSearchResults(html: String): String {
  let lines = html.split("\n").filter(|l| !l.trim().isEmpty())
  let results = []
  
  for (i, line) in lines.enumerate() {
    // Extract URL and title from <a> tags
    let urlMatch = line.match("href=\"([^\"]+)\"")
    let titleMatch = line.match(">([^<]+)</a>")
    
    if urlMatch && titleMatch {
      results.push("${i+1}. ${titleMatch[1]}\n   ${urlMatch[1]}")
    }
  }

  if results.isEmpty() {
    return "(could not parse results)"
  }

  return results.join("\n")
}

fn encodeUri(s: String): String {
  return s.replace(" ", "+").replace("&", "%26").replace("?", "%3F")
}
