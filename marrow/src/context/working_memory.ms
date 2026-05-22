// SmallCode - Working Memory
// Persistent scratchpad that survives across turns
// Compensates for small models' limited internal reasoning

import { BudgetEngine } from "./budget"
import { readFile, writeFile, pathExists } from "std/fs"
import { cwd } from "std/env"

const MEMORY_FILE = ".smallcode/memory.md"

pub struct WorkingMemory {
  content: String
  maxTokens: Int
  dirty: Bool
}

pub impl WorkingMemory {
  pub fn new(maxTokens: Int): WorkingMemory {
    return WorkingMemory {
      content: "",
      maxTokens: maxTokens,
      dirty: false,
    }
  }

  // Load from disk (if exists)
  pub fn load(self) {
    let path = "${cwd()}/${MEMORY_FILE}"
    if pathExists(path) {
      self.content = readFile(path)
      // Enforce token limit on load
      self.truncateToFit()
    }
  }

  // Save to disk
  pub fn save(self) {
    if !self.dirty { return }
    let path = "${cwd()}/${MEMORY_FILE}"
    writeFile(path, self.content)
    self.dirty = false
  }

  // Get current memory content (for injecting into context)
  pub fn get(self): String {
    if self.content.isEmpty() {
      return ""
    }
    return "<working_memory>\n${self.content}\n</working_memory>"
  }

  // Set memory content (model writes to this)
  pub fn set(self, content: String) {
    self.content = content
    self.truncateToFit()
    self.dirty = true
  }

  // Append to memory
  pub fn append(self, text: String) {
    if self.content.isEmpty() {
      self.content = text
    } else {
      self.content = "${self.content}\n${text}"
    }
    self.truncateToFit()
    self.dirty = true
  }

  // Clear a specific section (by header)
  pub fn clearSection(self, header: String) {
    let lines = self.content.split("\n")
    let result = []
    let skipping = false

    for line in lines {
      if line.startsWith("## ${header}") {
        skipping = true
        continue
      }
      if skipping && line.startsWith("## ") {
        skipping = false
      }
      if !skipping {
        result.push(line)
      }
    }

    self.content = result.join("\n").trim()
    self.dirty = true
  }

  // Clear all memory
  pub fn clear(self) {
    self.content = ""
    self.dirty = true
  }

  // Get token usage
  pub fn tokenCount(self): Int {
    return BudgetEngine.countTokens(self.content)
  }

  // Check if memory is empty
  pub fn isEmpty(self): Bool {
    return self.content.trim().isEmpty()
  }

  fn truncateToFit(self) {
    while BudgetEngine.countTokens(self.content) > self.maxTokens {
      // Remove oldest content (top lines) until we fit
      let lines = self.content.split("\n")
      if lines.length <= 1 {
        self.content = self.content.slice(0, self.maxTokens * 4) // rough char estimate
        break
      }
      lines.removeFirst()
      self.content = lines.join("\n")
    }
  }
}
