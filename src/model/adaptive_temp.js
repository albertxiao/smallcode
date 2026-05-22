// SmallCode — Adaptive Retry Temperature (Feature 12)
//
// When the improvement loop retries a failed edit, the default temperature
// (usually 0.3-0.7) is used for every attempt. This causes the model to
// produce nearly identical outputs: same strategy, same mistake.
//
// We nudge temperature differently per attempt:
//   attempt 1 (initial fail)  → lower: become more deterministic, fix the exact error
//   attempt 2 (still failing) → higher: explore a different approach
//   attempt 3+                → back to original: the deterministic retry might finally work
//
// This is applied as a DELTA on top of the configured temperature, not an
// absolute value — so user config is always respected as the anchor.
//
// Configuration:
//   SMALLCODE_TEMP_ADAPT=false   disable entirely
//   SMALLCODE_TEMP_DELTA=0.15   how much to shift per attempt (default 0.15)
//   SMALLCODE_TEMP_MAX=1.0      clamp upper bound (default 1.0)
//   SMALLCODE_TEMP_MIN=0.0      clamp lower bound (default 0.0)

'use strict';

const DELTA = process.env.SMALLCODE_TEMP_DELTA !== undefined
  ? (isNaN(parseFloat(process.env.SMALLCODE_TEMP_DELTA)) ? 0.15 : parseFloat(process.env.SMALLCODE_TEMP_DELTA))
  : 0.15;
const MAX_T = process.env.SMALLCODE_TEMP_MAX !== undefined
  ? (isNaN(parseFloat(process.env.SMALLCODE_TEMP_MAX)) ? 1.0 : parseFloat(process.env.SMALLCODE_TEMP_MAX))
  : 1.0;
const MIN_T = process.env.SMALLCODE_TEMP_MIN !== undefined
  ? (isNaN(parseFloat(process.env.SMALLCODE_TEMP_MIN)) ? 0.0 : parseFloat(process.env.SMALLCODE_TEMP_MIN))
  : 0.0;

/**
 * Return an adjusted temperature for a retry attempt.
 *
 * @param {number} baseTemp   - The model's configured temperature
 * @param {number} attempt    - 1-indexed retry attempt number (0 = first call, no adjust)
 * @param {object} options
 * @param {boolean} options.isRepair - Whether this is a validation-repair attempt
 * @returns {number}  adjusted temperature
 */
function adaptTemperature(baseTemp, attempt, options = {}) {
  if (process.env.SMALLCODE_TEMP_ADAPT === 'false') return baseTemp;
  if (typeof baseTemp !== 'number' || isNaN(baseTemp)) return baseTemp;
  if (attempt <= 0) return baseTemp;

  let delta;
  if (options.isRepair) {
    // Repair attempts follow: low → high → original → low → high ...
    const phase = attempt % 3;
    if (phase === 1) delta = -DELTA;       // attempt 1: go deterministic
    else if (phase === 2) delta = +DELTA;  // attempt 2: explore
    else delta = 0;                        // attempt 3: back to base
  } else {
    // Non-repair (e.g. clarification retry): just nudge up slightly to vary
    delta = Math.min(attempt * 0.05, DELTA);
  }

  return Math.min(MAX_T, Math.max(MIN_T, +(baseTemp + delta).toFixed(3)));
}

/**
 * Apply the adapted temperature directly to a request body.
 * No-op if no temperature field exists in the body.
 *
 * @param {object} body    - Chat completion request body
 * @param {number} attempt - 1-indexed attempt
 * @param {object} options - { isRepair }
 */
function applyAdaptiveTemperature(body, attempt, options = {}) {
  if (process.env.SMALLCODE_TEMP_ADAPT === 'false') return body;
  if (!body || typeof body !== 'object') return body;
  // Only adapt if the body already has a temperature field
  if (typeof body.temperature !== 'number') return body;
  body.temperature = adaptTemperature(body.temperature, attempt, options);
  return body;
}

module.exports = {
  adaptTemperature,
  applyAdaptiveTemperature,
  DELTA,
  MAX_T,
  MIN_T,
};
