// SmallCode - Context Compactor
// Summarizes old conversation turns to free context space

import { BudgetEngine } from "./budget"

pub struct Message {
  role: String          // "user" | "assistant" | "system" | "tool"
  content: String
  turn: Int
  tokens: Int
  summarized: Bool
}

pub struct Compactor {
  messages: List<Message>
  budget: BudgetEngine
  currentTurn: Int
}

pub impl Compactor {
  pub fn new(budget: BudgetEngine): Compactor {
    return Compactor {
      messages: [],
      budget: budget,
      currentTurn: 0,
    }
  }

  // Add a message to conversation history
  pub fn add(self, role: String, content: String) {
    let tokens = BudgetEngine.countTokens(content)
    self.messages.push(Message {
      role: role,
      content: content,
      turn: self.currentTurn,
      tokens: tokens,
      summarized: false,
    })
    self.budget.addConversationTokens(tokens)
  }

  // Advance to next turn
  pub fn nextTurn(self) {
    self.currentTurn += 1
    self.budget.newTurn()
  }

  // Get messages formatted for the model (respecting budget)
  pub fn getContext(self): List<Message> {
    // If we're within budget, return everything
    if self.budget.available() > 0 {
      return self.messages
    }

    // Need to compact: summarize older turns
    self.compact()
    return self.messages
  }

  // Compact old turns into summaries
  pub fn compact(self) {
    if self.messages.length < 4 { return }

    // Keep the last 2 turns intact, summarize everything before
    let keepFromTurn = self.currentTurn - 1
    let toSummarize = self.messages.filter(|m| m.turn < keepFromTurn && !m.summarized)

    if toSummarize.isEmpty() { return }

    // Build a compact summary of old turns
    let summary = buildSummary(toSummarize)
    let summaryTokens = BudgetEngine.countTokens(summary)

    // Calculate tokens freed
    let freedTokens = toSummarize.map(|m| m.tokens).sum()

    // Remove old messages and insert summary
    self.messages = self.messages.filter(|m| m.turn >= keepFromTurn || m.summarized)
    self.messages.insert(0, Message {
      role: "system",
      content: summary,
      turn: 0,
      tokens: summaryTokens,
      summarized: true,
    })

    // Update budget
    self.budget.evict(freedTokens - summaryTokens)
  }

  // Get total token count of current context
  pub fn totalTokens(self): Int {
    return self.messages.map(|m| m.tokens).sum()
  }

  // Clear all history
  pub fn clear(self) {
    self.messages = []
    self.currentTurn = 0
  }
}

// Build a compact summary from a list of messages
fn buildSummary(messages: List<Message>): String {
  let parts = []

  // Group by turn
  let turns = groupByTurn(messages)

  for turn in turns {
    let userMsg = turn.find(|m| m.role == "user")
    let assistantMsg = turn.find(|m| m.role == "assistant")
    let toolMsgs = turn.filter(|m| m.role == "tool")

    let summary = "[Previous turn] "
    if userMsg {
      // Truncate user message to first line or 100 chars
      let short = userMsg.content.split("\n").first().slice(0, 100)
      summary += "User: ${short}"
    }
    if toolMsgs.length > 0 {
      summary += " | Tools used: ${toolMsgs.length}"
    }
    if assistantMsg {
      // Extract just the action taken
      let short = assistantMsg.content.split("\n").first().slice(0, 100)
      summary += " | Assistant: ${short}"
    }
    parts.push(summary)
  }

  return parts.join("\n")
}

fn groupByTurn(messages: List<Message>): List<List<Message>> {
  let groups: Map<Int, List<Message>> = {}
  for msg in messages {
    if !groups.has(msg.turn) {
      groups.set(msg.turn, [])
    }
    groups.get(msg.turn).push(msg)
  }
  return groups.values().toList()
}
