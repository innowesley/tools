# Plan: setup.sh — full nitty-gritty, non-breaking, idempotent

## Goal
Make `tools/setup.sh` safe to rerun anytime: handles venv, editable deps,
Playwright + Camoufox browsers, all CLI symlinks (incl. camoufox), PATH,
git pull without destroying local work. Collects failures and reports fixes
instead of failing fast or swallowing errors.

User choices: full coverage, keep auto-pull (safer), collect + report.

## Existing Logic Analysis
9 steps: pull tools/, stash+pull each repo in repos.conf, .gitignore patch,
venv create-if-missing, pip install -r requirements, playwright install
chromium (every run, errors hidden), nuke __editable__ pths + tools.pth,
symlink only REPOS CLIs (misses camoufox → `command not found`), PATH append
to ~/.bashrc with fragile grep.

## Changes
1. FAILURES collector; required vs advisory; final summary with fix commands.
2. Idempotent guards: skip playwright if ms-playwright has chromium;
   skip camoufox fetch if version.json exists (--force-browsers overrides).
3. Symlink all console scripts in .venv/bin (denylist python/pip/activate),
   not just REPOS — permanently fixes camoufox-class bugs.
4. Safer auto-pull: stash only if dirty; pull only if @{u} exists + network
   (git ls-remote 10s); clone SSH→HTTPS fallback; pop conflicts leave stash
   + recovery hint.
5. Step 7 surgical: only write tools.pth if `import tools` probe fails;
   never mass-delete __editable__ pths.
6. PATH robust: check live $PATH + bashrc/zshrc exact-line grep before append.
7. End with `acewriter auth doctor` advisory.

## Potential Conflicts
- tools.pth vs editable installs → verify imports before/after.
- proxman/proxyrun rename → treat as optional.
- Auto-pull vs uncommitted acewriter fixes → stash-only-if-dirty, safe pop.

## Backward Compatibility
Same CLI (+ --force-browsers, --no-pull opt-out), same repos.conf contract,
same symlink locations. Reruns are no-ops.

## Migration/Rollout
1. Script-only change. 2. First rerun = no-op proof. 3. --force-browsers
proves fetch path once.

## Risk Assessment
Pull conflicts (Med) → safe stash/pop. Offline/slow downloads (Med) →
skip-if-present + advisory. Shell config corruption (Low) → exact-line grep.

## Regression Prevention
Keep REPOS order, set -euo pipefail, spinner fallback. No requirements change.

## Testing Strategy
1. Double run → second all-skips, exit 0. 2. rm ~/.local/bin/camoufox → restored.
3. Offline → collected failures, no corruption. 4. Dirty tree round-trips.
5. Import probe passes.

## Progress Log
- [x] Plan approved (full coverage, keep pull, collect+report)
- [ ] setup.sh rewritten
- [ ] Verified syntax + idempotence + doctor

## Progress Log (Build)
- [x] Rewrote setup.sh: FAILURES collector, safe_pull (stash-only-if-dirty, upstream+network guards, SSH→HTTPS fallback), skip-if-present browsers + --force-browsers, symlink all entry points (fixes camoufox), surgical .pth, robust PATH (bash/zsh + live check), advisory doctor step, --no-pull/--help.
- Verified: bash -n SYNTAX_OK; denylist probes (python/pip denied, camoufox/acewriter linked); PATH-line already present; skip-guards hit (camoufox version.json + chromium present → downloads skipped).
- Live doctor: camoufox ok, all cookies cached, only api.turnitin.app DNS FAIL (expected, advisory).
- Status: completed
