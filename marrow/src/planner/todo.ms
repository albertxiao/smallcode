// SmallCode - TODO Task Manager
// Manages the TODO.md file that externalizes the model's plan
// The model reads this each turn to know what step it's on

import { readFile, writeFile, pathExists, mkdirp } from "std/fs"
import { cwd } from "std/env"

const TODO_PATH = ".smallcode/TODO.md"

pub struct TaskItem {
  number: Int
  description: String
  status: String        // "pending" | "in_progress" | "done" | "failed"
  retries: Int
  error: String?
}

pub struct Todo {
  tasks: List<TaskItem>
}

pub impl Todo {
  pub fn new(): Todo {
    let todo = Todo { tasks: [] }
    todo.load()
    return todo
  }

  // Load from disk
  pub fn load(self) {
    let path = "${cwd()}/${TODO_PATH}"
    if !pathExists(path) { return }

    let content = readFile(path)
    self.tasks = parseTodoFile(content)
  }

  // Save to disk
  pub fn save(self) {
    let path = "${cwd()}/${TODO_PATH}"
    mkdirp("${cwd()}/.smallcode")
    writeFile(path, self.render())
  }

  // Add a task
  pub fn add(self, task: TaskItem) {
    self.tasks.push(task)
  }

  // Get next pending task
  pub fn nextPending(self): TaskItem? {
    return self.tasks.find(|t| t.status == "pending" || t.status == "in_progress")
  }

  // Mark a task as complete
  pub fn complete(self, num: Int) {
    let task = self.tasks.find(|t| t.number == num)
    if task { task.status = "done" }
    // Auto-start next
    let next = self.nextPending()
    if next { next.status = "in_progress" }
  }

  // Mark a task as failed
  pub fn fail(self, num: Int, error: String) {
    let task = self.tasks.find(|t| t.number == num)
    if task {
      task.status = "failed"
      task.error = error
    }
  }

  // Increment retry count
  pub fn retry(self, num: Int) {
    let task = self.tasks.find(|t| t.number == num)
    if task { task.retries += 1 }
  }

  // Get retry count for a task
  pub fn retryCount(self, num: Int): Int {
    let task = self.tasks.find(|t| t.number == num)
    return if task { task.retries } else { 0 }
  }

  // Total tasks
  pub fn total(self): Int { return self.tasks.length }

  // Completed tasks
  pub fn completed(self): Int { return self.tasks.filter(|t| t.status == "done").length }

  // Is empty
  pub fn isEmpty(self): Bool { return self.tasks.isEmpty() }

  // Clear all tasks
  pub fn clear(self) { self.tasks = [] }

  // Format as compact string for context injection
  pub fn format(self): String {
    return self.tasks.map(|t| {
      let marker = match t.status {
        "done" => "[x]"
        "in_progress" => "[>]"
        "failed" => "[!]"
        _ => "[ ]"
      }
      let suffix = if t.error { " (failed: ${t.error})" } else { "" }
      return "${marker} ${t.number}. ${t.description}${suffix}"
    }).join("\n")
  }

  // Render as TODO.md content
  pub fn render(self): String {
    let lines = ["# SmallCode Task Plan", ""]
    
    for task in self.tasks {
      let checkbox = match task.status {
        "done" => "- [x]"
        "failed" => "- [!]"
        _ => "- [ ]"
      }
      let line = "${checkbox} ${task.description}"
      if task.error {
        line += " *(failed: ${task.error})*"
      }
      lines.push(line)
    }

    let done = self.completed()
    let total = self.total()
    lines.push("")
    lines.push("Progress: ${done}/${total}")

    return lines.join("\n")
  }
}

// Parse a TODO.md file back into TaskItems
fn parseTodoFile(content: String): List<TaskItem> {
  let lines = content.split("\n")
  let tasks = []
  let num = 1

  for line in lines {
    let trimmed = line.trim()
    
    // Match "- [x] task" or "- [ ] task" or "- [!] task"
    let match = trimmed.match("^-\\s*\\[([ x!>])\\]\\s*(.+)")
    if match {
      let status = match match[1] {
        "x" => "done"
        "!" => "failed"
        ">" => "in_progress"
        _ => "pending"
      }
      let description = match[2].trim()
      // Remove error suffix if present
      let error = null
      let errMatch = description.match("\\s*\\*\\(failed:\\s*(.+?)\\)\\*$")
      if errMatch {
        error = errMatch[1]
        description = description.replace(errMatch[0], "").trim()
      }

      tasks.push(TaskItem {
        number: num,
        description: description,
        status: status,
        retries: 0,
        error: error,
      })
      num += 1
    }
  }

  return tasks
}
