// SmallCode — BoneScript Compile Tool
// Compiles a .bone file into a complete Node.js/TypeScript backend project
// Generates: routes, models, auth, events, migrations, SDK, admin panel, Docker, CI

import { exec } from "std/process"
import { readFile, pathExists } from "std/fs"
import { resolve, extname } from "std/path"
import { cwd } from "std/env"
import { ToolResult, ToolContext } from "../registry"

pub fn builtinBoneCompile(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let filePath = args.get("path") as String
  let target = (args.get("target") as String?) ?? "express"
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

  // Run compilation
  let result = exec(
    "node \"${compiler}\" compile \"${fullPath}\" --target ${target}",
    { cwd: ctx.cwd, timeout: 30000, shell: true }
  )

  if result.exitCode != 0 {
    let errOutput = "${result.stdout}\n${result.stderr}".trim()
    return ToolResult {
      output: "",
      metadata: { target: target, exit_code: result.exitCode },
      error: "BoneScript compile failed:\n${errOutput.slice(0, 2000)}",
    }
  }

  let output = result.stdout.trim()
  return ToolResult {
    output: "Compiled ${filePath} → output/ (target: ${target})\n${output.slice(0, 2000)}",
    metadata: { target: target, path: "output/" },
    error: null,
  }
}

// Locate the bonescript-compiler CLI
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
