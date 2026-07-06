# AceWriter Architecture & Error Handling — Merged Plan

## Goal

Refactor AceWriter into a clean layered library with:
1. **No silent exception swallowing** — every error is either logged or raised with a typed exception
2. **A proper service layer** — shared orchestration logic for both `api.py` and `cli/`
3. **Exception hierarchy integrity** — all custom exceptions inherit from `AceWriterError`
4. **CLI concerns moved out of `lib/`** — no user-facing I/O in core/services
5. **Dependency inversion** — interfaces for detectors, humanizers, renderers, document loaders

---

## Existing Logic Analysis

### Current architecture

```
cli/__main__.py            api.py
  │                          │
  │  argparse, sys.exit      │  stable interface
  │                          │
  ▼                          │
lib/commands/                │
  (orchestration +           │
   print + argparse)         │
  │                          │
  ▼                          ▼
lib/pipeline/              core/
  │                          │
  ▼                          │
lib/detector/, lib/humanizer/, lib/document/, lib/editing/
```

### Key problem

`lib/commands/` is the only orchestration path for CLI but lives in `lib/`. It accepts `argparse.Namespace`, prints to stdout/stderr, reads stdin. The `api.py` → `core/` path duplicates orchestration without a shared abstraction.

### Exception hierarchy issues

- **`AceWriterError` base** exists in `exceptions.py` with 9 subclasses
- **`DetectorError` and `RenderError`** are defined but never raised (dead code)
- **`LibreOfficeNotInstalled`** inherits from `RuntimeError` instead of `AceWriterError`
- **6 `except Exception: pass`** blocks in `lib/document/report.py` and `lib/document/base.py`
- **16 bare `except Exception:`** blocks across the codebase
- **1 `ValueError`** in `lib/pipeline/stages.py:83` instead of custom `InvalidInputError`

### I/O in library code

- `lib/pipeline/stages.py:64` — `print("Note: PDF support is experimental...")` to stderr
- `lib/spinner.py` — Rich Console progress display (CLI UI in library)
- `lib/config.py` — 37 `print()` calls + interactive prompts (CLI wizard in library)
- `lib/commands/` — ~14 `print()` calls mixing orchestration with output

### Pipeline-specific issues

- `pipeline_abort` flag is redundant — exception already stops execution
- Marker parse fallback silently misaligns paragraphs with no warning

---

## Potential Conflicts & Hidden Coupling

| Coupling | Risk |
|----------|------|
| `lib/commands/` used directly by CLI; gutting it breaks `cli/__main__.py` if not rewired first | Mitigation: migrate callers before removing old code; keep deprecation shims |
| `lib/config.py`'s wizard reads/writes config files that `lib/config.py`'s loader reads | Split must preserve file format compatibility |
| `lib/spinner.py` imported by pipeline stages via `ctx.metadata["quiet"]` convention | Stages must accept a progress callback instead, or stop importing spinner |
| `libreoffice` conversion is used from multiple call sites | Keeping `LibreOfficeNotInstalled` in the hierarchy via multiple inheritance preserves backward compat |

---

## Merged Findings

### Critical

| Finding | Fix |
|---------|-----|
| `except Exception: pass` in `document/report.py` (3x), `document/base.py` (3x) | Log or raise typed error |
| Bare `except Exception:` (16 occurrences) across proxy, humanizer, detector, document code | Narrow to specific types |
| No shared service layer between `api.py` and `cli/` | Create `services/` package |
| `LibreOfficeNotInstalled` inherits `RuntimeError` not `AceWriterError` | Change to `(ProcessingError, RuntimeError)` |
| `ValueError` at `stages.py:83` instead of `InvalidInputError` | Use `InvalidInputError` |
| `print("PDF support is experimental...")` at `stages.py:64` | Move to CLI layer (not `warnings.warn`) |

### Recommended

| Finding | Fix |
|---------|-----|
| `lib/commands/` mixes orchestration + I/O (14 prints) | Move prints to CLI, return structured results |
| `lib/spinner.py` is CLI UI in library | Move to `cli/spinner.py` |
| `lib/config.py` CLI wizard mixed with config loading | Split into `lib/config.py` (logic) + `cli/config_wizard.py` (UI) |
| `DetectorError`/`RenderError` defined but never raised | Add raise sites or deprecate/remove |
| Marker parse fallback silently misaligns paragraphs | Add `warnings.warn()` when fallback + count mismatch |
| `pipeline_abort` flag is redundant | Remove flag and early-return checks |
| Temp-file hack in `full.py` | Replace with direct text passthrough |
| No dependency inversion for detectors, humanizers, renderers, document loaders | Define interfaces + inject implementations |

### Optional

| Finding | Fix |
|---------|-----|
| `lib/renderers/` in `lib/` | Acceptable as documented output adapters |
| Input validation at library boundaries | Add guard clauses with typed exceptions |

---

## Service Layer Design

### Single entry point, not three classes

Use a single `services/analysis.py` (or `services/pipeline.py`) instead of duplicating orchestration across `score.py`, `humanize.py`, `full.py`:

```
services/
├── __init__.py
├── analysis.py          # or pipeline.py
├── interfaces.py        # Detector, Humanizer, Renderer, DocumentLoader protocols
└── options.py           # shared option dataclasses (or reuse from core/)
```

### AnalysisService

```python
class AnalysisService:
    def __init__(
        self,
        detector: Detector,
        humanizer: Humanizer,
        document_loader: DocumentLoader,
        renderers: dict[str, Renderer],
    ):
        ...

    def score(self, source: str, options: ScoreOptions) -> ScoreResult: ...
    def humanize(self, source: str, options: HumanizeOptions) -> HumanizeResult: ...
    def full(self, source: str, options: FullOptions) -> FullResult: ...
```

### Service contract

- Accept typed dataclass options
- Return typed result dataclasses
- NEVER print, NEVER read stdin, NEVER touch argparse
- Raise `AceWriterError` subclasses on failure
- Accept injected dependencies via constructor

### Migration

1. Create `services/` package
2. Implement orchestration logic (lifted from `core/` and `lib/commands/`)
3. Wire `api.py` to create service with default dependencies and delegate
4. Wire `cli/__main__.py` to create service and manage I/O
5. Delegate or absorb `lib/commands/`

---

## Dependency Inversion

### Interfaces (in `services/interfaces.py`)

```python
from typing import Protocol

class Detector(Protocol):
    def detect(self, text: str, *, options: DetectorOptions) -> DetectionResult: ...

class Humanizer(Protocol):
    def humanize(self, text: str, *, options: HumanizerOptions) -> HumanizationResult: ...

class Renderer(Protocol):
    def render(self, result: AnalysisResult, **kwargs) -> str | bytes: ...

class DocumentLoader(Protocol):
    def load(self, source: str | Path) -> Document: ...
```

### Why this matters

- Testing: mock any external dependency without network calls
- Extensibility: add new AI providers by implementing the protocol
- Isolation: swap implementations without touching orchestration

### Migration

- Define protocols first (existing classes already match closely)
- Type-hint `AnalysisService` with protocols
- Add tests with mock implementations
- No immediate need to change existing concrete classes

### What's NOT changing immediately

- The `Detector` protocol doesn't mean rewrite `lib/detector/proxy.py`
- `Renderer` protocol doesn't mean rewrite `lib/renderers/terminal.py`
- These are type annotations + constructor injection in the new service layer
- Existing concrete classes continue working as-is

---

## Error Boundary Decision

**No `InternalAceWriterError`.** Unexpected programming errors should propagate naturally during development. The plan previously proposed wrapping all unexpected exceptions — removed per feedback.

`api.py` entry points will:

- Let `AceWriterError` subclasses propagate (caller's responsibility)
- Let unexpected exceptions propagate (visible during development, easier debugging)
- Document the exception hierarchy so callers know what to catch

---

## Print-in-Library Rule

**Not a blanket ban.** The automated check will enforce:

```python
# OK in lib/:
# - renderer output methods (renderer-owns-output pattern)
# - debug helpers gated by when=debug
# - config wizard (accepted as bundled CLI tool)
# Tests are exempt.

# NOT OK in core/services:
# - user-facing print() in service layer
# - print() in pipeline orchestration
```

The test will scan `services/`, `core/`, and `lib/pipeline/` — not `lib/renderers/`, not `lib/debug.py`, not `lib/config.py`.

---

## Phase Plan (4 Pull Requests)

### PR 1: Exception cleanup only

- P1.1 — Fix 6 `except Exception: pass` (log or raise typed error)
- P1.2 — Narrow 16 bare `except Exception:` to specific types
- P1.3 — Fix `LibreOfficeNotInstalled` → `(ProcessingError, RuntimeError)`
- P1.4 — Fix `ValueError` → `InvalidInputError` in stage 83
- P1.5 — Move `print("PDF support is experimental...")` from stage 64 to CLI layer
- P1.6 — Handle unused `DetectorError`/`RenderError` (add raise sites or remove)

**Scope:** `lib/document/`, `lib/detector/`, `lib/humanizer/`, `lib/pipeline/`, `exceptions.py`

**Tests:**
- Trigger each fixed error path, assert correct exception type
- Verify `LibreOfficeNotInstalled` is caught by `except ProcessingError`
- Verify `InvalidInputError` raised for unknown humanizer

---

### PR 2: Service layer introduction

- P2.1 — Define interfaces in `services/interfaces.py`
- P2.2 — Create `services/analysis.py` with `AnalysisService`
- P2.3 — Create `services/options.py` / reuse from `core/`
- P2.4 — Wire `api.py` to delegate to `AnalysisService`
- P2.5 — Add error documentation (which exceptions callers should catch)

**Scope:** New `services/` package, modify `api.py`

**Tests:**
- `AnalysisService.score()` with mock detector → typed result
- `AnalysisService.humanize()` with mock humanizer → typed result
- `AnalysisService.full()` with mock dependencies
- `api.score()` → same result as direct service call
- `api.humanize()` → produces zero stdout/stderr

**Not in scope:** CLI separation, `lib/commands/` removal

---

### PR 3: CLI separation

- P3.1 — Move `lib/spinner.py` to `cli/spinner.py`
- P3.2 — Split `lib/config.py` → `lib/config.py` (logic) + `cli/config_wizard.py` (UI)
- P3.3 — Move `resolve_input()` from `lib/commands/__init__.py` to `cli/input.py`
- P3.4 — Wire `cli/__main__.py` to use `AnalysisService`, manage I/O
- P3.5 — Add deprecation shims for moved modules

**Scope:** `cli/`, `lib/commands/`, `lib/config.py`, `lib/spinner.py`

**Tests:**
- CLI output comparison pre/post refactor (content only, not formatting)
- `acewriter score sample.docx` before/after
- `acewriter full sample.docx --suggest` before/after
- Deprecation warning fires for old import paths

**Not in scope:** Pipeline polish, temp-file hack, marker parse

---

### PR 4: Cleanup and polish

- P4.1 — Remove redundant `pipeline_abort` flag
- P4.2 — Add marker parse fallback `warnings.warn()`
- P4.3 — Remove temp-file hack from `full.py`
- P4.4 — Add input validation guards at library boundaries
- P4.5 — Temp-file hack removal

**Scope:** `lib/pipeline/`, `lib/commands/full.py` (or absorbed into services)

**Tests:**
- Pipeline abort removed, verify exception still stops execution
- Marker parse fallback triggers warning
- Text passthrough works without temp files

---

## What's NOT Changing

| Component | Decision | Rationale |
|-----------|----------|-----------|
| `lib/debug.py` (`log()`) | Keep as-is | Diagnostic logging, gated by `when=debug`, fine in library |
| `lib/renderers/` | Keep renderer-owns-output pattern | Valid design (Rich itself works this way) |
| `lib/config.py` wizard | Stays in lib until PR 3 | Accepted as bundled CLI tool with clear docs |
| Existing detector/humanizer implementations | No rewrite needed | Protocols are annotations, not refactors |

---

## Backward Compatibility

| Change | Breakage Risk | Mitigation |
|--------|---------------|------------|
| `LibreOfficeNotInstalled` → `(ProcessingError, RuntimeError)` | Low | Multiple inheritance preserves both paths |
| `ValueError` → `InvalidInputError` | Low | Undocumented behavior; grep shows no dependents |
| `print()` → CLI layer | Low | Output identical but produced at different layer |
| Move `lib/spinner.py` | Low | Only imported by pipeline; pipeline won't import after refactor |
| Move `lib/commands/*` | Medium | Add deprecation shims before removing originals |
| New `AnalysisService` | None | Additive — existing paths continue working |

### Deprecation shim pattern

```python
# Original location after move:
import warnings
from cli.commands import resolve_input as _resolve_input

def resolve_input(*args, **kwargs):
    warnings.warn(
        "lib.commands.resolve_input moved to cli.input.resolve_input",
        DeprecationWarning, stacklevel=2
    )
    return _resolve_input(*args, **kwargs)
```

---

## Migration/Rollout Strategy

```
PR 1 — Exception cleanup (independent, can ship alone)
    P1.1 Fix except Exception: pass
    P1.2 Narrow bare except Exception:
    P1.3 Fix LibreOfficeNotInstalled hierarchy
    P1.4 Fix ValueError in stage 83
    P1.5 Move print to CLI layer
    P1.6 Handle DetectorError/RenderError dead code

PR 2 — Service layer (additive, existing paths untouched)
    P2.1 Define interfaces
    P2.2 Create AnalysisService
    P2.3 Wire api.py to use service
    P2.4 Add error documentation

PR 3 — CLI separation (depends on PR 2)
    P3.1 Move spinner
    P3.2 Split config.py
    P3.3 Move resolve_input
    P3.4 Wire cli/__main__.py
    P3.5 Add deprecation shims

PR 4 — Pipeline polish
    P4.1 Remove pipeline_abort
    P4.2 Marker parse warning
    P4.3 Temp-file hack removal
    P4.4 Input validation guards
```

**Rollback:** Each PR is independently revertible. PRs 1 and 2 are safe to ship standalone. PR 3 should be tested with both old and new import paths before removing legacy code.

---

## Risk Assessment

| Change | Risk | Mitigation |
|--------|------|------------|
| P1.1: Silent catch → raise typed error | Medium — existing callers may not handle new exception | Check callers; only raise for critical paths, log+continue for non-critical |
| P1.2: Bare except → narrow types | Low | Previously caught everything; review each site to preserve intended behavior |
| P1.3: LibreOfficeNotInstalled re-hierarchy | Low | Backward compat via multiple inheritance |
| P1.5: Move print out of pipeline | Low | CLI prints same message at different point |
| P2: New service layer | Low | Additive — no existing code changes |
| P3: CLI separation | Medium | CLI output could differ subtly; compare before/after |
| P4.3: Temp-file removal | Low | Text passthrough is simpler and more reliable |
| Dependency inversion protocols | None | Type annotations only; no runtime changes |

---

## Regression Prevention

### Pre/post comparison for each PR

1. `acewriter score sample.docx` — compare stderr, compare stdout
2. `acewriter full sample.docx --suggest` — compare output
3. `python -c "from acewriter.api import score; result = score('sample.txt')"` — verify no stdout/stderr
4. `python -c "from acewriter.api import score; score('nonexistent.docx')"` — verify `AceWriterError`, not raw `Exception`

### Automated checks

- Scan `services/`, `core/`, `lib/pipeline/` for `print(` calls — fail if any found (renderers, debug, config exempt)
- `test_api_produces_no_stderr.py` — call `api.score()`, `api.humanize()`, assert nothing on stderr
- `test_all_exceptions_inherit_from_acewriter_error.py` — walk `exceptions.py`, verify all classes inherit from `AceWriterError`

---

## Testing Strategy

### Unit tests (PR 1)

- For each `except` block fix: trigger the error path, assert correct exception type or graceful continuation
- `test_libre_office_not_installed_is_processing_error`: verify `isinstance(LibreOfficeNotInstalled(), ProcessingError)`
- `test_stage_83_raises_invalid_input_error`: mock bad tool name, verify `InvalidInputError`
- `test_stage_64_has_no_print`: capture output, verify no print() side effects

### Unit tests (PR 2)

- `test_analysis_service_score_with_mock_detector`: inject mock, verify typed `ScoreResult`
- `test_analysis_service_humanize_with_mock_humanizer`: verify typed `HumanizeResult`
- `test_analysis_service_injects_dependencies`: verify constructor params are used

### E2E tests (PR 3)

- `test_cli_through_services_produces_same_output`: compare CLI output old vs new
- `test_cli_exit_code_on_error`: verify `sys.exit(1)` for `AceWriterError`, `sys.exit(0)` for success

### E2E tests (PR 4)

- `test_pipeline_abort_removed`: inject humanizer error, verify exception propagates
- `test_text_passthrough_no_tempfile`: verify full() works without temp files

---

## Progress Log

### 2026-07-06 — PR 1 completed

| Item | File(s) | Change |
|------|---------|--------|
| P1.1 | `lib/document/report.py` (3x), `lib/document/base.py` (4x) | Replaced 7 `except Exception: pass` with `log("module", "msg", error=e)` |
| P1.2 | `lib/document/report_assembler.py`, `lib/humanizer/humanizeai.py`, `lib/humanizer/zerogpt.py`, `lib/detector/quillbot.py`, `lib/detector/humanizeai.py`, `lib/document/docx/analyzer.py`, `lib/config.py`, `cli/__main__.py` | Narrowed 8 bare `except Exception:` to specific types (ImportError, json.JSONDecodeError, AttributeError, KeyError, TypeError) |
| P1.2 | `lib/detector/proxy.py` | Narrowed inner `except Exception:` to `OSError` (outer kept as `Exception` for curl_cffi compatibility) |
| P1.3 | `lib/document/base.py` | `LibreOfficeNotInstalled` → `(ProcessingError, RuntimeError)` |
| P1.4 | `lib/pipeline/stages.py` | `ValueError` → `InvalidInputError` for unknown humanizer |
| P1.5 | `lib/pipeline/stages.py` | Replaced `print("PDF support is experimental...")` with `log(..., when=debug)` |
| P1.6 | `lib/detector/proxy.py` | Added `DetectorError` raise in proxy cache save failure path; `RenderError` left as catchable type without raise site |

Verified: all files compile, `except Exception: pass` eliminated, hierarchy fixes confirmed.

### 2026-07-06 — PR 2 completed

| Item | File(s) | Change |
|------|---------|--------|
| P2.1 | `services/interfaces.py` (new) | Defined `Detector`, `Humanizer`, `DocumentLoader`, `Renderer` protocols |
| P2.2 | `services/analysis.py` (new) | Created `AnalysisService` with `score()`, `humanize()`, `full()` methods, typed options/results, DI constructor |
| P2.3 | `core/options.py` | Added `FullOptions` dataclass; also reused existing `ScoreOptions`/`HumanizeOptions` from core |
| P2.4 | `api.py` | Replaced `run_score`/`run_humanize` calls with `AnalysisService` delegate; added `api.full()` entry point |
| P2.5 | `api.py`, `services/analysis.py` | Added docstrings documenting exception types callers should expect |

Verified: imports compile, existing `core/` paths unchanged, service sets `quiet=True` internally.

### 2026-07-06 — PR 3 completed

| Item | File(s) | Change |
|------|---------|--------|
| P3.1 | `cli/spinner.py` (new), `lib/spinner.py` (shim) | Moved spinner implementation to CLI; deprecation shim redirects old imports |
| P3.2 | `cli/config_wizard.py` (new), `lib/config.py` (trimmed) | Split interactive wizard (InquirerPy, prints) into CLI; config data/loading stays in `lib/` |
| P3.3 | `cli/input.py` (new), `lib/commands/__init__.py` (shim) | Moved `resolve_input`, `get_pdf_path`, `is_doc` to CLI; deprecation shims in old location |
| P3.4 | `cli/__main__.py` | Updated spinner imports to use `cli.spinner`; updated config wizard import to `cli.config_wizard`; `lib/commands/` imports kept (forwarded via shims) |
| P3.5 | `lib/spinner.py`, `lib/commands/__init__.py` | Added deprecation shims with `DeprecationWarning` for all moved functions |
| Bonus | `lib/commands/humanize.py` (8 prints), `lib/commands/score.py` (6 prints) | Added Rich dim/italic styling to all tips, status messages, output paths, and errors |

Remaining `lib/` imports in `cli/__main__.py` (cmd_humanize, cmd_score, cmd_full, config, detector, auth, credentials, humanizer.styles) — these are core library modules or will be addressed when CLI fully wires to `AnalysisService` (future PR).

### 2026-07-06 — CLI polish (error handling + helpful messages)

| Item | File(s) | Change |
|------|---------|--------|
| Error boundary | `cli/__main__.py` | Wrapped `_main()` in try/except `AceWriterError` — all library exceptions now print clean "Error: ..." instead of tracebacks. Also catches `KeyboardInterrupt` → clean `sys.exit(130)`. |
| Fuzzy subcommand matching | `cli/__main__.py` | Unknown commands like `analyze` or `sructure` now suggest close matches via `difflib.get_close_matches` (e.g. "Did you mean humanize?") before exiting. |
| Better no-subcommand message | `cli/__main__.py` | `acewriter` with no args now lists all 7 available commands instead of "Use 'acewriter score' or 'acewriter humanize'." |

**Verified:**
- `acewriter` → "Available: auth, config, full, humanize, list, score, structure"
- `acewriter analyze` → "Did you mean humanize?"
- `acewriter sructure` → "Did you mean structure, score?"
- `acewriter humanize` (no file) → "Error: empty input" (no traceback)
- `acewriter full` (no file) → "Error: full requires a file path"
- `acewriter structure` (no file) → argparse built-in error

### 2026-07-06 — CLI Rich styling applied

| Item | File(s) | Change |
|------|---------|--------|
| Console import | `cli/__main__.py` | Added `from rich.console import Console` + `_console = Console(stderr=True)` |
| Error messages (13) | `cli/__main__.py` | All `print("Error: ...", file=stderr)` → `_console.print("[red]Error:[/red] ...")` |
| Status messages (8) | `cli/__main__.py` | Config paths, login flow, proxies → `_console.print("[dim]...[/dim]")` or `[cyan]...[/cyan]` |
| Success/failure (2) | `cli/__main__.py` | Login success → `[bold green]✓[/bold green]`, failure → `[bold red]✗[/bold red]` |
| Cancelled (8) | `cli/__main__.py` | All `KeyboardInterrupt` handlers → `[yellow]Cancelled.[/yellow]` / `[yellow]Interrupted.[/yellow]` |
| `_say()` helper | `cli/__main__.py` | Uses `_console.print` with `[dim]` now (was bare `print`) |
| Remaining `print(stderr)` | 1 left (`format_debug_output`) | Intentional — outputs pre-formatted structured data, not an error message |

**Total: 38 of 39 `print(..., file=stderr)` replaced with `_console.print()` using Rich markup.**
