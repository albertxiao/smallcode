// SmallCode - Built-in Hooks
// Default hooks that ship with SmallCode

import { EventBus } from "../core/event_bus"
import { exec } from "std/process"
import { cwd, pathExists } from "std/env"

pub struct BuiltinHooks {
  eventBus: EventBus
}

pub impl BuiltinHooks {
  pub fn new(eventBus: EventBus): BuiltinHooks {
    let hooks = BuiltinHooks { eventBus: eventBus }
    hooks.register()
    return hooks
  }

  fn register(self) {
    // Auto-format after edits (if a formatter is detected)
    self.eventBus.on("tool.complete", |data| {
      let name = data.get("name") as String
      if name != "patch" && name != "write_file" { return }
      
      // Try to detect and run formatter
      let dir = cwd()
      if pathExists("${dir}/.prettierrc") || pathExists("${dir}/biome.json") {
        // Don't auto-format — too slow and noisy
        // Just note that it's available
      }
    })

    // Track file edits for undo capability
    self.eventBus.on("tool.start", |data| {
      let name = data.get("name") as String
      if name == "patch" || name == "write_file" {
        // Could snapshot file here for undo
        // For MVP, rely on git
      }
    })

    // Warn when context is getting full
    self.eventBus.on("context.eviction", |data| {
      let freed = data.get("freed") as Int
      let needed = data.get("needed") as Int
      if freed < needed {
        self.eventBus.emit("hook.warning", {
          message: "Context is very full. Consider starting a new session or clearing old context.",
        })
      }
    })
  }
}
