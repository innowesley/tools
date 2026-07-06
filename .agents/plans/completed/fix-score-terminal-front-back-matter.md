# Fix: Score terminal chunk highlights show front/back matter

## Problem

When running `acewriter full file.docx --pdf`, the terminal output for the **score** phase shows the full document text (including front matter like title/headers and back matter like References) in the chunk highlight panels. The scoring was correctly done on body-only text (10909 chars vs 12468 total), but the chunk highlight display renders the full text.

## Root Cause

`ScoreResult.from_context()` in `pipeline/results.py:83` sets `input_text` to `ctx.text` — the **full** document text (12468 chars). But the `score_stage` pipeline extracts body-only text for actual scoring and stores it in `ctx.metadata["scored_text"]`. The chunk highlight display (`_render_score` → `render_detector_detail` → `build_highlighted_text`) uses `result.input_text` as the canvas for highlighting. Since chunk offsets are relative to the body-only text but `input_text` is the full text, the full text is rendered as-is with only the highlighted portions actually marking correct positions.

Additionally, any text after the last chunk position in the full document (references section, etc.) gets displayed unhighlighted because of the "rest" append in `build_highlighted_text` line 46-47.

## Fix

**File:** `acewriter/lib/pipeline/results.py`, line 83

Change:
```python
input_text=ctx.text or "",
```
To:
```python
input_text=ctx.metadata.get("scored_text") or ctx.text or "",
```

This uses the body-only text that was actually scored for the chunk highlight display. When `scored_text` is not available (error/abort paths), it falls back to `ctx.text`.

## Impact

- **Score terminal**: chunk highlights will now show only body paragraphs (no front/back matter)
- **Humanize terminal**: unaffected — `HumanizeResult.from_context` (line 39) still uses `ctx.text` directly (humanize doesn't use `scored_text`)
- **PDF/HTML reports**: unaffected — they use `ctx.metadata.get("scored_text", ctx.text)` already via `assemble_score_report`
- **Standalone `score` command**: also benefits — any DOCX with front/back matter will show cleaner output

## Testing

1. Run `acewriter full .samples/007-sample.docx --docx` — verify score chunk highlights show only body paragraphs
2. Run `acewriter score .samples/007-sample.docx` — standalone score also cleaner
3. Run `acewriter humanize .samples/007-sample.docx` — no regression
