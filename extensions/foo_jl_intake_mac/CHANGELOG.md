# Changelog — foo_jl_intake

All notable changes to the Intake component are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **Row tints**: SimPlaylist rows of intake releases get a tint and icon by status: new, resolved, proposed, approved, placing, placed, rejected.
- **Review marker**: Resolved and proposed releases that need review show amber with a "needs review" tooltip (warning icon on resolved); new ones get the tooltip only.
- **Group badge**: A group of one proposed or approved release shows the target collection and confidence; amber when it needs review or is below 0.6.
- **Context actions**: Propose, Assign (to a candidate or any collection), Approve, Reject, Execute placement, Resume placement, Swap to library paths, Delete local copy, Refresh.
- **Background execute**: Execute and Resume keep running when foobar2000 quits and are picked up at the next start.
- **Live updates**: Income folders are watched with FSEvents; a sidecar change or a finished command reloads the status.
- **Network shares**: `mac-volume://` rows match, also when a share is mounted twice; a stalled volume is skipped instead of blocking.
- **Share links**: Rows kept under a local symlink to the music share (`file://<link>/...`, the plorg shadow link) match the share's releases; the link is read without touching the share.
- **Swap with share links**: A playlist that uses a share link gets library rows in the link form; a row whose link does not lead to the library copy is skipped.
- **Delete with share links**: Rows under a link that does not point at the mounted share count as unchecked, so "Swap, then delete" deletes nothing.
- **Preferences**: Tools > Intake sets the CLI, bun, rules folder, watched folders, share links, library mapping, row colours, confirmations and log level, with a status line, Test CLI and Reload now.

### Notes
- **Changes only through the CLI**: Reads sidecars and CLI output; music files and sidecars change only through the intake command-line tool.
- **Requirements**: A SimPlaylist build with the row decorator API, and an intake CLI that reports schema 1.
- **Changes made on the NAS**: Need Refresh; FSEvents sees only changes made through this Mac.
