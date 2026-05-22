// SmallCode — Bayesian Tool Scorer (ARK-inspired)
// Tracks success/failure per tool per task_type
// Scores inform tool selection: proven tools rank higher, broken ones get demoted
// Learning persists across sessions via .smallcode/tool_scores.json

import { readFile, writeFile, pathExists, mkdirp } from "std/fs"
import { cwd } from "std/env"

const SCORES_FILE = ".smallcode/tool_scores.json"
const EXPLORATION_BONUS = 0.15   // New tools get a chance to compete
const CONFIDENCE_CAP = 0.95      // Prevent bias from locking out tools
const DECAY_FACTOR = 0.98        // Slight decay per session to prevent stale scores

pub struct ToolScore {
  tool_name: String
  task_type: String
  success_count: Int
  failure_count: Int
  total_calls: Int
  avg_latency_ms: Int
  confidence: Float      // Bayesian: success / (success + failure + 2) — Laplace smoothed
  last_error: String?
}

pub struct ToolScorer {
  scores: Map<String, ToolScore>  // key = "tool_name:task_type"
}

pub impl ToolScorer {
  pub fn new(): ToolScorer {
    let scorer = ToolScorer { scores: {} }
    scorer.load()
    return scorer
  }

  // Record a successful tool call
  pub fn recordSuccess(self, toolName: String, taskType: String, latencyMs: Int) {
    let key = "${toolName}:${taskType}"
    let score = self.getOrCreate(key, toolName, taskType)
    score.success_count += 1
    score.total_calls += 1
    score.avg_latency_ms = (score.avg_latency_ms * (score.total_calls - 1) + latencyMs) / score.total_calls
    score.confidence = self.computeConfidence(score)
    score.last_error = null
    self.save()
  }

  // Record a failed tool call
  pub fn recordFailure(self, toolName: String, taskType: String, error: String) {
    let key = "${toolName}:${taskType}"
    let score = self.getOrCreate(key, toolName, taskType)
    score.failure_count += 1
    score.total_calls += 1
    score.confidence = self.computeConfidence(score)
    score.last_error = error
    self.save()
  }

  // Get the composite score for a tool on a task type (0.0 - 1.0)
  pub fn getScore(self, toolName: String, taskType: String): Float {
    let key = "${toolName}:${taskType}"
    if !self.scores.has(key) {
      // Unknown tool — give exploration bonus
      return 0.5 + EXPLORATION_BONUS
    }
    let score = self.scores.get(key)
    return min(score.confidence, CONFIDENCE_CAP)
  }

  // Get the best tool for a task type (highest scoring)
  pub fn bestToolFor(self, taskType: String, candidates: List<String>): String? {
    let best: String? = null
    let bestScore: Float = 0.0

    for tool in candidates {
      let s = self.getScore(tool, taskType)
      if s > bestScore {
        bestScore = s
        best = tool
      }
    }
    return best
  }

  // Should we avoid this tool? (>50% failure rate with enough data)
  pub fn shouldAvoid(self, toolName: String, taskType: String): Bool {
    let key = "${toolName}:${taskType}"
    if !self.scores.has(key) { return false }
    let score = self.scores.get(key)
    return score.total_calls >= 3 && score.confidence < 0.35
  }

  // Get summary for display
  pub fn summary(self): String {
    let lines = []
    for (key, score) in self.scores {
      let pct = (score.confidence * 100).toFixed(0)
      let status = if score.confidence >= 0.7 { "✓" } else if score.confidence >= 0.4 { "~" } else { "✗" }
      lines.push("  ${status} ${score.tool_name}:${score.task_type} — ${pct}% (${score.success_count}/${score.total_calls})")
    }
    if lines.isEmpty() { return "  No tool history yet." }
    return lines.sort().join("\n")
  }

  // Bayesian confidence: Laplace-smoothed success rate
  fn computeConfidence(self, score: ToolScore): Float {
    // (successes + 1) / (total + 2) — Laplace smoothing
    return (score.success_count + 1).toFloat() / (score.total_calls + 2).toFloat()
  }

  fn getOrCreate(self, key: String, toolName: String, taskType: String): ToolScore {
    if !self.scores.has(key) {
      self.scores.set(key, ToolScore {
        tool_name: toolName,
        task_type: taskType,
        success_count: 0,
        failure_count: 0,
        total_calls: 0,
        avg_latency_ms: 0,
        confidence: 0.5,
        last_error: null,
      })
    }
    return self.scores.get(key)
  }

  fn load(self) {
    let path = "${cwd()}/${SCORES_FILE}"
    if pathExists(path) {
      let content = readFile(path)
      self.scores = parseJson(content)
    }
  }

  fn save(self) {
    mkdirp("${cwd()}/.smallcode")
    let path = "${cwd()}/${SCORES_FILE}"
    writeFile(path, toJson(self.scores, indent: 2))
  }
}

fn min(a: Float, b: Float): Float { if a < b { return a } else { return b } }
