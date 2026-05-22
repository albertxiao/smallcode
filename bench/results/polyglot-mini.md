# Polyglot-Mini Benchmark Results

19 short coding tasks across 6 languages. Each task runs in an isolated temp
workspace — no shared state, no internet, no installed toolchain required for
the verify step (all checks are file-content based).

## Latest result

| Model | Pass rate | Mean time/task | Date |
|---|---|---|---|
| huihui-gemma-4-e4b-it-abliterated (8B) | **19/19 (100%)** | 11.3s | 2026-05-21 |

## Per-language breakdown

| Language | Tasks | Passed |
|---|---|---|
| Python | 5 | 5 |
| JavaScript | 4 | 4 |
| TypeScript | 3 | 3 |
| Shell | 3 | 3 |
| Markdown | 2 | 2 |
| JSON | 2 | 2 |

## Setup

Requires a running OpenAI-compatible endpoint. Set `SMALLCODE_BASE_URL` and
`SMALLCODE_MODEL` in `.env`, then:

```bash
npm run bench:polyglot
```

Results are saved to `.smallcode/benchmarks/<run-id>.json`.

## Notes

- Run on Windows with LM Studio serving the model locally at `10.0.0.20:1234`
- Timeout per task: 120s
- The model used is an 8B parameter model — larger models will generally score
  higher and run faster
