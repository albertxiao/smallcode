// SmallCode - Permission System
// Tiered auto-approve / ask / deny for tool invocations
// Small models need guardrails — prevent destructive actions without asking

pub struct PermissionPolicy {
  rules: List<PermissionRule>
  defaultAction: String     // "ask" | "allow" | "deny"
}

pub struct PermissionRule {
  pattern: String           // tool name or glob pattern
  action: String            // "allow" | "ask" | "deny"
  reason: String?           // shown to user when asking
  conditions: List<String>? // additional conditions (path patterns, etc.)
}

pub enum PermissionDecision {
  Allow
  Deny { reason: String }
  Ask { prompt: String }
}

pub struct PermissionManager {
  policy: PermissionPolicy
  sessionOverrides: Map<String, String>  // tool → "allow" | "deny" (user decisions this session)
  autoApproveAll: Bool
}

pub impl PermissionManager {
  pub fn new(autoApprove: Bool): PermissionManager {
    return PermissionManager {
      policy: defaultPolicy(),
      sessionOverrides: {},
      autoApproveAll: autoApprove,
    }
  }

  // Check if a tool call is allowed
  pub fn check(self, toolName: String, args: Map<String, Any>): PermissionDecision {
    if self.autoApproveAll {
      return PermissionDecision.Allow
    }

    // Check session overrides first
    if self.sessionOverrides.has(toolName) {
      match self.sessionOverrides.get(toolName) {
        "allow" => return PermissionDecision.Allow
        "deny" => return PermissionDecision.Deny { reason: "Denied by user this session" }
        _ => {}
      }
    }

    // Check rules in order (first match wins)
    for rule in self.policy.rules {
      if matchesRule(toolName, args, rule) {
        match rule.action {
          "allow" => return PermissionDecision.Allow
          "deny" => return PermissionDecision.Deny { reason: rule.reason ?? "Policy denied" }
          "ask" => return PermissionDecision.Ask { prompt: rule.reason ?? "Allow ${toolName}?" }
          _ => {}
        }
      }
    }

    // Default action
    match self.policy.defaultAction {
      "allow" => return PermissionDecision.Allow
      "deny" => return PermissionDecision.Deny { reason: "Default policy: deny" }
      _ => return PermissionDecision.Ask { prompt: "Allow ${toolName}?" }
    }
  }

  // Record user decision for this session
  pub fn recordDecision(self, toolName: String, allowed: Bool) {
    self.sessionOverrides.set(toolName, if allowed { "allow" } else { "deny" })
  }

  // Record "allow all" for a tool category
  pub fn allowCategory(self, category: String) {
    let tools = match category {
      "read" => ["read_file", "find_files", "search", "symbols", "project_overview"]
      "write" => ["write_file", "patch"]
      "run" => ["bash"]
      "plan" => ["memory", "plan"]
      _ => []
    }
    for tool in tools {
      self.sessionOverrides.set(tool, "allow")
    }
  }
}

// Default permission policy — tuned for small model safety
fn defaultPolicy(): PermissionPolicy {
  return PermissionPolicy {
    rules: [
      // Always allow reads — they're safe and context-building
      PermissionRule { pattern: "read_file", action: "allow", reason: null, conditions: null },
      PermissionRule { pattern: "find_files", action: "allow", reason: null, conditions: null },
      PermissionRule { pattern: "search", action: "allow", reason: null, conditions: null },
      PermissionRule { pattern: "symbols", action: "allow", reason: null, conditions: null },
      PermissionRule { pattern: "project_overview", action: "allow", reason: null, conditions: null },

      // Allow working memory and plan — internal tools
      PermissionRule { pattern: "memory", action: "allow", reason: null, conditions: null },
      PermissionRule { pattern: "plan", action: "allow", reason: null, conditions: null },

      // Ask for writes — model might make mistakes
      PermissionRule { pattern: "write_file", action: "ask", reason: "Create/overwrite file", conditions: null },
      PermissionRule { pattern: "patch", action: "ask", reason: "Edit file", conditions: null },

      // Ask for shell commands — could be destructive
      PermissionRule { pattern: "bash", action: "ask", reason: "Run shell command", conditions: null },

      // Deny web tools by default (privacy)
      PermissionRule { pattern: "web_search", action: "ask", reason: "Internet search", conditions: null },
      PermissionRule { pattern: "web_fetch", action: "ask", reason: "Fetch URL", conditions: null },
    ],
    defaultAction: "ask",
  }
}

fn matchesRule(toolName: String, args: Map<String, Any>, rule: PermissionRule): Bool {
  // Simple name match or glob
  if rule.pattern == toolName { return true }
  if rule.pattern == "*" { return true }
  if rule.pattern.endsWith("*") {
    let prefix = rule.pattern.slice(0, rule.pattern.length - 1)
    if toolName.startsWith(prefix) { return true }
  }

  // Check additional conditions
  if rule.conditions {
    for cond in rule.conditions {
      // Path-based conditions: "path:*.env" means deny if path matches
      if cond.startsWith("path:") {
        let pattern = cond.slice(5)
        let path = args.get("path") as String? ?? ""
        if path.match(pattern) { return true }
      }
    }
  }

  return false
}
