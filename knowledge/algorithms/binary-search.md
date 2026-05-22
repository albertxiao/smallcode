---
keywords: [search, sort, binary, log-n, bisect]
---

# Binary Search

O(log n) lookup in a sorted array. Compare the middle element to the target,
recurse on the half that could contain it.

```python
def binary_search(arr, target):
    lo, hi = 0, len(arr) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if arr[mid] == target:
            return mid
        elif arr[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1
```

Common pitfalls:
- Use `lo <= hi`, not `lo < hi`, or you'll miss the last element
- `mid = (lo + hi) // 2` — integer division
- For "first occurrence" variants, don't return on equality; record `mid` and continue searching left
