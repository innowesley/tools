#!/usr/bin/env bash
set -euo pipefail

# ── Parse args ──
VERBOSE=false
FORCE_BROWSERS=false
NO_PULL=false
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
        --force-browsers) FORCE_BROWSERS=true ;;
        --no-pull) NO_PULL=true ;;
        -h|--help)
            echo "Usage: setup.sh [-v|--verbose] [--force-browsers] [--no-pull]"
            echo "  --force-browsers  re-download Playwright Chromium + Camoufox even if present"
            echo "  --no-pull         skip all git stash/pull (install only)"
            exit 0 ;;
    esac
done

# ── Source libs with graceful fallback ──
if [[ -d ~/scripts/lib ]]; then
    source ~/scripts/lib/colors.sh
    source ~/scripts/lib/spinner.sh
    source ~/scripts/lib/logging.sh
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; GRAY=""; NC=""
    info()    { echo "  $*"; }
    warn_line() { echo "  ${YELLOW}⚠ $*${NC}"; }
    run_with_spinner() { local m="$1" t0=$SECONDS; shift; echo "  $m"; "$@"; local rc=$?; local e=$((SECONDS-t0)); echo "  ${GRAY}(${e}s)${NC}"; return $rc; }
fi

# ── Helpers ──
header()  { printf "\n${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$*"; }
summary() { printf "  ${BOLD}${GREEN}✓${NC}  ${BOLD}%s${NC}\n" "$*"; }
skip_msg() { printf "  ${GRAY}↷ %s${NC}\n" "$*"; }

# Collect-and-report: keep going, list fixes at the end.
FAILURES=()
record_failure() { FAILURES+=("$1 :: fix: $2"); }
print_failures() {
    if ((${#FAILURES[@]} == 0)); then return 0; fi
    printf "\n${BOLD}${YELLOW}━━━ Action needed (%d) ━━━${NC}\n" "${#FAILURES[@]}"
    local f
    for f in "${FAILURES[@]}"; do
        printf "  ${YELLOW}•${NC} %s\n" "$f"
    done
    return 1
}

_epoch_ms() {
    local t="${EPOCHREALTIME}"
    echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))
}

_fmt_ms() {
    local e=$1
    printf "%d.%1ds" $(( e / 1000 )) $(( e % 1000 / 100 ))
}

# run_step <message> <required:true|false> <cmd...>
# Required failures are recorded AND return nonzero at the end; never aborts mid-run.
run_step() {
    local msg="$1" rc=0 t0 req="${2:-true}"
    shift 2
    t0=$(_epoch_ms)
    if $VERBOSE; then
        info "$msg"
        "$@" || rc=$?
        local now=$(_epoch_ms)
        echo "  ${GRAY}($(_fmt_ms $(( now - t0 ))))${NC}"
    else
        run_with_spinner "$msg" "$@" || rc=$?
    fi
    if ((rc != 0)); then
        record_failure "$msg (exit $rc)" "rerun with -v to see output, then fix manually"
    fi
    return 0
}

figlet_header() {
    if command -v figlet &>/dev/null && command -v lolcat &>/dev/null; then
        echo "$*" | figlet -f small 2>/dev/null | lolcat --force 2>/dev/null
    else
        printf "\n${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$*"
    fi
}

_net_ok() {
    # Fast upstream reachability probe (10s). Used before any pull/fetch.
    git ls-remote https://github.com 2>/dev/null | head -1 | grep -q . 2>/dev/null
}

_git_dirty() { [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]]; }
_has_upstream() { git -C "$1" rev-parse --abbrev-ref --symbolic-full-name @{u} &>/dev/null; }

# safe_pull <dir> — stash only if dirty, pull only with upstream+network,
# restore stash, never drop a conflicting stash.
safe_pull() {
    local dir="$1" label="${2:-$1}" stashed=false
    local msg="setup.sh-$(date +%Y%m%d%H%M%S)"
    if _git_dirty "$dir"; then
        if git -C "$dir" stash push --include-untracked -m "$msg" >/dev/null 2>&1; then
            stashed=true
        else
            record_failure "Stash $label" "run 'git -C $label status' and commit or stash manually"
            return 0
        fi
    fi
    if _has_upstream "$dir"; then
        if _net_ok; then
            if ! git -C "$dir" pull --rebase 2>/dev/null; then
                record_failure "Pull $label" "run 'git -C $label pull --rebase' with -v to see why"
            fi
        else
            skip_msg "$label: offline, skipping pull"
        fi
    else
        $VERBOSE && info "$label: no upstream, skipping pull"
    fi
    if $stashed; then
        if git -C "$dir" stash list --format="%gs" 2>/dev/null | grep -q "$msg"; then
            if ! git -C "$dir" stash pop >/dev/null 2>&1; then
                record_failure "Restore $label stash" "run 'git -C $label stash list' then 'git stash pop' manually"
            fi
        fi
    fi
}

# ── Start ──
cd "$(dirname "$0")"

figlet_header "Setup"

# Read repo list from config
REPOS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    REPOS+=("$line")
done < repos.conf

if ! $NO_PULL; then
header "1. Git pull tools/"
if git rev-parse --git-dir >/dev/null 2>&1; then
    safe_pull "." "tools"
else
    info "Not a git repo, skipping"
fi

header "2. Clone/pull tool repos"
for repo in "${REPOS[@]}"; do
    if [ -d "$repo/.git" ]; then
        safe_pull "$repo" "$repo"
    else
        if _net_ok; then
            if ! git clone "git@github.com:innowesley/$repo.git" 2>/dev/null; then
                info "$repo: SSH clone failed, trying HTTPS"
                if git clone "https://github.com/innowesley/$repo.git" 2>/dev/null; then
                    (cd "$repo" && git branch --set-upstream-to=origin/main main 2>/dev/null) || true
                else
                    record_failure "Clone $repo" "check SSH key or network, then clone manually"
                fi
            else
                (cd "$repo" && git branch --set-upstream-to=origin/main main 2>/dev/null) || true
            fi
        else
            record_failure "Clone $repo (missing dir, offline)" "reconnect, then rerun setup.sh"
        fi
    fi
done
else
    skip_msg "Git pull skipped (--no-pull)"
fi

header "3. Ensure .gitignore ignores tool dirs"
for dir in "${REPOS[@]}" .venv; do
    if ! grep -qx "$dir/" .gitignore 2>/dev/null; then
        echo "$dir/" >> .gitignore
    fi
done
summary ".gitignore up to date"

header "4. Create venv if missing"
if [ ! -f .venv/bin/python ]; then
    run_step "Creating .venv" true python3 -m venv .venv
else
    summary ".venv already exists"
fi

header "5. Install/update deps"
if [ -f .venv/bin/python ]; then
    run_step "Installing packages" true \
        .venv/bin/python -m pip install \
        --config-settings editable_mode=compat \
        -r requirements.txt
    # Verify the imports setup.sh depends on later.
    if ! .venv/bin/python -c "import acewriter" 2>/dev/null; then
        record_failure "import acewriter failed after pip install" "run '.venv/bin/python -m pip install -r requirements.txt -v'"
    fi
else
    record_failure ".venv/bin/python missing" "run 'python3 -m venv .venv' manually"
fi

header "6. Browsers (skip if present)"
if .venv/bin/python -c "import playwright" 2>/dev/null; then
    if $FORCE_BROWSERS || ! ls -d ~/.cache/ms-playwright/chromium-* >/dev/null 2>&1; then
        if _net_ok; then
            run_step "Playwright Chromium" false .venv/bin/python -m playwright install chromium
        else
            skip_msg "Playwright: offline, skipping download"
        fi
    else
        summary "Playwright Chromium already present"
    fi
else
    info "Playwright not installed, skipping"
fi
if .venv/bin/python -c "import camoufox" 2>/dev/null; then
    if $FORCE_BROWSERS || [ ! -f ~/.cache/camoufox/version.json ]; then
        if _net_ok; then
            run_step "Camoufox browser" false .venv/bin/python -m camoufox fetch
        else
            skip_msg "Camoufox: offline, skipping download (run 'camoufox fetch' later)"
        fi
    else
        summary "Camoufox browser already present"
    fi
else
    info "Camoufox not installed (acewriter[browser] missing?), skipping fetch"
fi

header "7. Fix .pth for flat-layout packages"
SITE_PKGS=$(echo .venv/lib/python*/site-packages)
if .venv/bin/python -c "import tools" 2>/dev/null || [ -f "$SITE_PKGS/tools.pth" ]; then
    # Only write when needed; never mass-delete __editable__ pths (that undoes pip editable installs).
    if ! .venv/bin/python -c "import tools" 2>/dev/null; then
        echo "$(pwd)" > "$SITE_PKGS/tools.pth"
        summary "tools.pth written"
    else
        summary "imports OK, .pth untouched"
    fi
else
    echo "$(pwd)" > "$SITE_PKGS/tools.pth"
    summary "tools.pth written"
fi

header "8. Symlink entry points to ~/.local/bin"
TARGET="${HOME}/.local/bin"
mkdir -p "$TARGET"
# Link repo tools (backward compat) + every other console script pip installed
# (camoufox, playwright, ...). Denylist interpreters and activators.
DENY='^(python[0-9.]*|pip[0-9.]*|wheel|setuptools|activate.*|dotenv)$'
linked=0
for src in .venv/bin/*; do
    name="$(basename "$src")"
    [ -f "$src" ] && [ -x "$src" ] || continue
    if [[ "$name" =~ $DENY ]]; then continue; fi
    # Only link real entry points, not libs: must have a shebang or be ELF.
    head -c 2 "$src" 2>/dev/null | grep -q . || continue
    ln -sf "$(pwd)/$src" "$TARGET/$name"
    linked=$((linked + 1))
done
# Backward-compat guarantee: every REPOS entry resolves even if its binary
# name differs from the dir name (link best-effort, never fail the run).
for tool in "${REPOS[@]}"; do
    if [ ! -e "$TARGET/$tool" ] && [ -f ".venv/bin/$tool" ]; then
        ln -sf "$(pwd)/.venv/bin/$tool" "$TARGET/$tool"
    fi
done
summary "$linked entry points linked ($TARGET)"

header "9. Ensure ~/.local/bin is in PATH"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
added=false
for rc in ~/.bashrc ~/.zshrc; do
    [ -f "$rc" ] || continue
    if grep -qF "$PATH_LINE" "$rc" 2>/dev/null || grep -qF 'export PATH=$HOME/.local/bin' "$rc" 2>/dev/null; then
        continue
    fi
    # Only touch the rc of the current shell to stay idempotent.
    if [[ "$rc" == ~/.bashrc && "${SHELL:-}" == *zsh* ]]; then continue; fi
    if [[ "$rc" == ~/.zshrc && "${SHELL:-}" != *zsh* ]]; then continue; fi
    printf '\n# Added by tools/setup.sh\n%s\n' "$PATH_LINE" >> "$rc"
    summary "Added ~/.local/bin to PATH in $rc"
    added=true
done
if ! $added; then
    if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
        summary "${HOME}/.local/bin already on PATH"
    else
        info "Run 'source ~/.bashrc' (or ~/.zshrc) or open a new terminal"
    fi
fi

header "10. Doctor (advisory)"
if [ -x .venv/bin/acewriter ] || command -v acewriter >/dev/null 2>&1; then
    # Never fails the run — just surfaces camoufox/cookie/DNS state.
    (.venv/bin/acewriter auth doctor 2>/dev/null || acewriter auth doctor 2>/dev/null) || \
        info "doctor skipped (acewriter not runnable yet)"
else
    info "doctor skipped (acewriter not installed yet)"
fi

figlet_header "Done"
info "Run from anywhere: ${REPOS[*]}"
if ! print_failures; then
    info "Rerun with -v for details. Partial setup is usable; fix items above when convenient."
    exit 1
fi
