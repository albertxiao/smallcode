# Knowledge Notes

Drop short reference docs into this directory and SmallCode will inject the
most relevant ones into the system prompt based on keyword overlap with your
prompt. Designed for small models that benefit from algorithm cheat sheets
or syntax reminders inline.

## Layout

```
knowledge/
  algorithms/
    binary-search.md
    quicksort.md
  syntax/
    python-fstrings.md
    typescript-generics.md
  conventions/
    git-commit-style.md
```

## File format

Plain Markdown. The first `# Heading` is used as the title. Optional YAML
front-matter controls when the note gets injected:

```markdown
---
keywords: [search, sort, binary, log-n]
---

# Binary Search

Logarithmic-time lookup in a sorted array. Compare middle element, recurse
left or right based on comparison.
```

If you skip the front-matter, keywords are inferred from the path and the
first heading.

## Selection

For each user prompt, SmallCode tokenizes the message, scores each note by
keyword overlap, and picks the top hits up to the budget (default 1500
tokens). Notes are deliberately small — keep each one under 500 words.

## Configuration

- `SMALLCODE_KNOWLEDGE_DIR=./knowledge` — override the directory
- `SMALLCODE_KNOWLEDGE_MAX_TOKENS=1500` — per-message injection cap
- `SMALLCODE_KNOWLEDGE_DISABLE=true` — turn it off
