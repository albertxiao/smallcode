// SmallCode - TUI Input Handler
// Readline-style input with history and basic editing

import { Terminal, readLine } from "std/terminal"

const PROMPT = "› "
const MAX_HISTORY = 100

pub struct Input {
  terminal: Terminal
  history: List<String>
  historyPos: Int
}

pub impl Input {
  pub fn new(terminal: Terminal): Input {
    return Input {
      terminal: terminal,
      history: [],
      historyPos: -1,
    }
  }

  // Read a line of input from the user
  pub fn read(self): String {
    let line = readLine(PROMPT)
    
    if line.trim().isEmpty() { return "" }

    // Add to history
    if self.history.isEmpty() || self.history.last() != line {
      self.history.push(line)
      if self.history.length > MAX_HISTORY {
        self.history.removeFirst()
      }
    }
    self.historyPos = -1

    return line.trim()
  }

  // Multi-line input mode (for pasting)
  pub fn readMultiLine(self): String {
    println("  (multi-line mode: enter empty line to submit)")
    let lines = []
    while true {
      let line = readLine("… ")
      if line.trim().isEmpty() && lines.length > 0 { break }
      lines.push(line)
    }
    return lines.join("\n")
  }
}
