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
2. Rebase per the Safe Worktree Rebase Procedure (`feature/intake-*`: merge main in instead, see `CLAUDE.local.md`).
3. From main repo: `./Scripts/ff-merge.sh <name>`. It refuses unless the worktree is clean, on `dev/<name>` and on top of `origin/main`. For other branch names: `./Scripts/ff-merge.sh <worktree-dir> <branch>`.

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
**Location:** the file listed by `git ls-files -oi --exclude-standard -- 'extensions/*/BACKLOG.md'`, otherwise `BACKLOG.md` at the worktree root. If `git ls-files BACKLOG.md` lists the root file, it is Tidal's leftover until your next rebase: don't use it. If neither exists, create one at the root. Never force-add a backlog.

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
| `git checkout --theirs <file>` | Replaces the file with one side of the conflict and discards the other. During a rebase "theirs" is your branch and "ours" is main, the reverse of a merge. |
| `git rebase -X theirs` | Auto-resolves conflicts for your branch and silently drops main's side, with no review. |
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
#   CLEAN working tree: git reset --merge
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

## Working with Sub-agents

The main session orchestrates and sub-agents do the multi-file work. If this section disagrees with another section, the other section wins. `feature/intake-*` worktrees follow their `CLAUDE.local.md` first: they merge main in and never rebase.

### Roles
- **Orchestrator (main session):** talks with the user, reads enough code to decide, writes briefs, spawns agents, judges reports, verifies, merges, reports back.
- **Do yourself:** a lookup, a one-line fix, a quick check.
- **Delegate:** multi-file implementation, investigations across many files, fixes. Build and fix agents use `model: opus`.
- **Session in the main checkout:** don't implement there. Create a temporary worktree first (see Parallelism).

### Briefs
A sub-agent knows only its brief. Each brief states:
- **Goal**, the facts already verified, and what is ruled out.
- **Where to look:** absolute paths of files, specs and docs. Don't paste their content.
- **Scope**, including what is out of scope.
- **Rules:** worktree path and branch, gates to run, its scratch folder, commit message format, the never-list below.
- **Report format:** short. What changed, deviations from the brief, build and test results, decisions left for the user.
- **Clean up:** stop background jobs before reporting.

### What Sub-agents May Run
- **Allowed:** `./Scripts/build.sh` with `--debug`, `--release`, `--clean` or `--regenerate`; `./Scripts/run_tests.sh`; read-only git; `git add <explicit paths>`; `git commit`. `build.sh` already runs the tests where a component has them. Effects DSP's `build.sh` takes no flags.
- **Never:**
  - `--install`, `install.sh`, `test_install.sh`, direct `xcodebuild`
  - any other git command that changes state: `push`, `merge`, `rebase`, `stash`, `reset`, `clean`, `restore`, `checkout`, `switch`, `add -A`
  - `ff-merge.sh`, `release_component.sh`, any `gh` command that writes
  - the main checkout and other worktrees
  - starting or quitting foobar2000, writing to `~/Library/foobar2000-v2/`
  - copying or committing `SecretConfig.h`
- **Scratch files:** `<session scratchpad>/<agent label>/`, absolute path in the brief. Never in the worktree: `ff-merge.sh` refuses to run with untracked files.

### Parallelism
- **At most 5 agents at once.** Spawn them unnamed, in the background. Wait for completion notices; don't poll.
- **Parallel only if work units touch different files.** `shared/` counts as touching every component. Otherwise run in sequence.
- **Never two builds, test runs or installs at once.** At most one running agent may build. The others report "not built"; the orchestrator then builds each in turn and sends failures back.
- **Default: the session's own worktree.** `build.sh` compiles a component's whole tree, including another agent's half-done edits, and the git index is shared. So in one worktree, run in parallel only read-only work or changes to different components. Same-component implementation runs in sequence.
- **Separate worktrees:** only for parallel implementation in one component. The orchestrator creates them, one per agent. Don't use the Agent tool's `isolation: "worktree"`: it lands in `.claude/worktrees/` rather than `Foobar2000-worktrees/`, with no SDK link.
  ```bash
  git worktree add --no-track -b dev/<name> ~/Projects/Foobar2000-worktrees/<name> <session branch, or origin/main>
  ln -s ~/Projects/Foobar2000/SDK-2026-10-01 ~/Projects/Foobar2000-worktrees/<name>/SDK-2026-10-01
  ```
  A component with a `SecretConfig.h.template` also needs its `SecretConfig.h` symlinked from the main checkout. Bring results back with `git cherry-pick`. Remove with `git worktree remove <path>` (no `--force`), then `git branch -D dev/<name>` once `git cherry <session branch> dev/<name>` shows only `-` lines.
- **Installs are global.** `--install` writes to `~/Library/foobar2000-v2/user-components/`, shared by every worktree, and the last install wins. Only the orchestrator installs, and only with the user's go-ahead.

### Judging Reports
- Don't relay a report unverified. Read the diff, run the build and tests, check the behaviour or screenshot, confirm claims about files and functions.
- Push back on scope creep, silently dropped requirements and trade-offs the agent chose for the user. Surface them with a recommendation.

### Plans and Size
- Size each task small, medium or large. Medium and large get a written plan, reviewed once, in one round, by a fresh sub-agent that hasn't seen the drafting, before the user approves it.
- A plan starts with "What will be done" in plain words, then the steps, then the implementation details.
- An approved multi-part plan is the go for building every part. Merges still need approval (below). When a part merges, start the next at once. Never park approved parts silently; if a part really waits on the user, say so and name the exact step.

### Merging and Releases
- Every merge to main and every release needs the user's explicit approval. An ambiguous reply is not approval.
- Merge one branch at a time:
  1. Commit your work and move untracked files out of the tree: `ff-merge.sh` refuses anything else.
  2. Rebase per the Safe Worktree Rebase Procedure.
  3. Run `./Scripts/build.sh` for each component the branch changes or that uses a changed `shared/` file.
  4. Run `./Scripts/ff-merge.sh <name>` from the main checkout. If it refuses because main moved, go back to step 2.
  5. Confirm `git ls-remote origin main` matches the branch tip. With fast-forward merges, step 3 was the build of main.
- Stashes are shared by all worktrees. Before the procedure's `git stash pop`, check `git stash list`: if your stash isn't on top, pop it by exact ref.
- After merging, remove temporary worktrees and branches. `dev/<component>` worktrees are permanent; keep them.
- Changelog, Backlog Management and Knowledge Base apply as written; the orchestrator makes sure their updates land with the change. Only the orchestrator edits `BACKLOG.md`. Parallel agents report changelog entries instead of writing them.

### Reporting to the User
- The user often reads on a phone. Short and plain: the outcome first, then what needs them, then one clear question if a decision is needed.
- No unverified claims. Say "untested" when it is.
- UI changes: send a screenshot once the change is installed and visible. If there is none, say the change wasn't checked in the app.
- Say so in advance whenever you would instruct sub-agents differently from this section.

### Quality Gates
Never skip Build & Test or Build Verification, for agents or the orchestrator. When something fails, find out why before changing anything.
