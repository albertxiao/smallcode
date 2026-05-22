// SmallCode - Configuration Module
// Loads and validates project + user-level config

import { readFile, pathExists } from "std/fs"
import { parse as parseToml } from "std/toml"
import { merge } from "std/objects"
import { homedir, cwd } from "std/env"

// Default configuration values
const DEFAULTS = {
  model: {
    provider: "ollama",
    name: "qwen2.5-coder-14b",
    context_length: null,
    tool_format: null,
  },
  context: {
    max_budget_pct: 70,
    working_memory_tokens: 500,
    summary_threshold: 200,
  },
  tools: {
    enabled: ["read_file", "write_file", "patch", "bash", "search", "find_files", "symbols", "memory", "plan"],
    disabled: [],
    bash_timeout: 30,
  },
  planner: {
    auto_plan: true,
    max_retries: 2,
    validate_after_edit: true,
  },
  hooks: {},
  tui: {
    theme: "dark",
    show_token_usage: true,
    auto_approve: false,
  },
}

struct Config {
  model: ModelConfig
  context: ContextConfig
  tools: ToolsConfig
  planner: PlannerConfig
  hooks: Map<String, String>
  tui: TuiConfig
}

struct ModelConfig {
  provider: String
  name: String
  context_length: Int?
  tool_format: String?
}

struct ContextConfig {
  max_budget_pct: Int
  working_memory_tokens: Int
  summary_threshold: Int
}

struct ToolsConfig {
  enabled: List<String>
  disabled: List<String>
  bash_timeout: Int
}

struct PlannerConfig {
  auto_plan: Bool
  max_retries: Int
  validate_after_edit: Bool
}

struct TuiConfig {
  theme: String
  show_token_usage: Bool
  auto_approve: Bool
}

// Load config from multiple sources with precedence:
// project config > user config > defaults
pub fn loadConfig(): Config {
  let userConfigPath = "${homedir()}/.config/smallcode/config.toml"
  let projectConfigPath = "${cwd()}/smallcode.toml"

  let config = DEFAULTS

  // Layer user config
  if pathExists(userConfigPath) {
    let userRaw = readFile(userConfigPath)
    let userConfig = parseToml(userRaw)
    config = merge(config, userConfig)
  }

  // Layer project config (highest priority)
  if pathExists(projectConfigPath) {
    let projectRaw = readFile(projectConfigPath)
    let projectConfig = parseToml(projectRaw)
    config = merge(config, projectConfig)
  }

  return config as Config
}

// Get the active tools list (enabled minus disabled)
pub fn activeTools(config: Config): List<String> {
  return config.tools.enabled.filter(|t| !config.tools.disabled.contains(t))
}
