// SmallCode - Session Persistence
// Save/resume conversations across process restarts
// Stores: messages, working memory, plan state, budget state, model choice

import { readFile, writeFile, pathExists, mkdirp, glob } from "std/fs"
import { cwd } from "std/env"
import { Compactor, Message } from "../context/compactor"
import { WorkingMemory } from "../context/working_memory"

const SESSIONS_DIR = ".smallcode/sessions"

pub struct SessionSnapshot {
  id: String
  model: String
  provider: String
  turnCount: Int
  messages: List<Message>
  workingMemory: String
  planSteps: String?
  createdAt: Int
  lastActiveAt: Int
  status: String          // "active" | "paused" | "completed"
}

pub struct SessionStore {
  sessionsDir: String
}

pub impl SessionStore {
  pub fn new(): SessionStore {
    let dir = "${cwd()}/${SESSIONS_DIR}"
    mkdirp(dir)
    return SessionStore { sessionsDir: dir }
  }

  // Save current session state
  pub fn save(self, snapshot: SessionSnapshot) {
    let path = "${self.sessionsDir}/${snapshot.id}.json"
    writeFile(path, toJson(snapshot, indent: 2))
  }

  // Load a session by ID
  pub fn load(self, id: String): SessionSnapshot? {
    let path = "${self.sessionsDir}/${id}.json"
    if !pathExists(path) { return null }
    let content = readFile(path)
    return parseJson(content) as SessionSnapshot
  }

  // List all saved sessions
  pub fn list(self): List<SessionSummary> {
    let files = glob("*.json", { cwd: self.sessionsDir })
    let summaries = []

    for file in files {
      let content = readFile("${self.sessionsDir}/${file}")
      let snap = parseJson(content) as SessionSnapshot
      summaries.push(SessionSummary {
        id: snap.id,
        model: snap.model,
        turns: snap.turnCount,
        lastActive: snap.lastActiveAt,
        status: snap.status,
        preview: getPreview(snap.messages),
      })
    }

    // Sort by last active (most recent first)
    summaries.sort(|a, b| b.lastActive - a.lastActive)
    return summaries
  }

  // Resume the most recent active session
  pub fn resumeLatest(self): SessionSnapshot? {
    let sessions = self.list()
    let active = sessions.find(|s| s.status == "active" || s.status == "paused")
    if !active { return null }
    return self.load(active.id)
  }

  // Delete a session
  pub fn delete(self, id: String) {
    let path = "${self.sessionsDir}/${id}.json"
    if pathExists(path) {
      deleteFile(path)
    }
  }

  // Mark session as completed
  pub fn complete(self, id: String) {
    let snap = self.load(id)
    if snap {
      snap.status = "completed"
      snap.lastActiveAt = now()
      self.save(snap)
    }
  }
}

pub struct SessionSummary {
  id: String
  model: String
  turns: Int
  lastActive: Int
  status: String
  preview: String
}

// Create a snapshot from current session state
pub fn createSnapshot(
  id: String,
  model: String,
  provider: String,
  turnCount: Int,
  messages: List<Message>,
  memory: WorkingMemory,
  planSteps: String?,
): SessionSnapshot {
  return SessionSnapshot {
    id: id,
    model: model,
    provider: provider,
    turnCount: turnCount,
    messages: messages,
    workingMemory: memory.content,
    planSteps: planSteps,
    createdAt: now(),
    lastActiveAt: now(),
    status: "active",
  }
}

// Generate a short ID for new sessions
pub fn newSessionId(): String {
  let timestamp = now().toString(36)
  let rand = randomHex(4)
  return "${timestamp}-${rand}"
}

fn getPreview(messages: List<Message>): String {
  // Get the first user message as preview
  let userMsg = messages.find(|m| m.role == "user")
  if userMsg {
    return userMsg.content.slice(0, 80)
  }
  return "(empty session)"
}
