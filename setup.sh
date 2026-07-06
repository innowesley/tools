#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Read repo list from config
REPOS=()
while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    REPOS+=("$line")
done < repos.conf

echo "=== 1. Git pull tools/ (if git repo) ==="
if git rev-parse --git-dir 2>/dev/null; then
    git stash push -m "setup.sh $(date +%H:%M)" 2>/dev/null || true
    git pull --rebase
    git stash pop 2>/dev/null || true
else
    echo "  Not a git repo, skipping"
fi

echo "=== 2. Clone/pull tool repos ==="
for repo in "${REPOS[@]}"; do
    if [ -d "$repo/.git" ]; then
        echo "  Pulling $repo..."
        (cd "$repo" && git stash --include-untracked 2>/dev/null || true && git pull --rebase && git stash pop 2>/dev/null || true)
    else
        echo "  Cloning $repo..."
        git clone "git@github.com:innowesley/$repo.git"
        (cd "$repo" && git branch --set-upstream-to=origin/main main)
    fi
done

echo "=== 3. Ensure .gitignore ignores tool dirs ==="
for dir in "${REPOS[@]}" .venv; do
    if ! grep -qx "$dir/" .gitignore 2>/dev/null; then
        echo "$dir/" >> .gitignore
    fi
done

echo "=== 4. Create venv if missing ==="
if [ ! -f .venv/bin/python ]; then
    python3 -m venv .venv
fi

echo "=== 5. Install/update deps ==="
.venv/bin/python -m pip install --config-settings editable_mode=compat -r requirements.txt

echo "=== 6. Fix .pth for flat-layout packages ==="
SITE_PKGS=$(echo .venv/lib/python*/site-packages)
for f in "$SITE_PKGS"/__editable__.*.pth; do
    rm -f "$f"
done
echo "$(pwd)" > "$SITE_PKGS/tools.pth"

echo "=== 7. Symlink tools to ~/.local/bin ==="
TARGET="${HOME}/.local/bin"
mkdir -p "$TARGET"
for tool in "${REPOS[@]}"; do
    src=".venv/bin/$tool"
    if [ -f "$src" ]; then
        ln -sf "$(pwd)/$src" "$TARGET/$tool"
        echo "  ✓ $tool"
    fi
done

echo ""
echo "=== Done ==="
echo "Run from anywhere: ${REPOS[*]}"
