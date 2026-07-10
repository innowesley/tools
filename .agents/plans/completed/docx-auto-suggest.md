# Plan: `--docx` Automatically Enables Suggestion Generation (No Error)

**Date:** 2026-07-08
**Status:** Draft

## Summary

Currently, `py -m acewriter score <file> --docx` errors out with:
```
Error: --docx exports rewrite suggestions.
       Use --suggest --docx to show and export suggestions.
```

The user must add `--suggest` to make `--docx` work. Instead, `--docx` should automatically generate rewrite suggestions for the DOCX export, and `--suggest` should **only** control whether suggestions are **displayed** in terminal/PDF/JSON output.

---

## Existing Logic Analysis

### Files affected:

| File | Lines | Role |
|---|---|---|
| `lib/commands/score.py` | 105–123 | Validation guard that errors on `--docx` without `--suggest` |
| `lib/commands/score.py` | 207–230 | Suggestion collection + enrichment logic |
| `lib/commands/score.py` | 233–234 | Terminal rendering call (passes `suggest_requested=suggest`) |
| `lib/commands/score.py` | 237–335 | DOCX export — uses `suggestions` (enriched) or `suggestions_raw` |
| `lib/commands/score.py` | 392–404, 467–483, 490–506 | PDF rendering — passes `assemble_score_report(… suggestions=suggestions, humanize_suggestions=suggest …)` |
| `lib/renderers/terminal.py` | 182–207 | Terminal suggestion display — gated by `if suggestions:` **not** by `suggest_requested` |
| `lib/renderers/json.py` | 20–21 | JSON suggestion inclusion — gated by `if suggestions:` only |
| `lib/document/report_assembler.py` | 1210–1214 | PDF report suggestion assembly — uses pre-enriched suggestions as-is when not `None` |

### Current flow:

```
cmd_score(args):
  ├─ [GUARD] if --docx and not --suggest → ERROR, return
  ├─ (pipeline: read → score → analyze)
  ├─ suggest = getattr(args, "suggest", False)
  ├─ has_docx = getattr(args, "docx", False)
  ├─ if suggest or has_docx:
  │    ├─ collect raw suggestions (suggestions_raw)
  │    └─ if suggest and suggestions_raw:        ← enrichment only for --suggest
  │         → suggestions = _enrich_suggestions_with_rewrites(suggestions_raw)
  ├─ render(result, suggestions=suggestions, suggest_requested=suggest)
  │    └─ terminal: if suggestions: → show      ← ignores suggest_requested
  │    └─ json:     if suggestions: → include   ← ignores suggest_requested
  ├─ if has_docx:
  │    └─ docx_suggestions = suggestions or suggestions_raw or []
  │       → if --suggest not set: suggestions=[], falls to suggestions_raw (no rewrites)
  └─ if pdf:
       └─ assemble_score_report(suggestions=suggestions, humanize_suggestions=suggest)
          └─ if suggestions is not None: use as-is (bypasses humanize_suggestions gate)
```

### Root cause of the problem:

1. The guard at line 110 blocks `--docx` without `--suggest` entirely.
2. Even if the guard were removed, enrichment only happens when `suggest=True` (line 224).
3. Terminal/JSON renderers display suggestions based on non-empty `suggestions`, not on `suggest_requested`.
4. PDF renderer uses pre-enriched suggestions as-is, bypassing the `humanize_suggestions` gate.

---

## Changes Required

### Change 1: Remove validation guard — `lib/commands/score.py` lines 109–123

Delete the entire guard clause. `--docx` alone is now valid.

### Change 2: Enrich suggestions when `--docx` is set — `lib/commands/score.py` line 224

**Before:**
```python
if suggest and suggestions_raw:
```
**After:**
```python
if (suggest or has_docx) and suggestions_raw:
```

This ensures `_enrich_suggestions_with_rewrites()` runs when either `--suggest` or `--docx` is passed. The enriched `suggestions` list is then used by DOCX export (line 247) and also available for display formats.

### Change 3: Terminal renderer — gate on `suggest_requested` — `lib/renderers/terminal.py` lines 182–207

**Before:**
```python
# Display rewrite suggestions when --suggest is set
if suggestions:
    ...show suggestions...
elif suggest_requested:
    ...show "no suggestions" message...
```
**After:**
```python
# Display rewrite suggestions only when --suggest was explicitly passed
if suggest_requested:
    if suggestions:
        ...show suggestions...
    else:
        ...show "no suggestions" message...
```

This ensures terminal output only shows suggestions when `--suggest` is passed, not just because `--docx` populated the suggestions list.

### Change 4: JSON renderer — gate on `suggest_requested` — `lib/renderers/json.py` line 20

**Before:**
```python
if suggestions:
    data["suggestions"] = suggestions
```
**After:**
```python
if suggestions and suggest_requested:
    data["suggestions"] = suggestions
```

This ensures JSON output only includes suggestions when `--suggest` is explicitly passed.

### Change 5: PDF rendering — don't pass enriched suggestions when `--suggest` is unset — `lib/commands/score.py`

Three calls to `assemble_score_report()` pass `suggestions=suggestions`:
- Line 402 (HTML fallback path)
- Line 479 (`_do_pdf_docx` cover report)
- Line 502 (`_do_pdf_docx` summary report)

**Change each from:**
```python
suggestions=suggestions,
```
**To:**
```python
suggestions=suggestions if suggest else None,
```

This ensures the PDF report assembly only receives pre-enriched suggestions when `--suggest` was explicitly passed. When `suggest=False`, it passes `None`, which causes `assemble_score_report()` to collect raw suggestions from scores and only enrich them if `humanize_suggestions=True` (which is also `suggest`, so `False`). The result: no suggestions in PDF output when only `--docx` is used.

---

## Backward Compatibility

| Scenario | Before | After |
|---|---|---|
| `--docx` only | ERROR | ✅ Sugg. generated, exported to DOCX, not shown in terminal/PDF |
| `--suggest` only | ✅ Terminal/PDF show suggestions | ✅ Same (no change) |
| `--suggest --docx` | ✅ Both terminal + DOCX | ✅ Same (no change) |
| `--docx --pdf` | ERROR | ✅ Sugg. in DOCX, not in PDF |
| `--suggest --docx --pdf` | ✅ Sugg. in terminal/DOCX/PDF | ✅ Same (no change) |
| `--json` only | ✅ No suggestions in JSON | ✅ Same |
| `--suggest --json` | ✅ Suggestions in JSON | ✅ Same |
| `--docx --json` | ERROR | ✅ Sugg. in DOCX, not in JSON |

No breaking changes for existing workflows. The only behavioral change is that `--docx` (previously an error) now works.

---

## Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| `--docx` generates API calls for rewrites without user explicitly asking | Low — `--docx` already implies rewrite intent, and rewrites were always needed for export | Clear docstring on `--docx` flag |
| Terminal shows suggestions when user only wanted DOCX | Mitigated by Change 3 — strictly gated on `--suggest` | Verify in testing |
| PDF shows suggestions when user only wanted DOCX | Mitigated by Change 5 — pass `suggestions=None` when `suggest=False` | Verify in testing |
| JSON includes suggestions when user only wanted DOCX | Mitigated by Change 4 — gated on `suggest_requested` | Verify in testing |

---

## Testing Strategy

### Automated tests to verify:
1. **`--docx` without `--suggest`** — no error, DOCX file produced, no terminal suggestion output, no PDF suggestion output
2. **`--suggest` without `--docx`** — suggestions shown in terminal, no DOCX produced (unchanged behavior)
3. **`--suggest --docx`** — suggestions shown in terminal AND DOCX produced (unchanged behavior)
4. **`--docx --pdf`** — DOCX produced with suggestions, PDF without suggestions
5. **`--docx --json`** — JSON output without suggestions, DOCX produced
6. **`--suggest --docx --json`** — JSON output WITH suggestions, DOCX produced

### Manual verification:
- Run `py -m acewriter score /path/to/sample.docx --pdf --tier pro --docx` — no error, DOCX + PDF produced
- Run `py -m acewriter score /path/to/sample.docx --docx` — DOCX produced, no terminal suggestions
- Run `py -m acewriter score /path/to/sample.docx --suggest --docx` — suggestions in terminal + DOCX

---

## Migration/Rollout Strategy

1. Apply changes in a single commit
2. Update the `--docx` flag help text in `cli/__main__.py` (line 420) to reflect new behavior:
   ```
   "Export as DOCX with rewrite suggestions applied. Suggestions are automatically generated."
   ```
3. Update the `--suggest` flag help text in `cli/__main__.py` (line 456) to clarify:
   ```
   "Preview rewrite suggestions in terminal/PDF. Use --docx to export them."
   ```
4. Rollback: revert the commit; no data migration needed

---

## Regression Prevention

- All existing `--suggest` workflows remain unchanged
- All existing `--pdf`, `--json`, terminal-only workflows remain unchanged
- The only new codepath is `--docx` without `--suggest`, which previously errored
- Each display format (terminal, JSON, PDF) independently gates on `suggest`/`suggest_requested`
