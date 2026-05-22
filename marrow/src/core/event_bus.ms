// SmallCode - Event Bus
// Simple pub/sub event system for hooks and UI updates

pub struct EventBus {
  listeners: Map<String, List<fn(Map<String, Any>)>>
}

pub impl EventBus {
  pub fn new(): EventBus {
    return EventBus { listeners: {} }
  }

  // Subscribe to an event
  pub fn on(self, event: String, handler: fn(Map<String, Any>)) {
    if !self.listeners.has(event) {
      self.listeners.set(event, [])
    }
    self.listeners.get(event).push(handler)
  }

  // Unsubscribe all handlers for an event
  pub fn off(self, event: String) {
    self.listeners.remove(event)
  }

  // Emit an event to all subscribers
  pub fn emit(self, event: String, data: Map<String, Any>) {
    if !self.listeners.has(event) { return }
    for handler in self.listeners.get(event) {
      handler(data)
    }
  }

  // Emit and collect responses (for pre-hooks that can block)
  pub fn emitWithResponse(self, event: String, data: Map<String, Any>): List<Any> {
    if !self.listeners.has(event) { return [] }
    let results = []
    for handler in self.listeners.get(event) {
      results.push(handler(data))
    }
    return results
  }

  // One-time listener (auto-removes after first call)
  pub fn once(self, event: String, handler: fn(Map<String, Any>)) {
    let wrapped = |data| {
      handler(data)
      self.removeHandler(event, wrapped)
    }
    self.on(event, wrapped)
  }

  fn removeHandler(self, event: String, handler: fn(Map<String, Any>)) {
    if !self.listeners.has(event) { return }
    self.listeners.set(event, self.listeners.get(event).filter(|h| h != handler))
  }
}

// Standard events:
// - "model.request"     { turn, tool_calls }
// - "model.token"       { token }
// - "model.complete"    {}
// - "model.early_stop"  {}
// - "tool.start"        { name, id }
// - "tool.complete"     { name, output_tokens }
// - "tool.error"        { name, error }
// - "context.eviction"  { freed, needed }
// - "session.start"     {}
// - "session.end"       {}
// - "plan.step"         { step, total }
