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
- **Cannot be placed**: A release whose target can never be built (for example graded tier reject) now says "cannot be placed" in its tooltip and group badge; "slot pending" is kept for singles.
- **Group badge**: A group of one proposed or approved release shows the target collection and confidence; amber when it needs review or is below 0.6.
- **Title-formatting fields**: `%intake_status%`, `%intake_target%` and `%intake_collection%` for SimPlaylist columns and group patterns; changed playlist rows refresh at most once per second, only after a field was used.
- **Context actions**: Propose, Assign (to a candidate or any collection), Approve, Reject, Execute placement, Resume placement, Swap to library paths, Delete local copy, Refresh.
- **Assign then propose**: Assigning a resolved release to a collection also proposes it, so it is ready to approve.
- **Assign picker**: "Assign to other collection…" shows the list at once (Suggested, Recent, All collections) and filters it as you type, by any part of the name, ignoring case, accents and brackets.
- **Reject reasons**: The Reject sheet offers preset reasons (Already in library, Lower quality than library copy, Not wanted) or Other… for your own text; it starts on Already in library, then keeps the last choice until quit.
- **Background execute**: Execute and Resume keep running when foobar2000 quits and are picked up at the next start.
- **Execute follow-ups**: The Execute sheet offers to swap playlist rows to the library copies when the placement ends, then delete the local copies; swap is remembered, delete starts unticked each time; the choice also applies after a restart.
- **Quit before follow-ups**: Quitting foobar2000 after a placement ended but before its swap or delete ran logs one console line per run, so they can be done by hand.
- **Status bar**: SimPlaylist shows the running command at the bottom right, with the placement count, and its result for 10 seconds; a click lists running commands and those just ended.
- **Live updates**: Income folders are watched with FSEvents; a sidecar change or a finished command reloads the status.
- **Automatic scan**: New files in an income folder are scanned (`intake scan <income>`) 60 s after they stop arriving, one scan at a time; income folders on this Mac are also scanned once at startup; errors go to the console only.
- **Propose after scan**: Releases an automatic scan writes as resolved are proposed in the same run, followed by one reload.
- **Income folder guard**: A release root that is an income folder itself (loose files at its top level) is ignored, so stray rows under the folder are not tinted or acted on.
- **Network shares**: `mac-volume://` rows match, also when a share is mounted twice; a stalled volume is skipped instead of blocking; rows with decomposed (accented) names away from every release skip Unicode normalisation.
- **Share links**: Rows kept under a local symlink to the music share (`file://<link>/...`, the plorg shadow link) match the share's releases; the link is read without touching the share.
- **Swap with share links**: A playlist that uses a share link gets library rows in the link form; a row whose link does not lead to the library copy is skipped.
- **Delete with share links**: Rows under a link that does not point at the mounted share count as unchecked, so "Swap, then delete" deletes nothing.
- **Preferences**: Tools > Intake sets the CLI, bun, rules folder, watched folders, share links, library mapping, row colours, confirmations, automatic scan and log level, with a status line, Test CLI and Reload now.

### Notes
- **Changes only through the CLI**: Reads sidecars and CLI output; music files and sidecars change only through the intake command-line tool.
- **Requirements**: A SimPlaylist build with the row decorator API, and an intake CLI that reports schema 1.
- **Changes made on the NAS**: Need Refresh; FSEvents sees only changes made through this Mac.
- **Fields outside playlists**: Items in no playlist (library viewers) are not refreshed when a field value changes; `mac-volume://` rows need a volume foobar2000 resolves, and an older volume id gets values once SimPlaylist has shown one of its rows, also before a field was used.
- **Placement count on shares**: Moves only when file events report the sidecar changes; on a share without them (SMB untested) it stays at 0/n until Refresh or the run ends.
- **Automatic scan limits**: Files written into a network income folder by another machine start no scan; the CLI keeps a folder's sidecar once written, so tracks arriving after its scan are not added; a scan stopped at the 15-minute cap is not repeated for that folder until restart.
