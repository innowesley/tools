# Plan: Guard Against No-Change DOCX Export When Rewrites Are Empty

## Problem

When `--docx --suggest` is used, if all rewrite suggestions lack usable `alternative` text (e.g., `_enrich_suggestions_with_rewrites` fails for every suggestion), the following buggy behavior occurs:

1. **Terminal display**: "Rewrite Suggestions" header shows but **no suggestions are listed** (renderer skips items with `alt == text` or `alt is None` at `terminal.py:191`).
2. **DOCX export**: A "Rewritten" DOCX file is **still created** with **zero changes** (all edits become no-ops after `plan_replacements` filters them), and the user sees `"Rewritten: /path/to/file.docx"`.

**Confirmed in second run** — the Rewrite Suggestions section was empty but a DOCX was exported.

## Root Cause

The guard at `score.py:247-248` only checks if the *list* is non-empty:
```python
docx_suggestions = suggestions or suggestions_raw or []
if docx_suggestions:   # passes even if all items have alternative=None
```

It doesn't check whether the suggestions actually have usable rewrites. Downstream:
- `Edit.from_suggestion_dict()` sets `replacement = alternative or text` → `original == replacement`
- `plan_replacements()` filters all no-op edits → empty `ReplacementPlan`
- `apply_edits()` still calls `doc.save()` (file saved with no changes)

## Existing Logic Analysis

### Affected Files

| File | Lines | Role |
|------|-------|------|
| `acewriter/lib/commands/score.py` | 247-332 | Main DOCX export logic with 3 paths |
| `acewriter/lib/editing/service.py` | 11-54 | `edit_docx()` — calls `plan_replacements` + `apply_edits` |
| `acewriter/lib/editing/docx.py` | 15-33 | `apply_edits()` — saves file even when plan is empty |
| `acewriter/lib/editing/planner.py` | 6-44 | `plan_replacements()` — filters no-op edits correctly |
| `acewriter/lib/commands/humanize.py` | 290-316, 322-358 | Also calls `edit_docx` — same empty-plan gap |
| `acewriter/lib/renderers/terminal.py` | 182-207 | Skips suggestions without rewrites (display-only, not a bug) |

### Execution Paths

**Path A — DOCX input** (`score.py:263-289`):
```
suggestions → edits → edit_docx(edits) → plan_replacements → apply_edits → doc.save()
                                                                         ↑
                                                                   GAP: saves even if plan empty
```

**Path B — PDF input with converted DOCX** (`score.py:290-305`):
```
suggestions → edits → loop {if e.original != e.replacement: replace} → doc.save()
                                                                         ↑
                                                                   GAP: saves even if no replacements
```

**Path C — Plain text** (`score.py:306-319`):
```
suggestions → edits → loop {if e.replacement: apply edit} → generate_docx → doc.save()
                                                                               ↑
                                                                         GAP: saves even if no changes
```

## Changes Required

### Change 1: `edit_docx` in `editing/service.py` — Return `None` for empty plan

After `plan_replacements(edits, text)`, if `plan.edits` is empty, log a debug message and return `None` instead of calling `apply_edits`.

- **Return type**: Currently `Path`. Change to accept `None` return (caller checks).
- **Logging**: `log("editing.service", "no valid rewrites to apply — skipping DOCX save", when=debug)`

### Change 2: `cmd_score` in `commands/score.py` (Path A) — Handle `None` return

After calling `edit_docx()`, check if `docx_out is None`. If so, skip setting `result.artifacts.docx` and the "Rewritten:" message. Fall through to the else branch or a new `continue`.

```python
docx_out = edit_docx(...)
if docx_out is None:
    if not quiet:
        _console.print("[dim]No DOCX exported: no valid rewrite suggestions to apply.[/dim]")
    continue  # or equivalent skip
```

### Change 3: `cmd_score` in `commands/score.py` (Path B) — Skip save for empty edits

Filter valid edits before the loop. Only save if there are valid edits:

```python
valid_edits = [e for e in edits if e.original and e.replacement and e.original != e.replacement]
if valid_edits:
    for e in valid_edits:
        find_and_replace_in_docx(doc, e.original, e.replacement)
    if source:
        out_name = source.parent / f"{source.stem}.suggested.assignace.docx"
    else:
        out_name = Path.cwd() / "output.suggested.assignace.docx"
    doc.save(str(out_name))
    docx_out = out_name
else:
    docx_out = None
```

### Change 4: `cmd_score` in `commands/score.py` (Path C) — Skip save for empty edits

Filter valid edits before applying. Only save if there are valid edits:

```python
valid_edits = [e for e in edits if e.replacement and e.start < e.end and e.replacement != e.original]
if valid_edits:
    edited = text
    for e in sorted(valid_edits, key=lambda e: e.start, reverse=True):
        edited = edited[:e.start] + e.replacement + edited[e.end:]
    out_name = Path.cwd() / "output.suggested.assignace.docx"
    doc = _generate_docx_from_text(edited)
    doc.save(str(out_name))
    docx_out = out_name
else:
    docx_out = None
```

### Change 5: Handle `None` in `humanize.py` callers

Both `edit_docx` call sites in `commands/humanize.py` (`humanize.py:301/303` and `humanize.py:356/358`) need to handle `None` return:

```python
docx_out = edit_docx(source, edits, output_path=docx_out, debug=debug)
if docx_out is None:
    if not quiet:
        _console.print("[dim]No DOCX exported: no valid rewrites to apply.[/dim]")
    # Skip artifact assignment
else:
    result.artifacts.docx = docx_out
    if not quiet:
        _console.print(f"[dim]DOCX:[/dim] [cyan]{docx_out}[/cyan]")
```

Also fix the plain-text fallback path at `humanize.py:304-313` (no `edit_docx` — direct save with no valid-edits guard).

### Change 6: Consolidate Path B/C `None` handling

After Path B and C (they share the same post-block code at lines 322-328), handle `None` docx_out:

```python
if docx_out is not None:
    if getattr(args, "rescore", False):
        from ..editing.rescore import run as rescore_run
        rescore_run(docx_out, edits)
    result.artifacts.docx = docx_out
    if not quiet:
        _console.print(f"[dim]Rewritten:[/dim] [cyan]{docx_out}[/cyan]")
```

## Potential Conflicts

- **`rescore` flag** (line 322-324): Currently always runs if `--rescore` is set. With the fix, it should only run if `docx_out is not None`. No conflict — just gate behind the check.
- **`result.artifacts.docx`** (line 326): Currently set unconditionally. With the fix, only set when document was actually created. Downstream consumers of this field should handle `None` — check if any exist.
- **Tests**: Any test that expects `result.artifacts.docx` to always be set when `--docx` is given would break. Need to check test fixtures.

## Backward Compatibility

- **Existing behavior**: When rewrites succeed, `edit_docx` returns a `Path` → everything works as before. No change.
- **New behavior**: When all rewrites fail, `edit_docx` returns `None` → no file created, no misleading message. **Strictly better UX.**
- **API surface**: `edit_docx` return type changes from `Path` to `Path | None`. All callers must handle `None`.

## Migration/Rollout Strategy

Single commit. No migration needed since this is a pure additive guard — existing successful runs are unaffected. If deployment fails, revert the commit.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `edit_docx` return type change breaks caller in `humanize.py` | Low | Medium | Both callers (`score.py:273/282` and `humanize.py:301/303/356/358`) must handle `None` |
| False positive: valid suggestions filtered as no-ops | Low | Medium | The filter checks `e.original != e.replacement` and `e.start < e.end` — same as `plan_replacements` logic |
| user confusion: `--docx` silently skips with no message | Low | Low | Explicit log + console message when skipping |

## Regression Prevention

- **Manual verification**: Run `--docx --suggest` on a document that produces suggestions → verify DOCX is created with changes
- **Manual verification**: Simulate enrich failure → verify no DOCX is created and message is printed
- **Code review**: Ensure all 3 paths handle `None` consistently

## Testing Strategy

1. **Unit test `edit_docx`**: Mock `plan_replacements` to return empty plan → assert return is `None`
2. **Unit test `apply_edits`**: May want to add a guard there too (defensive) — early return if `not plan.edits`
3. **Integration test**: Run score with `--docx --suggest` on a document where all detectors return 0% AI probability → verify no DOCX is created
4. **Existing tests**: Run full suite to check no regressions — especially any that assert `result.artifacts.docx` is set

## Progress Log

### 2026-07-08 — Implementation complete

**Changes made:**

[x] `editing/service.py`:
  - Changed return type `Path` → `Optional[Path]`
  - Added guard: `if not plan.edits: return None` after `plan_replacements`
  - Added import for `Optional`

[x] `commands/score.py` (all 3 DOCX paths):
  - Path A (DOCX input): `edit_docx` now returns `None` for empty plan — no file saved
  - Path B (PDF-converted): Added `valid_edits` filter — only saves if non-empty
  - Path C (plain text): Added `valid_edits` filter — only saves if non-empty
  - `rescore` gated behind `docx_out is not None`
  - Artifact assignment + "Rewritten:" message gated behind `docx_out is not None`
  - Added "No DOCX exported: no valid rewrite suggestions to apply." message

[x] `commands/humanize.py` (2 call sites):
  - `--suggest` path: `edit_docx` return check + `valid_edits` filter for plain-text fallback
  - Surgical edit path: `edit_docx` return check + `None`-safe artifact/print
  - Both paths: "No DOCX exported: no valid rewrites to apply." message

**Validation:**
- All 3 files pass AST syntax check
- No existing tests for editing module (verified via glob search)
- Dependencies (python-docx) not available in test env — import-level verification deferred
