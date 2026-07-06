# Fix: Full pipeline missing score terminal output

## Problem

Default shortcut (`acewriter file.docx --flags`) renders `HumanizeResult` → `_render_humanize()` which:
- Shows body text only
- **Ignores** `suggestions` parameter entirely
- **Ignores** `result.scores` / `result.combined_score`

While `acewriter score file.docx --suggest` renders `ScoreResult` → `_render_score()` which shows:
- AI Detector Summary table (score bars, combined)
- Per-detector chunk highlights (rich annotated panels)
- Rewrite Suggestions panels

The full pipeline has all the data, but drops it in terminal output.

## Root Cause

`renderers/terminal.py` lines 16-22:
```python
if isinstance(result, HumanizeResult):
    self._render_humanize(result, args)                    # suggestions param dropped
elif isinstance(result, ScoreResult):
    self._render_score(result, args, suggestions=suggestions, ...)
```

`_render_humanize` signature: `(self, result, args)` — no `suggestions` param, no score display logic.

## Fix

### File: `renderers/terminal.py`

Three targeted edits:

**Edit 1 — `render()`:** Pass `suggestions` to `_render_humanize`
```python
# BEFORE
if isinstance(result, HumanizeResult):
    self._render_humanize(result, args)

# AFTER
if isinstance(result, HumanizeResult):
    self._render_humanize(result, args, suggestions=suggestions)
```

**Edit 2 — `_render_humanize()` signature:** Add `suggestions` param
```python
# BEFORE
def _render_humanize(self, result: HumanizeResult, args) -> None:

# AFTER
def _render_humanize(self, result: HumanizeResult, args, suggestions: list[dict] | None = None) -> None:
```

**Edit 3 — `_render_humanize()` body:** After body text display, when scores exist, build ScoreResult and call `_render_score`

Add after the existing body-text display block (after the `else: print(result.output_text)` branch, inside the same method):
```python
    # Show scores + suggestions when available (full pipeline)
    if result.scores:
        detector_scores = {}
        for name, d in result.scores.items():
            display = self._display_name(name)
            detector_scores[name] = DetectorScore(
                name=name,
                display_name=display,
                score=d.get("score", -1.0),
                feedback=d.get("feedback", ""),
                flagged_words=d.get("flagged", []),
                chunks=d.get("chunks", []),
                tt_ms=d.get("tt_ms", 0),
                raw_response=d.get("raw_response"),
                suggestions=d.get("suggestions", []),
            )
        # Use humanized text for chunk highlight alignment
        scored_text = result.output_text or result.input_text
        score_result = ScoreResult(
            input_text=scored_text,
            detector_scores=detector_scores,
            combined_score=result.combined_score or 0,
            combine_method=result.combine_method or "median",
            duration_ms=result.duration_ms,
            source=result.source,
            structure=result.structure,
        )
        self._render_score(score_result, args, suggestions=suggestions)
```

This reuses the existing `_render_score` which handles:
- AI Detector Summary table
- Per-detector chunk highlights (with humanized text for proper offset alignment)
- Rewrite Suggestions panels (from the passed-in suggestions list)

## What changes vs stays

| Element | Before | After |
|---|---|---|
| `Humanizing with...` spinner | ✓ | ✓ |
| `Scoring original text...` spinner | ✓ | ✓ |
| `Running N detectors...` spinner | ✓ | ✓ |
| Humanized Body Text | ✓ | ✓ |
| AI Detector Summary table | ✗ | ✓ |
| Per-detector chunk highlights | ✗ | ✓ |
| Rewrite Suggestions panels | ✗ | ✓ |
| PDF/DOCX output messages | ✓ | ✓ |
| `--json` mode | unchanged | unchanged |
| `humanize` subcommand (no scores) | shows text only | shows text only (scores = None, skips) |

## Files changed
- `acewriter/lib/renderers/terminal.py` — single file, 3 edits

## Execution order
1. Apply 3 edits to `terminal.py`
2. Verify import: `python -c "import acewriter.lib.renderers.terminal"`
3. Run existing tests: `python -m pytest acewriter/tests/ -v --tb=short`

## Execution Progress

### 2026-07-06
- [x] Edit 1: `render()` — pass `suggestions` to `_render_humanize` (line 20)
- [x] Edit 2: `_render_humanize()` signature — added `suggestions` parameter (line 24)
- [x] Edit 3: `_render_humanize()` body — added score display block (lines 60-86):
  - Converts raw `result.scores` dict to `DetectorScore` objects
  - Builds `ScoreResult` with humanized text as `input_text`
  - Calls `self._render_score()` for full score table + chunk highlights + suggestions
- [x] Import verified: `import acewriter.lib.renderers.terminal` OK
- [x] Tests: same 15 pre-existing failures (missing `.samples/` files), no regressions

### Verification
All changes are in a single file: `acewriter/lib/renderers/terminal.py`
- Terminal output now shows: Body Text + AI Detector Summary table + chunk highlights + Rewrite Suggestions
