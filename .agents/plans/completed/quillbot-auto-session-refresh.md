# QuillBot: Auto-refresh stale sessions via Camoufox headless

## Objective
When a detector's API returns an authentication/session failure (e.g. quillbot `408 SESSION_FAILED`, humanizeai `400/401/403`), auto-discard stale browser-cookie3 cookies and obtain a fresh session via Camoufox headless browser.

Any detector that calls `CookieProvider.refresh()` inherits this fix — currently **quillbot** and **humanizeai**.

## Existing Logic Analysis

### The problem

1. `QuillBotDetector.check()` → calls `CookieProvider.get()` → `BrowserCookieExtractor.get_cookies()` → `_extract()`:
   - `_get_cookies_from_profile()` (browser-cookie3) **always succeeds** (reads quillbot cookies from Chrome profile)
   - Returns stale/expired cookies immediately → Camoufox headless fallback **never reached**
2. `_try_api()` receives stale cookies → API returns `408 SESSION_FAILED`
3. `_is_auth_failure()` detects it → calls `CookieProvider.refresh()`:
   - Deletes cookie cache
   - Calls same `BrowserCookieExtractor.get_cookies()` → `_extract()` → same stale profile cookies again
4. Retry with same stale cookies → same 408 failure → `"request failed after cookie refresh"`

### Current `refresh()` implementation (provider.py:60-75)
```python
def refresh(service, debug=False):
    CookieCache(service).delete()
    cookie = BrowserCookieExtractor.get_cookies(service, debug=debug)  # ← same stale path
    if cookie:
        CookieCache(service).write(cookie, source="browser")
        return cookie
    return None
```

### Current `_extract()` implementation (browser.py:124-181)
```python
def _extract(service, headless=True, debug=False):
    cookie = _get_cookies_from_profile(service, debug=debug)  # ← always succeeds
    if cookie:
        return cookie                                         # ← short-circuits
    # Camoufox headless → never reached for quillbot
```

## Proposed Changes

### File 1: `auth/browser.py` — Add `skip_profile` parameter to `_extract()`

- `_extract()` gets `skip_profile: bool = False` parameter
- When `True`, skip `_get_cookies_from_profile()` entirely — go straight to Camoufox headless
- No new methods, no duplicated logic
- Default stays `False` so `get_cookies()` / `auth login` behavior is unchanged

### File 2: `auth/provider.py` — Simplify `refresh()`

- `refresh()` deletes cached cookies first (already does)
- Calls `_extract(skip_profile=True, headless=True)` directly — no profile, no visible fallback, no env var
- Wraps in try/except to catch browser/timeout/Cloudflare exceptions
- On success: caches cookies, returns them
- On failure: logs warning, returns `None` → detector falls through to existing `"auth login"` message

## Potential Conflicts

- **None**: `_extract()` is only called from 3 places: `get_cookies()`, `get_cookies_interactive()`, and now `refresh()`. All existing callers pass `skip_profile=False` (default), so behavior is identical.
- The `refresh()` path today already returns `None` on failure — unchanged.

## Backward Compatibility

- `_extract()` signature changes from `(service, headless, debug)` to `(service, headless, skip_profile, debug)` — but it's only called internally by the class. No external consumers.
- `refresh()` return type stays `str | None` — same as before.

## Migration/Rollout Strategy

- No migration needed. This is a behavior improvement on the failure path.
- Rollback: revert the 2-file diff. The old code returns to reading stale profile cookies and failing.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Camoufox headless fails on Cloudflare | Medium | Refresh fails → user runs `auth login` (same as today) | Already handled — `None` return triggers existing prompt |
| Camoufox not installed | Medium | Same as above | `ImportError` caught, returns `None` |
| `_QUILLBOT_TRIGGER` doesn't set valid session | Medium | Camoufox "succeeds" but cookies still fail | Refresh+retry still fails → user gets `auth login` prompt |
| Camoufox headless succeeds (new positive case) | High | **quillbot starts working again** 🎉 | Auto-cached, subsequent calls hit cache |
| Latency (2-5s browser launch) | Always | Slower failure recovery | Only on failure path; normal path unaffected |

## Regression Prevention

- All existing callers of `_extract()` pass default `skip_profile=False` — no change in behavior
- `refresh()` return type unchanged — `None` still triggers `"auth login"` prompt
- Existing tests (if any) continue to pass

## Testing Strategy

1. **Manual test 1** (expected to work): Run `py -m acewriter score sample.docx --debug` twice
   - First run: quillbot fails 408 → `refresh()` launches Camoufox headless → gets fresh cookies → retry succeeds
   - Second run: cached detectors (fast) + cached quillbot cookies (no browser launch)
2. **Manual test 2** (Camoufox fails): Disconnect network or mock Cloudflare challenge
   - `refresh()` catches exception → logs warning → returns `None`
   - Detector prints `"QuillBot: authentication required. Run: py -m acewriter auth --login quillbot"`
3. **Regression check**: Run `acewriter auth login quillbot` — should still extract profile cookies as before

## Implementation

### `auth/browser.py` — 1 line changed, 1 line added

```python
# Line 124 — add skip_profile parameter
# Before:
def _extract(service: str, headless: bool = True, debug: bool = False) -> str | None:
# After:
def _extract(service: str, headless: bool = True, skip_profile: bool = False, debug: bool = False) -> str | None:

# Lines 129-132 — guard with skip_profile
# Before:
    cookie = _get_cookies_from_profile(service, debug=debug)
    if cookie:
        return cookie
# After:
    if not skip_profile:
        cookie = _get_cookies_from_profile(service, debug=debug)
        if cookie:
            return cookie
```

### `auth/provider.py` — Replace `refresh()` body

```python
@staticmethod
def refresh(service: str, debug: bool = False) -> str | None:
    lock = CookieProvider._lock_for(service)
    with lock:
        CookieCache(service).delete()

        log("auth.provider", f"{service}: refreshing cookies via headless browser", when=debug)

        from .browser import BrowserCookieExtractor
        try:
            # Skip stale browser-cookie3 profile; go straight to fresh Camoufox headless
            cookie = BrowserCookieExtractor._extract(service, headless=True, skip_profile=True, debug=debug)
            if cookie:
                CookieCache(service).write(cookie, source="browser")
                return cookie
        except Exception as e:
            log("auth.provider", f"{service}: headless refresh failed", when=debug, error=e)

        log("auth.provider", f"{service}: cookie refresh failed — run 'py -m acewriter auth --login {service}'", when=debug)
        return None
```

Note: The "run auth login" part will be printed by the quillbot detector's existing `_auth_help()` message, so we don't need to duplicate it here.

## Flow Diagram

```
 API returns auth failure (408/401/403/400-cloudflare)
         │
         ▼
 Detector._is_auth_failure() → True
         │
         ▼
 CookieProvider.refresh(service)         ← quillbot, humanizeai (service-agnostic)
   1. CookieCache.delete()               # delete stale cookies
   2. _extract(service, headless=True, skip_profile=True, debug=debug)
         │
    ┌────┴────┐
    │         │
  str       None / Exception
    │         │
    ▼         ▼
  Cache.write()   log("refresh failed")
  inject into     return None
  session, retry      │
    │                 ▼
    ▼          Detector shows:
  success      "auth required — run auth login"
```

---

## Execution Log

### 2026-07-09 — Status: Completed ✓

**Changes applied:**

1. **`auth/browser.py:124`** — Added `skip_profile: bool = False` parameter to `_extract()`. When `True`, browser-cookie3 profile extraction is skipped, going straight to Camoufox headless.

2. **`auth/provider.py:60-80`** — Replaced `refresh()` body. Now calls `_extract(service, headless=True, skip_profile=True, debug=debug)` directly, wrapped in try/except. On failure, logs warning and returns `None` (existing detector auth-help messages handle user-facing output).

**Auto-fixes for detectors:**
- `quillbot` (408 SESSION_FAILED) — Camoufox headless → fresh session → retry
- `humanizeai` (400/401/403/cloudflare) — same path, zero detector code changes

**Verified:**
- Syntax check passed for both files
- No new methods created, no code duplication
- Default `skip_profile=False` preserves existing behavior for `get_cookies()` and `auth login`
```
