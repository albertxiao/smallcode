// SmallCode - Plan Tool
// Allows the model to read/update its task plan

import { ToolResult, ToolContext } from "../registry"
import { Todo, TaskItem } from "../../planner/todo"

// Shared todo instance
let todo: Todo? = null

pub fn setTodoInstance(t: Todo) {
  todo = t
}

pub fn execute(args: Map<String, Any>, ctx: ToolContext): ToolResult {
  if !todo {
    todo = Todo.new()
  }

  let action = args.get("action") as String
  let task = args.get("task") as String?

  match action {
    "read" => {
      if todo.isEmpty() {
        return ToolResult {
          output: "(no active plan)",
          metadata: { tasks: 0 },
          error: null,
        }
      }
      return ToolResult {
        output: todo.format(),
        metadata: { tasks: todo.total(), completed: todo.completed() },
        error: null,
      }
    }
    "add" => {
      if !task {
        return ToolResult { output: "", metadata: null, error: "Task description required for 'add' action" }
      }
      let num = todo.total() + 1
      todo.add(TaskItem {
        number: num,
        description: task,
        status: "pending",
        retries: 0,
        error: null,
      })
      todo.save()
      return ToolResult {
        output: "Added task ${num}: ${task}",
        metadata: { task_number: num },
        error: null,
      }
    }
    "complete" => {
      if !task {
        return ToolResult { output: "", metadata: null, error: "Task number required for 'complete' action" }
      }
      let num = parseInt(task)
      if !num || num < 1 || num > todo.total() {
        return ToolResult { output: "", metadata: null, error: "Invalid task number: ${task}" }
      }
      todo.complete(num)
      todo.save()
      let next = todo.nextPending()
      let nextMsg = if next { " Next: ${next.number}. ${next.description}" } else { " All tasks complete!" }
      return ToolResult {
        output: "Completed task ${num}.${nextMsg}",
        metadata: { completed: num, remaining: todo.total() - todo.completed() },
        error: null,
      }
    }
    "clear" => {
      todo.clear()
      todo.save()
      return ToolResult {
        output: "Plan cleared",
        metadata: {},
        error: null,
      }
    }
    _ => {
      return ToolResult {
        output: "",
        metadata: null,
        error: "Unknown action '${action}'. Use: read, add, complete, clear",
      }
    }
  }
}
