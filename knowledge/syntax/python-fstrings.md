---
keywords: [python, format, string, fstring, interpolation]
---

# Python f-strings

Interpolated strings introduced in Python 3.6.

```python
name = "Alice"
age = 30
greeting = f"Hello, {name}! You are {age} years old."
# Hello, Alice! You are 30 years old.

# Format specifiers
pi = 3.14159
print(f"{pi:.2f}")          # 3.14
print(f"{1234567:,}")       # 1,234,567
print(f"{0.42:.0%}")        # 42%

# Self-documenting expressions (Python 3.8+)
x = 42
print(f"{x=}")              # x=42
```

For strings with literal braces, double them: `f"{{not a placeholder}}"`.
