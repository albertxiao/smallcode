// SmallCode - Project Overview Tool
// Generates a compact project summary for context injection
// Useful at session start and when model needs orientation

import { ToolResult, ToolContext } from "../registry"
import { glob, stat, readFile, pathExists } from "std/fs"
import { resolve, relative, basename, extname } from "std/path"
import { BudgetEngine } from "../../context/budget"

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  let path = args.get("path") as String? ?? "."
  let fullPath = resolve(ctx.cwd, path)

  let overview = []

  // 1. Detect project type from config files
  let projectType = detectProjectType(fullPath)
  overview.push("Project: ${basename(fullPath)} (${projectType})")

  // 2. File structure (top-level + key dirs)
  let structure = getStructure(fullPath)
  overview.push("")
  overview.push("Structure:")
  for line in structure {
    overview.push("  ${line}")
  }

  // 3. Key files summary
  let keyFiles = findKeyFiles(fullPath)
  if keyFiles.length > 0 {
    overview.push("")
    overview.push("Key files:")
    for kf in keyFiles {
      overview.push("  ${kf}")
    }
  }

  // 4. Dependencies (if detectable)
  let deps = detectDependencies(fullPath)
  if deps.length > 0 {
    overview.push("")
    overview.push("Dependencies: ${deps.join(", ")}")
  }

  let output = overview.join("\n")
  return ToolResult {
    output: output,
    metadata: { project_type: projectType, files: structure.length },
    error: null,
  }
}

fn detectProjectType(dir: String): String {
  if pathExists("${dir}/Cargo.toml") { return "Rust" }
  if pathExists("${dir}/go.mod") { return "Go" }
  if pathExists("${dir}/pyproject.toml") || pathExists("${dir}/setup.py") { return "Python" }
  if pathExists("${dir}/package.json") {
    if pathExists("${dir}/tsconfig.json") { return "TypeScript/Node" }
    return "JavaScript/Node"
  }
  if pathExists("${dir}/pom.xml") { return "Java/Maven" }
  if pathExists("${dir}/build.gradle") { return "Java/Gradle" }
  if pathExists("${dir}/marrow.toml") || pathExists("${dir}/smallcode.toml") { return "Marrowscript" }
  if pathExists("${dir}/.marrow") { return "MarrowScript system" }
  return "Unknown"
}

fn getStructure(dir: String): List<String> {
  let entries = glob("*", { cwd: dir })
  let result = []

  for entry in entries.slice(0, 30) {
    let info = stat("${dir}/${entry}")
    if info.isDirectory {
      let subCount = glob("**/*", { cwd: "${dir}/${entry}", ignore: ["node_modules/**", ".git/**"] }).length
      result.push("${entry}/ (${subCount} files)")
    } else {
      result.push(entry)
    }
  }

  if entries.length > 30 {
    result.push("... (${entries.length - 30} more)")
  }

  return result
}

fn findKeyFiles(dir: String): List<String> {
  let keyPatterns = [
    "README.md", "README", "readme.md",
    "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
    "Makefile", "Dockerfile", "docker-compose.yml",
    "tsconfig.json", ".env.example",
    "smallcode.toml", "smallcode.marrow",
  ]

  return keyPatterns.filter(|p| pathExists("${dir}/${p}"))
}

fn detectDependencies(dir: String): List<String> {
  let deps = []

  if pathExists("${dir}/package.json") {
    let content = readFile("${dir}/package.json")
    let pkg = parseJson(content)
    let allDeps = pkg.get("dependencies") as Map<String, Any>? ?? {}
    deps = allDeps.keys().slice(0, 10)
  }

  return deps
}
