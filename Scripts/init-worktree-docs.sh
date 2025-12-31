#!/bin/zsh
# Creates CLAUDE.md and BACKLOG.md in each worktree
# Usage: ./Scripts/init-worktree-docs.sh

set -e

WORKTREE_BASE="$HOME/Projects/Foobar2000-worktrees"
TODAY=$(date +%Y-%m-%d)

# Component display names
typeset -A DISPLAY_NAMES
DISPLAY_NAMES=(
    [simplaylist]="SimPlaylist"
    [plorg]="Playlist Organizer"
    [scrobble]="Last.fm Scrobbler"
    [waveform-seekbar]="Waveform Seekbar"
    [albumart]="Album Art"
    [queue-manager]="Queue Manager"
    [biography]="Artist Biography"
    [cloud-streamer]="Cloud Streamer"
    [playback-controls]="Playback Controls"
)

# Generate CLAUDE.md for a component
generate_claude_md() {
    local comp=$1
    local display_name="${DISPLAY_NAMES[$comp]}"
    local dir="$WORKTREE_BASE/$comp"

    cat > "$dir/CLAUDE.md" << EOF
# ${display_name} Component

Part of foobar2000 macOS Components Suite.

## Naming Convention
| Item | Pattern | Example |
|------|---------|---------|
| Branch | dev/<name> | dev/${comp} |
| Directory | foo_jl_<name>_mac | foo_jl_${comp//-/_}_mac |
| Component file | foo_jl_<name>.fb2k-component | foo_jl_${comp//-/_}.fb2k-component |

## Git Workflow
- **Branch**: dev/${comp}
- **Merge strategy**: FAST-FORWARD ONLY (no merge commits)
- **Before merging**: Always rebase onto main first

## Merge to Main
1. Ensure all changes committed
2. Run: \`git fetch origin && git rebase origin/main\`
3. From main repo: \`./Scripts/ff-merge.sh ${comp}\`

## Build & Test
\`\`\`bash
./Scripts/generate_xcode_project.rb
xcodebuild -project *.xcodeproj -scheme foo_jl_${comp//-/_} -configuration Release build
./Scripts/install.sh
\`\`\`

## Backlog Management
**At session start:** Check BACKLOG.md to see current state.

**During session:**
- Move task to "In Progress" when starting work
- Add "Started" date
- If task is too complex or deferred, add to "Pending" with priority
- On completion, move to "Completed" with date

**Complex tasks:** If a task emerges that's too large for this session, add it to BACKLOG.md Pending section immediately with notes about scope.

## Knowledge Base
**Before making changes:**
- Check \`docs/\` for existing patterns and conventions
- Check \`CONTRIBUTING.md\` for workflow rules
- Review similar implementations in other components

**After solving complex problems:**
- Create or update \`docs/<topic>.md\` with findings
- Document API quirks, SDK gotchas, or non-obvious solutions
- This helps future Claude sessions avoid re-discovering the same issues

## Release Process
**ALWAYS use the release script:**
\`\`\`bash
./Scripts/release_component.sh ${comp//-/_}
\`\`\`
Never manually:
- Create tags
- Build release packages
- Update version numbers outside version.h

The script handles: version reading, building, packaging, tagging, GitHub release.
EOF

    echo "Created CLAUDE.md in $dir"
}

# Generate BACKLOG.md for a component
generate_backlog_md() {
    local comp=$1
    local display_name="${DISPLAY_NAMES[$comp]}"
    local dir="$WORKTREE_BASE/$comp"

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
| Initial worktree setup | ${TODAY} | CLAUDE.md, BACKLOG.md created |

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
        generate_claude_md "$comp"
        generate_backlog_md "$comp"
        echo ""
    else
        echo "Skipping $comp (worktree not found at $dir)"
    fi
done

echo "=== Done ==="
