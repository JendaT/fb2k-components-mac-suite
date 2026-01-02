# SimPlaylist Component

Part of foobar2000 macOS Components Suite.

## Naming Convention
| Item | Pattern | Example |
|------|---------|---------|
| Branch | dev/<name> | dev/simplaylist |
| Directory | foo_jl_<name>_mac | foo_jl_simplaylist_mac |
| Component file | foo_jl_<name>.fb2k-component | foo_jl_simplaylist.fb2k-component |

## Git Workflow
- **Branch**: dev/simplaylist
- **Merge strategy**: FAST-FORWARD ONLY (no merge commits)
- **Before merging**: Always rebase onto main first

## Merge to Main
1. Ensure all changes committed
2. Run: `git fetch origin && git rebase origin/main`
3. From main repo: `./Scripts/ff-merge.sh simplaylist`

## Build & Test
```bash
./Scripts/generate_xcode_project.rb
xcodebuild -project *.xcodeproj -scheme foo_jl_simplaylist -configuration Release build
./Scripts/install.sh
```

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
- Check `docs/` for existing patterns and conventions
- Check `CONTRIBUTING.md` for workflow rules
- Review similar implementations in other components

**After solving complex problems:**
- Create or update `docs/<topic>.md` with findings
- Document API quirks, SDK gotchas, or non-obvious solutions
- This helps future Claude sessions avoid re-discovering the same issues

## Release Process
**ALWAYS use the release script:**
```bash
./Scripts/release_component.sh simplaylist
```
Never manually:
- Create tags
- Build release packages
- Update version numbers outside version.h

The script handles: version reading, building, packaging, tagging, GitHub release.
