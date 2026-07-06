# Strip humanization highlights in suggested DOCX

## Problem
`suggested.assignace.docx` has green highlights from BOTH humanization (13 edits) and suggestions (5 edits). The humanization highlights drown out the suggestion changes — hard to see what the suggestions actually changed.

## Goal
Only suggestion edits should be highlighted in green in the suggested DOCX. Humanization highlights should be stripped before suggestion edits are applied.

## Approach
Add a `_strip_highlights()` helper in `editing/docx.py` that removes all `<w:highlight>` elements from all paragraph runs. Call it in `apply_edits()` after loading the DOCX and before processing edits.

Safe for both callers:
- **Humanize** (edits original DOCX): no existing highlights → stripping is no-op
- **Score/suggest** (edits humanized DOCX): strips humanization green highlights → only suggestion replacements get fresh green highlights

## Files to modify

### `acewriter/lib/editing/docx.py`
1. Add `_strip_highlights(doc)` function that walks all paragraphs/runs, removes `<w:highlight>` from `w:rPr`
2. Call `_strip_highlights(doc)` in `apply_edits()` after line 21 (`doc = Document(str(original_path))`) and before `_apply_to_paragraphs()`

## Impact
- **`suggested.assignace.docx`**: only suggestion edits highlighted in green — clean diff
- **`humanized.assignace.docx`**: unchanged (humanization keeps its green highlights)
- **`score` standalone**: no existing highlights anyway, no behavior change
- **`humanize` standalone**: no existing highlights, no behavior change

## Testing
1. Run `acewriter full 007-sample.docx --suggest --docx` → open `007-sample.suggested.assignace.docx` → only 5 suggestion changes should be highlighted
2. Run `acewriter score 007-sample.docx --suggest --docx` → same behavior (no existing highlights)
3. Run `acewriter humanize 007-sample.docx --docx` → humanized DOCX still has green highlights on all edits

## Progress Log

### 2026-07-06 — Execution

1. [x] **Update editing/docx.py** — Added `_LIGHT_GREEN = "C6EFCE"` and `_CYAN = "D4F0FF"` constants. Added `_strip_highlights(doc)` helper that removes all `w:highlight` and run-level `w:shd` from paragraphs. Changed `apply_edits` signature to accept `highlight_color` (default `_LIGHT_GREEN`) and `strip_highlights` (default `False`). Replaced `w:highlight w:val="green"` with `w:shd w:val="clear" w:fill={highlight_color}`.

2. [x] **Update editing/service.py** — Added `highlight_color` and `strip_highlights` params to `edit_docx()`, forwarded to `apply_edits()`.

3. [x] **Update commands/score.py** — Added `highlight_color="D4F0FF"` and `strip_highlights=True` to the `edit_docx()` call in the DOCX export path (lines 244-249).

4. [x] **Add color legend to PDF** — Added `highlight-legend` div in `_render_annotated_section()` with three swatches (yellow=AI-detected, light green=Humanized, cyan=Rewrite suggestions). Added CSS for the legend in `REPORT_CSS`.

5. [x] **Verify** — Imports pass (`.venv/bin/python -c "import acewriter.lib.editing.docx; ..."` OK).
