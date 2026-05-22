# MarrowScript Feature Roadmap — SmallCode Integration

Features ranked by ease of implementation (1=trivial, 5=hard) and UX impact (1=minor, 5=game-changer). Current `.marrow` declarations compile to `src/compiled/` and `bin/features_adapter.js`.

---

## Tier 1: Low effort, high impact

### 1. `prompt intent_clarifier` — Smart ambiguity detection
**Ease: 1 | Impact: 4**

Replace the hand-rolled regex in `src/session/clarify.js` with a MarrowScript prompt declaration. The compiled version gets caching (identical vague prompts → instant response), retry on failure, and a tiny classifier model call that's far more accurate than regex heuristics.

```marrow
prompt intent_clarifier(user_message: string) {
  model: TinyClassifier
  timeout: 2s
  cache: { key: hash(user_message), ttl: 30m }
  returns: { clear: bool, question: string? }
}
```

### 2. `prompt commit_message` — Auto-generated commit messages
**Ease: 1 | Impact: 3**

When the agent finishes a task, generate a conventional commit message from the git diff. Currently hand-rolled in `bin/smallcode.js` as a string template. A MarrowScript declaration adds caching + validation (must be <72 chars, must start with `feat:`/`fix:`/`chore:`).

```marrow
prompt commit_message(diff: string, task: string) {
  model: TinyClassifier
  timeout: 5s
  cache: { key: hash(diff), ttl: 1h }
  constraints: [output.length <= 72, output matches "^(feat|fix|chore|docs|refactor|test|ci):"]
}
```

### 3. `prompt extract_plan` — Compiled plan parser
**Ease: 1 | Impact: 4**

Replace the regex-based `parsePlan()` in `src/session/plan_tracker.js` with a tiny LLM call that extracts structured steps from ANY response format — not just numbered lists. Handles edge cases like plans embedded in prose.

```marrow
prompt extract_plan(response: string) {
  model: TinyClassifier
  timeout: 3s
  returns: string[]
  constraints: [output.length >= 2, output.length <= 8]
  on_invalid: fail
}
```

### 4. `category code_intel` — Code graph query routing
**Ease: 1 | Impact: 3**

Add a new category to `tool_router.marrow` for code-intelligence queries ("how does X work", "what calls Y", "show me the inheritance tree"). Currently these hit `search` but should route to `graph_search`/`explain_symbol` with higher confidence.

### 5. `prompt error_diagnosis` — Structured error analysis
**Ease: 2 | Impact: 4**

When `bash` returns a non-zero exit code, run the error through a tiny classifier that outputs `{ type, file, line, suggestion }`. Currently the model sees raw stderr and guesses. This gives it structured input for the fix attempt.

```marrow
prompt error_diagnosis(command: string, stderr: string, exit_code: int) {
  model: TinyClassifier
  timeout: 5s
  returns: { type: string, file: string?, line: uint?, suggestion: string }
  cache: { key: hash(stderr), ttl: 5m }
}
```

---

## Tier 2: Moderate effort, high impact

### 6. `flow multi_file_edit` — Orchestrated multi-file changes
**Ease: 3 | Impact: 5**

A compiled flow that coordinates reading, planning, editing, and validating across multiple files as an atomic unit. Uses the snapshot system for rollback. Eliminates the most common failure mode on small models: editing file A, forgetting the import change in file B.

```marrow
flow multi_file_edit {
  step plan: extract_plan(ctx.task)
  step read_all: parallel_read(plan.files)
  step edit: for_each(plan.steps) { apply_edit(step) }
  step validate: parallel_validate(plan.files)
    compensate: rollback_all(plan.files)
}
```

### 7. `prompt semantic_merge` — Intelligent conflict resolution
**Ease: 3 | Impact: 4**

When `patch` fails because `old_str` changed between read and write, run a merge prompt that resolves the conflict using context from both the model's intent and the current file state. Currently just errors "old_str not found."

```marrow
prompt semantic_merge(file: string, intended_change: string, current_content: string) {
  model: SmallCoder
  timeout: 15s
  returns: string
  validate: { compiles: true, preserves_intent: true }
}
```

### 8. `router adaptive_model_select` — Runtime model switching
**Ease: 3 | Impact: 5**

Replace static model config with a router that learns from the current session: if the fast model keeps failing on a particular task type, automatically escalate to the medium model for the rest of the turn. Decay back to fast on next turn.

```marrow
router adaptive_model_select {
  by: session.failure_rate(model)
  tier fast    { failure_rate < 0.3 -> TinyClassifier }
  tier medium  { failure_rate < 0.6 -> SmallCoder }
  tier strong  {                    -> MediumCoder }
  decay: per_turn
}
```

### 9. `prompt test_generator` — Property-based test synthesis
**Ease: 3 | Impact: 4**

After writing a function, generate a minimal test that exercises the happy path + one edge case. Outputs a valid test file in the project's test framework (detected via test-runner). Cached by function signature hash.

```marrow
prompt test_generator(function_code: string, file_path: string, framework: string) {
  model: SmallCoder
  timeout: 20s
  cache: { key: hash(function_code), ttl: 1h }
  validate: { valid_syntax: true, imports_correct: true }
  constraints: [output contains "assert" or "expect" or "test"]
}
```

### 10. `flow verify_and_fix` — Compiled improvement loop
**Ease: 2 | Impact: 5**

Fully replace the 200+ line hand-rolled improvement loop in `bin/smallcode.js` with a compiled bounded loop from MarrowScript. Gets traces, budget enforcement, and retry strategy from the compiler for free.

```marrow
loop verify_and_fix {
  max_iterations: 3
  pattern: generate_validate
  step generate: fix_errors(ctx.file, ctx.errors, ctx.history)
  step validate: run_linter(ctx.file)
  terminate_when: validate.passed == true
  on_exhausted: decompose
}
```

---

## Tier 3: Moderate effort, moderate impact

### 11. `prompt summarize_changes` — Turn-end summary
**Ease: 2 | Impact: 3**

Generate a one-paragraph summary of what was accomplished this turn. Currently `streamFinalResponse` uses a hand-rolled prompt. The compiled version gets caching, token cap, and consistent format.

### 12. `prompt file_relevance_score` — Semantic file scoring
**Ease: 2 | Impact: 3**

Replace the heuristic scoring in `src/tools/file_tree.js` with a tiny LLM call that scores file relevance against the task. Falls back to the regex scorer on timeout. Improves `find_files` accuracy significantly for complex tasks.

### 13. `capability memory_prune` — Intelligent memory garbage collection
**Ease: 2 | Impact: 3**

When the memory store exceeds a threshold, run a classifier over all entries to determine which are still relevant. Prune low-value memories rather than FIFO eviction. Keeps the loadForTask results high-quality over long sessions.

### 14. `prompt decompose_task` — Compiled task decomposition
**Ease: 2 | Impact: 4**

The `pickDecomposeStrategy` in `bin/governor.js` uses hand-rolled heuristics. A MarrowScript prompt declaration would produce better decomposition strategies by actually understanding the code context.

```marrow
prompt decompose_task(task: string, errors: string, file_context: string) {
  model: SmallCoder
  timeout: 15s
  returns: { strategy: string, sub_tasks: string[] }
  constraints: [output.sub_tasks.length >= 2, output.sub_tasks.length <= 5]
}
```

### 15. `flow code_review` — Full review pipeline
**Ease: 3 | Impact: 3**

Compile the reviewer agent (Feature #18) into a MarrowScript flow with structured output parsing, confidence scoring, and auto-retry. Currently it's a raw fetch call.

```marrow
flow code_review {
  step review: review_response(ctx.task, ctx.code, ctx.files)
  step decide: if review.confidence > 0.7 and not review.ok
    then inject_feedback(review.issues)
    else pass
}
```

---

## Tier 4: High effort, high impact

### 16. `system AgentOrchestrator` — Multi-agent coordination
**Ease: 4 | Impact: 5**

Declare separate agents (planner, coder, reviewer, tester) as MarrowScript prompts with different models and responsibilities. The compiler generates the message-passing protocol and coordination logic. The ultimate MarrowScript demo.

```marrow
system AgentOrchestrator {
  agent planner { model: TinyClassifier, role: "decompose tasks into steps" }
  agent coder   { model: SmallCoder, role: "implement code changes" }
  agent reviewer { model: TinyClassifier, role: "critique code for bugs" }
  agent tester  { model: SmallCoder, role: "generate and run tests" }
  
  flow collaborate {
    step plan: planner.plan(ctx.task)
    step code: coder.implement(plan.steps)
    step review: reviewer.critique(code.output)
    step test: tester.verify(code.files)
    compensate: rollback_all
  }
}
```

### 17. `capability speculative_tool` — Pre-warm likely next tool
**Ease: 4 | Impact: 4**

Predict the next tool call from pattern history (read→patch, write→bash validate) and pre-load its schema + relevant context before the model even requests it. Saves one round-trip on 70% of tool sequences.

### 18. `flow git_workflow` — Compiled git operations
**Ease: 3 | Impact: 4**

Full git workflow as a MarrowScript flow: branch creation, staged commits, PR description generation, conflict resolution. Currently hand-rolled in `bin/commands.js`.

```marrow
flow git_workflow {
  step branch: create_branch(ctx.task)
  step commit: commit_changes(ctx.diff)
    validate: commit_message_format
  step pr: generate_pr_description(ctx.commits)
}
```

### 19. `router language_specialist` — Per-language model routing
**Ease: 3 | Impact: 4**

Route Python tasks to a Python-specialized model, TypeScript to a TS model, etc. When running locally with multiple models loaded, this maximizes quality per language without a single generalist model doing everything.

```marrow
router language_specialist {
  by: ctx.detected_language
  tier python     { -> PythonModel }
  tier typescript { -> TypeScriptModel }
  tier rust       { -> RustModel }
  fallback: SmallCoder
}
```

---

## Tier 5: High effort, transformative impact

### 20. `system SelfImproving` — Meta-learning loop
**Ease: 5 | Impact: 5**

The compiler generates a system that tracks which prompt strategies work best for specific task types, then auto-tunes the prompts over time. After N sessions, the system is empirically optimized for YOUR model + your coding style.

```marrow
system SelfImproving {
  meta_loop {
    observe: track(prompt_id, task_type, success_rate, token_cost)
    analyze: every 50 tasks { rank_strategies_by_success() }
    adapt: replace_underperforming_prompts(threshold: 0.4)
    constraint: never modify validated prompts without A/B test
  }
}
```

### 21. `capability knowledge_distill` — Session → permanent knowledge
**Ease: 4 | Impact: 4**

After a successful multi-step task, automatically distill the approach into a reusable knowledge note (written to `knowledge/`). Next time a similar task arrives, the knowledge note is injected directly — zero re-discovery cost.

### 22. `flow interactive_debug` — Compiled debugging session
**Ease: 5 | Impact: 5**

A full debugging flow: reproduce error → analyze stack → hypothesize root cause → test hypothesis → fix → verify. Each step is a separate MarrowScript prompt with its own retry/validate chain. The current ad-hoc "run it and see" approach gets replaced with systematic debugging.

---

## Priority Matrix

```
          HIGH IMPACT
              │
    ┌─────────┼─────────┐
    │ 6  8 10 │ 16 20 22│  ← HIGH EFFORT
    │  7  9 14│ 17 18 19│
    ├─────────┼─────────┤
    │ 1  3  5 │ 11 12 13│  ← LOW EFFORT
    │  2  4   │ 15 21   │
    └─────────┼─────────┘
          LOW IMPACT
```

**Recommended implementation order:**
1. `#1` intent_clarifier (trivial, replaces worst regex)
2. `#5` error_diagnosis (turns blind retries into targeted fixes)
3. `#10` verify_and_fix (replaces 200 lines of hand-rolled loop)
4. `#6` multi_file_edit (addresses #1 user pain point)
5. `#8` adaptive_model_select (self-tuning model routing)
6. `#9` test_generator (automatic quality gate)
7. `#16` AgentOrchestrator (the MarrowScript killer demo)
