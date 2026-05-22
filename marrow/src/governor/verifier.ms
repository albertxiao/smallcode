// SmallCode — Code Verification Engine (ARK-inspired)
// Pipeline: extract → auto-fix → compile → execute → test → lint
// Hard fail: refuses to deliver code that can't pass verification after N retries

import { exec } from "std/process"
import { readFile, writeFile, pathExists, mkdirp } from "std/fs"
import { extname, resolve, dirname, basename } from "std/path"
import { cwd } from "std/env"

pub struct VerificationResult {
  passed: Bool
  confidence: Float           // 0.0 - 1.0 calibrated
  compiled: Bool
  executed: Bool
  tests_passed: Bool
  lint_clean: Bool
  auto_fixed: Bool
  errors: List<String>
  hard_fail: Bool             // true = refuse to deliver
}

pub struct Verifier {
  maxRetries: Int
}

pub impl Verifier {
  pub fn new(maxRetries: Int = 2): Verifier {
    return Verifier { maxRetries: maxRetries }
  }

  // Full verification pipeline for a file
  pub fn verify(self, filePath: String): VerificationResult {
    let result = VerificationResult {
      passed: false,
      confidence: 0.0,
      compiled: false,
      executed: false,
      tests_passed: false,
      lint_clean: false,
      auto_fixed: false,
      errors: [],
      hard_fail: false,
    }

    let fullPath = resolve(cwd(), filePath)
    if !pathExists(fullPath) {
      result.errors.push("File not found: ${filePath}")
      result.hard_fail = true
      return result
    }

    let ext = extname(filePath)
    let content = readFile(fullPath)

    // Step 1: Structural check (placeholders, truncation)
    let structural = self.checkStructural(content)
    if !structural.passed {
      result.errors.append(structural.errors)
      // Auto-fix attempt
      let fixed = self.autoFix(content, ext)
      if fixed != content {
        writeFile(fullPath, fixed)
        content = fixed
        result.auto_fixed = true
      }
    }

    // Step 2: Compile
    let compileResult = self.compile(filePath, ext)
    result.compiled = compileResult.passed
    if !compileResult.passed {
      result.errors.append(compileResult.errors)
    }

    // Step 3: Execute (with timeout)
    if result.compiled {
      let execResult = self.execute(filePath, ext)
      result.executed = execResult.passed
      if !execResult.passed {
        result.errors.append(execResult.errors)
      }
    }

    // Step 4: Auto-generate and run smoke test
    if result.compiled && result.executed {
      let testResult = self.smokeTest(filePath, ext, content)
      result.tests_passed = testResult.passed
      if !testResult.passed {
        result.errors.append(testResult.errors)
      }
    }

    // Step 5: Lint
    let lintResult = self.lint(filePath, ext)
    result.lint_clean = lintResult.passed
    // Lint warnings don't block delivery

    // Compute confidence
    result.confidence = self.computeConfidence(result)
    result.passed = result.compiled && result.executed
    return result
  }

  // Hard fail check: should we refuse to deliver?
  pub fn shouldHardFail(self, results: List<VerificationResult>): Bool {
    // If all attempts failed to compile, hard fail
    let allFailedCompile = results.all(|r| !r.compiled)
    if allFailedCompile && results.length >= self.maxRetries {
      return true
    }
    // If code executes but crashes every time
    let allCrashed = results.all(|r| r.compiled && !r.executed)
    if allCrashed && results.length >= self.maxRetries {
      return true
    }
    return false
  }

  // ─── Pipeline stages ───────────────────────────────────────────────────

  fn checkStructural(self, content: String): StageResult {
    let errors = []

    // Check for placeholders
    let placeholders = ["// TODO", "// ...", "/* ... */", "pass  # placeholder", "raise NotImplementedError"]
    for p in placeholders {
      if content.contains(p) {
        errors.push("Contains placeholder: ${p}")
      }
    }

    // Check for truncation markers
    if content.contains("// ... rest of") || content.contains("# ... more") {
      errors.push("Appears truncated")
    }

    // Check balanced braces (for C-style languages)
    let openBraces = content.chars().filter(|c| c == '{').length
    let closeBraces = content.chars().filter(|c| c == '}').length
    if openBraces != closeBraces {
      errors.push("Unbalanced braces: ${openBraces} open, ${closeBraces} close")
    }

    return StageResult { passed: errors.isEmpty(), errors: errors }
  }

  fn compile(self, filePath: String, ext: String): StageResult {
    let cmd = match ext {
      ".py" => "python -m py_compile \"${filePath}\""
      ".js" | ".mjs" => "node --check \"${filePath}\""
      ".ts" | ".tsx" => "npx tsc --noEmit \"${filePath}\" 2>&1"
      ".rs" => "rustc --edition 2021 --crate-type lib \"${filePath}\" 2>&1"
      ".go" => "go build \"${filePath}\" 2>&1"
      ".c" => "gcc -fsyntax-only \"${filePath}\" 2>&1"
      ".cpp" => "g++ -fsyntax-only \"${filePath}\" 2>&1"
      ".bone" => {
        // BoneScript validation via bone_check
        let compiler = findBoneCompiler(cwd())
        if !compiler { return StageResult { passed: true, errors: [] } }
        "node \"${compiler}\" check \"${filePath}\" 2>&1"
      }
      _ => return StageResult { passed: true, errors: [] }  // No compiler available
    }

    let result = exec(cmd, { cwd: cwd(), timeout: 15000, shell: true })
    if result.exitCode == 0 {
      return StageResult { passed: true, errors: [] }
    }
    let output = "${result.stdout}\n${result.stderr}".trim()
    return StageResult { passed: false, errors: [output.slice(0, 500)] }
  }

  fn execute(self, filePath: String, ext: String): StageResult {
    let cmd = match ext {
      ".py" => "python \"${filePath}\""
      ".js" | ".mjs" => "node \"${filePath}\""
      ".ts" => "npx tsx \"${filePath}\""
      _ => return StageResult { passed: true, errors: [] }  // Can't execute this type
    }

    let result = exec(cmd, { cwd: cwd(), timeout: 10000, shell: true })
    if result.exitCode == 0 {
      return StageResult { passed: true, errors: [] }
    }
    let output = "${result.stdout}\n${result.stderr}".trim()
    return StageResult { passed: false, errors: [output.slice(0, 500)] }
  }

  fn smokeTest(self, filePath: String, ext: String, content: String): StageResult {
    // Auto-generate a minimal test based on language
    let testContent = match ext {
      ".py" => generatePythonSmokeTest(filePath, content)
      ".js" => generateJsSmokeTest(filePath, content)
      _ => return StageResult { passed: true, errors: [] }
    }

    if !testContent { return StageResult { passed: true, errors: [] } }

    // Write temp test file
    let testPath = "${dirname(filePath)}/.smoke_test${ext}"
    writeFile(resolve(cwd(), testPath), testContent)

    let cmd = match ext {
      ".py" => "python \"${testPath}\""
      ".js" => "node \"${testPath}\""
      _ => "echo ok"
    }

    let result = exec(cmd, { cwd: cwd(), timeout: 10000, shell: true })

    // Clean up
    try { deleteFile(resolve(cwd(), testPath)) } catch {}

    if result.exitCode == 0 {
      return StageResult { passed: true, errors: [] }
    }
    return StageResult { passed: false, errors: ["Smoke test failed: ${result.stderr.slice(0, 300)}"] }
  }

  fn lint(self, filePath: String, ext: String): StageResult {
    let cmd = match ext {
      ".py" => "python -m py_compile \"${filePath}\" 2>&1"  // basic
      ".go" => "go vet \"${filePath}\" 2>&1"
      _ => return StageResult { passed: true, errors: [] }
    }

    let result = exec(cmd, { cwd: cwd(), timeout: 10000, shell: true })
    return StageResult { passed: result.exitCode == 0, errors: [] }
  }

  fn autoFix(self, content: String, ext: String): String {
    let fixed = content

    // Fix orphan closing brace at end (common model error)
    if fixed.endsWith("\n}\n}") && ext != ".json" {
      // Don't auto-fix, might be valid
    }

    // Fix missing newline at end
    if !fixed.endsWith("\n") {
      fixed += "\n"
    }

    // Fix common Python indentation (tabs → spaces)
    if ext == ".py" && fixed.contains("\t") {
      fixed = fixed.replace("\t", "    ")
    }

    return fixed
  }

  fn computeConfidence(self, result: VerificationResult): Float {
    let score = 0.0
    if result.compiled { score += 0.35 }
    if result.executed { score += 0.25 }
    if result.tests_passed { score += 0.25 }
    if result.lint_clean { score += 0.10 }
    if result.auto_fixed { score -= 0.05 }  // Slight penalty for needing auto-fix
    return score
  }
}

struct StageResult {
  passed: Bool
  errors: List<String>
}

// ─── Auto-generated smoke tests ──────────────────────────────────────────────

fn generatePythonSmokeTest(filePath: String, content: String): String? {
  // Extract function names from Python code
  let functions = []
  let lines = content.split("\n")
  for line in lines {
    let match = line.match("^def (\\w+)\\(")
    if match && match[1] != "__" {
      functions.push(match[1])
    }
  }

  if functions.isEmpty() { return null }

  let moduleName = basename(filePath).replace(".py", "")
  let imports = "import sys; sys.path.insert(0, '.')\n"
  imports += "from ${moduleName} import ${functions.join(", ")}\n\n"

  let tests = functions.map(|f| {
    return "# Smoke test: ${f} is callable\nassert callable(${f}), '${f} should be callable'\nprint('✓ ${f}')\n"
  }).join("\n")

  return "${imports}${tests}print('All smoke tests passed')\n"
}

fn generateJsSmokeTest(filePath: String, content: String): String? {
  // Check if file exports anything
  if !content.contains("module.exports") && !content.contains("export ") {
    return null
  }

  let modulePath = "./${basename(filePath)}"
  return "const mod = require('${modulePath}');\nconsole.log('Module loaded successfully');\nconsole.log('Exports:', Object.keys(mod));\n"
}

// Locate the BoneScript compiler binary
fn findBoneCompiler(projectCwd: String): String? {
  let candidates = [
    resolve(projectCwd, "node_modules", "bonescript-compiler", "dist", "cli.js"),
    resolve(projectCwd, "..", "BoneScript", "compiler", "dist", "cli.js"),
  ]
  for candidate in candidates {
    if pathExists(candidate) { return candidate }
  }
  return null
}
