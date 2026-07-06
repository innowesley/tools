# Fix: full subcommand passes humanized DOCX to score (not temp text file)

## Problem
`cmd_full` writes humanized text to a temp `.txt` file, then `cmd_score` runs on it:
1. **Front/back matter scored**: No DOCX structure → `score_stage` scores ALL text (includes headers, title page, references)
2. **Offset mismatch**: Suggestions have body-relative offsets, but `edit_docx` applies them to the full original DOCX — wrong positions

## Solution
Pass the **humanized DOCX** (produced by `cmd_humanize` when `--docx` is set) to `cmd_score`. The humanized DOCX has structure metadata, so `score_stage` extracts body-only text, and `edit_docx` applies suggestions at correct positions.

## Changes

### 1. `acewriter/lib/commands/full.py` — rewrite `cmd_full`

Replace the temp-file approach with humanized-DOCX passthrough:

```python
import os
import tempfile
from pathlib import Path

from .humanize import cmd_humanize
from .score import cmd_score


def cmd_full(args):
    original_files = list(getattr(args, "files", []))

    result = cmd_humanize(args)

    if result is None or not result.output_text:
        return None

    if not original_files:
        return None

    orig_path = Path(original_files[0])

    # Try passing the humanized DOCX to score (if --docx was set)
    humanized_docx = orig_path.with_stem(orig_path.stem + ".humanized").with_suffix(".assignace.docx")
    if humanized_docx.exists():
        args.files = [str(humanized_docx)]
        cmd_score(args)
    else:
        # Fall back to temp text file (e.g., --pdf only, no --docx)
        fd, temp_path = tempfile.mkstemp(suffix=".txt", prefix="acewriter_full_")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(result.output_text)
            args._original_source = str(original_files[0])
            args.files = [temp_path]
            cmd_score(args)
        finally:
            os.unlink(temp_path)
```

### 2. No changes to `score.py` needed

When humanized DOCX is passed directly:
- `source.suffix == ".docx"` → True → `_body_to_full_offsets` runs → correct offset mapping
- `structure_stage` runs → body paragraphs identified → `score_stage` scores body-only
- `edit_docx` applies suggestions at correct positions → styling preserved

The `_original_source` override in `score.py` (lines 228-235) is still needed for the temp-file fallback path and should be kept.

## Why this works

| Before (temp .txt) | After (humanized DOCX) |
|---|---|
| No structure → scores ALL text | Structure available → scores body-only |
| Offsets relative to body-only text | `_body_to_full_offsets` maps to full DOCX |
| `edit_docx` misapplies edits | `edit_docx` applies at correct positions |
| Output: `output.suggested.assignace.docx` | Output: `007-sample.humanized.suggested.assignace.docx` |

## Backward Compatibility
- Standalone `score`: unchanged
- Standalone `humanize`: unchanged
- `full` without `--docx` (no humanized DOCX): falls back to temp file + `_original_source` override
- `full` with `--docx`: uses humanized DOCX → correct behavior
