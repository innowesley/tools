# Fix: `-Q` flag should suppress AI Detector Summary output

## Problem

When `acewriter humanize -Q` is used, the AI Detector Summary table is still printed to stdout. This pollutes output when piping/redirecting (e.g., `acewriter humanize -Q > file.txt` includes the detector summary in the file).

The `-Q` flag sets `args.quiet = True`, which correctly suppresses spinners and tips, but the `render()` call is made **unconditionally** — it ignores `quiet` entirely.

## Root Cause

In both `humanize.py` and `score.py`, the `render()` call is guarded only by `_defer_render` (JSON mode), not by `quiet`:

```python
# humanize.py:185-186
if not _defer_render:
    render(result, args, suggestions=suggestions, mode=mode)

# score.py:230-231
if not _defer_render:
    render(result, args, suggestions=suggestions, suggest_requested=suggest, mode=mode)
```

The `TerminalRenderer._render_score()` method always prints "AI Detector Summary" to stdout (terminal.py:147-148) with no `quiet` check.

## Fix

### Change 1: Guard `render()` with `quiet` in humanize.py (line 185-186)

```python
# Before:
if not _defer_render:
    render(result, args, suggestions=suggestions, mode=mode)

# After:
if not _defer_render and not quiet:
    render(result, args, suggestions=suggestions, mode=mode)
```

### Change 2: Guard `render()` with `quiet` in score.py (line 230-231)

```python
# Before:
if not _defer_render:
    render(result, args, suggestions=suggestions, suggest_requested=suggest, mode=mode)

# After:
if not _defer_render and not quiet:
    render(result, args, suggestions=suggestions, suggest_requested=suggest, mode=mode)
```

### Change 3: Defense-in-depth in terminal.py

Add early return at the top of `_render_humanize()` and `_render_score()`:

```python
def _render_humanize(self, result, args, ...):
    if getattr(args, "quiet", False):
        return
    # ... rest of method

def _render_score(self, result, args, ...):
    if getattr(args, "quiet", False):
        return
    # ... rest of method
```

This catches any future code path that calls `render()` without checking `quiet` first.

## Files Modified

| File | Lines | Change |
|------|-------|--------|
| `lib/commands/humanize.py` | 185 | Add `and not quiet` to render guard |
| `lib/commands/score.py` | 230 | Add `and not quiet` to render guard |
| `lib/renderers/terminal.py` | 25, 90 | Add `quiet` early-return guard |

## Impact Analysis

- **`cmd_full` (full.py):** Calls `cmd_humanize(args)` then `cmd_score(args)`. Both will now respect `quiet`, so `full -Q` also works correctly. No changes needed in full.py.
- **JSON mode (`--json`):** Already forces `quiet=True` (cli/__main__.py:891-892), and uses `_defer_render=True` which skips the non-deferred render call. The deferred render at the end of each command (humanize.py:454, score.py:563) is for JSON output — this is correct and unaffected.
- **Programmatic API (api.py):** Calls `cmd_humanize`/`cmd_score` directly. If called with `quiet=True`, terminal output will now be suppressed. This is correct behavior.
- **No behavioral change without `-Q`:** When `quiet=False` (default), the `and not quiet` condition is `True`, so render proceeds as before.

## Testing

1. `acewriter humanize test.txt -Q` → stdout should contain ONLY humanized text, no detector summary
2. `acewriter score test.txt -Q` → stdout should contain ONLY scores (if any stdout output), no detector summary table
3. `acewriter humanize test.txt` (no -Q) → should still print detector summary as before
4. `acewriter full test.docx -Q` → should suppress all terminal output
5. `acewriter humanize test.txt --json` → JSON output should still work (quiet already forced True)
