# Fix DOCX output: green highlighting and suggestion offset issues

## Problem

Two bugs in DOCX generation when using `humanize --docx`:

### Bug 1: Green highlighting on full-paragraph humanization edits
The `_apply_to_paragraphs()` function in `lib/editing/docx.py` highlights ALL text replacements
green (`w:highlight w:val="green"`), including the paragraph-level humanization swaps.
This makes `.humanized.assignace.docx` look like a marked-up mess (every body paragraph
green). The `.suggested.assignace.docx` has the same issue — humanization edits + 5
suggestion edits, all green, so both files appear to have identical green highlights.

### Bug 2: Wrong content suggestions on humanized DOCX
The zerogpt suggestions are generated from body text (with `\n\n` paragraph separators).
When these suggestions are applied to the DOCX (which uses `\n` separators), character
offsets are mismatched. While `_body_to_full_offsets()` in `score.py` tries to convert
these, the humanization path may not correctly use it, and the resulting edits replace
wrong text.

## Fix Plan

### Fix 1: Add `highlight` parameter to edit pipeline

**File:** `lib/editing/docx.py`
- Add `highlight: bool = True` parameter to `apply_edits()` and `_apply_to_paragraphs()`
- When `highlight=False`, skip the green highlight XML element on replacement runs
- Only apply green highlight when `is_replacement and highlight`

**File:** `lib/editing/service.py`
- Add `highlight: bool = True` parameter to `edit_docx()`
- Pass through to `apply_edits()`

**File:** `lib/commands/humanize.py`
- When calling `edit_docx()` for full paragraph humanization (line 318), pass `highlight=False`
- When calling `edit_docx()` for suggestions (line 269/humanize, line 244/score), keep `highlight=True`

**File:** `lib/commands/score.py`
- Keep `highlight=True` default for suggestion edits

### Fix 2: Use correct text for suggestion generation in humanize path

**File:** `lib/commands/humanize.py` (lines 107-120)
- When collecting suggestions with `--suggest`, ensure `_body_to_full_offsets` uses the
  humanized document (or the correct structure/docx reference) so suggestion offsets
  map correctly to the output DOCX.

The existing `_body_to_full_offsets()` in `score.py` already handles `\n\n`→`\n` offset
conversion. The humanize command's suggestion collection (line 113-117) calls this same
function but needs to verify it has the correct `ctx.docx` reference.

### Fix 3: Validate green highlighting in both paths

- Suggestion edits from score command: green highlight (signal: "this was rewritten")
- Full paragraph humanization: no green highlight (it's the main body text, not a suggestion)
- This visually distinguishes `.humanized.assignace.docx` (clean) from
  `.suggested.assignace.docx` (has green suggestion highlights)

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Existing users expect green on humanized DOCX | Low | Humanized DOCX is recent feature; no highlight is cleaner |
| Offset conversion misses edge cases | Medium | `_body_to_full_offsets` already tested in score path; same logic used |
| Suggestion highlights on wrong paragraphs | Medium | Verify the `ctx.docx` reference in humanize path points to humanized DOCX |

## Backward Compatibility

- Minimally invasive: adds optional `highlight` parameter (default `True` preserves current behavior for suggestions)
- Humanize path explicitly opts out with `highlight=False`
- No API changes to public interfaces

## Testing Strategy

1. Run `acewriter humanize file.docx --docx` → verify `.humanized.assignace.docx` has NO green highlights
2. Run `acewriter score file.docx --suggest --docx` → verify `.suggested.assignace.docx` has ONLY suggestion spans green
3. Run `acewriter humanize file.docx --suggest --score --docx` → verify both files, suggestion offsets correct
4. Compare highlighted text in DOCX against terminal suggestion output to verify content match
