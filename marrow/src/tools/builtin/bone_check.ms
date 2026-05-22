// SmallCode — BoneScript Check Tool
// Validates a .bone file without generating code
// Reports type errors, constraint violations, and syntax issues
// Integrates with the improvement loop for auto-fix feedback

import { exec } from "std/process"
import { readFile, pathExists } from "std/fs"
import { resolve, extname } from "std/path"
import { cwd } from "std/env"
import { ToolResult, ToolContext } from "../registry"

pub fn builtinBoneCheck(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let filePath = args.get("path") as String
  let fullPath = resolve(ctx.cwd, filePath)

  // Validate input
  if !pathExists(fullPath) {
    return ToolResult { output: "", metadata: null, error: "File not found: ${filePath}" }
  }
  if extname(filePath) != ".bone" {
    return ToolResult { output: "", metadata: null, error: "Expected a .bone file, got: ${filePath}" }
  }

  // Locate the BoneScript compiler
  let compiler = findCompiler(ctx.cwd)
  if !compiler {
    return ToolResult {
      output: "",
      metadata: null,
      error: "BoneScript compiler not found. Ensure bonescript-compiler is installed.",
    }
  }

  // Run validation
  let result = exec(
    "node \"${compiler}\" check \"${fullPath}\"",
    { cwd: ctx.cwd, timeout: 15000, shell: true }
  )

  if result.exitCode == 0 {
    let output = result.stdout.trim()
    return ToolResult {
      output: output || "✓ No errors found in ${filePath}",
      metadata: { valid: true },
      error: null,
    }
  }

  // Parse errors for structured feedback
  let errOutput = "${result.stdout}\n${result.stderr}".trim()
  let errors = errOutput.split("\n")
    .filter(|line| line.contains("error") || line.contains("Error"))
    .slice(0, 10)

  return ToolResult {
    output: "",
    metadata: { valid: false, error_count: errors.length },
    error: "BoneScript validation errors:\n${errors.join("\n")}",
  }
}

// Locate the bonescript-compiler CLI (shared logic with bone_compile)
fn findCompiler(projectCwd: String): String? {
  let candidates = [
    resolve(projectCwd, "node_modules", "bonescript-compiler", "dist", "cli.js"),
    resolve(projectCwd, "..", "BoneScript", "compiler", "dist", "cli.js"),
  ]

  for candidate in candidates {
    if pathExists(candidate) {
      return candidate
    }
  }
  return null
}
