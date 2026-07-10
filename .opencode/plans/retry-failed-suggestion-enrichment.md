# Plan: Retry Failed Suggestion Enrichment

**Date:** 2026-07-08
**Status:** Draft

## Problem

The `_enrich_suggestions_with_rewrites()` function in `report_assembler.py` tries two methods sequentially:
1. ZeroGPT batch (single API call with UUID markers)
2. Sequential HumanizeAI (one call per suggestion)

If **both** fail (timeout, rate limit, marker loss, etc.), suggestions are returned **without** `alternative` fields. The caller treats these as valid suggestions where `alternative == original`, so all edits get filtered out in `plan_replacements()` (line 17 of `planner.py`: `if e.original == e.replacement: continue`). Result: `edit_docx()` returns `None` and the user sees "No DOCX exported: no valid rewrite suggestions to apply."

There is **no retry** mechanism. A transient API failure on both methods means zero suggestions get enriched, even though a simple retry might succeed.

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

## Proposed Change

After both methods complete, check if any suggestions still lack `alternative`. If so, retry those failed suggestions individually using the sequential humanizer **one more time** (with a small delay before retry).

### Change 1: Add retry loop at end of `_enrich_suggestions_with_rewrites`

In `lib/document/report_assembler.py`, after line 391 (`_try_sequential_humanizeai(...)`), add:

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

Key design decisions:
- `max_workers=1` for retry — reduces concurrency to avoid rate limits that may have caused the first failure
- `time.sleep(2)` — brief cooldown before retry attempt
- Only retries suggestions that actually failed (not the entire batch)
- If retry also fails, return as-is (no infinite retry loop)

### Change 2: Update docstring

Update the function docstring to document the retry behavior.

## Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| Retry adds 2s delay even when all succeed | Low — 2s only on failed enrichments, which already took 20s+ | Check `still_missing` is non-empty first |
| Retry also fails, wasting time | Low — suggestions without alternatives are already unusable for DOCX | `max_workers=1`, single retry only |
| Rate limiting from retry | Low — 2s cooldown + single retry + sequential | No risk of flooding |

## Backward Compatibility

Fully backward compatible. Retry only activates when enrichment fails — all existing success paths are unchanged. If retry also fails, behavior is identical to current (return suggestions without alternatives).

## Testing

Manual verification:
1. Run with `--debug` to see the `"retrying N failed suggestions"` log line
2. Verify DOCX is produced when retry succeeds
3. Verify no behavioral change when enrichment succeeds on first try

The retry path is hard to unit-test without mocking API failures, but the logic is minimal and the log line confirms activation.
