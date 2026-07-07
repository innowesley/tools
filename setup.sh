#!/usr/bin/env bash
set -euo pipefail

# ── Parse args ──
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        -v|--verbose) VERBOSE=true ;;
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
    run_with_spinner() { local m="$1" t0=$SECONDS; shift; echo "  $m"; "$@"; local rc=$?; local e=$((SECONDS-t0)); echo "  ${GRAY}(${e}s)${NC}"; return $rc; }
fi

# ── Helpers ──
header()  { printf "\n${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$*"; }
summary() { printf "  ${BOLD}${GREEN}✓${NC}  ${BOLD}%s${NC}\n" "$*"; }

_epoch_ms() {
    local t="${EPOCHREALTIME}"
    echo $(( ${t%.*} * 1000 + 10#${t#*.} / 1000 ))
}

_fmt_ms() {
    local e=$1
    printf "%d.%1ds" $(( e / 1000 )) $(( e % 1000 / 100 ))
}

run_step() {
    local msg="$1" rc=0 t0
    shift
    t0=$(_epoch_ms)
    if $VERBOSE; then
        info "$msg"
        "$@" || rc=$?
        local now=$(_epoch_ms)
        echo "  ${GRAY}($(_fmt_ms $(( now - t0 ))))${NC}"
        return $rc
    else
        run_with_spinner "$msg" "$@" || true
    fi
}

figlet_header() {
    if command -v figlet &>/dev/null && command -v lolcat &>/dev/null; then
        echo "$*" | figlet -f small 2>/dev/null | lolcat --force 2>/dev/null
    else
        printf "\n${BOLD}${BLUE}━━━ %s ━━━${NC}\n" "$*"
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

header "1. Git pull tools/"
if git rev-parse --git-dir 2>/dev/null; then
    run_step "Stashing local changes" \
        git stash push -m "setup.sh $(date +%H:%M)" 2>/dev/null
    run_step "Pulling tools/" git pull --rebase
    git stash list 2>/dev/null | grep -q . && run_step "Restoring stash" bash -c 'git stash pop 2>/dev/null'
else
    info "Not a git repo, skipping"
fi

header "2. Clone/pull tool repos"
for repo in "${REPOS[@]}"; do
    if [ -d "$repo/.git" ]; then
        run_step "Stashing $repo" \
            git -C "$repo" stash push --include-untracked -m "setup.sh $(date +%H:%M)" 2>/dev/null
        if git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name @{u} &>/dev/null; then
            run_step "Pulling $repo" git -C "$repo" pull --rebase
        else
            $VERBOSE && info "$repo: no upstream, skipping pull"
        fi
        git -C "$repo" stash list 2>/dev/null | grep -q . && run_step "Restoring $repo stash" bash -c "git -C '$repo' stash pop 2>/dev/null"
    else
        run_step "Cloning $repo" git clone "git@github.com:innowesley/$repo.git"
        (cd "$repo" && git branch --set-upstream-to=origin/main main)
    fi
done

header "3. Ensure .gitignore ignores tool dirs"
for dir in "${REPOS[@]}" .venv; do
    if ! grep -qx "$dir/" .gitignore 2>/dev/null; then
        echo "$dir/" >> .gitignore
    fi
done
summary ".gitignore up to date"

header "4. Create venv if missing"
if [ ! -f .venv/bin/python ]; then
    run_step "Creating .venv" python3 -m venv .venv
else
    summary ".venv already exists"
fi

header "5. Install/update deps"
run_step "Installing packages" \
    .venv/bin/python -m pip install \
    --config-settings editable_mode=compat \
    -r requirements.txt

header "6. Download Playwright browser (if needed)"
if .venv/bin/python -c "import playwright" 2>/dev/null; then
    .venv/bin/python -m playwright install chromium 2>/dev/null && summary "Chromium browser"
else
    info "Playwright not installed, skipping"
fi

header "7. Fix .pth for flat-layout packages"
SITE_PKGS=$(echo .venv/lib/python*/site-packages)
for f in "$SITE_PKGS"/__editable__.*.pth; do
    rm -f "$f"
done
echo "$(pwd)" > "$SITE_PKGS/tools.pth"
summary "tools.pth written"

header "8. Symlink tools to ~/.local/bin"
TARGET="${HOME}/.local/bin"
mkdir -p "$TARGET"
for tool in "${REPOS[@]}"; do
    src=".venv/bin/$tool"
    if [ -f "$src" ]; then
        ln -sf "$(pwd)/$src" "$TARGET/$tool"
        summary "$tool"
    fi
done

figlet_header "Done"
info "Run from anywhere: ${REPOS[*]}"
