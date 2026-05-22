// SmallCode - Project Indexer
// Manages indexing lifecycle: initial scan, incremental updates, file watching

import { CodeIndex } from "./graph"
import { Summarizer } from "./summarizer"
import { EventBus } from "../core/event_bus"
import { glob, stat } from "std/fs"
import { cwd } from "std/env"

pub struct Indexer {
  index: CodeIndex
  summarizer: Summarizer
  eventBus: EventBus
  lastIndexed: Map<String, Int>   // file → last modified time
  indexing: Bool
}

pub impl Indexer {
  pub fn new(eventBus: EventBus): Indexer {
    let rootDir = cwd()
    let index = CodeIndex.new(rootDir)
    let summarizer = Summarizer.new(index)

    return Indexer {
      index: index,
      summarizer: summarizer,
      eventBus: eventBus,
      lastIndexed: {},
      indexing: false,
    }
  }

  // Full project index (background)
  pub fn indexAll(self) {
    if self.indexing { return }
    self.indexing = true

    self.eventBus.emit("index.start", {})
    self.index.indexProject()
    self.indexing = false

    self.eventBus.emit("index.complete", { symbols: self.index.symbols.length })
  }

  // Incremental index — only re-index changed files
  pub fn indexChanged(self) {
    let files = glob("**/*.{ms,ts,js,py,rs,go}", {
      cwd: self.index.rootDir,
      ignore: ["node_modules/**", ".git/**", "dist/**"],
    })

    let changed = 0
    for file in files {
      let info = stat(file)
      let lastMod = info.mtime

      if !self.lastIndexed.has(file) || self.lastIndexed.get(file) < lastMod {
        self.index.indexFile(file, "${self.index.rootDir}/${file}")
        self.lastIndexed.set(file, lastMod)
        changed += 1
      }
    }

    if changed > 0 {
      self.eventBus.emit("index.updated", { files: changed })
    }
  }

  // Index a single file (after edit)
  pub fn indexSingle(self, path: String) {
    self.index.indexFile(path, "${self.index.rootDir}/${path}")
  }

  // Get the code index
  pub fn getIndex(self): CodeIndex {
    return self.index
  }

  // Get the summarizer
  pub fn getSummarizer(self): Summarizer {
    return self.summarizer
  }

  // Get index stats
  pub fn stats(self): String {
    return self.index.stats()
  }
}
