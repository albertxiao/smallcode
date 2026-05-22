// SmallCode - Hook Loader
// Loads hook definitions from config files and registers them

import { readFile, pathExists, glob } from "std/fs"
import { parse as parseJson } from "std/json"
import { cwd, homedir } from "std/env"
import { EventBus } from "../core/event_bus"
import { HookRunner } from "./runner"

pub struct HookDef {
  name: String
  version: String
  description: String?
  when: HookTrigger
  then: HookAction
}

pub struct HookTrigger {
  type: String            // "pre_tool" | "post_tool" | "pre_edit" | "post_edit" | "session_start" | "session_end" | "step_complete"
  patterns: List<String>? // File patterns for file-based triggers
  toolNames: List<String>?  // Tool names for tool-based triggers
}

pub struct HookAction {
  type: String            // "run_command" | "inject_prompt"
  command: String?        // For run_command
  prompt: String?         // For inject_prompt
}

pub struct HookLoader {
  hooks: List<HookDef>
  runner: HookRunner
}

pub impl HookLoader {
  pub fn new(eventBus: EventBus): HookLoader {
    let loader = HookLoader {
      hooks: [],
      runner: HookRunner.new(eventBus),
    }
    loader.loadAll()
    return loader
  }

  // Load hooks from all config locations
  pub fn loadAll(self) {
    // Project-level hooks
    let projectDir = "${cwd()}/.smallcode/hooks"
    self.loadFromDir(projectDir)

    // User-level hooks
    let userDir = "${homedir()}/.config/smallcode/hooks"
    self.loadFromDir(userDir)

    // Register all loaded hooks with the runner
    for hook in self.hooks {
      self.runner.register(hook)
    }
  }

  fn loadFromDir(self, dir: String) {
    if !pathExists(dir) { return }

    let files = glob("*.json", { cwd: dir })
    for file in files {
      let content = readFile("${dir}/${file}")
      try {
        let parsed = parseJson(content) as HookDef
        self.hooks.push(parsed)
      } catch e {
        println("[warn] Failed to load hook ${file}: ${e}")
      }
    }
  }

  // Get all loaded hooks
  pub fn list(self): List<HookDef> {
    return self.hooks
  }
}
