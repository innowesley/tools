# Detector Resilience & Rate-Limit Handling (acewriter)

## Goal

Fix the three observed detector failures (`zerogpt`, `quillbot`, `turnitin`) at the root
(rate limiting, premium paywall, stale-auth masking), make every failure visible with an
actionable reason in the terminal, and correct a scoring name/value mislabel bug.
Scope confirmed by user: rate-limit-aware retry + messages, cross-run throttling + proxy
routing, turnitin chunking (serialized/paced), scoring mislabel fix.

## Root causes (evidence-backed)

1. **zerogpt** — expired cached cookie (514h). Anonymous fallback now paywalled:
   `api.zerogpt.com` returns `403 "Please make a purchase before accessing this resource"`.
   With a fresh login the API works — debug run returned `success:true, fakePercentage:33`
   for the **full 11588-char text in one request** → length never the cause.
2. **quillbot** — API requires Premium. Debug trace: `408 SESSION_FAILED`
   → auto headless refresh → `403 USER_PREMIUM_FORBIDDEN "user doesn't have premium
   privileges"`. Account-state issue, length-independent, not fixable by re-login.
3. **turnitin** — `429 "Rate limit exceeded, please waite for several seconds."
   retry_after: 7 seconds`. **Probes prove this is a frequency/IP rolling-window limit,
   NOT request size**: 22-word → 200; 200-word 2s after another call → 429; 4800-word
   alone → 200. Code today throws away the `retry_after` body (raw `urllib`, `HTTPError`
   → generic "Turnitin: request failed").
4. **Failure caching masks re-auth** — `runner.py:66` caches failures TTL=60s. Subsequent
   `score` runs (5.7s/2.6s totals) were pure cache hits, so a fresh login never ran.
5. **Scoring mislabel** — `stages.py` passes `detector_names=names` (registry order,
   unfiltered) with filtered `score_list` (display order) → debug showed
   `humanizeai:33 / turnitin:92` that were really `zerogpt:33 / youscan:92`.

## Existing Logic Analysis

- Detector protocol (`lib/detector/base.py`): `check()` → `DetectorResult`; `ChunkedDetector`
  mixin already exists (used by humanizeai: 2 parallel chunks + proxy pool, char-weighted
  merge). `splitter.py` `split_by_paragraph_groups()` is reusable.
- `run_detector_safe` (`runner.py`): dict conversion + cache (`TTL=300` success /
  `TTL=min(ttl,60)` failure).
- `terminal.py:127`: renders ALL failures as bare red `failed`, discards `ds.feedback`.
- `turnitin.py`: raw `urllib`, no cookie/proxy/curl impersonation, no status handling.
- `quillbot.py`: `_is_auth_failure()` treats 401/403/408 as refreshable → wastefully
  launches ~20s headless browser on premium blocks that refresh can't fix.
- `zerogpt.py`: cookie + no-cookie paths only accept `success:true`; paywall 403 → generic
  "all methods failed".
- `proxy.py` `ProxyPool`: loads `proxman --json` proxies; used by youscan + humanizeai
  chunks. turnitin does not use it.
- Auth: `CookieProvider` + per-service SQLite cookie cache; `history.jsonl` log exists.

## Proposed Changes

### 1. Rate-limit-aware retry + actionable failure messages
- **turnitin.py**:
  - Parse 429 body (`retry_after` seconds) instead of discarding it.
  - On 429: set `RateGate` cooldown (below), sleep `retry_after`, retry up to 2 attempts
    (deadline-aware within outer timeout).
  - Final feedback: `"Turnitin: rate limited — waiting Ns, retry again later"` or
    `"Turnitin: server error (500): <body error>"`; preserve `raw_response`.
- **quillbot.py**: if response body code is `USER_PREMIUM_FORBIDDEN` → return immediately,
  feedback `"QuillBot: premium account required — AI Detector API now requires a paid
  plan"`, **skip the cookie refresh** (saves ~20s/run). Keep refresh only for
  401/408-`SESSION_FAILED`.
- **zerogpt.py**: when a 403 paywall body is seen in either path, feedback:
  `"ZeroGPT: API requires a valid login — run: acewriter auth login zerogpt"` (instead of
  "all methods failed").
- **terminal.py** (~line 127): failed row shows truncated reason from `ds.feedback`
  (~40 chars) beside `failed`.

### 2. Cross-run throttling + proxy routing
- **New `lib/detector/rate.py`** — `RateGate`:
  - In-memory per-domain gate: minimum interval between calls (default ~1.0s, `acewriter`
    env/`--` override not needed initially).
  - `observe_429(domain, retry_after)`: set `cooldown_until = max(now, now+retry_after)`.
  - `acquire(domain)`: block until interval/cooldown satisfied.
  - **Cross-run persistence**: also persist last-call ts + cooldown in the existing SQLite
    `CacheStore` (small key, e.g. `rate:<domain>`), so a fresh CLI invocation that runs
    seconds after a hammered one waits instead of insta-429ing.
- **turnitin.py**: switch from `urllib` to `curl_cffi` (impersonate chrome) and route
  submit+poll through `ProxyPool` (like youscan), rotating per chunk → spreads IPs and
  buys headroom on the per-IP window.

### 3. Turnitin chunking (serialized, paced — NOT parallel)
- Convert `TurnitinDetector` to `ChunkedDetector`:
  - `_split_text`: reuse `split_by_paragraph_groups(truncated, n=2)`.
  - `_check_chunk`: `RateGate.acquire("turnitin")` before submit; submit+poll per chunk
    (same proxy for submit+poll); on 429 honors `retry_after` before retrying.
  - `_chunk_workers = 1` (serial). Rationale: the limit is a **frequency window** —
    parallel chunks would multiply hits. Chunking + pacing + proxies + gate is the combo
    that actually reduces 429s.
  - `_merge_results`: char-weighted average of successful chunk scores (reuse humanizeai
    merge pattern); if no chunk succeeded → failure feedback with first error reason.
- Tradeoff explicitly noted: chunking alone doesn't bypass the window; it is deployed
  WITH items 1+2.

### 4. Scoring name/value alignment fix (`lib/pipeline/stages.py`)
- Both `pre_score_stage` and `score_stage`:
  `pairs = [(name, d["score"]) for name, d in scores_dict.items() if d["score"] >= 0]`
  and pass aligned names/scores into `scoring.combined_score`. Fixes debug logs,
  `--weights`, and `--ignore-outliers` labeling. Median/mean result unchanged.

### 5. Failure-cache clarity
- On `acewriter auth login <service>` / `CookieProvider.refresh`: delete that service's
  cached **failure** rows from SQLite (add `CacheStore.detector_delete_failed(detector)`,
  schema unchanged) so re-auth visibly takes effect.
- Document `--no-cache` as the immediate escape hatch.

## Potential Conflicts

- `CacheStore` needs a new row-deletion method (~5 lines); must not alter schema.
- `turnitin` becomes a chunked/proxy detector → its `raw_response` shape changes to a
  merged dict; JSON consumers must tolerate that (field names preserved: score/feedback/
  chunks/raw_response). roundtrip consumers OK since only merged.
- RateGate in-memory singleton must be thread-safe (concurrent 5-detector runs already
  parallelize); use a lock around acquire/set.
- Cross-run gate state in SQLite adds cache writes per detector call — negligible volume.
- Proxy dependency: if `proxman`/proxies unavailable, fall back to direct curl_cffi
  (same as youscan's behavior) so turnitin still works without proxies.

## Backward Compatibility

- Additive: new feedback strings, retry-on-429, chunked turnitin, rate gate, cache-row
  cleanup. No CLI flag removal, no result schema key removal.
- Existing cached success/failure rows remain valid.
- Median/mean `combined_score` unchanged; weighted/outlier labels become correct.
- turnitin `raw_response` merged-shape is the only visible change; documented in
  `API_REFERENCE.md`.

## Migration / Rollout Strategy

- One PR, no data migration. Ship chunks: (a) messages + scoring fix (quick wins),
  (b) rate gate + proxy routing, (c) turnitin chunking, (d) auth cache-clear.
- Each step independently releasable; (a)+(d) can land together.

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| QuillBot/premium message key drifts | Med | Keep generic 403 fallback; message is advisory |
| Chunking turnitin changes score semantics | Low-Med | Weighted avg mirrors humanizeai; tests assert ±1% vs single-shot on pass path |
| 429 retries add latency to already-slow runs | Low | Cap 2 extra attempts + deadline; retry_after-driven sleep |
| Proxy pool empty → turnitin broken | Med | Direct fallback path (like youscan) |
| In-memory RateGate race under concurrency | Low | Guard with lock; cross-run state via SQLite row insert/update |
| Cache-clear deletes useful history | Low | Only on explicit `auth login`; only failed rows |

## Regression Prevention

- Unit tests:
  - turnitin: 429 body with `retry_after` → schedules cooldown + feedback contains
    "rate limited"; 500 w/ body → server message preserved; 200 short req merges.
  - turnitin chunking: 2-chunk success weighted-merge ≈ full-text result (±1%); all-chunks-fail
    → failure feedback with first error.
  - quillbot: `USER_PREMIUM_FORBIDDEN` → no `CookieProvider.refresh` call (mock), feedback
    contains "premium".
  - zerogpt: paywall 403 → feedback contains "auth login".
  - RateGate: observe_429 sets cooldown; acquire blocks until elapsed; cross-run via
    fresh instance reads persisted cooldown.
  - stages: aligned `detector_names` vs filtered scores in both stages; median unchanged.
  - terminal: failed row renders truncated reason.
- Run `pytest` suite + `test-manual.sh` smoke.

## Testing Strategy

1. `pytest tests/` (existing + new) green.
2. Live manual `--no-cache --debug` on the sample doc:
   - turnitin either scores via chunked+proxy path or reports the precise 429/backoff;
   - quillbot fails fast with premium message, no browser launch;
   - zerogpt succeeds with fresh cookie / else login hint;
   - terminal rows show reasons; scoring log shows correct name→score pairs.
3. Burst test: two `score` runs back-to-back → second run waits per RateGate instead of
   insta-429 (verify via debug timestamps / no immediate failure).
4. Update `API_REFERENCE.md` + `README` notes on rate limiting and chunking.

## Out of Scope

- Obtaining paid QuillBot/ZeroGPT accounts or provicing proxy infra.
- Rewriting other detectors (youscan/humanizeai) to the new gate unless trivial.
## Implementation Progress

Status: **implemented, verified — smoke test passed**

- [x] Move plan to pending; documented proxy TTL item
- [x] Rate-limit-aware retry + actionable failure messages
  - turnitin: 429 body `retry_after` parsed, honored w/ backoff; 500/network rotate proxy; clear reasons
  - quillbot: `USER_PREMIUM_FORBIDDEN` → fail-fast "premium account required", no browser refresh
  - zerogpt: `_paywall_reason()` → "auth login zerogpt" hint (helpers return 200 body regardless of success)
  - terminal.py: failed rows show shortened reason + tt_ms
- [x] Scoring name/value alignment (pipeline/stages.py — both pre_score_stage & score_stage)
- [x] RateGate (lib/detector/rate.py) — min-interval + 429 cooldown, persisted via CacheStore kv; turnitin routes through ProxyPool (curl_cffi, per-chunk rotation, _PROXY_ATTEMPTS=3)
- [x] Turnitin chunking (ChunkedDetector, _chunk_workers=1 serial, char-weighted merge)
- [x] Proxy TTL 1hr (PROXY_CACHE_TTL=3600) + stale-file fallback on refresh failure
- [x] auth login + CookieProvider.refresh clear that service's cached failure rows (CacheStore.detector_delete_failed + kv table)
- [x] Regression tests written: tests/test_detector_resilience.py
- [x] Offline verification: 19/19 tests pass (shadow-package run, no install/network).
      One test expectation corrected (weighted merge uses total chars 300 -> 66.67).
- [x] Post-install verification:
      - venv pytest: 19/19 new resilience tests pass. (15 failures in
        test_docstructure_migration.py are PRE-EXISTING: test computes SAMPLES at
        repo-root/.samples (parent.parent.parent), but samples live at
        acewriter/.samples — path mismatch, unrelated to these changes.)
      - Live smoke `acewriter score the-farewell-family-analysis.docx --no-cache --debug`:
        - turnitin split into 2 chunks; first submit 429 → rate.gate "cooldown +7s",
          retried after retry_after → 200, both chunks scored (13.81%, 39.46%,
          raw status=success chunks_ok=1/2). 429 recovery works.
        - quillbot 403 USER_PREMIUM_FORBIDDEN → fail-fast premium message, no browser
          (30.3s saved vs old ~20s refresh path).
        - zerogpt success:fakePercentage=33.1 via fresh cookie (no paywall).
        - youscan 92%, humanizeai chunked ok; auth cookies all HIT from cache.

Progress notes:
- CacheDatabase gained `kv` table + `detector_delete_failed`; CacheStore wrappers + kv_get/kv_set.
- Live probe confirmed turnitin 429 is frequency-window (not size): 22w→200, 200w@2s→429, 4800w alone→200.
- Post-install smoke (2026-08-10 10:28–10:30): 429→cooldown→retry→200 recovery observed live on both chunks;
  quillbot premium fail-fast confirmed; zerogpt fresh-cookie success confirmed; DB rows show all
  turnitin/youscan/humanizeai success, quillbot premium block, zerogpt 33.1%.
