# Plan: Connectivity Check Before Enrichment

**Date:** 2026-07-08
**Status:** Draft

## Problem

When the host machine has no internet, the enrichment step (`_enrich_suggestions_with_rewrites`) wastes **24+ seconds** waiting for API timeouts (ZeroGPT batch: 90s timeout × 2 retries, then sequential HumanizeAI per suggestion). The user would rather detect no-internet fast and skip enrichment with a clear message.

## Where to check

**Single point: start of `_enrich_suggestions_with_rewrites()`**

Rationale:
- Detectors (`zerogpt`, `humanizeai`, `turnitin`, `youscan`, `quillbot`) have SQLite caches — they may produce results even without internet from prior runs
- Enrichment has **no cache** — it always makes API calls
- Checking earlier (before detectors) would block valid cached results
- This is the last internet-dependent step

## How to check

Try a TCP connection to `clients3.google.com:443` (Google's connectivity check endpoint) with a **3-second timeout**:

```python
import socket
def _has_internet(timeout: float = 3.0) -> bool:
    try:
        socket.create_connection(("clients3.google.com", 443), timeout=timeout)
        return True
    except (OSError, socket.gaierror):
        return False
```

- 443 = HTTPS port (most reliable — proxies/firewalls rarely block it)
- 3s timeout — fast enough to not annoy, long enough for real connections
- `socket.gaierror` catches DNS failures
- `OSError` catches connection refused, timeout, network unreachable

## Change

**File:** `lib/document/report_assembler.py`, in `_enrich_suggestions_with_rewrites()`

At the very top, before collecting `to_humanize`:

```python
def _enrich_suggestions_with_rewrites(
    suggestions: list[dict],
    max_workers: int = 2,
    timeout: int = 90,
) -> list[dict]:
    # ── Quick connectivity check — skip enrichment if no internet ──
    if not _has_internet():
        log("report.enrich", "no internet — skipping rewrite enrichment", when=False)
        return suggestions

    # rest of the function...
```

Add `_has_internet()` as a module-level helper function (or static method) in the same file.

## Behavior with no internet

1. Connectivity check fails → log `"no internet — skipping rewrite enrichment"`
2. `suggestions` returned as-is (no alternatives populated)
3. `docx_suggestions = suggestions or suggestions_raw` → no alternatives → `edit_docx()` returns None → "No DOCX exported" message
4. Score results + PDF are still produced normally
5. Total time wasted: **~3 seconds** (the connectivity check) instead of **24+ seconds** (API timeouts)

## Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| `clients3.google.com` blocked by firewall | Low — 443 is standard HTTPS, widely allowed | Timeout is only 3s, fallback is same as today |
| DNS resolution fails but internet works | Very low — DNS failure usually = no internet | Check would incorrectly skip enrichment, but suggestions would still fail anyway at API timeout |
| 3s delay on every enrichment | Low — 3s only when no internet | Could move check after `to_humanize` empty check to avoid delay when all suggestions already have alternatives |

## Optimization

The check can be placed **after** the `to_humanize` check:

```python
to_humanize = [...]
if not to_humanize:
    return suggestions  # All have alternatives already — no API calls needed

# Only check connectivity when we actually need API calls
if not _has_internet():
    log(...)
    return suggestions
```

This way, if all suggestions already have alternatives (e.g., from detectors that pre-populate them), connectivity is never checked.
