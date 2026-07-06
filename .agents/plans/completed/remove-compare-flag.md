# Remove `--compare` flag

`--compare` is a no-op flag. It only adds `pre_score_stage` (scores original text with zerogpt), but the terminal never displays this data. The HTML/PDF report already falls back gracefully without it.

## Changes

### 1. `cli/__main__.py` — line 428
Remove the `--compare` argument definition.

### 2. `lib/commands/humanize.py` — lines 45-47, 62
- Remove the Pro-tier check for `--compare`
- Remove `--compare` from the `pre_score_stage` condition (line 62)

### 3. `lib/document/report_tier.py` — line 9
Remove `COMPARISON = "comparison"` from `Feature` enum (only used by the removed check).

## Verification
- `acewriter file.docx` — still runs `pre_score_stage` (via `args.score=True`)
- `acewriter score file.docx` — unaffected
- `acewriter humanize file.docx --pdf` — still works (HTML report uses fallback)
- `acewriter --help` — no `--compare` listed

## Risk
None. `pre_score_stage` still runs for `--pdf` / `--score`. Report assembly falls back gracefully.

## Progress Log
- [x] `cli/__main__.py` — removed `--compare` argument definition
- [x] `lib/commands/humanize.py` — removed Pro-tier check and `--compare` from condition
- [x] `lib/document/report_tier.py` — removed `COMPARISON` enum value
- [x] Verify: `--compare` no longer appears in CLI help
- [x] Verify: no remaining references to `compare` or `COMPARISON` in codebase
- [x] Note: user reverted by mistake, re-applied all 3 changes
