# SmallCode Benchmarks

Run these to measure how well your model handles real coding tasks.

## Quick start

```bash
# Sanity check — 5 trivial tasks, ~30s
npm run bench:smoke

# Full polyglot suite — 19 tasks across Python/JS/TS/Shell/Markdown/JSON
npm run bench:polyglot

# Multi-step tool-use tasks — persistent shell, env vars, renames, etc.
npm run bench:tools

# List available suites
npm run bench:list
```

Results are saved to `.smallcode/benchmarks/<run-id>.json` and printed to stdout.

## Options

```bash
node bench/harness.js --suite polyglot-mini --timeout 120
node bench/harness.js --suite smoke --model my-model --base-url http://localhost:1234/v1
node bench/harness.js --suite tool-use --task fix-from-error   # single task
```

| Flag | Default | Description |
|---|---|---|
| `--suite` | `smoke` | Which suite to run |
| `--timeout` | `240` | Seconds per task before kill |
| `--model` | from `.env` | Override model name |
| `--base-url` | from `.env` | Override API base URL |
| `--task` | all | Run a single task by ID |
| `--list` | — | List suites and exit |

## Suites

**smoke** (5 tasks) — Basic sanity check. Should pass in ~30s on any capable model.

**polyglot-mini** (19 tasks) — Short exercises across Python, JavaScript, TypeScript,
Shell, Markdown, and JSON. Inspired by Aider's Polyglot benchmark. No toolchain
required — all verify steps are file-content checks.

**tool-use** (10 tasks) — Multi-step tasks that exercise the persistent shell
(env vars across calls, cd + write), multi-file edits, and JSON config updates.

## Baselines

See `results/` for recorded baseline runs. Contribute your own by running the
benchmark and opening a PR with your results added to the table.
