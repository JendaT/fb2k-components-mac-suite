#!/bin/zsh
# Creates all component worktrees with SDK symlinks
# Usage: ./Scripts/worktree-setup.sh

set -e

MAIN_REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKTREE_BASE="$HOME/Projects/Foobar2000-worktrees"
SDK_DIR="SDK-2025-03-07"

COMPONENTS=(
    simplaylist
    plorg
    scrobble
    waveform
    albumart
    queue-manager
    biography
    cloud-streamer
    playback-controls
)

echo "=== foobar2000 Worktree Setup ==="
echo "Main repo: $MAIN_REPO"
echo "Worktree base: $WORKTREE_BASE"
echo ""

mkdir -p "$WORKTREE_BASE"

for comp in "${COMPONENTS[@]}"; do
    WORKTREE_DIR="$WORKTREE_BASE/$comp"

    if [ -d "$WORKTREE_DIR" ]; then
        echo "Skipping $comp (already exists)"
        continue
    fi

    echo "Creating worktree: $comp"

    # Create branch if doesn't exist, then worktree
    if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/dev/$comp"; then
        git -C "$MAIN_REPO" worktree add "$WORKTREE_DIR" "dev/$comp"
    else
        git -C "$MAIN_REPO" worktree add "$WORKTREE_DIR" -b "dev/$comp" main
    fi

    # Symlink SDK
    if [ -d "$MAIN_REPO/$SDK_DIR" ] && [ ! -e "$WORKTREE_DIR/$SDK_DIR" ]; then
        ln -s "$MAIN_REPO/$SDK_DIR" "$WORKTREE_DIR/$SDK_DIR"
        echo "  - SDK symlinked"
    fi

    # Symlink shared directory
    if [ -d "$MAIN_REPO/shared" ] && [ ! -e "$WORKTREE_DIR/shared" ]; then
        ln -s "$MAIN_REPO/shared" "$WORKTREE_DIR/shared"
        echo "  - shared/ symlinked"
    fi

    echo ""
done

echo "=== Setup Complete ==="
git -C "$MAIN_REPO" worktree list
