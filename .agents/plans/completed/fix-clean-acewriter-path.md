# Fix `clean-acewriter.sh` default directory path

## Status: ✅ Completed

## Problem
The script at `acewriter/clean-acewriter.sh` has a hardcoded default path:
```bash
DIR="${1:-/home/kunta/projects/tools/.samples}"
```
But the actual samples directory is `/home/kunta/projects/tools/acewriter/.samples/`.

Running the script without arguments gives the error:
```
Directory not found: /home/kunta/projects/tools/.samples
```

## Fix
Change the default to resolve relative to the script's own location using `$(dirname "$0")`:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${1:-$SCRIPT_DIR/.samples}"
```

This is robust — works regardless of which directory the user runs the script from.

## Files Changed
- `acewriter/clean-acewriter.sh` — 2 lines: add `SCRIPT_DIR` detection, update `DIR` default

## Verification
```bash
./clean-acewriter.sh          # works — finds acewriter/.samples/
./clean-acewriter.sh /custom/path  # still works — overrides
```
## Risk

None. Simple path fix, no logic changes.

## Progress Log

- [x] Read current script — hardcoded `/home/kunta/projects/tools/.samples` on line 5
- [x] Apply fix — changed to `SCRIPT_DIR` detection using `$(dirname "$0")`
- [x] Verify: runs correctly from acewriter/ directory — cleaned 9 generated files
- [x] Verify: runs correctly from parent directory — no error
- [x] Final .samples/ state: only original source files remain, all generated outputs removed
