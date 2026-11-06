#!/bin/zsh
# Creates a blank BACKLOG.md in each component worktree that has none.
# Never overwrites an existing BACKLOG.md. CLAUDE.md is tracked in git and comes
# with the branch, so this script does not write it.
# Usage: ./Scripts/init-worktree-docs.sh

set -e

WORKTREE_BASE="$HOME/Projects/Foobar2000-worktrees"
TODAY=$(date +%Y-%m-%d)

# Component display names
typeset -A DISPLAY_NAMES
DISPLAY_NAMES=(
    [effects-dsp]="Effects DSP"
    [simplaylist]="SimPlaylist"
    [plorg]="Playlist Organizer"
    [scrobble]="Last.fm Scrobbler"
    [waveform-seekbar]="Waveform Seekbar"
    [albumart]="Album Art"
    [queue-manager]="Queue Manager"
    [biography]="Artist Biography"
    [cloud-streamer]="Cloud Streamer"
    [playback-controls]="Playback Controls"
    [spectrum]="Spectrum Analyzer"
    [vectorscope]="Vectorscope"
)

# Generate BACKLOG.md for a component
generate_backlog_md() {
    local comp=$1
    local display_name="${DISPLAY_NAMES[$comp]}"
    local dir="$WORKTREE_BASE/$comp"

    if [ -e "$dir/BACKLOG.md" ]; then
        echo "Keeping existing BACKLOG.md in $dir"
        return 0
    fi

    cat > "$dir/BACKLOG.md" << EOF
# ${display_name} Component Backlog

## In Progress
| Task | Priority | Started | Notes |
|------|----------|---------|-------|

## Pending
| Task | Priority | Added | Notes |
|------|----------|-------|-------|

## Completed
| Task | Completed | Notes |
|------|-----------|-------|
| Initial worktree setup | ${TODAY} | BACKLOG.md created |

## Ideas (Unscoped)
EOF

    echo "Created BACKLOG.md in $dir"
}

# Main
echo "=== Initializing Worktree Documentation ==="
echo ""

# Iterate over all components defined in DISPLAY_NAMES
for comp in "${(@k)DISPLAY_NAMES}"; do
    dir="$WORKTREE_BASE/$comp"
    if [ -d "$dir" ]; then
        generate_backlog_md "$comp"
        echo ""
    else
        echo "Skipping $comp (worktree not found at $dir)"
    fi
done

echo "=== Done ==="
