#!/bin/zsh
# Fast-forward merges a worktree's branch to main
# Usage: ./Scripts/ff-merge.sh <worktree-dir> [branch]
#        branch defaults to dev/<worktree-dir>
#
# This script never rebases. It:
# 1. Refuses unless run from the main checkout, with the worktree clean, on its
#    branch, with nothing in progress, and on top of origin/main
# 2. Pushes the branch; the push is rejected if it would overwrite commits pushed
#    from elsewhere
# 3. Fast-forward merges to main (no merge commit)
# 4. Pushes main

set -e

WORKTREE_NAME=$1
BRANCH="${2:-dev/$WORKTREE_NAME}"
MAIN_REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORKTREE_DIR="$HOME/Projects/Foobar2000-worktrees/$WORKTREE_NAME"

# Validation
if [ -z "$WORKTREE_NAME" ]; then
    echo "Usage: $0 <worktree-dir> [branch]"
    echo ""
    echo "branch defaults to dev/<worktree-dir>"
    exit 1
fi

if [ ! -d "$MAIN_REPO/.git" ]; then
    echo "Error: Run this from the main checkout, not from a worktree: $MAIN_REPO"
    exit 1
fi

if [ ! -d "$WORKTREE_DIR" ]; then
    echo "Error: Worktree not found: $WORKTREE_DIR"
    echo "Run ./Scripts/worktree-setup.sh first to create worktrees."
    exit 1
fi

# Before the other checks: a stopped rebase detaches HEAD, and a stopped merge or
# cherry-pick can leave a clean tree.
WORKTREE_GIT_DIR="$(git -C "$WORKTREE_DIR" rev-parse --absolute-git-dir)"
for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
    if [ -e "$WORKTREE_GIT_DIR/$state" ]; then
        echo "Error: A rebase, merge or cherry-pick is in progress in $WORKTREE_DIR ($state)"
        echo "Finish or abort it, then rerun."
        exit 1
    fi
done

CURRENT_BRANCH="$(git -C "$WORKTREE_DIR" branch --show-current)"
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    echo "Error: $WORKTREE_DIR is on '${CURRENT_BRANCH:-detached HEAD}', expected '$BRANCH'"
    echo "For other branch names: $0 <worktree-dir> <branch>"
    exit 1
fi

if [ -n "$(git -C "$WORKTREE_DIR" status --porcelain)" ]; then
    echo "Error: Uncommitted changes or untracked files in $WORKTREE_DIR"
    echo ""
    echo "Commit your work and move untracked files out of the tree:"
    git -C "$WORKTREE_DIR" status --short
    exit 1
fi

echo "=== Fast-Forward Merging $BRANCH to main ==="
echo ""

echo "Step 1: Checking $BRANCH is on top of origin/main..."
git -C "$WORKTREE_DIR" fetch origin
if ! git -C "$WORKTREE_DIR" merge-base --is-ancestor origin/main HEAD; then
    echo ""
    echo "Error: $BRANCH is not on top of origin/main. Nothing was merged."
    echo "Rebase per the Safe Worktree Rebase Procedure (feature/intake-*: merge main in, see CLAUDE.local.md), rebuild, rerun."
    exit 1
fi

echo ""
echo "Step 2: Pushing $BRANCH..."
if ! git -C "$WORKTREE_DIR" push origin "$BRANCH" --force-with-lease --force-if-includes; then
    echo ""
    echo "Error: Push rejected. Nothing was merged."
    echo "Look for commits pushed from elsewhere: git log $BRANCH..origin/$BRANCH"
    echo "If the push says 'stale info' after the remote branch was deleted, clear the tracking ref and rerun:"
    echo "  git update-ref -d refs/remotes/origin/$BRANCH"
    exit 1
fi

echo ""
echo "Step 3: Fast-forwarding main..."
git -C "$MAIN_REPO" checkout main
git -C "$MAIN_REPO" pull --ff-only origin main
git -C "$MAIN_REPO" merge --ff-only "$BRANCH"

echo ""
echo "Step 4: Pushing main..."
git -C "$MAIN_REPO" push origin main

echo ""
echo "=== Done: $BRANCH merged to main ==="
echo ""
echo "Commits merged:"
git -C "$MAIN_REPO" log --oneline -5
