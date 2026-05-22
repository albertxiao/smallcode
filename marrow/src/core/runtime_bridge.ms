// SmallCode - Runtime Bridge
// Connects the MarrowScript-compiled cognition runtime to our TUI and tool system
// When marrowc compile succeeds, this module imports from output/src/cognition/
// Until then, it provides a compatible interface backed by our .ms implementations

import { ModelAdapter, CompletionRequest, CompletionResponse } from "../model/adapter"
import { BudgetEngine } from "../context/budget"
import { EventBus } from "./event_bus"

// Cognition context — matches MarrowScript's emitted CognitionCtx interface
pub struct CognitionCtx {
  trace_id: String
  signal: AbortSignal?
  prompts: PromptRegistry
  routers: RouterRegistry
  memory: MemoryLayer
  logger: Logger
  metrics: MetricsCollector
}

pub struct PromptRegistry {
  registry: Map<String, PromptFn>
}

pub type PromptFn = fn(Map<String, Any>, CognitionCtx) -> Any

pub impl PromptRegistry {
  pub fn new(): PromptRegistry {
    return PromptRegistry { registry: {} }
  }

  pub fn register(self, name: String, handler: PromptFn) {
    self.registry.set(name, handler)
  }

  pub fn get(self, name: String): PromptFn? {
    return self.registry.get(name)
  }

  pub fn findSummarizer(self): PromptFn? {
    return self.registry.get("compress_history") ?? self.registry.get("compress_conversation")
  }
}

pub struct RouterRegistry {
  routers: Map<String, CompiledRouter>
}

pub struct CompiledRouter {
  name: String
  tiers: List<RouterTier>
  fallback: String
  confidenceThreshold: Float
}

pub struct RouterTier {
  name: String
  max: Float?
  modelRef: String
}

pub struct RouteChoice {
  model_id: String
  tier: String
}

pub impl CompiledRouter {
  // Deterministic routing — same input always picks the same tier
  pub fn route(self, input: Map<String, Any>): RouteChoice {
    let complexity = input.get("complexity") as Float? ?? 0.5

    for tier in self.tiers {
      if tier.max && complexity <= tier.max {
        return RouteChoice { model_id: tier.modelRef, tier: tier.name }
      }
    }

    // Last tier (no max) or fallback
    let lastTier = self.tiers.last()
    if lastTier {
      return RouteChoice { model_id: lastTier.modelRef, tier: lastTier.name }
    }
    return RouteChoice { model_id: self.fallback, tier: "fallback" }
  }

  pub fn escalate(self, currentTier: String): RouteChoice? {
    let found = false
    for tier in self.tiers {
      if found {
        return RouteChoice { model_id: tier.modelRef, tier: tier.name }
      }
      if tier.name == currentTier {
        found = true
      }
    }
    return null
  }
}

pub impl RouterRegistry {
  pub fn new(): RouterRegistry {
    return RouterRegistry { routers: {} }
  }

  pub fn register(self, router: CompiledRouter) {
    self.routers.set(router.name, router)
  }

  pub fn get(self, name: String): CompiledRouter? {
    return self.routers.get(name)
  }
}

pub struct MemoryLayer {
  index: SemanticIndex?
}

pub struct SemanticIndex {
  // Bounded BFS graph walk — mirrors MarrowScript's semantic_slice output
  pub fn walk(self, task: String, hopDepth: Int, maxFiles: Int): SliceResult {
    // Delegates to our intel/graph.ms implementation
    return SliceResult { files: [], symbols: [], target_symbol: "" }
  }
}

pub struct SliceResult {
  files: List<String>
  symbols: List<String>
  target_symbol: String
}

pub impl MemoryLayer {
  pub fn new(): MemoryLayer {
    return MemoryLayer { index: null }
  }

  pub fn getIndex(self): SemanticIndex? {
    return self.index
  }

  pub fn setIndex(self, idx: SemanticIndex) {
    self.index = idx
  }
}

// Logger that matches MarrowScript's emitted logger shape
pub struct Logger {
  pub fn info(self, event: String, data: Map<String, Any>) {
    // Structured log line
    let msg = "[${event}]"
    for (k, v) in data {
      msg += " ${k}=${v}"
    }
    println(msg)
  }

  pub fn warn(self, event: String, data: Map<String, Any>) {
    print("[WARN] ")
    self.info(event, data)
  }

  pub fn error(self, event: String, data: Map<String, Any>) {
    print("[ERROR] ")
    self.info(event, data)
  }
}

// Metrics collector — matches MarrowScript's emitted counter interface
pub struct MetricsCollector {
  counters: Map<String, Int>
}

pub impl MetricsCollector {
  pub fn new(): MetricsCollector {
    return MetricsCollector { counters: {} }
  }

  pub fn counter(self, name: String, labels: Map<String, String>) {
    let key = "${name}|${labels.entries().map(|(k,v)| "${k}=${v}").join(",")}"
    let current = self.counters.get(key) ?? 0
    self.counters.set(key, current + 1)
  }

  pub fn getAll(self): Map<String, Int> {
    return self.counters
  }
}

// Build the default coding router from MarrowScript declaration
pub fn buildCodingRouter(): CompiledRouter {
  return CompiledRouter {
    name: "coding_router",
    tiers: [
      RouterTier { name: "trivial", max: 0.3, modelRef: "qwen2.5-coder:1.5b" },
      RouterTier { name: "simple", max: 0.6, modelRef: "qwen2.5-coder:7b" },
      RouterTier { name: "complex", max: null, modelRef: "qwen2.5-coder:14b" },
    ],
    fallback: "qwen2.5-coder:14b",
    confidenceThreshold: 0.6,
  }
}

// Build the tool router
pub fn buildToolRouter(): CompiledRouter {
  return CompiledRouter {
    name: "tool_router",
    tiers: [
      RouterTier { name: "classify", max: 0.3, modelRef: "qwen2.5-coder:1.5b" },
      RouterTier { name: "execute", max: null, modelRef: "qwen2.5-coder:7b" },
    ],
    fallback: "qwen2.5-coder:7b",
    confidenceThreshold: 0.5,
  }
}

// Build the full cognition context
pub fn buildCognitionCtx(eventBus: EventBus): CognitionCtx {
  let prompts = PromptRegistry.new()
  let routers = RouterRegistry.new()
  routers.register(buildCodingRouter())
  routers.register(buildToolRouter())

  return CognitionCtx {
    trace_id: generateTraceId(),
    signal: null,
    prompts: prompts,
    routers: routers,
    memory: MemoryLayer.new(),
    logger: Logger {},
    metrics: MetricsCollector.new(),
  }
}

fn generateTraceId(): String {
  // Simple trace ID — 16 hex chars
  return randomHex(16)
}
