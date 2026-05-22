// SmallCode - Hook Runner
// Executes hooks when their trigger events fire

import { EventBus } from "../core/event_bus"
import { HookDef, HookAction } from "./loader"
import { exec } from "std/process"
import { cwd } from "std/env"

pub struct HookRunner {
  eventBus: EventBus
  hooks: Map<String, List<HookDef>>  // event type → hooks
}

pub impl HookRunner {
  pub fn new(eventBus: EventBus): HookRunner {
    return HookRunner {
      eventBus: eventBus,
      hooks: {},
    }
  }

  // Register a hook definition
  pub fn register(self, hook: HookDef) {
    let eventType = mapTriggerToEvent(hook.when.type)
    
    if !self.hooks.has(eventType) {
      self.hooks.set(eventType, [])
    }
    self.hooks.get(eventType).push(hook)

    // Subscribe to the event
    self.eventBus.on(eventType, |data| {
      self.executeHooks(eventType, data)
    })
  }

  // Execute all hooks for an event
  fn executeHooks(self, eventType: String, data: Map<String, Any>) {
    let hooks = self.hooks.get(eventType) ?? []
    
    for hook in hooks {
      // Check if this specific hook should fire (pattern matching)
      if !shouldFire(hook, data) { continue }

      // Execute the action
      match hook.then.type {
        "run_command" => {
          self.runCommand(hook.then.command ?? "", data)
        }
        "inject_prompt" => {
          // Emit a prompt injection event
          self.eventBus.emit("hook.prompt", {
            name: hook.name,
            prompt: hook.then.prompt ?? "",
          })
        }
        _ => {}
      }
    }
  }

  fn runCommand(self, command: String, data: Map<String, Any>) {
    // Substitute variables in command
    let cmd = command
    for (key, value) in data {
      cmd = cmd.replace("{${key}}", toString(value))
    }

    let result = exec(cmd, { cwd: cwd(), timeout: 30000, shell: true })
    if result.exitCode != 0 {
      self.eventBus.emit("hook.error", {
        command: cmd,
        error: result.stderr,
        exit_code: result.exitCode,
      })
    }
  }
}

// Map our trigger types to event bus event names
fn mapTriggerToEvent(triggerType: String): String {
  match triggerType {
    "pre_tool" => "tool.start"
    "post_tool" => "tool.complete"
    "pre_edit" => "tool.start"      // filtered to write tools
    "post_edit" => "tool.complete"   // filtered to write tools
    "session_start" => "session.start"
    "session_end" => "session.end"
    "step_complete" => "plan.step"
    _ => triggerType
  }
}

// Check if a hook's pattern matches the event data
fn shouldFire(hook: HookDef, data: Map<String, Any>): Bool {
  // File pattern matching
  if hook.when.patterns {
    let path = data.get("path") as String?
    if !path { return false }
    return hook.when.patterns.any(|pattern| matchGlob(path, pattern))
  }

  // Tool name matching
  if hook.when.toolNames {
    let toolName = data.get("name") as String?
    if !toolName { return false }
    return hook.when.toolNames.contains(toolName)
  }

  // No filters — always fire
  return true
}

fn matchGlob(path: String, pattern: String): Bool {
  // Simple glob matching: * matches anything, ** matches path separators too
  let regex = pattern
    .replace(".", "\\.")
    .replace("**", "GLOBSTAR")
    .replace("*", "[^/]*")
    .replace("GLOBSTAR", ".*")
  return path.match(regex) != null
}
