# Plan: Fix Detector Cache Misses Due to Non-Deterministic Body Text

## Problem

The detector cache produces **zero hits** across runs — every single CLI invocation produces unique cache keys for all detectors. Analysis of the SQLite cache (`~/.cache/acewriter/cache.db`) shows **20 distinct keys** for what should be the same 5 detectors on the same document across multiple runs. No prefix is shared between any two entries.

Worse: the *same detector* (zerogpt) shows **wildly different scores and chunk texts** across runs (86%, 18%, 41%, 12%, 17%) — the body text being scored is genuinely different each time.

## Root Cause

The pipeline has two issues:

### Issue 1: Temp file save in `detect_structure` introduces drift

`structure_stage` (stages.py:375) calls `detect_structure(ctx.docx)` where `ctx.docx` is a python-docx `Document` object (not a file path). `detect_structure` (docstructure_adapter.py:491-498) detects this and:

```python
tmp = tempfile.NamedTemporaryFile(suffix=".docx", delete=False)
docx_source.save(tmp.name)       # re-serialize to temp file
ds_doc = ds_analyze(tmp.name)    # analyze temp file
os.unlink(tmp.name)
```

Each `docx_source.save()` re-serializes the XML — altering metadata timestamps, `wp:creationId`, and potentially XML namespace ordering. The docstructure parser then reads this re-serialized file, which may produce slightly different paragraph features (font sizes, style names, etc.) due to the re-serialization. This causes the paragraph classifier to assign different `ParagraphRole` values, which means `_extract_body_text()` selects a **different subset of paragraphs** each run.

### Issue 2: Double document loading

`resolve_input()` in `cmd_score` loads the document to get `doc.text`, then `read_stage` loads it AGAIN to set `ctx.text` and `ctx.docx`. While both loads read the same file, this wastes I/O and creates two separate `DocxDocument` object instances.

## Evidence

From the SQLite cache query:

```
Distinct key+detector combos: 20
  zerogpt     : 10 distinct keys, 10 total entries  ← NEVER a hit
  humanizeai  : 7 distinct keys, 7 total entries
  ...
```

Same detector, same file — different key every time:

| Run | zerogpt key prefix | zerogpt score | Sample chunk text |
|-----|-------------------|---------------|-------------------|
| 1 | `414e1510d8cd...` | 86% | "The 2026 FIFA World Cup is the **largest tournament in football history**, with 48 t" |
| 2 | `0ea3cee78ee9...` | 18% | "The 2026 FIFA World Cup is the **largest in the history of football tournaments**, a" |
| 3 | `65e48d9a29e3...` | 41% | "**It will have 48 teams playing in the United States, Canada and Mexico.**" |

The chunk text fragments are **different versions** of the same passage — confirming the body text changes each run.

## Fix

### Change 1: Pass `ctx.source` directly to `detect_structure` in `structure_stage`

**File:** `acewriter/lib/pipeline/stages.py` (line 375)

Current:
```python
ctx.structure = detect_structure(ctx.docx, debug=debug)
```

New:
```python
ctx.structure = detect_structure(
    ctx.docx if ctx.docx is not None else ctx.source,
    debug=debug
)
```

Wait — better approach: always prefer the file path when available. Since `ctx.docx` is only set for DOCX/PDF input, and `ctx.source` holds the original path, we can pass `ctx.source` directly when it's a `.docx` file:

```python
if ctx.source and ctx.source.suffix.lower() == ".docx":
    ctx.structure = detect_structure(ctx.source, debug=debug)
else:
    ctx.structure = detect_structure(ctx.docx, debug=debug)
```

This way, for DOCX input, `detect_structure` receives the original file path and calls `ds_analyze` directly — no temp file, no re-serialization, producing **deterministic** results every time.

For PDF input (where `ctx.docx` is a converted in-memory Document), we keep the current temp-file path.

### Change 2: Add debug logging for cache key / body text

**File:** `acewriter/lib/pipeline/stages.py` — in `score_stage`

Add logging to show a body-text hash + first 80 chars when `debug=True`:
```python
text = _extract_body_text(ctx.structure)
log("pipeline.score", f"body text hash={hashlib.sha256(text.encode()[:64]...", when=debug)
```

**File:** `acewriter/lib/detector/cache.py` — already logs cache HIT/MISS when `debug=True`

This enables `--debug` diagnosis.

### Change 3 (optional): Eliminate double document load

**File:** `acewriter/lib/commands/score.py` — store `doc.docx` from `resolve_input` to avoid second load in `read_stage`.

This is a larger refactor and not strictly needed to fix the cache issue, but would improve consistency.

## Potential Conflicts

- **PDF input**: When source is PDF, `ctx.source` is the PDF file, not a DOCX. The `if ctx.source.suffix.lower() == ".docx"` guard correctly falls through to the temp-file path. No conflict.
- **Tests**: Any test that mocks `detect_structure` or expects it to be called with a `DocxDocument` would break. Need to update mocks.
- **`ctx.docx` modifications**: If any pipeline stage modifies `ctx.docx` before `structure_stage`, the in-memory Document might have changes not reflected on disk. For the `score` command, no stage modifies `ctx.docx`. For `humanize`, the `humanize_stage` might — but in that case, the in-memory path is still available via the fallback.

## Backward Compatibility

- For DOCX input: behavior changes from "save temp + analyze" to "analyze original file directly". The analysis output should be the same *in principle*, but the paragraph classification **stabilizes** (no longer differs between runs). Existing score results may differ slightly from before, but only because the previous behavior was non-deterministic.
- For PDF input: behavior unchanged.
- Cache keys change between versions (stabilized). Old cache entries become stale — acceptable, they'll expire by TTL.

## Migration/Rollout Strategy

Single commit. If deployment fails (e.g., PDF input breaks), revert and use the old code path as a fallback for DOCX input if issues are found.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Direct file path changes docstructure analysis behavior | Medium | Medium | Only affects paragraph classification; user-facing scores may shift slightly but stabilize |
| Original DOCX file changes between load and structure analysis | Low | Low | `structure_stage` runs immediately after `read_stage`; unlikely |
| PDF path used for DOCX detection (wrong suffix) | Low | Medium | Guard checks `.docx` suffix explicitly |

## Testing Strategy

1. **Run twice, check cache hit**: Score the same DOCX file twice with `--debug`:
   ```
   py -m acewriter score doc.docx --suggest --debug 2>&1 | grep -i "cache"
   ```
   Second run should show "cache HIT" for each detector.

2. **Verify body text stability**: Add temporary logging (Change 2) to confirm body text hash is identical between runs.

3. **PDF regression**: Run on a PDF file to confirm the temp-file fallback still works.

4. **Existing test suite**: Run `pytest` to check for regressions.

## Progress Log

### 2026-07-08 — Implementation complete

**Changes made:**

[x] `acewriter/lib/pipeline/stages.py` line 375:
  - Before: `ctx.structure = detect_structure(ctx.docx, debug=debug)`
  - After: For DOCX files (`ctx.source.suffix == ".docx"`), passes `ctx.source` (file path) directly to `detect_structure`, bypassing the temp-file save → deterministic structure analysis.
  - For PDF or other sources: falls back to `ctx.docx` (existing temp-file path).

**Flow analysis verified:**
- Score (DOCX): ✅ runs `structure_stage` immediately after `read_stage`, no intermediate modification of `ctx.docx`.
- Score (PDF): ✅ guard checks `.docx` suffix → falls through to `ctx.docx`.
- Humanize (DOCX): ✅ `structure_stage` runs before `humanize_stage`.
- Full: ✅ `cmd_humanize` followed by `cmd_score` on output file — both are safe.
- Rescore: ✅ unaffected — pipeline doesn't include `structure_stage`.
- CLI debug / rewrite.py: ✅ unaffected — call `detect_structure` directly.
- No other stage modifies `ctx.docx` between `read_stage` and `structure_stage`.

**Validation:**
- File passes AST syntax check.
- Dependencies (python-docx) not available in test env — deferred.
