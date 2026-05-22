// SmallCode - Task Planner
// Decomposes complex user requests into atomic steps
// Critical for small models that can't hold multi-step plans in working memory

import { ModelAdapter, ChatMessage, CompletionRequest } from "../model/adapter"
import { BudgetEngine } from "../context/budget"
import { Todo, TaskItem } from "./todo"
import { Validator as StepValidator } from "./validator"
import { EventBus } from "../core/event_bus"

pub struct Planner {
  model: ModelAdapter
  budget: BudgetEngine
  todo: Todo
  validator: StepValidator
  eventBus: EventBus
  autoDecompose: Bool
  maxRetries: Int
}

pub impl Planner {
  pub fn new(model: ModelAdapter, budget: BudgetEngine, eventBus: EventBus, config: PlannerConfig): Planner {
    return Planner {
      model: model,
      budget: budget,
      todo: Todo.new(),
      validator: StepValidator.new(config.validate_after_edit),
      eventBus: eventBus,
      autoDecompose: config.auto_plan,
      maxRetries: config.max_retries,
    }
  }

  // Determine if a request should be decomposed into steps
  pub fn shouldDecompose(self, userMessage: String): Bool {
    if !self.autoDecompose { return false }

    // Heuristics for multi-step tasks:
    let indicators = [
      "implement",
      "refactor",
      "add feature",
      "create",
      "build",
      "set up",
      "migrate",
      "convert",
      "fix all",
      "update all",
      "across",
      "multiple files",
    ]

    let lower = userMessage.toLowerCase()

    // Check for multi-step indicators
    let hasIndicator = indicators.any(|ind| lower.contains(ind))

    // Check message length (longer = more complex)
    let isLong = userMessage.length > 200

    // Check for numbered lists in the request
    let hasSteps = lower.match("\\d+\\.\\s") != null

    return hasIndicator || isLong || hasSteps
  }

  // Decompose a user request into atomic steps
  pub fn decompose(self, userMessage: String): List<TaskItem> {
    let prompt = "Break this coding task into numbered atomic steps. Each step should be a single action (read one file, edit one function, run one command). Be specific about which files and functions.

Task: ${userMessage}

Respond with ONLY a numbered list, nothing else. Example:
1. Read src/main.ms to understand current structure
2. Add import for new module at top of src/main.ms
3. Create src/utils/helper.ms with helper function
4. Run type checker to verify no errors"

    let request = CompletionRequest {
      messages: [
        ChatMessage { role: "user", content: prompt, tool_calls: null, tool_call_id: null, name: null },
      ],
      tools: null,
      temperature: 0.1,
      max_tokens: 1000,
      stop: null,
      stream: false,
    }

    let response = self.model.complete(request)
    let steps = parseSteps(response.content)

    // Store in todo
    for step in steps {
      self.todo.add(step)
    }
    self.todo.save()

    self.eventBus.emit("plan.created", { steps: steps.length })
    return steps
  }

  // Get the next pending step
  pub fn nextStep(self): TaskItem? {
    return self.todo.nextPending()
  }

  // Mark current step as complete
  pub fn completeStep(self, stepNum: Int) {
    self.todo.complete(stepNum)
    self.todo.save()
    self.eventBus.emit("plan.step", { step: stepNum, total: self.todo.total() })
  }

  // Get the current plan context for injection into model prompt
  pub fn contextPrompt(self): String {
    if self.todo.isEmpty() { return "" }

    let current = self.todo.nextPending()
    if !current { return "" }

    return "Current plan progress:
${self.todo.format()}

Focus on step ${current.number}: ${current.description}
Complete this step, then I'll move to the next one."
  }

  // Validate the result of a step (run lint/compile/test)
  pub fn validateStep(self): ValidationResult {
    return self.validator.run()
  }

  // Handle a failed step: revert and retry
  pub fn handleFailure(self, stepNum: Int, error: String): RetryAction {
    let retries = self.todo.retryCount(stepNum)
    if retries >= self.maxRetries {
      // Give up on this step, mark as failed
      self.todo.fail(stepNum, error)
      self.todo.save()
      return RetryAction.Skip
    }

    // Increment retry count and try again
    self.todo.retry(stepNum)
    self.todo.save()
    return RetryAction.Retry { error: error, attempt: retries + 1 }
  }

  // Clear the plan
  pub fn clear(self) {
    self.todo.clear()
  }

  // Check if there's an active plan
  pub fn hasActivePlan(self): Bool {
    return !self.todo.isEmpty() && self.todo.nextPending() != null
  }
}

pub enum RetryAction {
  Retry { error: String, attempt: Int }
  Skip
}

pub struct ValidationResult {
  passed: Bool
  errors: List<String>
  warnings: List<String>
}

// Parse numbered steps from model output
fn parseSteps(text: String): List<TaskItem> {
  let lines = text.split("\n")
  let steps = []
  let num = 1

  for line in lines {
    let trimmed = line.trim()
    // Match "1.", "1)", "- ", "* " prefixed lines
    let match = trimmed.match("^(?:\\d+[.)\\s]|[-*]\\s)(.+)")
    if match {
      steps.push(TaskItem {
        number: num,
        description: match[1].trim(),
        status: "pending",
        retries: 0,
        error: null,
      })
      num += 1
    }
  }

  return steps
}
