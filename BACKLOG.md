# Tidal Integration Component Backlog

## In Progress
| Task | Priority | Started | Notes |
|------|----------|---------|-------|

## Pending
| Task | Priority | Added | Notes |
|------|----------|-------|-------|
| Phase 5.3: Background sync | Medium | 2026-02-11 | Auto-sync Tidal playlist changes to local copies |
| Verify quality fallback (96kbps issue) | High | 2026-02-11 | Logging added, needs testing after restart |
| Verify album art extractor | High | 2026-02-11 | Service created, needs testing after restart |

## Completed
| Task | Completed | Notes |
|------|-----------|-------|
| Phase 1: MVP (OAuth, playback, preferences) | 2026-02-11 | Full tidal:// protocol handler |
| Phase 2: Browser Panel | 2026-02-11 | Search, drag-drop, double-click, context menu |
| Phase 3: Album/Artist Search | 2026-02-11 | Album/artist models, search type selector, drill-down nav |
| Phase 4: User Library & Favorites | 2026-02-11 | Library mode, favorites CRUD, context menu add/remove |
| Phase 5.1: Playlist browsing | 2026-02-11 | User playlists API, playlist drill-down, playlist columns |
| Phase 5.2: Import playlists/albums | 2026-02-11 | "Import as New Playlist" context menu, creates fb2k playlists |
| Phase 6: Enhanced metadata | 2026-02-11 | ISRC, DATE, TOTALTRACKS, COPYRIGHT in track metadata |
| Search pagination | 2026-02-11 | Infinite scroll for search and library sections |
| Album art extractor service | 2026-02-11 | TidalAlbumArtExtractor for tidal:// URLs (untested) |
| Quality fallback logging | 2026-02-11 | Diagnostic logging for DRM cascade |
| Reconnect button | 2026-02-11 | Preferences shows Reconnect when token expired |
| Shared UIStyles integration | 2026-02-11 | Browser uses fb2k_ui:: styles |
| Drag-drop modern API | 2026-02-11 | pasteboardWriterForRow: replacing deprecated API |
| Initial worktree setup | 2026-01-25 | CLAUDE.md, BACKLOG.md created |

## Ideas (Unscoped)
- Offline mode / download caching
- Lyrics display integration
- Radio / mix support
- Collaborative playlist editing
