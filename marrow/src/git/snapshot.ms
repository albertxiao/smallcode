// SmallCode - File Snapshot System
// Captures file state before edits for one-key undo
// Essential safety net for small models that make mistakes

import { readFile, writeFile, pathExists, mkdirp, deleteFile, copyFile } from "std/fs"
import { resolve, relative, dirname } from "std/path"
import { cwd } from "std/env"
import { EventBus } from "../core/event_bus"

const SNAPSHOT_DIR = ".smallcode/snapshots"

pub struct FileSnapshot {
  path: String
  content: String
  timestamp: Int
  turnNumber: Int
}

pub struct SnapshotSet {
  id: String
  label: String
  files: List<FileSnapshot>
  timestamp: Int
  turnNumber: Int
}

pub struct SnapshotManager {
  snapshots: List<SnapshotSet>
  maxSnapshots: Int
  eventBus: EventBus
}

pub impl SnapshotManager {
  pub fn new(eventBus: EventBus, maxSnapshots: Int = 20): SnapshotManager {
    return SnapshotManager {
      snapshots: [],
      maxSnapshots: maxSnapshots,
      eventBus: eventBus,
    }
  }

  // Capture a snapshot of files before editing them
  pub fn capture(self, paths: List<String>, label: String, turnNumber: Int): String {
    let files = []
    for path in paths {
      let fullPath = resolve(cwd(), path)
      if pathExists(fullPath) {
        let content = readFile(fullPath)
        files.push(FileSnapshot {
          path: path,
          content: content,
          timestamp: now(),
          turnNumber: turnNumber,
        })
      }
    }

    let id = "snap_${now().toString(36)}_${randomHex(4)}"
    let snapshot = SnapshotSet {
      id: id,
      label: label,
      files: files,
      timestamp: now(),
      turnNumber: turnNumber,
    }

    self.snapshots.push(snapshot)

    // Evict old snapshots
    while self.snapshots.length > self.maxSnapshots {
      self.snapshots.removeFirst()
    }

    // Persist to disk
    self.saveToDisk(snapshot)
    self.eventBus.emit("snapshot.created", { id: id, files: paths.length })

    return id
  }

  // Revert to a snapshot (undo)
  pub fn revert(self, id: String): RevertResult {
    let snapshot = self.snapshots.find(|s| s.id == id)
    if !snapshot {
      return RevertResult { success: false, error: "Snapshot not found: ${id}", filesReverted: 0 }
    }

    let reverted = 0
    for file in snapshot.files {
      let fullPath = resolve(cwd(), file.path)
      mkdirp(dirname(fullPath))
      writeFile(fullPath, file.content)
      reverted += 1
    }

    self.eventBus.emit("snapshot.reverted", { id: id, files: reverted })
    return RevertResult { success: true, error: null, filesReverted: reverted }
  }

  // Revert the most recent snapshot (one-key undo)
  pub fn undoLast(self): RevertResult {
    if self.snapshots.isEmpty() {
      return RevertResult { success: false, error: "No snapshots to undo", filesReverted: 0 }
    }
    let last = self.snapshots.last()
    return self.revert(last.id)
  }

  // List available snapshots
  pub fn list(self): List<SnapshotSummary> {
    return self.snapshots.map(|s| SnapshotSummary {
      id: s.id,
      label: s.label,
      files: s.files.length,
      timestamp: s.timestamp,
      turnNumber: s.turnNumber,
    })
  }

  // Get the most recent snapshot for a specific file
  pub fn lastFor(self, path: String): FileSnapshot? {
    for i in range(self.snapshots.length - 1, -1, -1) {
      let snap = self.snapshots[i]
      let file = snap.files.find(|f| f.path == path)
      if file { return file }
    }
    return null
  }

  // Clear all snapshots
  pub fn clear(self) {
    self.snapshots = []
  }

  fn saveToDisk(self, snapshot: SnapshotSet) {
    let dir = "${cwd()}/${SNAPSHOT_DIR}"
    mkdirp(dir)
    let path = "${dir}/${snapshot.id}.json"
    writeFile(path, toJson(snapshot))
  }
}

pub struct RevertResult {
  success: Bool
  error: String?
  filesReverted: Int
}

pub struct SnapshotSummary {
  id: String
  label: String
  files: Int
  timestamp: Int
  turnNumber: Int
}
