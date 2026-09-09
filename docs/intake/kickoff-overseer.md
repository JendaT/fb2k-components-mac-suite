# Intake Kickoff — Overseer Instructions

New spec set landed (uncommitted): `docs/intake/intake-01..04-*.md` +
`knowledge_base/14_INTAKE_SYSTEM_OVERVIEW.md`. Read the overview FIRST —
it is the map (decisions, worker split, phases).

## Your tasks (overseer only — do NOT implement)

1. Review the five docs for consistency with repo conventions. Commit ONLY
   intake files to main: `docs: add intake system specs v1 (docs 00-04)`.
   Do not sweep the other untracked WIP (biography, playback-controls, etc.).
2. Wire into the knowledge base per existing conventions (index/links;
   reference from CLAUDE.md if tooling docs are listed there).
3. Create two worktrees (usual flow):
   - `../Foobar2000-intake-cli`, branch `feature/intake-cli` — tools worker.
     Scope: docs 01, 02, 03. First deliverable = P1: `tools/intake/` Bun
     package implementing `intake scan / resolve / status` + sidecar schema,
     with fixture corpus + golden tests per doc 01 acceptance gate
     (≥90% roots bounded, zero file mutations). No beets shim yet (P2).
   - `../Foobar2000-intake-ext`, branch `feature/intake-extension` —
     extension worker. Scope: docs 03, 04. First deliverable = P4 part A:
     `jl_row_decorator_provider` API in `shared/` + SimPlaylist integration
     behind a zero-provider guard (benchmarks unchanged with no provider).
     `foo_jl_intake_mac` comes after part A is merged.
4. In each worktree write the worker handoff per repo convention
   (CLAUDE context + plan file): scope, doc references, acceptance gates,
   and the explicit boundary — doc 03 is the contract; any change request
   to it comes back through you (review + schema/CLI semver bump).
5. Constraints to embed in both handoffs:
   - No personal data in this repo. Real maps/paths live in the private
     `music-rules` repo (Forgejo; not created yet) — workers use fixtures
     and `INTAKE_RULES_DIR` indirection only.
   - Resolver development is read-only against a fixture corpus. Never run
     against `/volume1/music` or any live income folder.
   - Bun/TypeScript for the CLI; suite conventions (knowledge_base 01-10)
     for the extension.
6. Stop after commit + worktrees + handoffs. Report: commit hash, worktree
   paths, handoff file locations, and any spec inconsistencies you found.
