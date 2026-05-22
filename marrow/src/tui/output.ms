// SmallCode - TUI Output Handler
// Streaming output with color-coded tool calls and compact formatting

import { Terminal, setColor, resetColor, bold, dim } from "std/terminal"

const COLOR_ASSISTANT = "white"
const COLOR_TOOL = "cyan"
const COLOR_ERROR = "red"
const COLOR_WARNING = "yellow"
const COLOR_INFO = "blue"
const COLOR_DIM = "gray"

pub struct Output {
  terminal: Terminal
  inResponse: Bool
  linePos: Int
}

pub impl Output {
  pub fn new(terminal: Terminal): Output {
    return Output {
      terminal: terminal,
      inResponse: false,
      linePos: 0,
    }
  }

  // Start a new response block
  pub fn startResponse(self) {
    self.inResponse = true
    self.linePos = 0
    println("")
  }

  // End a response block
  pub fn endResponse(self) {
    self.inResponse = false
    if self.linePos > 0 {
      println("")
    }
    println("")
  }

  // Write a single token (streaming)
  pub fn writeToken(self, token: String) {
    print(token)
    self.linePos += token.length
    // Track newlines
    if token.contains("\n") {
      self.linePos = token.length - token.lastIndexOf("\n") - 1
    }
  }

  // Write tool start indicator
  pub fn writeToolStart(self, name: String) {
    if self.linePos > 0 { println("") }
    setColor(COLOR_TOOL)
    print("  ⚙ ${name} ")
    dim()
    print("running...")
    resetColor()
    self.linePos = 0
  }

  // Write tool completion
  pub fn writeToolComplete(self, name: String) {
    print("\r")  // Return to start of line
    setColor(COLOR_TOOL)
    println("  ✓ ${name}")
    resetColor()
    self.linePos = 0
  }

  // Write tool error
  pub fn writeToolError(self, name: String, error: String) {
    print("\r")
    setColor(COLOR_ERROR)
    println("  ✗ ${name}: ${error}")
    resetColor()
    self.linePos = 0
  }

  // Write info message
  pub fn writeInfo(self, msg: String) {
    setColor(COLOR_INFO)
    println("  ${msg}")
    resetColor()
  }

  // Write warning
  pub fn writeWarning(self, msg: String) {
    setColor(COLOR_WARNING)
    println("  ⚠ ${msg}")
    resetColor()
  }

  // Write error
  pub fn writeError(self, msg: String) {
    setColor(COLOR_ERROR)
    println("  ✗ ${msg}")
    resetColor()
  }

  // Write a separator
  pub fn separator(self) {
    dim()
    println("  ─────────────────────────────────────")
    resetColor()
  }
}
