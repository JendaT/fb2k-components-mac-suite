#!/bin/zsh
# Fast-forward merges dev/<component> to main
# Usage: ./Scripts/ff-merge.sh <component>
#
# This script:
# 1. Rebases the component branch onto latest main
# 2. Pushes the rebased branch
# 3. Fast-forward merges to main (no merge commit)
# 4. Pushes main

set -e

COMPONENT=$1
MAIN_REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKTREE_DIR="$HOME/Projects/Foobar2000-worktrees/$COMPONENT"

# Validation
if [ -z "$COMPONENT" ]; then
    echo "Usage: $0 <component>"
    echo ""
    echo "Components: simplaylist plorg scrobble waveform albumart"
    echo "            queue-manager biography cloud-streamer playback-controls"
    exit 1
fi

if [ ! -d "$WORKTREE_DIR" ]; then
    echo "Error: Worktree not found: $WORKTREE_DIR"
    echo "Run ./Scripts/worktree-setup.sh first to create worktrees."
    exit 1
fi

# Check for uncommitted changes in worktree
if [ -n "$(git -C "$WORKTREE_DIR" status --porcelain)" ]; then
    echo "Error: Uncommitted changes in $WORKTREE_DIR"
    echo ""
    echo "Please commit or stash changes first:"
    git -C "$WORKTREE_DIR" status --short
    exit 1
fi

echo "=== Fast-Forward Merging dev/$COMPONENT to main ==="
echo ""

# Rebase worktree onto latest main
echo "Step 1: Rebasing dev/$COMPONENT onto main..."
git -C "$WORKTREE_DIR" fetch origin
git -C "$WORKTREE_DIR" rebase origin/main

if [ $? -ne 0 ]; then
    echo ""
    echo "Error: Rebase failed. Resolve conflicts in $WORKTREE_DIR"
    echo "After resolving: git rebase --continue"
    echo "To abort: git rebase --abort"
    exit 1
fi

echo ""
echo "Step 2: Pushing rebased dev/$COMPONENT..."
git -C "$WORKTREE_DIR" push origin "dev/$COMPONENT" --force-with-lease

echo ""
echo "Step 3: Fast-forwarding main..."
git -C "$MAIN_REPO" checkout main
git -C "$MAIN_REPO" pull --ff-only origin main
git -C "$MAIN_REPO" merge --ff-only "dev/$COMPONENT"

if [ $? -ne 0 ]; then
    echo ""
    echo "Error: Fast-forward failed. Branch has diverged from main."
    echo "This shouldn't happen if rebase succeeded. Check branch state."
    exit 1
fi

echo ""
echo "Step 4: Pushing main..."
git -C "$MAIN_REPO" push origin main

echo ""
echo "=== Done: dev/$COMPONENT merged to main ==="
echo ""
echo "Commits merged:"
git -C "$MAIN_REPO" log --oneline -5
