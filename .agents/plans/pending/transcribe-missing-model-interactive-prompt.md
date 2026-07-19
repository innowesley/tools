# Plan: Interactive Model Selection When Model Missing

## Goal
When `transcribe` is run and the requested model (including default `base`) is not cached, instead of crashing with a traceback, prompt the user with a nice interactive menu using `questionary` — let them download the model or use a cached alternative.

---

## Existing Logic Analysis

**File: `transcribe/lib/engine.py`** (75 lines)
- `load_model(name)` → calls `resolve_model(name)` then checks `_CACHE_DIR / f"{resolved}.pt"`. If missing → raises `FileNotFoundError` (line 59).
- `resolve_model(name)` → returns name if it's a known Whisper model (even if not cached). No error for uncached-but-known models.
- `transcribe_file(path, model_name)` → calls `load_model(model_name)`. No error handling.

**File: `transcribe/__main__.py`** (380 lines)
- `transcribe_one(src, args)` → calls `engine.transcribe_file(...)` at line 130.
- The only `except` catches `KeyboardInterrupt` — `FileNotFoundError` propagates uncaught → traceback crash.
- Output file paths use `_out_path(src, args.model, fmt)` — if user switches model, `args.model` must be updated.

**File: `transcribe/pyproject.toml`** (39 lines)
- Only dependency: `openai-whisper`. No interactive prompt library.

---

## Potential Conflicts

| Concern | Mitigation |
|---|---|
| Batch/non-interactive mode can't prompt | Detect TTY with `sys.stdin.isatty()`. If not interactive → auto-download. |
| Output file naming depends on `args.model` | If user picks cached model, update `args.model` before output. |
| `--test` mode with missing model | Apply same prompt logic. |
| User may want to skip prompts in scripts | Add `--yes` / `-y` flag. |
| New dependency `questionary` adds weight | Already depends on `openai-whisper` (large dep). `questionary` is lightweight. |

---

## Library Choice: `questionary`

**Recommended: [`questionary`](https://github.com/tmbo/questionary)**

Why over alternatives:

| Library | Pros | Cons |
|---|---|---|
| `questionary` | Modern API, `select`/`confirm`/`checkbox`, active maintenance, built on `prompt_toolkit` | Slightly heavier (uses `prompt_toolkit`) |
| `inquirer` | Simple API | Less actively maintained, fewer features |
| `pick` | Zero-dependency curses wrapper | Ugly, no mouse support, limited formatting |
| Raw `input()` | No dependency | Ugly, no arrow-key navigation |

`questionary` gives us:
- Arrow-key navigation with a styled list
- Auto-sizing to terminal width
- Clean separation of choice title and value
- Keyboard shortcuts (arrow keys, enter, ctrl-c)

---

## Prompt Design

### Interactive (TTY) — using `questionary.select()`

```
? Model 'base' not cached. What would you like to do?
  ❯ Download 'base' (142MB)
    Use cached 'large-v3-turbo' (1543MB)  [alias: turbo]
    Cancel
```

- Arrow keys to navigate, Enter to select
- First option highlighted by default (safest — download the requested model)

### User selection logic:

| User picks | Action |
|---|---|
| **Download '<model>'** | Call `engine.download_model(args.model)`, then proceed |
| **Use cached '<cached>'** | Set `args.model = cached_name`, then proceed |
| **Cancel** | Print "Cancelled." and `sys.exit(0)` |

### Non-interactive (`!sys.stdin.isatty()` or `--yes`)

Auto-download the requested model silently:
```
Model 'base' not cached. Downloading...
```

---

## Changes Required

### 1. `transcribe/pyproject.toml`
Add dependency:
```toml
dependencies = [
    "openai-whisper",
    "questionary>=2.0,<3",
]
```

### 2. `transcribe/lib/engine.py` — new `download_model()` function
Extract download logic from `cmd_add_model()` into a reusable function:
```python
def download_model(name: str) -> None:
    """Download a Whisper model if not already cached."""
    resolved = ALIASES.get(name, name)
    cached = _CACHE_DIR / f"{resolved}.pt"
    if cached.exists():
        return
    import whisper
    print(f"Downloading model '{resolved}'...", file=sys.stderr)
    try:
        whisper.load_model(resolved, download_root=str(_CACHE_DIR))
        print(f"Done. Model cached at {_CACHE_DIR}", file=sys.stderr)
    except Exception as e:
        print(f"Error downloading model '{resolved}': {e}", file=sys.stderr)
        sys.exit(1)
```

### 3. `transcribe/__main__.py` — add `_ensure_model()`
New function called before transcription begins:

```python
def _ensure_model(args) -> bool:
    """Ensure the requested model is available. Prompt interactively if not."""
    model_path = engine._CACHE_DIR / f"{args.model}.pt"
    if model_path.exists():
        return True

    # Non-interactive or --yes: auto-download
    if args.yes or not sys.stdin.isatty():
        engine.download_model(args.model)
        return True

    # Interactive prompt
    cached = engine.list_models()
    choices = [
        questionary.Choice(
            title=f"Download '{args.model}'",
            value="download",
        ),
    ]
    for m in cached:
        label = m["name"]
        if m["aliases"]:
            label += f"  [alias: {' | '.join(m['aliases'])}]"
        choices.append(
            questionary.Choice(
                title=f"Use cached '{label}' ({m['size_mb']:.0f}MB)",
                value=m["name"],
            )
        )
    choices.append(questionary.Choice(title="Cancel", value="cancel"))

    result = questionary.select(
        f"Model '{args.model}' not cached. What would you like to do?",
        choices=choices,
    ).ask()

    if result == "download":
        engine.download_model(args.model)
        return True
    elif result == "cancel" or result is None:  # None = user pressed Ctrl+C
        print("Cancelled.", file=sys.stderr)
        return False
    else:
        args.model = result
        return True
```

### 4. `transcribe/__main__.py` — wire into `transcribe_one()`
At the start, before any processing:
```python
def transcribe_one(src: Path, args):
    if not _ensure_model(args):
        return False
    # ... rest unchanged ...
```

### 5. `transcribe/__main__.py` — add `--yes` flag
```python
parser.add_argument("-y", "--yes", action="store_true",
    help="Auto-download model without prompt")
```

### 6. `transcribe/__main__.py` — import `questionary`
```python
import questionary
```

### 7. `transcribe/__main__.py` — simplify `cmd_add_model()`
Refactor to call `engine.download_model()` instead of duplicating the logic.

---

## Backward Compatibility

- **100% backward compatible.** The crash-on-missing-model is replaced with a prompt or auto-download.
- All flags, commands, output paths, and file naming conventions are preserved.
- If a user always has the requested model cached → no change in behavior.

---

## Migration/Rollout Strategy

1. Add `questionary` to `pyproject.toml`
2. Add `download_model()` to `engine.py`
3. Add `_ensure_model()` + `--yes` flag to `__main__.py`
4. Wire into `transcribe_one()`
5. Refactor `cmd_add_model()` to reuse `download_model()`
6. Test all scenarios

Rollback: `git revert` the commit. Simple and clean.

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `questionary` not installed at runtime | Low | Blocks transcription | Add to `pyproject.toml` deps; `pip install transcribe` installs it |
| Ctrl+C during prompt | Medium | Low | `questionary` handles it gracefully — returns `None`, handled as Cancel |
| User in tmux/screen without full TTY | Low | Medium | `sys.stdin.isatty()` reliable; fallback is auto-download |
| User wanted old behavior | Very low | Low | Tracebacks are never desired UX |
| `questionary` 3.0 breaking changes | Low | Low | Pin version `>=2.0,<3` |

---

## Regression Prevention

All these cases must work identically before and after:

| Command | Expected behavior |
|---|---|
| `transcribe file.mp3 -m turbo` (turbo cached) | No prompt, transcribe immediately |
| `transcribe file.mp3` (base cached) | No prompt, transcribe immediately |
| `transcribe file.mp3 -m nonexistent` | `resolve_model` still raises `ValueError` for unknown names (line 51) — not affected |
| `transcribe batch ./dir/` (base missing) | Auto-download in batch (no TTY) |
| `echo "" \| transcribe file.mp3` (piped) | Auto-download (no TTY) |
| `transcribe file.mp3 -y` (base missing) | Auto-download (skip prompt) |
| `transcribe --test file.mp3` (model cached) | No prompt, runs test as before |
| `transcribe file.mp3` (base missing, TTY) | **Prompt appears** (was crash) — intentional improvement |

---

## Testing Strategy

1. **`transcribe ~/Downloads/success.mp3`** — base missing → prompt appears
2. **Select "Download 'base'"** → downloads base, transcribes, saves `success.base.txt`
3. **Select "Use cached 'large-v3-turbo'"** → transcribes with turbo, saves `success.large-v3-turbo.txt`
4. **Select "Cancel"** → exits cleanly with "Cancelled."
5. **`echo "" | transcribe ~/Downloads/success.mp3`** — non-TTY → auto-downloads base
6. **`transcribe ~/Downloads/success.mp3 -y`** — auto-downloads base, no prompt
7. **`transcribe ~/Downloads/success.mp3 -m turbo`** — turbo cached → no prompt
8. **`transcribe batch ./podcasts/`** — auto-download in batch mode
9. **`transcribe --test ~/Downloads/success.mp3`** — test mode with prompt
10. **Ctrl+C during prompt** — exits cleanly with "Cancelled."

---

## Files Changed

| File | Change |
|---|---|
| `transcribe/pyproject.toml` | Add `questionary>=2.0,<3` to dependencies |
| `transcribe/lib/engine.py` | Add `import sys`, add `download_model()` function |
| `transcribe/__main__.py` | Add `import questionary`, `_ensure_model()`, `--yes` flag, wire into `transcribe_one()`, refactor `cmd_add_model()` |

---

## Progress Log

### [x] 2026-07-11 — Added `questionary>=2.0,<3` to pyproject.toml
### [x] 2026-07-11 — Added `sys` import + `download_model()` to engine.py
### [x] 2026-07-11 — Added `import questionary`, `_ensure_model()`, `--yes` flag, wired into `transcribe_one()`, refactored `cmd_add_model()` in __main__.py
### [ ] 2026-07-11 — Testing
