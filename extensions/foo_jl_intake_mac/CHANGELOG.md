# Changelog — foo_jl_intake

All notable changes to the Intake component are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **Row tints**: SimPlaylist rows of intake releases get a tint and icon by status: new, resolved, proposed, approved, placing, placed, rejected.
- **Review marker**: Resolved and proposed releases that need review show amber with a "needs review" tooltip (warning icon on resolved); new ones get the tooltip only.
- **Row tooltip**: Hovering an intake row shows its status, the target folder from the tier on, who assigned it with the confidence, or what is still missing.
- **Group badge**: A group of one proposed or approved release shows the target collection and confidence; amber when it needs review or is below 0.6.
- **Context actions**: Propose, Assign (to a candidate or any collection), Approve, Reject, Execute placement, Resume placement, Swap to library paths, Delete local copy, Refresh.
- **Assign then propose**: Assigning a resolved release to a collection also proposes it, so it is ready to approve.
- **Background execute**: Execute and Resume keep running when foobar2000 quits and are picked up at the next start.
- **Live updates**: Income folders are watched with FSEvents; a sidecar change or a finished command reloads the status.
- **Income folder guard**: A release root that is an income folder itself (loose files at its top level) is ignored, so stray rows under the folder are not tinted or acted on.
- **Network shares**: `mac-volume://` rows match, also when a share is mounted twice; a stalled volume is skipped instead of blocking.
- **Preferences**: Tools > Intake sets the CLI, bun, rules folder, watched folders, library mapping, row colours, confirmations and log level, with a status line, Test CLI and Reload now.

### Notes
- **Changes only through the CLI**: Reads sidecars and CLI output; music files and sidecars change only through the intake command-line tool.
- **Requirements**: A SimPlaylist build with the row decorator API, and an intake CLI that reports schema 1.
- **Changes made on the NAS**: Need Refresh; FSEvents sees only changes made through this Mac.
