# Plan: Retry Failed Suggestion Enrichment

**Date:** 2026-07-08
**Status:** Draft

## Problem

`_enrich_suggestions_with_rewrites()` tries two methods sequentially:
1. ZeroGPT batch (single API call with UUID markers)
2. Sequential HumanizeAI (one call per suggestion)

If **both** fail (timeout, rate limit, marker loss, etc.), suggestions are returned **without** `alternative` fields. Edits where `original == replacement` are filtered out by `plan_replacements()`. Result: `edit_docx()` returns `None` and user sees "No DOCX exported."

There is **no retry** mechanism.

## Current Flow

```
_enrich_suggestions_with_rewrites(suggestions)
  ├─ to_humanize = suggestions without "alternative" 
  ├─ if not to_humanize → return (all done)
  ├─ _try_zerogpt_batch(suggestions, to_humanize)
  │   └─ 1 call to ZeroGPT rewrite API
  │   └─ if success → return
  ├─ _try_sequential_humanizeai(suggestions, to_humanize)
  │   └─ 1 attempt per suggestion (with HTTP retries=3)
  │   └─ fails silently for each failed suggestion
  └─ return suggestions  ← may still lack alternatives
```

## Single Change

After both methods complete, check if any suggestions still lack `alternative`. If so, retry those failed suggestions individually with the sequential humanizer **one more time** (with a small cooldown).

**File:** `lib/document/report_assembler.py`, in `_enrich_suggestions_with_rewrites()`

After `_try_sequential_humanizeai(...)`, add:

```python
# ── Retry any suggestions that still lack alternatives ──
still_missing = [
    (i, s) for i, s in enumerate(suggestions)
    if not s.get("alternative") and s.get("text")
]
if still_missing:
    log("report.enrich", f"retrying {len(still_missing)} failed suggestions", when=False)
    import time
    time.sleep(2)  # Brief cooldown before retry
    _try_sequential_humanizeai(suggestions, still_missing, max_workers=1, timeout=timeout)
```

**Design decisions:**
- `max_workers=1` — sequential to avoid rate limits that may have caused first failure
- `time.sleep(2)` — cooldown before retry
- Only retries suggestions that actually failed (not full batch)
- Single retry only (no infinite loop)
- If retry also fails, return as-is (outcome same as before)

## Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| 2s delay even when all succeed | Low — only checks `still_missing` first, empty=skip | Only runs if non-empty |
| Retry also fails | Low — same as today's behavior | Single retry only |
| Rate limiting | Low — 2s cooldown + sequential + single retry | `max_workers=1` |

## Backward Compatibility

Fully backward compatible. Only activates when enrichment fails — all existing success paths unchanged. No changes to registry, no changes to which detectors produce suggestions.
