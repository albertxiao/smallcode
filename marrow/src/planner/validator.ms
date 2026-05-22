// SmallCode - Step Validator
// Runs post-step checks (lint, compile, test) to catch errors early
// Critical for small models: validates each atomic step before moving on

import { exec } from "std/process"
import { pathExists } from "std/fs"
import { cwd } from "std/env"

pub struct ValidationResult {
  passed: Bool
  errors: List<String>
  warnings: List<String>
  command: String?
}

pub struct Validator {
  enabled: Bool
  commands: List<ValidatorCommand>
}

struct ValidatorCommand {
  name: String
  command: String
  errorPattern: String      // Regex to extract errors from output
  warningPattern: String    // Regex to extract warnings
}

pub impl Validator {
  pub fn new(enabled: Bool): Validator {
    let validator = Validator {
      enabled: enabled,
      commands: [],
    }
    // Auto-detect available validators
    validator.detect()
    return validator
  }

  // Run validation and return results
  pub fn run(self): ValidationResult {
    if !self.enabled || self.commands.isEmpty() {
      return ValidationResult { passed: true, errors: [], warnings: [], command: null }
    }

    // Run the first available validator
    let cmd = self.commands[0]
    let result = exec(cmd.command, {
      cwd: cwd(),
      timeout: 30000,
      shell: true,
    })

    let errors = []
    let warnings = []

    if result.exitCode != 0 {
      // Parse errors from output
      let output = "${result.stdout}\n${result.stderr}"
      errors = extractMatches(output, cmd.errorPattern)
      warnings = extractMatches(output, cmd.warningPattern)

      // If no pattern matched, use raw output
      if errors.isEmpty() {
        errors = [output.slice(0, 500)]  // Cap error message size
      }
    }

    return ValidationResult {
      passed: result.exitCode == 0,
      errors: errors,
      warnings: warnings,
      command: cmd.name,
    }
  }

  // Auto-detect project validators
  fn detect(self) {
    let dir = cwd()

    // TypeScript/JavaScript
    if pathExists("${dir}/tsconfig.json") {
      self.commands.push(ValidatorCommand {
        name: "tsc",
        command: "npx tsc --noEmit 2>&1 | head -20",
        errorPattern: "error TS\\d+:",
        warningPattern: "warning",
      })
    }

    // Rust
    if pathExists("${dir}/Cargo.toml") {
      self.commands.push(ValidatorCommand {
        name: "cargo check",
        command: "cargo check 2>&1 | head -30",
        errorPattern: "^error",
        warningPattern: "^warning",
      })
    }

    // Python
    if pathExists("${dir}/pyproject.toml") || pathExists("${dir}/setup.py") {
      if pathExists("${dir}/.flake8") || pathExists("${dir}/pyproject.toml") {
        self.commands.push(ValidatorCommand {
          name: "ruff",
          command: "ruff check . 2>&1 | head -20",
          errorPattern: "\\w+\\.py:\\d+:\\d+: E",
          warningPattern: "\\w+\\.py:\\d+:\\d+: W",
        })
      }
    }

    // Go
    if pathExists("${dir}/go.mod") {
      self.commands.push(ValidatorCommand {
        name: "go build",
        command: "go build ./... 2>&1 | head -20",
        errorPattern: "^\\./",
        warningPattern: "",
      })
    }

    // Generic: package.json lint script
    if pathExists("${dir}/package.json") {
      self.commands.push(ValidatorCommand {
        name: "npm lint",
        command: "npm run lint --silent 2>&1 | head -20",
        errorPattern: "error",
        warningPattern: "warning",
      })
    }

    // Marrowscript (our own language)
    if pathExists("${dir}/marrow.toml") {
      self.commands.push(ValidatorCommand {
        name: "marrow check",
        command: "marrow check 2>&1 | head -20",
        errorPattern: "error:",
        warningPattern: "warning:",
      })
    }
  }

  // Get available validators list (for display)
  pub fn available(self): List<String> {
    return self.commands.map(|c| c.name)
  }
}

fn extractMatches(text: String, pattern: String): List<String> {
  if pattern.isEmpty() { return [] }
  let matches = text.matchAll(pattern)
  return matches.map(|m| m[0]).slice(0, 5)  // Max 5 errors
}
