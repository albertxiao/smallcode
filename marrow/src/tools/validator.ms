// SmallCode - Tool Call Validator
// Validates and auto-repairs malformed tool calls from small models
// Key insight: small models often produce *almost* correct output

import { ToolDef, ToolParam } from "./registry"

pub struct ToolValidator {
  repairAttempts: Int
}

pub impl ToolValidator {
  pub fn new(): ToolValidator {
    return ToolValidator { repairAttempts: 0 }
  }

  // Validate arguments against tool definition
  // Returns null if valid, error string if invalid
  pub fn validate(self, tool: ToolDef, args: Map<String, Any>): String? {
    let errors = []

    // Check required parameters
    for param in tool.parameters {
      if param.required && !args.has(param.name) {
        // Try fuzzy match (model might use slightly wrong name)
        let fuzzyMatch = findFuzzyKey(args, param.name)
        if fuzzyMatch {
          // Auto-repair: rename the key
          args.set(param.name, args.get(fuzzyMatch))
          args.remove(fuzzyMatch)
        } else {
          errors.push("Missing required parameter '${param.name}'")
        }
      }
    }

    // Type coercion for common mistakes
    for param in tool.parameters {
      if !args.has(param.name) { continue }
      let value = args.get(param.name)

      match param.type {
        "int" => {
          if typeof(value) == "string" {
            let parsed = parseInt(value)
            if parsed != null {
              args.set(param.name, parsed)
            } else {
              errors.push("Parameter '${param.name}' must be an integer, got '${value}'")
            }
          }
        }
        "bool" => {
          if typeof(value) == "string" {
            match value.toLowerCase() {
              "true" | "yes" | "1" => args.set(param.name, true)
              "false" | "no" | "0" => args.set(param.name, false)
              _ => errors.push("Parameter '${param.name}' must be a boolean")
            }
          }
        }
        "string" => {
          // Coerce non-strings to string
          if typeof(value) != "string" {
            args.set(param.name, toString(value))
          }
        }
        _ => {}
      }
    }

    // Warn about unknown parameters (don't error — model might be creative)
    let knownParams = tool.parameters.map(|p| p.name)
    let unknownParams = args.keys().filter(|k| !knownParams.contains(k))
    // Just remove unknown params silently — small models often add extra fields

    for unknown in unknownParams {
      args.remove(unknown)
    }

    if errors.isEmpty() {
      return null
    }

    return errors.join("; ")
  }

  // Generate a repair hint for the model when validation fails
  pub fn repairHint(self, tool: ToolDef, error: String): String {
    self.repairAttempts += 1

    let paramList = tool.parameters
      .filter(|p| p.required)
      .map(|p| "  ${p.name} (${p.type}): ${p.description}")
      .join("\n")

    return "Tool call error: ${error}\n\nRequired parameters for '${tool.id}':\n${paramList}\n\nPlease try again with correct parameters."
  }

  // Check if we've exhausted repair attempts
  pub fn shouldGiveUp(self): Bool {
    return self.repairAttempts >= 3
  }

  // Reset repair counter (after successful call)
  pub fn resetRepairs(self) {
    self.repairAttempts = 0
  }
}

// Try to parse JSON from a potentially malformed string
pub fn repairJson(text: String): Map<String, Any>? {
  // Try as-is first
  try { return parseJson(text) } catch {}

  // Remove trailing comma before }
  let fixed = text.replace(",\\s*}", "}")
  try { return parseJson(fixed) } catch {}

  // Try wrapping in braces if missing
  if !text.startsWith("{") {
    try { return parseJson("{${text}}") } catch {}
  }

  // Try removing markdown code fences
  let cleaned = text
    .replace("```json", "")
    .replace("```", "")
    .trim()
  try { return parseJson(cleaned) } catch {}

  // Try extracting the first {...} block
  let match = text.match("(\\{[\\s\\S]*\\})")
  if match {
    try { return parseJson(match[1]) } catch {}
  }

  return null
}

// Fuzzy key matching for parameter names
fn findFuzzyKey(map: Map<String, Any>, target: String): String? {
  let targetLower = target.toLowerCase().replace("_", "")

  for key in map.keys() {
    let keyLower = key.toLowerCase().replace("_", "").replace("-", "")
    // Exact match after normalization
    if keyLower == targetLower { return key }
    // Substring match
    if keyLower.contains(targetLower) || targetLower.contains(keyLower) { return key }
    // Edit distance ≤ 2
    if editDistance(keyLower, targetLower) <= 2 { return key }
  }

  return null
}

// Simple Levenshtein distance
fn editDistance(a: String, b: String): Int {
  if a.length == 0 { return b.length }
  if b.length == 0 { return a.length }

  let matrix = []
  for i in range(0, a.length + 1) {
    matrix.push([])
    for j in range(0, b.length + 1) {
      if i == 0 { matrix[i].push(j) }
      else if j == 0 { matrix[i].push(i) }
      else { matrix[i].push(0) }
    }
  }

  for i in range(1, a.length + 1) {
    for j in range(1, b.length + 1) {
      let cost = if a[i-1] == b[j-1] { 0 } else { 1 }
      matrix[i][j] = min3(
        matrix[i-1][j] + 1,
        matrix[i][j-1] + 1,
        matrix[i-1][j-1] + cost,
      )
    }
  }

  return matrix[a.length][b.length]
}

fn min3(a: Int, b: Int, c: Int): Int {
  if a <= b && a <= c { return a }
  if b <= c { return b }
  return c
}
