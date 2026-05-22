// SmallCode — Model Profiles (Runtime)
// Compiled from: src/model/profiles.ms
//
// Per-model capability profiles that drive routing, context budget, and tool format.
// Loaded from profiles/*.toml or auto-detected from model name patterns.

const KNOWN_PROFILES = {
  // ─── Gemma ─────────────────────────────────────────────────────────────
  'gemma-4': {
    context_length: 32768,
    max_output: 8192,
    supports_tool_calling: true,
    tool_format: 'native',
    strengths: ['code_completion', 'instruction_following', 'tool_use'],
    weaknesses: ['very_long_planning'],
  },
  'gemma-4-e4b': {
    context_length: 32768,
    max_output: 8192,
    supports_tool_calling: true,
    tool_format: 'native',
    strengths: ['speed', 'code_completion', 'tool_use'],
    weaknesses: ['complex_reasoning', 'multi_file'],
  },

  // ─── Qwen ──────────────────────────────────────────────────────────────
  'qwen3': {
    context_length: 32768,
    max_output: 8192,
    supports_tool_calling: true,
    tool_format: 'hermes',
    strengths: ['reasoning', 'code_generation', 'planning'],
    weaknesses: ['verbosity'],
  },
  'qwen2.5-coder': {
    context_length: 32768,
    max_output: 8192,
    supports_tool_calling: true,
    tool_format: 'hermes',
    strengths: ['code_completion', 'refactoring'],
    weaknesses: ['long_planning', 'multi_file'],
  },

  // ─── DeepSeek ──────────────────────────────────────────────────────────
  'deepseek-coder': {
    context_length: 16384,
    max_output: 4096,
    supports_tool_calling: true,
    tool_format: 'json',
    strengths: ['code_completion', 'debugging'],
    weaknesses: ['instruction_following', 'tool_use_reliability'],
  },

  // ─── CodeLlama / Llama ─────────────────────────────────────────────────
  'codellama': {
    context_length: 16384,
    max_output: 4096,
    supports_tool_calling: false,
    tool_format: 'text',
    strengths: ['code_completion'],
    weaknesses: ['tool_use', 'instruction_following', 'planning'],
  },
  'llama-3': {
    context_length: 8192,
    max_output: 4096,
    supports_tool_calling: true,
    tool_format: 'native',
    strengths: ['general_reasoning'],
    weaknesses: ['code_specific'],
  },

  // ─── Mistral / Nemo ────────────────────────────────────────────────────
  'mistral-nemo': {
    context_length: 128000,
    max_output: 4096,
    supports_tool_calling: true,
    tool_format: 'native',
    strengths: ['long_context', 'instruction_following'],
    weaknesses: ['code_specific'],
  },

  // ─── StarCoder ─────────────────────────────────────────────────────────
  'starcoder': {
    context_length: 8192,
    max_output: 4096,
    supports_tool_calling: false,
    tool_format: 'text',
    strengths: ['code_completion', 'infilling'],
    weaknesses: ['instruction_following', 'tool_use', 'planning'],
  },
};

/**
 * Match a model name to a known profile using fuzzy prefix matching.
 * @param {string} modelName - The model name from config (e.g. "huihui-gemma-4-e4b-it-abliterated")
 * @returns {object|null} Profile or null if no match
 */
function matchProfile(modelName) {
  const name = modelName.toLowerCase();

  // Try exact key matches first (longest match wins)
  const keys = Object.keys(KNOWN_PROFILES).sort((a, b) => b.length - a.length);
  for (const key of keys) {
    if (name.includes(key)) {
      return { ...KNOWN_PROFILES[key], matched_key: key };
    }
  }
  return null;
}

/**
 * Get the effective profile for a model, with defaults for unknowns.
 * @param {string} modelName
 * @param {number} detectedContextWindow - From endpoint auto-detection (0 if unknown)
 * @returns {object}
 */
function getProfile(modelName, detectedContextWindow = 0) {
  const matched = matchProfile(modelName);

  const profile = {
    context_length: detectedContextWindow || matched?.context_length || 32768,
    max_output: matched?.max_output || 4096,
    supports_tool_calling: matched?.supports_tool_calling ?? true,
    tool_format: matched?.tool_format || 'native',
    strengths: matched?.strengths || [],
    weaknesses: matched?.weaknesses || [],
    matched_key: matched?.matched_key || null,
  };

  return profile;
}

module.exports = { KNOWN_PROFILES, matchProfile, getProfile };
