# Plan: Add `full` subcommand

## Goal
Add `acewriter full file.docx` — a simple wrapper that runs `humanize` then `score` on the humanized output. No new pipeline complexity, no hidden cross-pipeline. Just chain the existing subcommands.

## Existing Logic Analysis

### How humanize works (`cmd_humanize`)
- Reads input via `resolve_input(args)` from `args.files[0]`
- Runs stages: read → structure (if DOCX) → humanize → (optional pre_score if --pdf) → quick zerogpt fallback
- Returns `HumanizeResult` with `.output_text` (full text) and `.humanized_body_paragraphs`
- Renders terminal output, generates DOCX/PDF/HTML exports based on flags

### How score works (`cmd_score`)
- Reads input via `resolve_input(args)` from `args.files[0]`
- Runs stages: read → structure (if DOCX) → score (all detectors) → collect suggestions
- Returns `ScoreResult` with scores, suggestions
- Renders terminal output, generates DOCX (surgical-edit) / PDF / HTML exports

### How routing works (`__main__.py`)
- `_CMDS = {"humanize", "score", "auth", "config", "list", "structure"}`
- Parses argv to find cmd, then builds the appropriate parser
- After parsing, dispatches to the appropriate function
- No-file fallback routes to `cmd_humanize` for interactive stdin (already reviewed and kept)

## Potential Conflicts

1. **Both subcommands run fully** — humanize generates its exports (humanized DOCX/PDF), then score generates its exports (surgical-edit DOCX/PDF). This is intended — user gets both sets of output files.

2. **File consumed by first call** — `cmd_humanize` reads the file; `cmd_score` needs the humanized text as input. Solved via temp file.

3. **`-o` flag** — humanize saves the humanized text to `-o` path. Score ignores `-o`. No conflict.

## Implementation

### 1. New file: `acewriter/lib/commands/full.py`

```python
import os
import sys
import tempfile
from pathlib import Path

from . import get_pdf_path
from .humanize import cmd_humanize
from .score import cmd_score


def cmd_full(args):
    original_files = list(getattr(args, "files", []))
    
    # Step 1: Humanize (runs fully as-is — terminal output + exports)
    result = cmd_humanize(args)
    
    if result is None or not result.output_text:
        return None
    
    # Step 2: Write humanized text to temp file
    fd, temp_path = tempfile.mkstemp(suffix=".txt", prefix="acewriter_full_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(result.output_text)
        
        # Step 3: Score the humanized text (runs fully as-is — all detectors + exports)
        args.files = [temp_path]
        cmd_score(args)
    finally:
        os.unlink(temp_path)
```

### 2. Add to `cli/__main__.py`

#### a) Parser builder
```python
def _build_full_parser():
    parser = argparse.ArgumentParser(
        prog="acewriter full",
        description="Humanize a document, then run full AI detection analysis on the result.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    _add_global_args(parser)
    _add_shared_args(parser)
    _add_humanize_args(parser)
    _add_score_args(parser)
    return parser
```

#### b) Add to import
```python
from ..lib.commands.full import cmd_full
```

#### c) Add `"full"` to `_CMDS`
```python
_CMDS = {"humanize", "score", "full", "auth", "config", "list", "structure"}
```

#### d) Add parser selection before `parse_known_args`
```python
elif cmd == "full":
    parser = _build_full_parser()
```

#### e) Add routing after `_merge_config`

Place it after the `if cmd == "score":` menu block and before the `cmd == "score" and not files` check:

```python
if cmd == "full":
    if not getattr(args, "files", []):
        print("Error: full requires a file path", file=sys.stderr)
        sys.exit(1)
    cmd_full(args)
    return
```

This should be placed AFTER the `if cmd == "score":` menu block and BEFORE the `if cmd == "score" and not getattr(args, "files", []):` check (around line 719), so it returns early before the file-processing loop.

### 3. No changes to existing commands
- `cmd_humanize` and `cmd_score` are reused exactly as-is
- No pipeline code duplication
- No new pipeline stages

## Backward Compatibility
- No changes to `score` or `humanize` behavior
- `full` is a new subcommand — no existing usage to break
- The default shortcut (`acewriter file.docx`) still errors cleanly

## Migration/Rollout Strategy
**Cut-and-dry:** Add new file, add ~10 lines to `__main__.py`. If issues, revert those changes.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Temp file races | Low | Low | `mkstemp` creates secure temp files, immediate cleanup in `finally` |
| Both commands generate exports | Intended | — | Humanize + score each produce their normal output files |
| `args.files` mutation | Low | Medium | Score receives temp file path, original file unaffected |
| Humanize output shows in terminal | Intended | — | User sees both outputs as expected |

## Regression Prevention
- `acewriter score file.docx` — unchanged behavior
- `acewriter humanize file.docx` — unchanged behavior
- `acewriter file.docx` — still errors cleanly
- `acewriter full file.docx` — humanize output + score output on humanized text

## Testing Strategy
1. `acewriter full file.docx` → humanize body text + score table on humanized output
2. `acewriter full file.docx --suggest` → same + suggestions from humanized text
3. `acewriter full file.docx --suggest --docx` → humanize DOCX + surgical-edit DOCX
4. `acewriter full file.docx --pdf` → humanize PDF + score PDF report
5. `acewriter full` (no file) → error
6. `acewriter full file.docx --detector zerogpt` → only zerogpt on humanized output
7. `acewriter full file.docx -H other-humanizer -S academic` → custom humanization
8. Verify `score` and `humanize` subcommands still work exactly as before
