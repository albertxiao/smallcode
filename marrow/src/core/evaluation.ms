// SmallCode - Evaluation Runner
// Mirrors MarrowScript's emitted evaluation runtime
// Tests prompts against recorded expectations — CI-friendly

import { ModelAdapter, CompletionRequest } from "../model/adapter"
import { EventBus } from "./event_bus"
import { readFile, writeFile, pathExists, mkdirp } from "std/fs"
import { cwd } from "std/env"

const EVAL_DIR = ".smallcode/eval"

pub struct EvalCase {
  name: String
  input: Map<String, Any>
  expectations: List<Expectation>
}

pub struct Expectation {
  kind: String          // "must_contain" | "must_not_contain" | "max_lines" | "min_lines" | "matches_pattern"
  values: List<String>? // for contain checks
  value: Int?           // for line count checks
  pattern: String?      // for regex checks
}

pub struct EvalResult {
  caseName: String
  passed: Bool
  output: String
  failures: List<String>
  latencyMs: Int
}

pub struct EvalSuite {
  name: String
  promptName: String
  cases: List<EvalCase>
  minPassRate: Float
}

pub struct EvalReport {
  suiteName: String
  results: List<EvalResult>
  passRate: Float
  totalMs: Int
  baselineMet: Bool
}

pub struct EvaluationRunner {
  model: ModelAdapter
  eventBus: EventBus
}

pub impl EvaluationRunner {
  pub fn new(model: ModelAdapter, eventBus: EventBus): EvaluationRunner {
    return EvaluationRunner { model: model, eventBus: eventBus }
  }

  // Run an evaluation suite
  pub fn run(self, suite: EvalSuite): EvalReport {
    let results = []
    let startTime = now()

    for evalCase in suite.cases {
      let caseStart = now()

      // Call the prompt
      let request = CompletionRequest {
        messages: [{ role: "user", content: toJson(evalCase.input) }],
        tools: null,
        temperature: 0.0,  // Deterministic for eval
        max_tokens: 4096,
        stop: null,
        stream: false,
      }

      let response = self.model.complete(request)
      let output = response.content

      // Check expectations
      let failures = []
      for exp in evalCase.expectations {
        let failure = checkExpectation(exp, output)
        if failure {
          failures.push(failure)
        }
      }

      results.push(EvalResult {
        caseName: evalCase.name,
        passed: failures.isEmpty(),
        output: output.slice(0, 500),  // Truncate for storage
        failures: failures,
        latencyMs: now() - caseStart,
      })
    }

    let passed = results.filter(|r| r.passed).length
    let passRate = if results.length > 0 { (passed as Float) / (results.length as Float) } else { 0.0 }

    let report = EvalReport {
      suiteName: suite.name,
      results: results,
      passRate: passRate,
      totalMs: now() - startTime,
      baselineMet: passRate >= suite.minPassRate,
    }

    // Save report
    self.saveReport(report)
    return report
  }

  fn saveReport(self, report: EvalReport) {
    mkdirp("${cwd()}/${EVAL_DIR}")
    let path = "${cwd()}/${EVAL_DIR}/${report.suiteName}.last.json"
    writeFile(path, toJson(report, indent: 2))
  }
}

// Check a single expectation against output
fn checkExpectation(exp: Expectation, output: String): String? {
  match exp.kind {
    "must_contain" => {
      for val in (exp.values ?? []) {
        if !output.contains(val) {
          return "Expected output to contain '${val}'"
        }
      }
    }
    "must_not_contain" => {
      for val in (exp.values ?? []) {
        if output.contains(val) {
          return "Expected output NOT to contain '${val}'"
        }
      }
    }
    "max_lines" => {
      let lines = output.split("\n").length
      if lines > (exp.value ?? 999999) {
        return "Expected max ${exp.value} lines, got ${lines}"
      }
    }
    "min_lines" => {
      let lines = output.split("\n").length
      if lines < (exp.value ?? 0) {
        return "Expected min ${exp.value} lines, got ${lines}"
      }
    }
    "matches_pattern" => {
      if exp.pattern && !output.match(exp.pattern) {
        return "Output did not match pattern '${exp.pattern}'"
      }
    }
    _ => {}
  }
  return null
}

// Built-in evaluation suite for the category classifier
pub fn classifyEvalSuite(): EvalSuite {
  return EvalSuite {
    name: "classify_accuracy",
    promptName: "classify_category",
    cases: [
      EvalCase {
        name: "read_request",
        input: { user_message: "show me the contents of main.ms" },
        expectations: [Expectation { kind: "must_contain", values: ["read"], value: null, pattern: null }],
      },
      EvalCase {
        name: "edit_request",
        input: { user_message: "fix the bug on line 42" },
        expectations: [Expectation { kind: "must_contain", values: ["write"], value: null, pattern: null }],
      },
      EvalCase {
        name: "search_request",
        input: { user_message: "find all uses of parseJson" },
        expectations: [Expectation { kind: "must_contain", values: ["search"], value: null, pattern: null }],
      },
      EvalCase {
        name: "run_request",
        input: { user_message: "run the tests" },
        expectations: [Expectation { kind: "must_contain", values: ["run"], value: null, pattern: null }],
      },
      EvalCase {
        name: "plan_request",
        input: { user_message: "implement a full auth system with JWT, user registration, and password reset" },
        expectations: [Expectation { kind: "must_contain", values: ["plan"], value: null, pattern: null }],
      },
    ],
    minPassRate: 0.80,
  }
}

// Format an eval report for terminal display
pub fn formatReport(report: EvalReport): String {
  let lines = []
  lines.push("Evaluation: ${report.suiteName}")
  lines.push("Pass rate: ${(report.passRate * 100).toFixed(0)}% (baseline: ${if report.baselineMet { "✅ met" } else { "❌ FAILED" }})")
  lines.push("Duration: ${report.totalMs}ms")
  lines.push("")

  for result in report.results {
    let icon = if result.passed { "✅" } else { "❌" }
    lines.push("  ${icon} ${result.caseName} (${result.latencyMs}ms)")
    for failure in result.failures {
      lines.push("     └─ ${failure}")
    }
  }

  return lines.join("\n")
}
