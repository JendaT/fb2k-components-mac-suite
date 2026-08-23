# foobar2000 macOS Components

## Identifying the Current Component

Determine the component from the git branch name:
- Branch `dev/simplaylist` -> component `simplaylist`, directory `foo_jl_simplaylist_mac`
- Branch `dev/scrobble` -> component `scrobble`, directory `foo_jl_scrobble_mac`
- Branch `main` -> no specific component (repo root)

Pattern: branch `dev/<name>` maps to `extensions/foo_jl_<name>_mac/`.

## Naming Convention
| Item | Pattern | Example |
|------|---------|---------|
| Branch | dev/\<name\> | dev/simplaylist |
| Directory | foo_jl_\<name\>_mac | foo_jl_simplaylist_mac |
| Component file | foo_jl_\<name\>.fb2k-component | foo_jl_simplaylist.fb2k-component |

## Git Workflow
- **Branch**: `dev/<name>` for each component
- **Merge strategy**: FAST-FORWARD ONLY (no merge commits)
- **Before merging**: Always rebase onto main first

## Merge to Main
1. Ensure all changes committed
2. Run: `git fetch origin && git rebase origin/main`
3. From main repo: `./Scripts/ff-merge.sh <name>`

## Build & Test (CRITICAL)

**ALWAYS use the component's Scripts/ folder. NEVER call xcodebuild directly.**

```bash
# From the component directory (extensions/foo_jl_<name>_mac/):

# Standard build + install:
./Scripts/build.sh --install

# Clean rebuild:
./Scripts/build.sh --clean --install

# If new source files were added:
./Scripts/build.sh --regenerate --install
```

**Options:**
- `--debug` / `--release` - Configuration (default: Release)
- `--clean` - Clean before building
- `--regenerate` - Regenerate Xcode project (after adding/removing files)
- `--install` - Install to foobar2000 after building

**NEVER run xcodebuild directly** - it outputs to DerivedData instead of local build/, causing install to copy stale binaries.

## Build Verification (CRITICAL)

The build script prints an unambiguous banner on completion:
- `BUILD SUCCEEDED` — safe to proceed
- `BUILD FAILED` — STOP. Do NOT tell the user the build succeeded. Read the error output and fix the issue.

**NEVER assume a build succeeded without seeing `BUILD SUCCEEDED` in the output.** If the build output is unclear or you did not see the banner, re-run the build or check the log file at `build/build.log`.

## Changelog (IMPORTANT)

Two changelogs exist:
1. **Extension CHANGELOG** (`extensions/foo_jl_<name>_mac/CHANGELOG.md`) — detailed, per-component
2. **Global CHANGELOG** (`CHANGELOG.md` at repo root) — summary of all components

**When updating a component's CHANGELOG, always also append the same entry to the global CHANGELOG** under the matching component section. Keep the global entries concise (skip Technical subsections).

**Style:** Keep entries compact — one line per item, bold the feature/area name, then a short description. No multi-sentence explanations. Example:
```
- **Space key**: Now toggles play/pause instead of track selection; starts playback when stopped.
- **Scroll rendering**: Tracks no longer appear blank when scrolling outside the initial viewport.
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

**Before releasing, rebase onto main** to pick up the latest shared code, build scripts, and this CLAUDE.md:
```bash
# Follow the Safe Worktree Rebase Procedure below, then:
./Scripts/release_component.sh <name>
```

**ALWAYS use the release script.** Never manually:
- Create tags
- Build release packages
- Update version numbers outside version.h

The script handles: version reading, building, packaging, tagging, GitHub release.

## Worktree Safety (CRITICAL)

Worktrees are **active development environments** with uncommitted work. NEVER use destructive git commands on them.

### Forbidden Commands on Worktrees

| Command | Why Dangerous |
|---------|---------------|
| `git checkout --theirs <file>` | Replaces local file with main's version, discarding all local changes |
| `git rebase -X theirs` | Auto-resolves all conflicts in favor of main, discarding local changes |
| `git stash drop` | Permanently deletes stashed changes |
| `git reset --hard` | Destroys all uncommitted changes |

### Safe Worktree Rebase Procedure

**ZERO DATA LOSS policy: No uncommitted work may ever be lost during rebase. If any step fails, ROLLBACK and STOP.**

**Step-by-step procedure (mandatory for every rebase):**

```bash
# Step 1: Check for uncommitted changes
git status

# Step 2: If changes exist, stash them
git stash push -m "pre-rebase: $(date +%Y%m%d-%H%M%S)"

# Step 3: Perform rebase
git fetch origin && git rebase origin/main

# Step 4: If rebase FAILS (conflicts with committed code):
#   ROLLBACK: git rebase --abort
#   RESTORE: git stash pop
#   STOP and report which commits conflict with main

# Step 5: If rebase succeeds, restore stashed changes
git stash pop

# Step 6: If stash pop FAILS (uncommitted work conflicts with rebased code):
#   The stash is PRESERVED (git does not drop it on conflict)
#   CLEAN working tree: git checkout -- .
#   STOP and report to user:
#     - Which files from the stash conflict
#     - The stash ref (so user can manually resolve)
#     - Suggest: git stash show to inspect, git stash pop to retry manually
```

**CRITICAL RULES:**
- NEVER use `git rebase -X theirs` or any auto-resolution strategy
- NEVER drop or delete a stash
- NEVER proceed past a failed step
- If no uncommitted changes exist (step 1 clean), skip steps 2/5/6
- On ANY unexpected error: STOP immediately and report to user

### Why This Matters

Incident 2026-01-13: Automated rebase with `-X theirs` destroyed uncommitted work in simplaylist worktree. User had to recover from another commit. Conflicts require human judgment, not automation.
