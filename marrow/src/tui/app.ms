// SmallCode - TUI Application
// Minimal terminal UI focused on readability and quick interaction
// Optimized for the coding workflow: input → streaming output → approve/reject

import { Session } from "../core/session"
import { EventBus } from "../core/event_bus"
import { TuiConfig } from "../core/config"
import { Input } from "./input"
import { Output } from "./output"
import { StatusBar } from "./status"
import { DiffView } from "./diff_view"
import { Terminal, clearScreen, moveCursor, setColor, resetColor } from "std/terminal"

const LOGO = "⚡ SmallCode"

pub struct App {
  session: Session
  config: TuiConfig
  terminal: Terminal
  input: Input
  output: Output
  status: StatusBar
  diffView: DiffView
  running: Bool
}

pub impl App {
  pub fn new(session: Session, config: TuiConfig): App {
    let terminal = Terminal.new()
    let app = App {
      session: session,
      config: config,
      terminal: terminal,
      input: Input.new(terminal),
      output: Output.new(terminal),
      status: StatusBar.new(terminal, session, config),
      diffView: DiffView.new(terminal),
      running: false,
    }

    // Wire up event handlers for streaming
    app.wireEvents()
    return app
  }

  pub fn run(self) {
    self.running = true
    self.showWelcome()
    self.status.render()

    while self.running {
      // Get user input
      let userInput = self.input.read()

      // Handle special commands
      if userInput.startsWith("/") {
        self.handleCommand(userInput)
        continue
      }

      if userInput.isEmpty() { continue }

      // Run through session
      self.output.startResponse()
      let response = self.session.runOnce(userInput)
      self.output.endResponse()
      self.status.render()
    }

    self.cleanup()
  }

  fn wireEvents(self) {
    let eventBus = self.session.eventBus

    // Streaming tokens
    eventBus.on("model.token", |data| {
      self.output.writeToken(data.get("token") as String)
    })

    // Tool execution
    eventBus.on("tool.start", |data| {
      let name = data.get("name") as String
      self.output.writeToolStart(name)
    })

    eventBus.on("tool.complete", |data| {
      let name = data.get("name") as String
      self.output.writeToolComplete(name)
    })

    eventBus.on("tool.error", |data| {
      let name = data.get("name") as String
      let error = data.get("error") as String
      self.output.writeToolError(name, error)
    })

    // Early stop
    eventBus.on("model.early_stop", |_| {
      self.output.writeWarning("(output stopped: repetition detected)")
    })

    // Context eviction
    eventBus.on("context.eviction", |data| {
      let freed = data.get("freed") as Int
      self.output.writeInfo("(freed ${freed} tokens from context)")
    })
  }

  fn handleCommand(self, cmd: String) {
    let parts = cmd.split(" ")
    let command = parts[0]

    match command {
      "/quit" | "/exit" | "/q" => {
        self.running = false
      }
      "/clear" => {
        self.session.reset()
        clearScreen()
        self.showWelcome()
      }
      "/stats" => {
        let stats = self.session.stats()
        self.output.writeInfo("Model: ${stats.model}")
        self.output.writeInfo("Turns: ${stats.turns}")
        self.output.writeInfo("Context: ${stats.context_usage}")
        self.output.writeInfo("Memory: ${stats.memory_tokens} tokens")
      }
      "/memory" => {
        let content = self.session.memory.get()
        if content.isEmpty() {
          self.output.writeInfo("(working memory is empty)")
        } else {
          self.output.writeInfo(content)
        }
      }
      "/plan" => {
        if self.session.planner && self.session.planner.hasActivePlan() {
          self.output.writeInfo(self.session.planner.todo.format())
        } else {
          self.output.writeInfo("(no active plan)")
        }
      }
      "/model" => {
        if parts.length > 1 {
          self.output.writeInfo("Model switching not yet implemented in session")
        } else {
          self.output.writeInfo("Current: ${self.session.model.name()}")
        }
      }
      "/sessions" => {
        let store = SessionStore.new()
        let sessions = store.list()
        if sessions.isEmpty() {
          self.output.writeInfo("No saved sessions")
        } else {
          self.output.writeInfo("Saved sessions:")
          for s in sessions {
            let status = match s.status {
              "active" => "🟢"
              "paused" => "⏸"
              _ => "✓"
            }
            self.output.writeInfo("  ${status} ${s.id} (${s.turns} turns, ${s.model}) ${s.preview}")
          }
        }
      }
      "/save" => {
        let store = SessionStore.new()
        let snapshot = createSnapshot(
          newSessionId(),
          self.session.model.name(),
          self.session.config.model.provider,
          self.session.turnCount,
          self.session.compactor.messages,
          self.session.memory,
          null,
        )
        store.save(snapshot)
        self.output.writeInfo("Session saved: ${snapshot.id}")
      }
      "/eval" => {
        let suiteName = if parts.length > 1 { parts[1] } else { "classify_accuracy" }
        self.output.writeInfo("Running evaluation: ${suiteName}...")
        let evalRunner = EvaluationRunner.new(self.session.model, self.session.eventBus)
        let suite = classifyEvalSuite()
        let report = evalRunner.run(suite)
        self.output.writeInfo(formatReport(report))
      }
      "/trace" => {
        self.output.writeInfo("Current trace: ${self.session.traces?.currentTraceId ?? "none"}")
        self.output.writeInfo("Spans recorded: ${self.session.traces?.spans.length ?? 0}")
      }
      "/budget" => {
        let tracker = BudgetTracker.new(self.session.eventBus)
        self.output.writeInfo("Budget: ${tracker.summary()}")
      }
      "/help" => {
        self.showHelp()
      }
      _ => {
        self.output.writeError("Unknown command: ${command}. Type /help for available commands.")
      }
    }
    self.status.render()
  }

  fn showWelcome(self) {
    println("")
    println("  ${LOGO} v0.1.0")
    println("  Model: ${self.session.model.name()}")
    println("  Context: ${self.session.budget.formatUsage()}")
    println("  Type /help for commands, /quit to exit")
    println("")
  }

  fn showHelp(self) {
    self.output.writeInfo("Commands:")
    self.output.writeInfo("  /quit, /q     Exit SmallCode")
    self.output.writeInfo("  /clear        Reset conversation")
    self.output.writeInfo("  /stats        Show session statistics")
    self.output.writeInfo("  /memory       Show working memory")
    self.output.writeInfo("  /plan         Show current task plan")
    self.output.writeInfo("  /model        Show/switch model")
    self.output.writeInfo("  /sessions     List saved sessions")
    self.output.writeInfo("  /save         Save current session")
    self.output.writeInfo("  /eval [name]  Run prompt evaluation")
    self.output.writeInfo("  /trace        Show current trace info")
    self.output.writeInfo("  /budget       Show token budget status")
    self.output.writeInfo("  /help         Show this help")
  }

  fn cleanup(self) {
    self.session.memory.save()
    println("\n  Goodbye!\n")
  }
}
