// SmallCode - Entry Point
// Terminal-native AI coding agent optimized for small LLMs

import { loadConfig } from "./config"
import { Session } from "../core/session"
import { createAdapter } from "../model/adapter"
import { ToolRegistry } from "../tools/registry"
import { ToolRouter } from "../tools/router"
import { BudgetEngine } from "../context/budget"
import { BudgetTracker } from "./budget_policy"
import { TraceWriter } from "./traces"
import { PromptCache } from "./prompt_cache"
import { SessionStore, newSessionId } from "./session_persistence"
import { MCPServer } from "./mcp_server"
import { EvaluationRunner, classifyEvalSuite, formatReport } from "./evaluation"
import { buildCognitionCtx } from "./runtime_bridge"
import { App } from "../tui/app"
import { EventBus } from "./event_bus"
import { parseArgs } from "std/cli"

const VERSION = "0.1.0"

fn main(args: List<String>) {
  let opts = parseArgs(args, {
    flags: {
      "help": { short: "h", type: "bool" },
      "version": { short: "v", type: "bool" },
      "config": { short: "c", type: "string" },
      "model": { short: "m", type: "string" },
      "provider": { short: "p", type: "string" },
      "non-interactive": { type: "bool" },
      "resume": { short: "r", type: "bool" },
      "mcp": { type: "bool" },
      "eval": { type: "string" },
      "trace": { type: "string" },
    }
  })

  if opts.help {
    printUsage()
    return
  }

  if opts.version {
    println("smallcode v${VERSION}")
    return
  }

  // Load configuration
  let config = loadConfig()

  // CLI overrides
  if opts.model {
    config.model.name = opts.model
  }
  if opts.provider {
    config.model.provider = opts.provider
  }

  // Initialize subsystems
  let eventBus = EventBus.new()
  let budget = BudgetEngine.new(config.context)
  let budgetPolicy = BudgetTracker.new(eventBus)
  let traces = TraceWriter.new(eventBus, true)
  let cache = PromptCache.new(true)
  let sessionStore = SessionStore.new()
  let cognitionCtx = buildCognitionCtx(eventBus)
  let model = createAdapter(config.model)
  let tools = ToolRegistry.new(config.tools)
  let router = ToolRouter.new(tools, budget)
  let session = Session.new(config, model, router, budget, eventBus)

  // MCP server mode
  if opts.mcp {
    let mcpServer = MCPServer.new(tools, budget, eventBus)
    mcpServer.setSession(session)
    mcpServer.runStdio()
    return
  }

  // Evaluation mode
  if opts.eval {
    let evalRunner = EvaluationRunner.new(model, eventBus)
    let suite = match opts.eval {
      "classify" | "classify_accuracy" => classifyEvalSuite()
      _ => {
        println("Unknown eval suite: ${opts.eval}. Available: classify_accuracy")
        return
      }
    }
    let report = evalRunner.run(suite)
    println(formatReport(report))
    if !report.baselineMet {
      exit(1)
    }
    return
  }

  // Trace replay mode
  if opts.trace {
    let spans = TraceWriter.loadTrace(opts.trace)
    if !spans {
      println("Trace not found: ${opts.trace}")
      return
    }
    println(formatTrace(spans))
    return
  }

  // Resume previous session
  if opts.resume {
    let snapshot = sessionStore.resumeLatest()
    if snapshot {
      println("Resuming session ${snapshot.id} (${snapshot.turnCount} turns, model: ${snapshot.model})")
      // Restore state into session
      session.restoreFromSnapshot(snapshot)
    } else {
      println("No active session to resume. Starting fresh.")
    }
  }

  // Start new trace for this session
  traces.startTrace(newSessionId())

  // Non-interactive mode (pipe a prompt in)
  if opts.non_interactive {
    let prompt = opts.positional.join(" ")
    if prompt.isEmpty() {
      prompt = readStdin()
    }
    // Budget gate
    let budgetErr = budgetPolicy.assertCanSpend(1000, "run_turn")
    if budgetErr {
      println("Error: ${budgetErr.message}")
      exit(1)
    }
    let result = session.runOnce(prompt)
    println(result)
    traces.save()
    return
  }

  // Interactive TUI mode
  let app = App.new(session, config.tui)
  app.run()
  traces.save()
}

fn printUsage() {
  println("
smallcode v${VERSION} — AI coding agent for small LLMs

USAGE:
  smallcode [OPTIONS] [PROMPT]

OPTIONS:
  -h, --help              Show this help
  -v, --version           Show version
  -m, --model <NAME>      Model to use (overrides config)
  -p, --provider <NAME>   Provider (ollama, openai, anthropic, llamacpp)
  -c, --config <PATH>     Config file path
  -r, --resume            Resume last active session
  --non-interactive       Run single prompt, no TUI
  --mcp                   Run as MCP server (JSON-RPC over stdio)
  --eval <SUITE>          Run prompt evaluation suite
  --trace <ID>            Replay a recorded trace

MODES:
  Interactive (default)   TUI with streaming output
  Non-interactive         Single prompt via arg or stdin pipe
  MCP Server              Expose tools to other agents via MCP
  Evaluation              Test prompt quality against baselines
  Trace Replay            Debug by replaying recorded LLM calls

EXAMPLES:
  smallcode                                Start interactive session
  smallcode \"fix the bug in main.ms\"       Single prompt mode
  smallcode -m qwen3:8b                    Use specific model
  smallcode --resume                       Continue previous session
  smallcode --mcp                          Start as MCP server
  smallcode --eval classify_accuracy       Run classifier evaluation
  smallcode --trace abc123-def4            Replay a trace
  echo \"refactor this\" | smallcode --non-interactive
")
}
