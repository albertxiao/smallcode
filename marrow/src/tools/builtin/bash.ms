// SmallCode - Bash/Shell Tool
// Execute shell commands with timeout and output budget management

import { ToolResult, ToolContext } from "../registry"
import { exec } from "std/process"
import { resolve } from "std/path"

// Default timeout from config (can be overridden)
const DEFAULT_TIMEOUT = 30  // seconds

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let command = args.get("command") as String
  let workDir = args.get("cwd") as String?

  let effectiveCwd = if workDir {
    resolve(ctx.cwd, workDir)
  } else {
    ctx.cwd
  }

  // Safety check: block obviously dangerous commands
  let blocked = checkBlocked(command)
  if blocked {
    return ToolResult {
      output: "",
      metadata: null,
      error: "Command blocked: ${blocked}",
    }
  }

  // Execute with timeout
  let result = exec(command, {
    cwd: effectiveCwd,
    timeout: DEFAULT_TIMEOUT * 1000,  // ms
    shell: true,
    maxBuffer: 1024 * 1024,  // 1MB max output
  })

  let output = ""
  if result.stdout && result.stdout.length > 0 {
    output = result.stdout
  }
  if result.stderr && result.stderr.length > 0 {
    if output.length > 0 {
      output += "\n--- stderr ---\n"
    }
    output += result.stderr
  }

  // Truncate output to be context-friendly
  let maxOutputChars = 4000  // ~1000 tokens
  if output.length > maxOutputChars {
    // Keep first part and last part
    let headSize = maxOutputChars * 2 / 3
    let tailSize = maxOutputChars / 3
    let head = output.slice(0, headSize)
    let tail = output.slice(output.length - tailSize)
    output = "${head}\n\n[... ${output.length - maxOutputChars} chars truncated ...]\n\n${tail}"
  }

  if result.exitCode != 0 {
    return ToolResult {
      output: output,
      metadata: { exit_code: result.exitCode, command: command },
      error: "Command exited with code ${result.exitCode}",
    }
  }

  if output.isEmpty() {
    output = "(no output)"
  }

  return ToolResult {
    output: output,
    metadata: { exit_code: 0, command: command },
    error: null,
  }
}

// Block commands that are extremely dangerous in an automated context
fn checkBlocked(command: String): String? {
  let cmd = command.trim().toLowerCase()

  // Block recursive force deletes at root-like paths
  if cmd.contains("rm -rf /") && !cmd.contains("rm -rf ./") {
    return "Recursive delete at root path not allowed"
  }
  if cmd.contains("rmdir /s /q c:\\") || cmd.contains("format c:") {
    return "Destructive system command not allowed"
  }

  // Block credential stealing
  if cmd.contains("cat ~/.ssh") || cmd.contains("cat /etc/shadow") {
    return "Reading sensitive system files not allowed"
  }

  // Block network exfiltration of project files
  if cmd.contains("curl") && cmd.contains("--upload") {
    return "File upload commands blocked for safety"
  }

  return null
}
