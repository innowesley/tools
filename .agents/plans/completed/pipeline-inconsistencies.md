# Fix: Pipeline inconsistencies in default shortcut

## Problem

The default shortcut (`acewriter file.docx --flags`) routes to `cmd_humanize`, which:
- Shows confusing tip: "--suggest is for 'score --suggest'"
- Exports **humanized** DOCX instead of **suggestion-based** DOCX
- Runs duplicate ZeroGPT scoring (main pipeline + second pipeline)
- Mixes original-text scores with humanized-text scores

## Expected behavior

Default shortcut runs BOTH humanize and score. When `--suggest` is passed:
- Collect + enrich suggestions from original text
- `--docx` exports suggestion-based surgical DOCX
- Show suggestions in terminal

## Changes

### File: `commands/humanize.py`

1. **Remove confusing tip (line 49-51)** — replace with proper implementation
2. **Disable duplicate scoring (lines 102-125)** — only run second zerogpt score when `ctx.scores` is empty
3. **Add suggestion collection (after pipeline, when `--suggest`)**:
   - Call `_collect_suggestions(ctx.original_scores or ctx.scores, ctx.text)`
   - Call `_enrich_suggestions_with_rewrites(suggestions)`
   - Pass suggestions to terminal renderer
4. **Fix DOCX export (line 262)** — when `--suggest` is also passed, export suggestion-based DOCX instead of humanized DOCX
5. **Fix score merge (lines 120-124)** — don't overwrite `ctx.scores` with zerogpt-only scores; keep the main pipeline's richer scores

### File: `commands/score.py`

- No changes needed (suggestion-based DOCX path works correctly)

## Execution order

1. Fix duplicate scoring (conditional second pipeline)
2. Add suggestion collection + enrichment for `--suggest` in humanize path
3. Add suggestion-based DOCX export when `--suggest --docx` in humanize path
4. Remove confusing tip
5. Run tests

## Execution Progress

### 2026-07-06
- [x] Fix 1: Made `--suggest` tip conditional — only shows on `humanize` subcommand (not default shortcut)
- [x] Fix 2: Added suggestion collection — when `--suggest` passed on default shortcut, suggestions are collected from `ctx.original_scores` with body-to-full offset conversion for DOCX sources
- [x] Fix 3: Added suggestion-based DOCX export — when `--suggest --docx`, exports `*.suggested.assignace.docx` via surgical edits instead of full humanized DOCX
- [x] Fix 4: Made duplicate ZeroGPT scoring conditional — only runs when `ctx.scores` is empty (main pipeline already scored)
- [x] Fix 5: Removed score merge logic — unused after fix 4 simplifies to direct assignment
- [ ] Post-execution: All 15 tests fail due to missing `.samples/` files (pre-existing). Python imports verified OK.
