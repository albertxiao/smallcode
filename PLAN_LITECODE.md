# Implementation Plan: Litecode Architecture Features
*Based on: "Lessons from building a coding agent for 8k context windows"*
*Reference: https://github.com/razvanneculai/litecode*

Four improvements mapped to SmallCode's existing architecture. Each section has a precise file-level implementation spec.

---

## Feature 1: Parallel Executor

**What it does:** Independent file edits run simultaneously instead of sequentially.  
**Why it matters:** A 5-file refactor currently takes 5× as long as a 1-file edit. With parallel execution it takes as long as the slowest single edit.  
**Effort: High | Impact: 5**

### Current state
`runAgentLoop` in `bin/smallcode.js` is fully sequential. Every tool call waits for the previous one to complete before the model sees the result and issues the next call. There is no mechanism to execute independent tool calls in parallel.

### Architecture

The insight is that after the planner emits a numbered plan, steps that touch different files can be executed concurrently. The dependency graph is built in pure code (no LLM call).

```
User prompt → Planner call (lightweight, sees only project map + task)
           → Task list with per-step file targets
           → Dependency graph builder (pure code)
           → Parallel executor: runs independent steps concurrently
           → Merge results → single final response
```

### Implementation

**New file: `src/session/parallel_executor.js`**

```js
// Builds a dependency graph from a plan's step list.
// Two steps are dependent if:
//   - One step's output file is another step's input file, OR
//   - They share a file path, OR
//   - One step explicitly mentions "after step N"
function buildDependencyGraph(steps) { ... }

// Given a dependency graph, returns batches of step indices
// that can safely run in parallel.
// e.g. steps [0,1,2] where 1 depends on 0 → [[0,2], [1]]
function toParallelBatches(graph) { ... }

// Execute a batch of tool calls concurrently using Promise.all.
// Each call gets its own AbortController for timeout handling.
async function executeBatch(batch, executeToolFn, config) { ... }
```

**Changes to `bin/smallcode.js`**

1. After `_planTracker.ingestResponseAsync()` succeeds, pass the plan to `buildDependencyGraph()`.
2. If the dependency graph has at least one parallel batch (≥2 independent steps), route through `executeBatch()` instead of the normal tool loop.
3. Merge all tool results back into `conversationHistory` in dependency order (not execution order) so the model gets a coherent history.
4. Gate behind `SMALLCODE_PARALLEL=true` env var — off by default until validated.

**New env var:** `SMALLCODE_PARALLEL=true`

**File-level isolation contract:** Each parallel executor call must only see:
- System prompt (shared, read-only)
- Its own single task instruction
- The content of its target file(s)
- No prior tool results from sibling parallel steps

This is enforced by constructing a per-task `messages` array that excludes sibling results.

### Testing
- Smoke bench must stay 5/5 with `SMALLCODE_PARALLEL=false` (default)
- New bench case: 3-file refactor should complete in ≤ max(individual times) + 15% overhead when `SMALLCODE_PARALLEL=true`

---

## Feature 2: `action_type` Query Routing

**What it does:** Planner classifies each step as `query` (read-only, no disk writes) or `mutate` (can write). Query steps are routed through a separate code path that never touches disk.  
**Why it matters:** Without this, "how many lines does X have?" triggers a `write_file` call in some model responses. Currently the write-guard catches some of these but not all.  
**Effort: Low | Impact: 3**

### Current state
The tool router (`src/compiled/tool_router.js`) classifies by task type but has no concept of query vs mutate intent. The `read_before_write` guard (`src/session/read_before_write.js`) blocks first-write-without-read but doesn't distinguish "the model wants to answer, not write."

### Architecture

Add a pre-execution classifier that runs on each plan step before any tool calls:

```
Plan step text → action_type classifier → "query" | "mutate"
  "query"  → tools = [read_file, bash, search, find_files, graph_search, explain_symbol]
             (no write_file, patch, append_file)
  "mutate" → tools = full set (existing behavior)
```

### Implementation

**New file: `src/session/action_classifier.js`**

```js
const QUERY_PATTERNS = [
  /^(how many|how much|count|list|show|what is|what are|find|search|look|check|verify|confirm|does|is there|are there)/i,
  /\?$/,  // ends with question mark
  /\b(read|show me|display|print|output|explain|describe|summarize)\b/i,
];

const MUTATE_PATTERNS = [
  /\b(create|write|add|insert|delete|remove|rename|move|refactor|update|fix|change|replace|modify|implement|generate)\b/i,
];

/**
 * Classify a plan step as query (read-only) or mutate (can write).
 * Returns 'query' | 'mutate'.
 * Defaults to 'mutate' if ambiguous — safer to allow writes than block them.
 */
function classifyAction(stepText) { ... }

/**
 * Given action_type, return the allowed tool names for this step.
 */
function getToolsForActionType(actionType, allTools) { ... }
```

**Changes to `bin/smallcode.js`**

In the plan execution section, after each step starts:
1. Call `classifyAction(currentStepText)` 
2. If `'query'`, filter `currentTools` to exclude `write_file`, `patch`, `append_file`, `create_and_run`
3. Log `✓ query step — write tools disabled` in TUI

**Changes to `src/compiled/tool_router.js`**

Add `query` as a valid category in `CATEGORIES`. Map it to `[read_file, bash, search, find_files, graph_search, explain_symbol, memory_load]`.

### Edge cases
- If model outputs a write tool call during a `query` step, reject with message: `"This step is read-only. Use a read tool or rephrase the plan step."`
- Do not block `bash` — bash can both read and write; model must be trusted to use it appropriately in query mode

---

## Feature 3: Dependency Graph Orchestrator (Pure Code)

**What it does:** Builds a dependency graph between plan steps in pure code (no LLM). Decides which steps run in parallel vs sequential. The orchestrator is deterministic and has zero token cost.  
**Why it matters:** Without a dependency graph, parallel execution is unsafe — step 2 might overwrite step 1's output if they touch the same file.  
**Effort: Medium | Impact: 4**

### Current state
`PlanTracker` in `src/session/plan_tracker.js` tracks a linear ordered list of steps. There is no concept of dependencies between steps and no parallel execution.

### Architecture

```
Plan steps (string[])
  → file mention extractor (regex, no LLM)
  → dependency detector (same file = dependency)
  → DAG builder (pure JS, adjacency list)
  → topological sort → parallel batches
```

### Implementation

**New file: `src/session/dependency_graph.js`**

```js
/**
 * Extract file paths mentioned in a step description.
 * Handles: "edit foo.py", "update src/bar.ts", "fix the handler in api/routes.js"
 * Returns string[] of normalized paths.
 */
function extractFileMentions(stepText, cwd) { ... }

/**
 * Build a dependency adjacency list from a plan step array.
 * Two steps are dependent (i → j, j depends on i) if:
 *   1. They mention the same file path (write conflict)
 *   2. Step j text says "after step i" or "once step i is done"
 *   3. Step i produces an artifact (create/write) that step j consumes (import/use)
 * 
 * Returns Map<stepIndex, Set<stepIndex>> (j depends on i → map[j].has(i))
 */
function buildDependencyGraph(steps, cwd) { ... }

/**
 * Topological sort → parallel execution batches.
 * Returns number[][] where each inner array is a batch of
 * step indices that can run concurrently.
 * 
 * Example: steps [0,1,2,3] where 2 depends on 0, 3 depends on 1
 * → [[0,1], [2,3]]  (steps 0 and 1 run first in parallel, then 2 and 3)
 */
function toParallelBatches(graph, totalSteps) { ... }

/**
 * Validate that all file paths mentioned in plan steps exist on disk.
 * Returns { valid: bool, missing: string[] }
 * Called by orchestrator before execution starts.
 */
function validateFilePaths(steps, cwd) { ... }
```

**Changes to `src/session/plan_tracker.js`**

Add `buildExecutionOrder(cwd)` method to `PlanTracker` that:
1. Calls `buildDependencyGraph(this.plan, cwd)`
2. Calls `toParallelBatches(graph, this.plan.length)`
3. Returns the batch array, caches it as `this.executionBatches`

**Changes to `bin/smallcode.js`**

After plan extraction succeeds:
1. Call `_planTracker.buildExecutionOrder(process.cwd())`
2. Log batch structure in TUI: `✓ plan: 3 batches, 2 parallel`
3. Pass batches to parallel executor (Feature 1) if `SMALLCODE_PARALLEL=true`

---

## Feature 4: File Path Validation Before Execution

**What it does:** After the model emits a plan, validate that every file path mentioned in plan steps actually exists on disk before any tool calls start. Throw a clear error on missing paths instead of silently misrouting.  
**Why it matters:** When a model hallucinates a path (or the user renamed a file), the current behavior routes to the closest match or writes to a wrong location. Early validation surfaces the problem immediately with a useful error message.  
**Effort: Low | Impact: 3**

### Current state
No pre-execution path validation exists. `read_before_write` guard only checks at write time. Hallucinated paths produce confusing errors mid-task.

### Implementation

This is entirely new code in the orchestrator layer, no existing code changes needed except wiring.

**New function in `src/session/dependency_graph.js`** (part of Feature 3's file)

```js
/**
 * Extract all file path tokens from a string.
 * Matches: relative paths (foo.py, src/bar.ts), absolute paths (/app/foo.c),
 * quoted paths ("foo.py", 'src/bar.ts'), backtick paths (`foo.py`).
 * Returns string[] of candidate paths.
 */
function extractPathTokens(text) {
  const patterns = [
    /`([^`]+\.[a-zA-Z0-9]{1,6})`/g,          // backtick paths
    /"([^"]+\.[a-zA-Z0-9]{1,6})"/g,           // double-quoted
    /'([^']+\.[a-zA-Z0-9]{1,6})'/g,           // single-quoted
    /\b([\w./\\-]+\.[a-zA-Z0-9]{1,6})\b/g,   // bare paths with extension
  ];
  ...
}

/**
 * For each extracted path, check fs.existsSync(path.resolve(cwd, p)).
 * Returns { missing: string[], found: string[] }.
 * Only validates paths that look like source files (have extensions, not URLs).
 */
function validatePlanPaths(planSteps, cwd) { ... }
```

**Changes to `bin/smallcode.js`**

After `_planTracker.ingestResponseAsync()` succeeds, immediately call `validatePlanPaths()`:

```js
try {
  const { validatePlanPaths } = require('../src/session/dependency_graph');
  const { missing } = validatePlanPaths(_planTracker.plan, process.cwd());
  if (missing.length > 0) {
    const msg = `[PATH-VALIDATION] Plan references files that don't exist: ${missing.join(', ')}. ` +
                `Check file names or run \`find_files\` to locate the correct paths.`;
    conversationHistory.push({ role: 'system', content: msg });
    // Inject into TUI
    if (_fullscreenRef) _fullscreenRef.addTool('warning', 'warn', `missing: ${missing.join(', ')}`);
  }
} catch {}
```

Note: This is advisory, not blocking. The warning is injected as a system message so the model can self-correct (run `find_files` to locate the right path) rather than hard-erroring.

**Why advisory not blocking:** The model sometimes correctly creates NEW files that don't exist yet. Hard-blocking on missing paths would break `create X.py` type tasks. The warning gives the model information to correct hallucinated paths without preventing legitimate new-file creation.

---

## Implementation Order

| # | Feature | Files | Effort | Ship as |
|---|---------|-------|--------|---------|
| 4 | Path validation | `src/session/dependency_graph.js` (new), `bin/smallcode.js` | 2h | v0.9.9 |
| 2 | Query routing | `src/session/action_classifier.js` (new), `bin/smallcode.js`, `src/compiled/tool_router.js` | 3h | v0.9.9 |
| 3 | Dependency graph | `src/session/dependency_graph.js` (extend), `src/session/plan_tracker.js` | 4h | v1.0.0 |
| 1 | Parallel executor | `src/session/parallel_executor.js` (new), `bin/smallcode.js` | 8h | v1.0.0 |

Start with 4 and 2 (low-effort, ship together as v0.9.9). Then 3 and 1 together (they're coupled — the graph feeds the executor) as v1.0.0.

## Smoke test gate

Before committing any feature:
```
node bench/harness.js --suite smoke --timeout 120
```
Must show 5/5 (100%) with default settings (`SMALLCODE_PARALLEL` not set).
