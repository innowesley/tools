# Plan: Make `--suggest` Work on Humanize Subcommand + Switch Suggestion Source to Humanized Text

## Existing Logic Analysis
- `commands/humanize.py`: suggestion collection used `ctx.original_scores` (original text scores) to find still-flagged chunks — stale after humanization
- `commands/humanize.py`: suggestion collection required both `--suggest` and `--score` flags (so humanize subcommand could never use it)
- `commands/humanize.py`: had a tip telling users `--suggest` doesn't work on humanize
- `cli/__main__.py`: humanize parser had no `--suggest` argument
- `commands/humanize.py`: had separate suggestion-based DOCX path using Edit offsets from original text

## Changes Made

### 1. `cli/__main__.py` — Add `--suggest` to humanize parser
- Added `parser.add_argument("--suggest", ...)` in `_build_humanize_parser()`

### 2. `commands/humanize.py` — Remove confusing tip
- Deleted the `if getattr(args, "suggest", False) and not getattr(args, "score", False): print("Tip: ...")` block

### 3. `commands/humanize.py` — Add `score_stage` for `--suggest`
- Changed `if getattr(args, "score", False):` → `if getattr(args, "score", False) or getattr(args, "suggest", False):`

### 4. `commands/humanize.py` — Swap suggestion source to humanized text
- Changed `_scores_for_suggestions = ctx.original_scores or ctx.scores or {}` → `ctx.scores or {}`
- Removed `_body_to_full_offsets` call (no longer needed — humanized text is body-only)
- Changed `_collect_suggestions(text=ctx.text or "")` → `text=humanized_body` (uses `ctx.metadata["humanized_body"]` which matches exactly what `score_stage` scored)
- Removed `and getattr(args, "score", False)` guard — `--suggest` works standalone

### 5. `commands/humanize.py` — Remove suggestion-based DOCX branch
- Removed the `elif getattr(args, "suggest", False) and suggestions:` block (surgical Edit-based DOCX from suggestion dicts)
- Since suggestions now come from humanized text, offsets don't match original document — not safe for surgical editing
- Falls through to the full-paragraph humanized DOCX path

## Backward Compatibility
- `acewriter file.docx --suggest` (default shortcut): unchanged behavior — `args.score=True` still set, `pre_score_stage` still runs, suggestions now come from humanized text (different but correct)
- `acewriter score --suggest`: completely unaffected — uses `cmd_score()`, not `cmd_humanize()`
- `acewriter humanize --suggest`: **new** — previously silently ignored, now works

## Migration/Rollout Strategy
- No migration needed — this only affects `humanize --suggest` which previously was a no-op with a tip

## Risk Assessment
- Low risk — suggestion source change affects what `--suggest` proposes (should propose rewrites for still-flagged chunks, which is more useful)
- Suggestion-based DOCX removal means `humanize --suggest --docx` exports full humanized doc instead of surgical edit doc — acceptable since suggestions are for terminal preview only

## Regression Prevention
- Suggestion collection now uses `ctx.scores` (humanized) and body text — both set by `score_stage` which runs before collection
- The `humanized_body` fallback chain (`humanized_body_paragraphs` → `humanized_body` → `ctx.humanized` → `""`) ensures text is always available

## Progress Log
- [x] Add `--suggest` to humanize parser (cli/__main__.py)
- [x] Remove confusing tip (commands/humanize.py)
- [x] Add `score_stage` when `--suggest` (commands/humanize.py)
- [x] Swap suggestion source to humanized text (commands/humanize.py)
- [x] Remove suggestion-based DOCX branch (commands/humanize.py)
- [x] Verify: all diff contents correct
- [x] Verify: all pre-existing test failures are unchanged (missing .samples/ fixtures)
