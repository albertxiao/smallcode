// SmallCode - Diff Viewer
// Shows proposed file changes with approve/reject functionality
// Single-key interaction: y to approve, n to reject

import { Terminal, setColor, resetColor, readKey } from "std/terminal"

pub struct DiffView {
  terminal: Terminal
}

pub struct DiffHunk {
  path: String
  startLine: Int
  oldLines: List<String>
  newLines: List<String>
}

pub impl DiffView {
  pub fn new(terminal: Terminal): DiffView {
    return DiffView { terminal: terminal }
  }

  // Show a diff and ask for approval
  pub fn showAndApprove(self, hunk: DiffHunk): Bool {
    println("")
    setColor("cyan")
    println("  ┌─ ${hunk.path}:${hunk.startLine}")
    resetColor()

    // Show removed lines
    for line in hunk.oldLines {
      setColor("red")
      println("  │ - ${line}")
      resetColor()
    }

    // Show added lines
    for line in hunk.newLines {
      setColor("green")
      println("  │ + ${line}")
      resetColor()
    }

    setColor("cyan")
    println("  └─")
    resetColor()

    // Ask for approval
    setColor("yellow")
    print("  Apply? [y]es / [n]o / [a]ll: ")
    resetColor()

    let key = readKey()
    println("")

    match key {
      "y" | "Y" | "\n" => return true
      "a" | "A" => return true  // TODO: set flag for auto-approve rest
      _ => return false
    }
  }

  // Show a unified diff without approval (read-only)
  pub fn showDiff(self, path: String, oldContent: String, newContent: String) {
    let oldLines = oldContent.split("\n")
    let newLines = newContent.split("\n")

    println("")
    setColor("cyan")
    println("  ── ${path} ──")
    resetColor()

    // Simple line-by-line diff
    let maxLines = max(oldLines.length, newLines.length)
    let contextShown = 0
    let lastDiffLine = -10

    for i in range(0, maxLines) {
      let oldLine = if i < oldLines.length { oldLines[i] } else { null }
      let newLine = if i < newLines.length { newLines[i] } else { null }

      if oldLine == newLine {
        // Context line — only show near changes
        if i - lastDiffLine <= 3 {
          println("  ${padNum(i+1)} │ ${oldLine ?? ""}")
          contextShown += 1
        }
      } else {
        // Show context before diff if needed
        if i - lastDiffLine > 3 && contextShown > 0 {
          println("       ...")
        }
        
        lastDiffLine = i
        if oldLine {
          setColor("red")
          println("  ${padNum(i+1)} │-${oldLine}")
          resetColor()
        }
        if newLine {
          setColor("green")
          println("  ${padNum(i+1)} │+${newLine}")
          resetColor()
        }
      }
    }
    println("")
  }
}

fn padNum(n: Int): String {
  let s = toString(n)
  while s.length < 4 { s = " ${s}" }
  return s
}

fn max(a: Int, b: Int): Int { if a > b { return a } else { return b } }
