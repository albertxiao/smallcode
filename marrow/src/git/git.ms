// SmallCode - Git Integration
// Auto-diff, commit, branch, undo — all git-aware
// Small models benefit hugely from seeing git diff as context

import { exec } from "std/process"
import { pathExists } from "std/fs"
import { cwd } from "std/env"
import { EventBus } from "../core/event_bus"

pub struct GitInfo {
  isRepo: Bool
  branch: String
  hasChanges: Bool
  ahead: Int
  behind: Int
}

pub struct GitDiff {
  staged: String
  unstaged: String
  untracked: List<String>
  summary: String       // compact one-liner for context injection
}

pub struct Git {
  rootDir: String
  eventBus: EventBus
}

pub impl Git {
  pub fn new(eventBus: EventBus): Git {
    return Git { rootDir: cwd(), eventBus: eventBus }
  }

  // Check if we're in a git repo
  pub fn isRepo(self): Bool {
    let result = exec("git rev-parse --is-inside-work-tree", { cwd: self.rootDir, timeout: 5000, shell: true })
    return result.exitCode == 0
  }

  // Get current branch info
  pub fn info(self): GitInfo {
    if !self.isRepo() {
      return GitInfo { isRepo: false, branch: "", hasChanges: false, ahead: 0, behind: 0 }
    }

    let branch = execTrim("git branch --show-current")
    let status = execTrim("git status --porcelain")
    let hasChanges = !status.isEmpty()

    // Ahead/behind tracking branch
    let abResult = execTrim("git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null")
    let ahead = 0
    let behind = 0
    if abResult.contains("\t") {
      let parts = abResult.split("\t")
      ahead = parseInt(parts[0]) ?? 0
      behind = parseInt(parts[1]) ?? 0
    }

    return GitInfo { isRepo: true, branch: branch, hasChanges: hasChanges, ahead: ahead, behind: behind }
  }

  // Get current diff (staged + unstaged)
  pub fn diff(self): GitDiff {
    let staged = execTrim("git diff --cached --stat")
    let unstaged = execTrim("git diff --stat")
    let untrackedRaw = execTrim("git ls-files --others --exclude-standard")
    let untracked = untrackedRaw.split("\n").filter(|l| !l.isEmpty())

    let stagedFull = execTrim("git diff --cached")
    let unstagedFull = execTrim("git diff")

    // Build compact summary for context injection
    let changedFiles = []
    let statusLines = execTrim("git status --porcelain").split("\n").filter(|l| !l.isEmpty())
    for line in statusLines {
      let marker = line.slice(0, 2).trim()
      let file = line.slice(3).trim()
      changedFiles.push("${marker} ${file}")
    }

    let summary = if changedFiles.isEmpty() {
      "No uncommitted changes"
    } else {
      "Changes: ${changedFiles.join(", ")}"
    }

    return GitDiff {
      staged: stagedFull,
      unstaged: unstagedFull,
      untracked: untracked,
      summary: summary,
    }
  }

  // Get compact diff for context injection (token-efficient)
  pub fn contextDiff(self, maxTokens: Int = 500): String {
    let diff = self.diff()
    if diff.summary == "No uncommitted changes" {
      return ""
    }

    let output = "[git] ${diff.summary}"
    // Add abbreviated diff if budget allows
    let fullDiff = "${diff.staged}\n${diff.unstaged}".trim()
    if fullDiff.length > 0 && fullDiff.length / 4 < maxTokens {
      output += "\n${fullDiff}"
    }
    return output
  }

  // Stage and commit changes
  pub fn commit(self, message: String, files: List<String>?): Bool {
    if files && files.length > 0 {
      // Stage specific files
      for file in files {
        exec("git add \"${file}\"", { cwd: self.rootDir, timeout: 5000, shell: true })
      }
    } else {
      // Stage all changes
      exec("git add -A", { cwd: self.rootDir, timeout: 5000, shell: true })
    }

    let result = exec("git commit -m \"${escapeQuotes(message)}\"", { cwd: self.rootDir, timeout: 10000, shell: true })
    if result.exitCode == 0 {
      self.eventBus.emit("git.commit", { message: message })
    }
    return result.exitCode == 0
  }

  // Create a branch (for risky operations)
  pub fn createBranch(self, name: String): Bool {
    let result = exec("git checkout -b \"${name}\"", { cwd: self.rootDir, timeout: 5000, shell: true })
    if result.exitCode == 0 {
      self.eventBus.emit("git.branch", { name: name })
    }
    return result.exitCode == 0
  }

  // Undo last commit (soft reset)
  pub fn undoLastCommit(self): Bool {
    let result = exec("git reset --soft HEAD~1", { cwd: self.rootDir, timeout: 5000, shell: true })
    if result.exitCode == 0 {
      self.eventBus.emit("git.undo", {})
    }
    return result.exitCode == 0
  }

  // Discard changes to a specific file
  pub fn discardFile(self, path: String): Bool {
    let result = exec("git checkout -- \"${path}\"", { cwd: self.rootDir, timeout: 5000, shell: true })
    return result.exitCode == 0
  }

  // Discard all unstaged changes
  pub fn discardAll(self): Bool {
    let result = exec("git checkout -- .", { cwd: self.rootDir, timeout: 5000, shell: true })
    return result.exitCode == 0
  }

  // Stash current changes (for quick save/restore)
  pub fn stash(self, message: String?): Bool {
    let cmd = if message { "git stash push -m \"${message}\"" } else { "git stash" }
    let result = exec(cmd, { cwd: self.rootDir, timeout: 5000, shell: true })
    return result.exitCode == 0
  }

  // Pop stash
  pub fn stashPop(self): Bool {
    let result = exec("git stash pop", { cwd: self.rootDir, timeout: 5000, shell: true })
    return result.exitCode == 0
  }

  // Get log (recent commits)
  pub fn log(self, count: Int = 5): String {
    return execTrim("git log --oneline -${count}")
  }

  // Get blame for a file range
  pub fn blame(self, path: String, startLine: Int, endLine: Int): String {
    return execTrim("git blame -L ${startLine},${endLine} \"${path}\"")
  }

  // Show what changed in the last N commits (for context)
  pub fn recentChanges(self, commits: Int = 3): String {
    return execTrim("git log --stat --oneline -${commits}")
  }

  // Auto-generate a commit message from staged changes
  pub fn suggestCommitMessage(self): String {
    let diff = execTrim("git diff --cached --stat")
    if diff.isEmpty() { return "update" }

    let files = diff.split("\n").filter(|l| l.contains("|")).map(|l| l.split("|")[0].trim())
    if files.length == 1 {
      return "update ${files[0]}"
    }
    return "update ${files.length} files"
  }
}

fn execTrim(cmd: String): String {
  let result = exec(cmd, { cwd: cwd(), timeout: 10000, shell: true })
  if result.exitCode != 0 { return "" }
  return result.stdout.trim()
}

fn escapeQuotes(s: String): String {
  return s.replace("\"", "\\\"")
}
