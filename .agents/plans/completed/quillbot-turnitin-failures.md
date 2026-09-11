# Plan: Fix QuillBot + Turnitin `failed` in `acewriter score`

## Goal
Explain why `quillbot (QuillBot) failed` and `turnitin (Turnitin) failed` in the reported run, and fix them so `acewriter score *docx --pdf --no-cache --exclude youscan` returns real scores (or clear actionable errors) instead of generic `failed`.

User preference from Q&A: explanatory diagnosis + exact rerun/debug commands; user can rerun with `--debug` / `--json` and share output (already did once — that log is the basis below).

## Answer to "why?" (from your `--debug` log)

### 1. Turnitin → DNS failure to `api.turnitin.app`
Evidence:
```text
[detector.turnitin] submit POST https://api.turnitin.app/submit | 632 words
[detector.turnitin] submit failed — URLError: <urlopen error [Errno -2] Name or service not known>
```
- `Name or service not known` = DNS resolution failed for `api.turnitin.app`.
- This is **not** a timeout, auth, short-text, or quota error. The request never left the machine.
- Other detectors worked in the same run (`humanizeai`, `zerogpt`, `quillbot.com` all reached the network), so this is service-specific, not total offline.
- UX problem: terminal table only shows `failed | ─`. The real `URLError` is only visible with `--debug` (and JSON `feedback: "Turnitin: request failed"` is generic — root cause is swallowed in `turnitin.py:_try_turnitin()` which returns `None`).

Likely causes, in order:
1. `api.turnitin.app` domain is dead / changed / geo-blocked (custom proxy API, not official Turnitin).
2. Local DNS / firewall / VPN blocks that host only.
3. Service temporarily down (less likely given `Errno -2` vs HTTP 5xx).

### 2. QuillBot → `408 SESSION_FAILED` + broken cookie refresh
Evidence:
```text
[auth.provider] quillbot: cache MISS — launching browser
[auth.browser] profile: 22 cookies from chrome: ... qbDeviceId ... anonID ...
[detector.quillbot] API response status=408, body: {"code":"SESSION_FAILED","message":"couldn't verify session"}
[detector.quillbot] auth failure (status 408), refreshing cookie...
[auth.browser] launching Camoufox (headless) for quillbot
[auth.browser] browser error — FileNotFoundError: .../camoufox/version.json. Please run `camoufox fetch` to install.
[auth.provider] quillbot: cookie refresh failed
```
- Initial 22 Chrome cookies were extracted but QuillBot rejected the session (`couldn't verify session`).
- Auto-refresh path then failed because Camoufox browser binaries are not installed (`camoufox fetch` never run).
- Net effect: `QuillBot: request failed after cookie refresh` → terminal shows `failed`.
- Working detectors (`zerogpt` 5 cookies cache HIT, `humanizeai` 1 cookie cache HIT) prove `CookieProvider` + cache works in general; QuillBot specifically needs fresh valid session cookies.

No doc problem: 4459 scored chars / 632 words, 25 paragraphs detected — well above Turnitin's 10-word minimum and QuillBot's limits.

## Existing Logic Analysis

### Score pipeline (`lib/commands/score.py` → `lib/pipeline/stages.py::score_stage` → `lib/detector/runner.py`)
- `score_stage` extracts body-only text (`_extract_body_text`, 4459 chars here), resolves detectors (`resolve_detectors`: `all - youscan = zerogpt,humanizeai,turnitin,quillbot`), runs `run_all_detectors(..., max_workers=6)`.
- `run_detector_safe` catches exceptions, maps `DetectorResult(success=False)` → `{"score": -1.0, feedback, ...}`, caches failures with short TTL (`min(cache_ttl,60)` = 60s). `--no-cache` deletes before run, so current `failed` is live, not stale.
- `TerminalRenderer._render_score` (`lib/renderers/terminal.py:124-127`) renders any `score<0` (except `"timed out"`) as red `failed` with no reason. Real `feedback` is hidden unless `--debug` / `--json`. This is why the user saw no error.

### QuillBot (`lib/detector/quillbot.py`)
- `check()` → `CookieProvider.get("quillbot")` → `_make_session` (curl_cffi chrome impersonation) → POST `https://quillbot.com/api/ai-detector/score` with hardcoded headers (`useridtoken: empty-token`, `webapp-version: 43.33.0`, `qb-product: AI_CONTENT_DETECTOR`).
- `_is_auth_failure`: 401/403 or `408 + SESSION_FAILED` → `CookieProvider.refresh("quillbot")` → `BrowserCookieExtractor._extract(headless=True, skip_profile=True)` (Camoufox) → retry once.
- Current failure is at the refresh step (missing Camoufox install), plus possibly stale header/version if QuillBot rotated API.

### Turnitin (`lib/detector/turnitin.py`)
- `check()` → `_try_turnitin()`: `POST api.turnitin.app/submit {task_id,text}` (urllib, `timeout=min(30,10)=10s`) → if `processing`, poll `GET api.turnitin.app/fetch?task_id=` up to 8×2s.
- All `urlopen` exceptions are caught, logged only with `when=debug`, and function returns `None`; caller maps `None` → generic `DetectorResult("Turnitin: request failed")`. Original `URLError` string is lost to normal output.
- `@retry` decorator (`lib/detector/base.py`) only retries when `feedback in ("", "timed out")`, so this generic failure is **not retried**.

### Auth (`lib/auth/provider.py` + `lib/auth/browser.py` + `lib/auth/cache.py`)
- `get()`: file cache → `BrowserCookieExtractor.get_cookies` (tries chromium → chrome profiles) → env fallback (`QUILLBOT_COOKIE`).
- `refresh()`: delete cache → Camoufox headless `_extract(skip_profile=True)`. Requires `camoufox fetch` binaries + `version.json`.
- Log shows chromium profile has zero usable cookies (`Failed to find cookies for Chromium`), chrome profile yielded 22 cookies but QuillBot still said `SESSION_FAILED` — expected since QuillBot sessions are short-lived / fingerprint-bound.

## Proposed Investigation / Fix (phased)

### Phase 0 — Confirm with one-command repro (user already did; repeat after each fix)
```bash
# Full diagnostic (shows feedback + debug channel):
acewriter score *docx --no-cache --exclude youscan --debug 2>&1 | tee /tmp/score-debug.log

# Machine-readable feedback (shows per-detector feedback strings terminal hides):
acewriter score *docx --no-cache --exclude youscan --json 2>/dev/null | python3 -m json.tool | grep -A5 -E 'quillbot|turnitin'

# Isolate each failing detector (faster, avoids PDF + other detectors):
acewriter score *docx --no-cache -D quillbot --debug 2>&1 | tail -n 40
acewriter score *docx --no-cache -D turnitin --debug 2>&1 | tail -n 40

# Auth cache state:
python3 -m acewriter auth --status quillbot  # if supported; else check CookieCache files
```

### Phase 1 — Turnitin: determine if endpoint is dead and surface real error
1. DNS / connectivity check (read-only):
   ```bash
   nslookup api.turnitin.app; dig api.turnitin.app; curl -sv -m 10 https://api.turnitin.app/submit -X POST -H 'Content-Type: application/json' -d '{"task_id":"probe","text":"hello world test probe text for connectivity"}'
   ```
2. If DNS fails from multiple networks → endpoint deprecated. Decide: (a) update `_SUBMIT_URL/_FETCH_URL` to current host, or (b) mark detector degraded / disabled with clear message, or (c) route via existing `ProxyPool` like other detectors.
3. Code fix (minimal): preserve root cause — change `_try_turnitin` to return `DetectorResult(success=False, feedback=f"Turnitin: {type(e).__name__}: {e}")` instead of `None`, so `--json` and logs show `URLError ... Name or service not known` without needing `--debug`. Keep success path identical.
4. Optional: add one retry on `URLError`/timeout and structured `error_message` from server (`submit error: ...` already handled).

### Phase 2 — QuillBot: restore valid session
1. Install Camoufox binaries (the immediate blocker):
   ```bash
   camoufox fetch
   ls ~/.cache/camoufox/version.json
   ```
2. Re-login / refresh:
   ```bash
   python3 -m acewriter auth --login quillbot        # interactive browser login
   acewriter score *docx --no-cache -D quillbot --debug 2>&1 | tail -n 30
   ```
3. If `SESSION_FAILED` persists after fresh login:
   - Check `webapp-version: 43.33.0` vs live site (`Referer: https://quillbot.com/ai-content-detector` — inspect page/API for version bump).
   - Check whether `useridtoken` must be real (currently `empty-token`) or new required headers/cookies (`qbDeviceId`, `anonID` present but maybe expired).
   - Verify with `curl_cffi` impersonation still accepted; test `explain: True` payload shape.
4. Code hardening (minimal): when refresh fails, return feedback including the refresh error (`Camoufox binaries missing — run 'camoufox fetch'`), not generic `request failed after cookie refresh`. Do not change happy-path parsing (`data.value.aiScore`, chunks).

### Phase 3 — UX: never hide detector errors again (small, high-value)
- `lib/renderers/terminal.py`: for `failed` rows, append truncated `feedback` (e.g. first 80 chars) or add `--verbose` flag; at minimum print failures section below table like highlights section does for successes.
- `lib/detector/turnitin.py` + `quillbot.py`: ensure `feedback` always contains actionable next step (`check DNS`, `run camoufox fetch`, `run auth --login X`).
- Docs: note in README/CHANGELOG that `failed` means `score=-1`; use `--json` to see `feedback`.

## Potential Conflicts
- `webapp-version` / header changes in QuillBot: bumping version to match live site may fix QuillBot but break if pinned elsewhere (humanizer also talks to different hosts — no shared constant; grep shows version only in `quillbot.py`, safe).
- `CookieProvider` locks + `ThreadPoolExecutor(6)`: QuillBot refresh holds per-service lock; concurrent runs could serialize. No change proposed to locking.
- Turnitin URL change: `registry.py` marks `turnitin` as `requires_auth=False`; if new endpoint needs key, registry + `Credentials` + docs must change together.
- Terminal output change: scripts parsing `failed` string could break; mitigate by keeping `failed` token and appending reason after it.
- Camoufox install is environment-level (downloads browser); needs network + disk, may fail in sandboxed CI.

## Backward Compatibility
- All behavior fixes preserve `DetectorResult` schema (`success/score/feedback/flagged/raw_response/chunks`) and `run_detector_safe` dict keys; JSON consumers unaffected except more informative `feedback` strings.
- No change to scoring math (`median` of successful detectors only; `1/2 > 5%`, `Combined 12%` logic untouched).
- No change to cache keys/TTL semantics except failed results already use 60s TTL — keep.
- CLI flags unchanged; `--debug`/`--json` output becomes more useful but not restructured.

## Migration / Rollout Strategy
1. Land error-surfacing changes first (Turnitin preserves exception text; QuillBot includes refresh reason; terminal shows reason). Zero-risk, immediately helps users self-diagnose.
2. Env fix on user machine: `camoufox fetch` + `auth --login quillbot` (no deploy needed).
3. If Turnitin host is dead: feature-flag new URL behind constant + fallback to old URL on `URLError`, or temporarily exclude `turnitin` from `all` with a warning until replacement is verified. Avoid silently dropping a detector users expect.
4. Release as patch with CHANGELOG entry; no DB/config migration.

## Risk Assessment
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Turnitin endpoint permanently dead | High (DNS NXDOMAIN) | Detector unusable; combined score uses 2/4 detectors | Verify DNS externally; update URL or mark degraded explicitly |
| QuillBot rotates API/version again | Medium | `SESSION_FAILED` / `unrecognized response format` returns | Pin version via fetch from live page or make configurable; keep `_extract` tolerant |
| `camoufox fetch` fails (disk/net/policy) | Medium | QuillBot refresh stays broken | Document manual Chrome-login + `QUILLBOT_COOKIE` env fallback |
| Over-verbose terminal breaks scripts | Low | Parsing churn | Keep `failed` keyword; append reason in dim style / separate section |
| Retry storms on DNS failure | Low | Wasted time | Retry max 2 with backoff already; don't retry NXDOMAIN more than once |

## Regression Prevention
- Keep `zerogpt`/`humanizeai` paths untouched (they succeed; don't refactor shared `CookieProvider`/`runner` behavior beyond additive logging).
- Any edit to `turnitin.py` must preserve: 10-word minimum guard, `score*100` conversion, `processing→poll→success` flow, `error_message` handling.
- Any edit to `quillbot.py` must preserve: 15k char truncation, `aiScore 0-1→100` scaling, chunk mapping, `CookieProvider.touch` on success.
- Add assertion in code review: failure `feedback` must never be exactly `"Turnitin: request failed"` / `"QuillBot: request failed (network error)"` without cause suffix.

## Testing Strategy
1. **Repro (before fix):** `acewriter score *docx --no-cache -D turnitin --debug` → expect `URLError Name or service not known`; `-D quillbot --debug` → expect `408 SESSION_FAILED` + `camoufox ... version.json` error. Capture logs.
2. **Unit (new):** mock `urllib.request.urlopen` raising `URLError` → assert `feedback` contains `URLError`; mock QuillBot `408 SESSION_FAILED` + refresh raising `FileNotFoundError` → assert `feedback` mentions `camoufox fetch`.
3. **Integration (live, manual):** after `camoufox fetch` + login, `-D quillbot` returns `success=True, 0<=score<=100`; Turnitin either succeeds against fixed host or returns explicit DNS error (no silent `failed`).
4. **Regression:** full `score *docx --no-cache --exclude youscan` still yields `humanizeai ~0%`, `zerogpt ~25%`, combined `~12%` (median of 2) when the two remain down; `--json` schema valid; PDF generation unaffected.
5. **Existing suite:** run `pytest tests/ -k "detector or score or quillbot or turnitin"` before/after; no new failures.

## Immediate Next Steps for User (no code change needed)
1. Share output of: `nslookup api.turnitin.app` and `curl -sv -m 10 https://api.turnitin.app/submit` — confirms Turnitin DNS vs local network.
2. Run `camoufox fetch`, then `python3 -m acewriter auth --login quillbot`, then `acewriter score *docx --no-cache -D quillbot --debug 2>&1 | tail -n 30`.
3. Approve Phase 1+3 code fixes (error surfacing) if you want `failed` rows to explain themselves without `--debug`.

---
*Sources: `acewriter/lib/detector/quillbot.py`, `turnitin.py`, `runner.py`, `base.py`, `registry.py`, `lib/auth/provider.py`, `lib/renderers/terminal.py`, `lib/pipeline/stages.py`, user `--debug` log 2026-09-11 (632 words, 4459 scored chars).*

## Progress Log (Build 2026-09-11)
- [x] Moved plan to pending, reproduced via --debug/--json logs
- [x] provider.py: atomic refresh (no delete-before-success) + _last_refresh_error
- [x] browser.py: diagnose_browser_deps() (camoufox fetch hint, browser deps hint)
- [x] quillbot.py: session-expired feedback includes refresh reason
- [x] turnitin.py: _network_hint(), submit/poll/unexpected-status return actionable DetectorResult (no more None)
- [x] terminal.py: failed rows show truncated reason + failures section with tip
- [x] cli/__main__.py: `acewriter auth doctor` (camoufox, browser-cookie3, cookie age, DNS)
- Verified: py_compile OK; Turnitin DNS hint works; atomic refresh preserves cache; doctor reproduces both root causes; terminal renders reasons.
- Pre-existing failures: acewriter/tests/test_docstructure_migration (15 failed, missing .samples) — also fail on clean tree, unrelated.
- Note: acewriter/lib/detector/proxy.py proxman rename was pre-existing, untouched.
- Status: completed
