// SmallCode - Status Bar
// Shows model, token usage, and current step at bottom of terminal

import { Terminal, moveCursor, setColor, resetColor, dim, getTerminalSize } from "std/terminal"
import { Session } from "../core/session"
import { TuiConfig } from "../core/config"

pub struct StatusBar {
  terminal: Terminal
  session: Session
  config: TuiConfig
}

pub impl StatusBar {
  pub fn new(terminal: Terminal, session: Session, config: TuiConfig): StatusBar {
    return StatusBar {
      terminal: terminal,
      session: session,
      config: config,
    }
  }

  // Render the status bar at the bottom
  pub fn render(self) {
    if !self.config.show_token_usage { return }

    let size = getTerminalSize()
    let width = size.cols

    // Build status line
    let model = self.session.model.name()
    let budget = self.session.budget.formatUsage()
    let pct = self.session.budget.usagePct()

    // Color code based on usage
    let usageColor = if pct < 50 { "green" }
      else if pct < 80 { "yellow" }
      else { "red" }

    let left = " ${model}"
    let right = "${budget} "
    let padding = width - left.length - right.length
    let pad = " ".repeat(max(1, padding))

    // Render
    dim()
    print("\r")
    print(left)
    print(pad)
    setColor(usageColor)
    print(right)
    resetColor()
  }
}

fn max(a: Int, b: Int): Int { if a > b { return a } else { return b } }
