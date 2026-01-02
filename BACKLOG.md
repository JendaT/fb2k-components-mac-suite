# SimPlaylist Component Backlog

## In Progress
| Task | Priority | Started | Notes |
|------|----------|---------|-------|

## Pending
| Task | Priority | Added | Notes |
|------|----------|-------|-------|

## Completed
| Task | Completed | Notes |
|------|-----------|-------|
| Fix multi-item drag | 2026-01-02 | Defer selection change on mouseDown if item already selected, apply on mouseUp if no drag |
| Cross-playlist drag with cloud files | 2026-01-02 | Pass foobar2000 native paths directly (mac-volume://, mixcloud://, etc.) |
| Cross-playlist drag removes from source | 2026-01-02 | True MOVE operation - delete from source playlist after inserting to destination |
| Cross-playlist drag support | 2026-01-02 | Capture file paths at drag start, insert into new playlist if active changes |
| Fix folder drop file ordering | 2026-01-02 | Sort metadb_handle_list by path before inserting |
| Set focus on dropped items | 2026-01-02 | Set focus to first inserted item after external drop |
| Fix item ordering after drag to padding | 2026-01-02 | Default destPlaylistIndex to end instead of 0 |
| Fix focus ring appearing after drag | 2026-01-02 | Suppress focus ring for 100ms after drag ends |
| Fix drop indicator jumping erratically | 2026-01-02 | Pure distance-based algorithm for all boundary positions |
| Fix focus ring appearing on random items during drag | 2026-01-02 | Check isDragging and dropTargetRow before drawing |
| Fix focus lost after delete | 2026-01-02 | Calculate new focus before deletion, move to next/previous item |
| Reduce UI blink when item deleted | 2026-01-01 | Save/restore scroll position, disable CA animations during rebuild |
| Sort files from folder drops | 2026-01-01 | Sort by filename using localizedStandardCompare |
| Clear selection on drop | 2026-01-01 | Deselect existing, select only dropped items |
| Fix insertion indicator jump | 2026-01-01 | Keep at bottom of album when entering first track after padding |
| Fix media library drop | 2026-01-01 | Media library uses paths without file:// scheme |
| Fix drop indicator on padding rows | 2026-01-01 | Show at bottom of last track when over padding |
| Fix crash when folder dragged from Forklift | 2025-12-31 | Use process_locations_async SDK API instead of manual threading |
| Fix empty playlist not accepting drops | 2025-12-31 | Ensure view frame has minimum height matching scroll view bounds |
| Fix empty playlist inconsistent behavior | 2025-12-31 | Added guard in rowCount, clear all arrays when empty |
| Fix remaining selection after bulk delete | 2025-12-31 | Added setItemCount setter that sanitizes selection indices |
| Fix rogue outline during drag | 2025-12-31 | Fixed rectForRow being called with playlist indices instead of row indices |
| Progressive group calculation from visible area | 2025-12-31 | Sync detect first 200 items, then async for rest |
| Initial worktree setup | 2025-12-31 | CLAUDE.md, BACKLOG.md created |

## Ideas (Unscoped)

