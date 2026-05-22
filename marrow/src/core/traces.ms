// SmallCode - Cognition Traces
// Mirrors MarrowScript's emitted traces.ts — records every LLM boundary
// Enables: marrowc replay <trace_id>, regression testing, debugging

import { EventBus } from "./event_bus"
import { writeFile, readFile, pathExists, mkdirp } from "std/fs"
import { cwd } from "std/env"

const TRACES_DIR = ".smallcode/traces"

pub struct Span {
  trace_id: String
  span_id: String
  parent_span_id: String?
  kind: String            // "prompt_call" | "cache_hit" | "validate" | "repair" | "tool_call"
  status: String          // "ok" | "provider_error" | "validate_failed" | "repair_accepted" | etc.
  prompt_name: String?
  model_id: String?
  tier: String?
  attempt: Int
  input_tokens: Int
  output_tokens: Int
  latency_ms: Int
  confidence: Float?
  timestamp: Int
  metadata: Map<String, Any>
}

pub struct TraceWriter {
  eventBus: EventBus
  currentTraceId: String
  spans: List<Span>
  enabled: Bool
}

pub impl TraceWriter {
  pub fn new(eventBus: EventBus, enabled: Bool): TraceWriter {
    let writer = TraceWriter {
      eventBus: eventBus,
      currentTraceId: "",
      spans: [],
      enabled: enabled,
    }
    writer.wireEvents()
    return writer
  }

  pub fn startTrace(self, traceId: String) {
    self.currentTraceId = traceId
    self.spans = []
  }

  pub fn writeSpan(self, span: Span) {
    if !self.enabled { return }
    self.spans.push(span)
  }

  // Save trace to disk for replay
  pub fn save(self) {
    if !self.enabled || self.spans.isEmpty() { return }

    mkdirp("${cwd()}/${TRACES_DIR}")
    let path = "${cwd()}/${TRACES_DIR}/${self.currentTraceId}.json"
    let data = toJson(self.spans, indent: 2)
    writeFile(path, data)
  }

  // Load a trace for replay
  pub fn loadTrace(traceId: String): List<Span>? {
    let path = "${cwd()}/${TRACES_DIR}/${traceId}.json"
    if !pathExists(path) { return null }
    let content = readFile(path)
    return parseJson(content) as List<Span>
  }

  fn wireEvents(self) {
    // Record prompt calls
    self.eventBus.on("model.request", |data| {
      let span = Span {
        trace_id: self.currentTraceId,
        span_id: randomHex(8),
        parent_span_id: null,
        kind: "prompt_call",
        status: "pending",
        prompt_name: data.get("prompt") as String?,
        model_id: data.get("model") as String?,
        tier: data.get("tier") as String?,
        attempt: data.get("attempt") as Int? ?? 1,
        input_tokens: 0,
        output_tokens: 0,
        latency_ms: 0,
        confidence: null,
        timestamp: now(),
        metadata: data,
      }
      self.writeSpan(span)
    })

    // Record completions
    self.eventBus.on("model.complete", |data| {
      if self.spans.isEmpty() { return }
      let last = self.spans.last()
      if last.kind == "prompt_call" && last.status == "pending" {
        last.status = "ok"
        last.latency_ms = now() - last.timestamp
        last.output_tokens = data.get("output_tokens") as Int? ?? 0
      }
    })

    // Record tool calls
    self.eventBus.on("tool.complete", |data| {
      self.writeSpan(Span {
        trace_id: self.currentTraceId,
        span_id: randomHex(8),
        parent_span_id: self.spans.last()?.span_id,
        kind: "tool_call",
        status: "ok",
        prompt_name: null,
        model_id: null,
        tier: null,
        attempt: 1,
        input_tokens: 0,
        output_tokens: data.get("output_tokens") as Int? ?? 0,
        latency_ms: 0,
        confidence: null,
        timestamp: now(),
        metadata: data,
      })
    })

    // Record errors
    self.eventBus.on("tool.error", |data| {
      self.writeSpan(Span {
        trace_id: self.currentTraceId,
        span_id: randomHex(8),
        parent_span_id: self.spans.last()?.span_id,
        kind: "tool_call",
        status: "failed",
        prompt_name: null,
        model_id: null,
        tier: null,
        attempt: 1,
        input_tokens: 0,
        output_tokens: 0,
        latency_ms: 0,
        confidence: null,
        timestamp: now(),
        metadata: data,
      })
    })
  }
}

// Format a trace for human-readable display
pub fn formatTrace(spans: List<Span>): String {
  let lines = ["Trace: ${spans[0]?.trace_id ?? "unknown"}", ""]

  for span in spans {
    let prefix = match span.kind {
      "prompt_call" => "🧠"
      "tool_call" => "🔧"
      "cache_hit" => "💾"
      "validate" => "✓"
      "repair" => "🔄"
      _ => "•"
    }

    let statusIcon = match span.status {
      "ok" => "✅"
      "failed" | "provider_error" | "validate_failed" => "❌"
      "pending" => "⏳"
      _ => "•"
    }

    let detail = ""
    if span.prompt_name { detail += " prompt=${span.prompt_name}" }
    if span.model_id { detail += " model=${span.model_id}" }
    if span.tier { detail += " tier=${span.tier}" }
    if span.latency_ms > 0 { detail += " ${span.latency_ms}ms" }
    if span.output_tokens > 0 { detail += " ${span.output_tokens}tok" }

    lines.push("  ${prefix} ${statusIcon} ${span.kind}${detail}")
  }

  let totalTokens = spans.map(|s| s.input_tokens + s.output_tokens).sum()
  let totalLatency = spans.filter(|s| s.kind == "prompt_call").map(|s| s.latency_ms).sum()
  lines.push("")
  lines.push("  Total: ${totalTokens} tokens, ${totalLatency}ms, ${spans.length} spans")

  return lines.join("\n")
}
