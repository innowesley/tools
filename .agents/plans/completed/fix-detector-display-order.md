# Fix detector display order in terminal output

## Problem
Detectors appear in random order in terminal output because `run_all_detectors()` uses `as_completed()` (nondeterministic completion order). Users see detectors in whatever order they finish, which changes between runs.

## Desired order
```
humanizeai (Copyleaks)      24%
zerogpt (Turnitin V2)       29%
quillbot (QuillBot)          9%
turnitin (Turnitin)         failed
youscan (AssignAce Deep)    88%
```

## Fix
Two files, minimal changes:

### 1. `lib/detector/registry.py`
Add a `DISPLAY_ORDER` tuple defining canonical order:
```python
DISPLAY_ORDER = ("humanizeai", "zerogpt", "quillbot", "turnitin", "youscan")
```

### 2. `lib/renderers/terminal.py`
In `_render_score()`, sort `detector_scores.items()` by `DISPLAY_ORDER` before iterating. Unknown detectors (if any) go at the end.

Change from:
```python
for name, ds in result.detector_scores.items():
```
To:
```python
order_map = {name: i for i, name in enumerate(DISPLAY_ORDER)}
for name, ds in sorted(
    result.detector_scores.items(),
    key=lambda kv: order_map.get(kv[0], 999)
):
```

## Verification
Run `acewriter score file.docx` — detectors should always appear in the order: humanizeai, zerogpt, quillbot, turnitin, youscan.

## Risk
Minimal. Only changes display order; scoring logic, JSON output, and HTML reports unaffected.

## Progress Log
- [x] Add `DISPLAY_ORDER = ("humanizeai", "zerogpt", "quillbot", "turnitin", "youscan")` to `registry.py`
- [x] Sort scores dict in `run_all_detectors()` in `runner.py` before returning
- [x] Fix `score.py`: use `DISPLAY_ORDER` instead of `ALL_NAMES` when rebuilding DetectorScore dict
- [x] Fix `build_detector_overview()` in `report_assembler.py`: sort by `DISPLAY_ORDER` instead of score descending
- [x] Verify: terminal (score) ✅ — humanizeai, zerogpt, quillbot, turnitin, youscan
- [x] Verify: default (humanize + score) ✅ — same order
- [x] Verify: HTML report ✅ — Copyleaks, QuillBot, AssignAce Deep (zerogpt/turnitin filtered as failed)
