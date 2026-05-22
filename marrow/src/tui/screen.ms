// SmallCode — Full-Screen TUI Engine (MarrowScript declaration)
// Alternate screen buffer with panel layout, scrolling, and input handling
// Inspired by OpenCode's Bubble Tea / OpenTUI approach, but zero-dep Node.js

import { EventBus } from "../core/event_bus"

pub enum PanelId {
  Chat        // Main conversation area (scrollable)
  Input       // User input line (bottom)
  Status      // Status bar (model, tokens, file count)
  ToolLog     // Tool execution log (right panel or inline)
}

pub struct ScreenConfig {
  alternate_buffer: Bool     // Enter alternate screen (default: true)
  show_tool_panel: Bool      // Split view with tool log
  theme: String              // "dark" | "light" | "minimal"
  status_bar: Bool           // Show bottom status bar
}

pub struct Viewport {
  width: Int
  height: Int
  scroll_offset: Int
  max_scroll: Int
}

pub struct Panel {
  id: PanelId
  x: Int
  y: Int
  width: Int
  height: Int
  viewport: Viewport
  content: List<String>       // Lines of rendered content
  focused: Bool
}

pub struct Screen {
  config: ScreenConfig
  panels: Map<PanelId, Panel>
  width: Int
  height: Int
  dirty: Bool                 // Needs re-render
  eventBus: EventBus
}

pub impl Screen {
  pub fn new(config: ScreenConfig, eventBus: EventBus): Screen {
    return Screen {
      config: config,
      panels: {},
      width: 0,
      height: 0,
      dirty: true,
      eventBus: eventBus,
    }
  }

  // Enter alternate screen buffer and set up raw mode
  pub fn enter(self) {
    if self.config.alternate_buffer {
      // \x1b[?1049h = enter alternate buffer
      // \x1b[?25l = hide cursor
      write("\x1b[?1049h\x1b[?25l")
    }
    self.measureTerminal()
    self.layoutPanels()
    self.render()
  }

  // Leave alternate screen and restore terminal
  pub fn leave(self) {
    if self.config.alternate_buffer {
      // \x1b[?1049l = leave alternate buffer
      // \x1b[?25h = show cursor
      write("\x1b[?1049l\x1b[?25h")
    }
  }

  // Measure terminal dimensions
  pub fn measureTerminal(self) {
    // Done via process.stdout.columns/rows in JS runtime
    self.width = getTerminalWidth()
    self.height = getTerminalHeight()
  }

  // Layout panels based on screen dimensions
  pub fn layoutPanels(self) {
    let w = self.width
    let h = self.height
    let statusHeight = if self.config.status_bar { 1 } else { 0 }
    let inputHeight = 3  // Input area

    if self.config.show_tool_panel {
      // Split: chat 70% left, tools 30% right
      let chatWidth = (w * 70) / 100
      let toolWidth = w - chatWidth - 1  // 1 for divider

      self.panels.set(PanelId.Chat, Panel {
        id: PanelId.Chat,
        x: 0, y: 0,
        width: chatWidth,
        height: h - inputHeight - statusHeight,
        viewport: Viewport { width: chatWidth, height: h - inputHeight - statusHeight, scroll_offset: 0, max_scroll: 0 },
        content: [],
        focused: true,
      })

      self.panels.set(PanelId.ToolLog, Panel {
        id: PanelId.ToolLog,
        x: chatWidth + 1, y: 0,
        width: toolWidth,
        height: h - inputHeight - statusHeight,
        viewport: Viewport { width: toolWidth, height: h - inputHeight - statusHeight, scroll_offset: 0, max_scroll: 0 },
        content: [],
        focused: false,
      })
    } else {
      // Full width chat
      self.panels.set(PanelId.Chat, Panel {
        id: PanelId.Chat,
        x: 0, y: 0,
        width: w,
        height: h - inputHeight - statusHeight,
        viewport: Viewport { width: w, height: h - inputHeight - statusHeight, scroll_offset: 0, max_scroll: 0 },
        content: [],
        focused: true,
      })
    }

    self.panels.set(PanelId.Input, Panel {
      id: PanelId.Input,
      x: 0, y: h - inputHeight - statusHeight,
      width: w,
      height: inputHeight,
      viewport: Viewport { width: w, height: inputHeight, scroll_offset: 0, max_scroll: 0 },
      content: [],
      focused: false,
    })

    if self.config.status_bar {
      self.panels.set(PanelId.Status, Panel {
        id: PanelId.Status,
        x: 0, y: h - 1,
        width: w,
        height: 1,
        viewport: Viewport { width: w, height: 1, scroll_offset: 0, max_scroll: 0 },
        content: [],
        focused: false,
      })
    }
  }

  // Full render cycle
  pub fn render(self) {
    if !self.dirty { return }
    self.dirty = false

    // Clear screen
    write("\x1b[2J\x1b[H")

    // Render each panel
    for (_, panel) in self.panels {
      self.renderPanel(panel)
    }

    // Position cursor at input
    let inputPanel = self.panels.get(PanelId.Input)
    if inputPanel {
      write("\x1b[${inputPanel.y + 1};${inputPanel.x + 3}H")
      write("\x1b[?25h")  // Show cursor in input area
    }
  }

  fn renderPanel(self, panel: Panel) {
    let startLine = panel.viewport.scroll_offset
    let endLine = startLine + panel.height
    let visibleLines = panel.content.slice(startLine, endLine)

    for (i, line) in visibleLines.enumerate() {
      let row = panel.y + i + 1  // ANSI rows are 1-indexed
      let col = panel.x + 1
      write("\x1b[${row};${col}H")
      write(line.slice(0, panel.width))
    }
  }

  // Append content to a panel
  pub fn appendToPanel(self, panelId: PanelId, text: String) {
    let panel = self.panels.get(panelId)
    if !panel { return }

    let lines = text.split("\n")
    panel.content.append(lines)
    panel.viewport.max_scroll = max(0, panel.content.length - panel.height)

    // Auto-scroll to bottom
    panel.viewport.scroll_offset = panel.viewport.max_scroll
    self.dirty = true
  }

  // Scroll a panel
  pub fn scroll(self, panelId: PanelId, delta: Int) {
    let panel = self.panels.get(panelId)
    if !panel { return }

    panel.viewport.scroll_offset = clamp(
      panel.viewport.scroll_offset + delta,
      0,
      panel.viewport.max_scroll
    )
    self.dirty = true
  }

  // Handle terminal resize
  pub fn onResize(self) {
    self.measureTerminal()
    self.layoutPanels()
    self.dirty = true
    self.render()
  }
}

// Utility
fn clamp(val: Int, min: Int, max: Int): Int {
  if val < min { return min }
  if val > max { return max }
  return val
}

fn max(a: Int, b: Int): Int {
  if a > b { return a }
  return b
}

// Platform-provided (JS runtime)
fn write(s: String) {}
fn getTerminalWidth(): Int { return 80 }
fn getTerminalHeight(): Int { return 24 }
