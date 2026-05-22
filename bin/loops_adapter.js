// SmallCode — Bounded Loop Adapter
// Wraps the MarrowScript-compiled loop runtime for use in the agent loop.
// Replaces hand-rolled improvement iterations with bounded, traced loops.

let _loopsMod = null;
let _flowsMod = null;

function _getLoops() {
  if (_loopsMod) return _loopsMod;
  try {
    _loopsMod = require('../src/compiled/cognition/loops');
    return _loopsMod;
  } catch { return null; }
}

function _getFlows() {
  if (_flowsMod) return _flowsMod;
  try {
    _flowsMod = require('../src/compiled/flows');
    return _flowsMod;
  } catch { return null; }
}

/**
 * Run a bounded validation loop on a file.
 * Validates → if fails, returns errors for fixing → re-validates → repeat.
 * Max iterations enforced. Returns { passed, attempts, errors }.
 *
 * @param {function} validateFn - (filePath) => { passed, errors[] } | null
 * @param {string} filePath - Path to validate
 * @param {number} maxIterations - Max fix attempts (default 2)
 * @returns {{ passed: boolean, attempts: number, lastErrors: string[] }}
 */
async function runBoundedValidation(validateFn, filePath, maxIterations = 2) {
  const loops = _getLoops();

  // If compiled loops not available, fall back to simple counting
  if (!loops || !loops.runLoop) {
    // Simple fallback: just validate and return
    const result = validateFn(filePath);
    if (!result) return { passed: true, attempts: 0, lastErrors: [] };
    return { passed: result.passed, attempts: 1, lastErrors: result.errors || [] };
  }

  // Use compiled bounded loop
  let lastErrors = [];
  let attempts = 0;

  const loopResult = await loops.runLoop({
    name: `validate_${filePath}`,
    max_iterations: maxIterations,
    trace_id: require('crypto').randomUUID(),
    step: async (state) => {
      attempts++;
      const validation = validateFn(filePath);
      if (!validation) return { passed: true, errors: [] };
      lastErrors = validation.errors || [];
      return validation;
    },
    validate: (output) => output.passed === true,
  });

  return {
    passed: loopResult.final ? loopResult.final.passed : false,
    attempts,
    lastErrors,
    exhausted: loopResult.exhausted || false,
  };
}

/**
 * Execute a flow (saga) with backward compensation on failure.
 * @param {string} name - Flow name for tracing
 * @param {Array} steps - [{ name, action: async(ctx)=>void, compensate: async(ctx)=>void|null }]
 * @param {object} ctx - Shared context
 * @returns {{ ok: boolean, failed_step?: string, compensated: string[], error?: string }}
 */
async function executeFlow(name, steps, ctx) {
  const flows = _getFlows();

  if (!flows || !flows.executeFlow) {
    // Fallback: just run steps sequentially, no compensation
    for (const step of steps) {
      try {
        await step.action(ctx);
      } catch (e) {
        return { ok: false, failed_step: step.name, compensated: [], error: e.message };
      }
    }
    return { ok: true, compensated: [] };
  }

  return flows.executeFlow(name, steps, ctx);
}

module.exports = { runBoundedValidation, executeFlow };
