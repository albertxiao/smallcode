// SmallCode - Git Tools (exposed to the model)
// The model can check git status, diff, and commit via these tools

import { ToolResult, ToolContext } from "../registry"
import { Git } from "../../git/git"
import { EventBus } from "../../core/event_bus"

// Git status tool
pub fn executeStatus(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let git = Git.new(EventBus.new())
  let info = git.info()

  if !info.isRepo {
    return ToolResult { output: "Not a git repository", metadata: null, error: null }
  }

  let diff = git.diff()
  let output = "Branch: ${info.branch}"
  if info.ahead > 0 { output += " (${info.ahead} ahead)" }
  if info.behind > 0 { output += " (${info.behind} behind)" }
  output += "\n${diff.summary}"

  if diff.untracked.length > 0 {
    output += "\nUntracked: ${diff.untracked.slice(0, 10).join(", ")}"
  }

  return ToolResult { output: output, metadata: { branch: info.branch }, error: null }
}

// Git diff tool
pub fn executeDiff(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let git = Git.new(EventBus.new())
  let path = args.get("path") as String?

  let output = ""
  if path {
    // Diff for specific file
    let result = exec("git diff -- \"${path}\"", { cwd: ctx.cwd, timeout: 5000, shell: true })
    output = result.stdout
  } else {
    // Full diff
    let diff = git.diff()
    output = "${diff.unstaged}\n${diff.staged}".trim()
  }

  if output.isEmpty() {
    output = "No changes"
  }

  // Truncate long diffs
  if output.length > 3000 {
    output = output.slice(0, 3000) + "\n\n[... diff truncated]"
  }

  return ToolResult { output: output, metadata: null, error: null }
}

// Git commit tool
pub fn executeCommit(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let git = Git.new(EventBus.new())
  let message = args.get("message") as String? ?? git.suggestCommitMessage()
  let files = args.get("files") as List<String>?

  let success = git.commit(message, files)
  if success {
    return ToolResult {
      output: "Committed: ${message}",
      metadata: { message: message },
      error: null,
    }
  }

  return ToolResult { output: "", metadata: null, error: "Commit failed" }
}

// Git log tool
pub fn executeLog(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let git = Git.new(EventBus.new())
  let count = args.get("count") as Int? ?? 5
  let output = git.log(count)
  return ToolResult { output: output, metadata: null, error: null }
}
