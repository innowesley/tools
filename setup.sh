#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== 1. Git pull tools/ (if git repo) ==="
git pull 2>/dev/null || echo "  Not a git repo, skipping"

echo "=== 2. Clone/pull tool repos ==="
for repo in acewriter doctools transcribe docstructure; do
    if [ -d "$repo/.git" ]; then
        echo "  Pulling $repo..."
        (cd "$repo" && git pull)
    else
        echo "  Cloning $repo..."
        git clone "git@github.com:innowesley/$repo.git"
    fi
done

echo "=== 3. Ensure .gitignore ignores tool dirs ==="
for dir in acewriter doctools transcribe docstructure .venv; do
    if ! grep -qx "$dir/" .gitignore 2>/dev/null; then
        echo "$dir/" >> .gitignore
    fi
done

echo "=== 4. Install/update deps (only what's missing) ==="
py

echo "=== 5. Symlink tools to ~/.local/bin ==="
TARGET="${HOME}/.local/bin"
mkdir -p "$TARGET"
for tool in acewriter doctools transcribe; do
    src=".venv/bin/$tool"
    if [ -f "$src" ]; then
        ln -sf "$(pwd)/$src" "$TARGET/$tool"
        echo "  ✓ $tool"
    fi
done

echo ""
echo "=== Done ==="
echo "Run from anywhere: acewriter, doctools, transcribe"
