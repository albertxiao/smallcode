// SmallCode - Prompt Cache
// Mirrors MarrowScript's emitted cache.ts
// Caches prompt responses by deterministic key to avoid redundant LLM calls
// Key = sha256(prompt_name | model_id | template_hash | canonicalized_input)

import { readFile, writeFile, pathExists, mkdirp } from "std/fs"
import { cwd } from "std/env"

const CACHE_DIR = ".smallcode/cache"

pub struct CacheEntry {
  key: String
  value: String
  model_id: String
  prompt_name: String
  created_at: Int
  expires_at: Int
  hits: Int
}

pub struct PromptCache {
  entries: Map<String, CacheEntry>
  maxEntries: Int
  enabled: Bool
}

pub impl PromptCache {
  pub fn new(enabled: Bool, maxEntries: Int = 1000): PromptCache {
    let cache = PromptCache {
      entries: {},
      maxEntries: maxEntries,
      enabled: enabled,
    }
    cache.load()
    return cache
  }

  // Get a cached response
  pub fn get(self, promptName: String, modelId: String, input: Map<String, Any>): String? {
    if !self.enabled { return null }

    let key = deriveKey(promptName, modelId, input)
    let entry = self.entries.get(key)
    if !entry { return null }

    // Check expiry
    if now() > entry.expires_at {
      self.entries.remove(key)
      return null
    }

    entry.hits += 1
    return entry.value
  }

  // Store a response
  pub fn put(self, promptName: String, modelId: String, input: Map<String, Any>, value: String, ttlMs: Int) {
    if !self.enabled { return }

    let key = deriveKey(promptName, modelId, input)
    let entry = CacheEntry {
      key: key,
      value: value,
      model_id: modelId,
      prompt_name: promptName,
      created_at: now(),
      expires_at: now() + ttlMs,
      hits: 0,
    }

    self.entries.set(key, entry)

    // Evict if over capacity (LRU by created_at)
    if self.entries.size() > self.maxEntries {
      self.evictOldest()
    }

    self.save()
  }

  // Invalidate all entries for a prompt
  pub fn invalidate(self, promptName: String) {
    let toRemove = self.entries.keys().filter(|k| {
      let entry = self.entries.get(k)
      return entry && entry.prompt_name == promptName
    })
    for key in toRemove { self.entries.remove(key) }
  }

  // Clear entire cache
  pub fn clear(self) {
    self.entries = {}
    self.save()
  }

  // Get cache stats
  pub fn stats(self): String {
    let totalHits = self.entries.values().map(|e| e.hits).sum()
    return "${self.entries.size()} entries, ${totalHits} total hits"
  }

  fn evictOldest(self) {
    let oldest: CacheEntry? = null
    for entry in self.entries.values() {
      if !oldest || entry.created_at < oldest.created_at {
        oldest = entry
      }
    }
    if oldest {
      self.entries.remove(oldest.key)
    }
  }

  fn load(self) {
    let path = "${cwd()}/${CACHE_DIR}/cache.json"
    if pathExists(path) {
      let content = readFile(path)
      self.entries = parseJson(content)
    }
  }

  fn save(self) {
    mkdirp("${cwd()}/${CACHE_DIR}")
    let path = "${cwd()}/${CACHE_DIR}/cache.json"
    writeFile(path, toJson(self.entries))
  }
}

// Deterministic cache key derivation
// Same as MarrowScript's: sha256(canonicalize(input)) + "|" + model_ref + "|" + prompt_name
fn deriveKey(promptName: String, modelId: String, input: Map<String, Any>): String {
  let canonical = canonicalize(input)
  return sha256("${promptName}|${modelId}|${canonical}")
}

// Canonical JSON serialization (sorted keys, no whitespace)
fn canonicalize(obj: Map<String, Any>): String {
  let keys = obj.keys().sort()
  let parts = keys.map(|k| "\"${k}\":${toJson(obj.get(k))}")
  return "{${parts.join(",")}}"
}
