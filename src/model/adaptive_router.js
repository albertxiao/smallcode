'use strict';
// MarrowScript Feature Rank 8 — AdaptiveModelRouter
// Tracks per-model failure rates and escalates to stronger models when the
// primary model is performing poorly.
//
// Environment variables:
//   SMALLCODE_MODEL_STRONG   — strong model name (e.g. gpt-4o, claude-3-5-sonnet)
//   SMALLCODE_MODEL_MEDIUM   — medium model name (e.g. qwen2.5-coder:32b)
//
// Usage:
//   const router = getAdaptiveRouter();
//   router.recordCall(modelName, success);
//   const { model, url } = router.selectModel(config);

/**
 * Adaptive model router.
 * Monitors per-model failure rates and switches to stronger models when
 * the current model's failure rate exceeds configured thresholds.
 */
class AdaptiveModelRouter {
  constructor() {
    /** @type {Map<string, { fails: number, calls: number }>} */
    this.failureRates = new Map();
  }

  /**
   * Record the outcome of a chatCompletion call.
   * @param {string}  modelName
   * @param {boolean} success
   */
  recordCall(modelName, success) {
    if (!modelName) return;
    const key = String(modelName);
    if (!this.failureRates.has(key)) {
      this.failureRates.set(key, { fails: 0, calls: 0 });
    }
    const entry = this.failureRates.get(key);
    entry.calls++;
    if (!success) entry.fails++;
  }

  /**
   * Get the failure rate for a model.
   * @param {string} modelName
   * @returns {number} 0.0 – 1.0
   */
  getFailureRate(modelName) {
    const entry = this.failureRates.get(String(modelName));
    if (!entry || entry.calls === 0) return 0;
    return entry.fails / entry.calls;
  }

  /**
   * Select the best model given current failure rates.
   * Returns the strong or medium model if the primary has poor reliability.
   *
   * Thresholds:
   *   > 0.6 failure rate → use SMALLCODE_MODEL_STRONG (if set)
   *   > 0.3 failure rate → use SMALLCODE_MODEL_MEDIUM (if set)
   *   otherwise          → use config.model.name
   *
   * Requires at least 3 calls to start making routing decisions, to avoid
   * thrashing on the very first failure.
   *
   * @param {object} config  — agent config with model.name and model.baseUrl
   * @returns {{ model: string, url: string }}
   */
  selectModel(config) {
    const primaryModel = config?.model?.name || '';
    const primaryUrl = config?.model?.baseUrl || '';

    if (!primaryModel) return { model: primaryModel, url: primaryUrl };

    const entry = this.failureRates.get(primaryModel);
    // Not enough data yet — use primary
    if (!entry || entry.calls < 3) return { model: primaryModel, url: primaryUrl };

    const rate = entry.fails / entry.calls;

    if (rate > 0.6) {
      const strong = process.env.SMALLCODE_MODEL_STRONG;
      if (strong && strong !== primaryModel) {
        return { model: strong, url: primaryUrl };
      }
    }

    if (rate > 0.3) {
      const medium = process.env.SMALLCODE_MODEL_MEDIUM;
      if (medium && medium !== primaryModel) {
        return { model: medium, url: primaryUrl };
      }
    }

    return { model: primaryModel, url: primaryUrl };
  }

  /**
   * Reset all tracked failure rates (called on new agent session or test runs).
   */
  reset() {
    this.failureRates.clear();
  }
}

// ─── Singleton ────────────────────────────────────────────────────────────────

let _instance = null;

/**
 * Get the singleton AdaptiveModelRouter.
 * @returns {AdaptiveModelRouter}
 */
function getAdaptiveRouter() {
  if (!_instance) _instance = new AdaptiveModelRouter();
  return _instance;
}

module.exports = { AdaptiveModelRouter, getAdaptiveRouter };
