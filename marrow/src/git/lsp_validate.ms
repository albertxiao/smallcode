// SmallCode - LSP-Powered Validation
// Connects to language servers for real compiler diagnostics after edits
// Far more accurate than regex-based linting — feeds real errors to repair loop

import { exec } from "std/process"
import { pathExists } from "std/fs"
import { cwd } from "std/env"
import { extname } from "std/path"

pub struct Diagnostic {
  file: String
  line: Int
  col: Int
  severity: String      // "error" | "warning" | "info"
  message: String
  code: String?
}

pub struct ValidationResult {
  passed: Bool
  diagnostics: List<Diagnostic>
  command: String
}

pub struct LSPValidator {
  validators: Map<String, ValidatorConfig>
}

struct ValidatorConfig {
  name: String
  command: String
  parseOutput: fn(String) -> List<Diagnostic>
}

pub impl LSPValidator {
  pub fn new(): LSPValidator {
    let v = LSPValidator { validators: {} }
    v.detect()
    return v
  }

  // Validate a specific file after edit
  pub fn validateFile(self, path: String): ValidationResult {
    let ext = extname(path)
    let validator = self.validatorForExt(ext)
    if !validator {
      return ValidationResult { passed: true, diagnostics: [], command: "none" }
    }

    let cmd = validator.command.replace("{file}", path).replace("{dir}", cwd())
    let result = exec(cmd, { cwd: cwd(), timeout: 30000, shell: true })

    let output = "${result.stdout}\n${result.stderr}"
    let diagnostics = validator.parseOutput(output)

    // Filter to only errors in the edited file
    let fileDiags = diagnostics.filter(|d| d.file == path || d.file.endsWith(path))
    let errors = fileDiags.filter(|d| d.severity == "error")

    return ValidationResult {
      passed: errors.isEmpty(),
      diagnostics: fileDiags,
      command: validator.name,
    }
  }

  // Validate the whole project (lighter check)
  pub fn validateProject(self): ValidationResult {
    let allDiags: List<Diagnostic> = []
    let cmds = []

    for (ext, validator) in self.validators {
      let result = exec(validator.command.replace("{file}", ".").replace("{dir}", cwd()), {
        cwd: cwd(), timeout: 30000, shell: true
      })
      let output = "${result.stdout}\n${result.stderr}"
      allDiags.append(validator.parseOutput(output))
      cmds.push(validator.name)
    }

    let errors = allDiags.filter(|d| d.severity == "error")
    return ValidationResult {
      passed: errors.isEmpty(),
      diagnostics: allDiags.slice(0, 20),  // Cap at 20 for context budget
      command: cmds.join(", "),
    }
  }

  // Format diagnostics compactly for model context
  pub fn formatForModel(self, result: ValidationResult): String {
    if result.passed {
      return "✓ No errors (validated by ${result.command})"
    }

    let errors = result.diagnostics.filter(|d| d.severity == "error")
    let warnings = result.diagnostics.filter(|d| d.severity == "warning")

    let lines = ["✗ ${errors.length} errors, ${warnings.length} warnings (${result.command}):"]
    for diag in errors.slice(0, 10) {
      lines.push("  ${diag.file}:${diag.line}:${diag.col} error: ${diag.message}")
    }
    if errors.length > 10 {
      lines.push("  ... (${errors.length - 10} more errors)")
    }

    return lines.join("\n")
  }

  // Auto-detect available validators
  fn detect(self) {
    let dir = cwd()

    // TypeScript
    if pathExists("${dir}/tsconfig.json") {
      self.validators.set(".ts", ValidatorConfig {
        name: "tsc",
        command: "npx tsc --noEmit --pretty false 2>&1",
        parseOutput: parseTscOutput,
      })
      self.validators.set(".tsx", self.validators.get(".ts"))
    }

    // Rust
    if pathExists("${dir}/Cargo.toml") {
      self.validators.set(".rs", ValidatorConfig {
        name: "cargo",
        command: "cargo check --message-format short 2>&1",
        parseOutput: parseCargoOutput,
      })
    }

    // Python (ruff)
    if pathExists("${dir}/pyproject.toml") {
      self.validators.set(".py", ValidatorConfig {
        name: "ruff",
        command: "ruff check {file} --output-format concise 2>&1",
        parseOutput: parseRuffOutput,
      })
    }

    // Go
    if pathExists("${dir}/go.mod") {
      self.validators.set(".go", ValidatorConfig {
        name: "go",
        command: "go build ./... 2>&1",
        parseOutput: parseGoOutput,
      })
    }

    // ESLint (JS/JSX)
    if pathExists("${dir}/.eslintrc.json") || pathExists("${dir}/.eslintrc.js") || pathExists("${dir}/eslint.config.js") {
      self.validators.set(".js", ValidatorConfig {
        name: "eslint",
        command: "npx eslint {file} --format compact 2>&1",
        parseOutput: parseEslintOutput,
      })
      self.validators.set(".jsx", self.validators.get(".js"))
    }
  }

  fn validatorForExt(self, ext: String): ValidatorConfig? {
    return self.validators.get(ext)
  }
}

// --- Output parsers ---

fn parseTscOutput(output: String): List<Diagnostic> {
  let diags = []
  let lines = output.split("\n")
  for line in lines {
    // Format: src/file.ts(10,5): error TS2304: Cannot find name 'x'.
    let match = line.match("^(.+?)\\((\\d+),(\\d+)\\):\\s*(error|warning)\\s*(TS\\d+):\\s*(.+)")
    if match {
      diags.push(Diagnostic {
        file: match[1],
        line: parseInt(match[2]) ?? 0,
        col: parseInt(match[3]) ?? 0,
        severity: match[4],
        message: match[6],
        code: match[5],
      })
    }
  }
  return diags
}

fn parseCargoOutput(output: String): List<Diagnostic> {
  let diags = []
  let lines = output.split("\n")
  for line in lines {
    // Format: error[E0425]: cannot find value `x` in this scope --> src/main.rs:10:5
    let match = line.match("^(error|warning).*-->\\s*(.+?):(\\d+):(\\d+)")
    if match {
      diags.push(Diagnostic {
        file: match[2],
        line: parseInt(match[3]) ?? 0,
        col: parseInt(match[4]) ?? 0,
        severity: match[1],
        message: line,
        code: null,
      })
    }
  }
  return diags
}

fn parseRuffOutput(output: String): List<Diagnostic> {
  let diags = []
  let lines = output.split("\n")
  for line in lines {
    // Format: src/file.py:10:5: E501 Line too long
    let match = line.match("^(.+?):(\\d+):(\\d+):\\s*(\\w+)\\s*(.+)")
    if match {
      let severity = if match[4].startsWith("E") { "error" } else { "warning" }
      diags.push(Diagnostic {
        file: match[1],
        line: parseInt(match[2]) ?? 0,
        col: parseInt(match[3]) ?? 0,
        severity: severity,
        message: match[5],
        code: match[4],
      })
    }
  }
  return diags
}

fn parseGoOutput(output: String): List<Diagnostic> {
  let diags = []
  let lines = output.split("\n")
  for line in lines {
    // Format: ./file.go:10:5: error message
    let match = line.match("^(.+?):(\\d+):(\\d+):\\s*(.+)")
    if match {
      diags.push(Diagnostic {
        file: match[1],
        line: parseInt(match[2]) ?? 0,
        col: parseInt(match[3]) ?? 0,
        severity: "error",
        message: match[4],
        code: null,
      })
    }
  }
  return diags
}

fn parseEslintOutput(output: String): List<Diagnostic> {
  let diags = []
  let lines = output.split("\n")
  for line in lines {
    // Compact format: /path/file.js: line 10, col 5, Error - message (rule)
    let match = line.match("^(.+?):\\s*line (\\d+), col (\\d+),\\s*(Error|Warning)\\s*-\\s*(.+)")
    if match {
      diags.push(Diagnostic {
        file: match[1],
        line: parseInt(match[2]) ?? 0,
        col: parseInt(match[3]) ?? 0,
        severity: match[4].toLowerCase(),
        message: match[5],
        code: null,
      })
    }
  }
  return diags
}
