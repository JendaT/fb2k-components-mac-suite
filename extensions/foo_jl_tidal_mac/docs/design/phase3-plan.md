# Tidal Integration: Phase 3+ Plan

**Created**: 2026-02-11
**Updated**: 2026-02-11
**Status**: Phases 3-6 Complete (core features done)
**Depends on**: Phase 1 (MVP) and Phase 2 (Browser) - both complete

## Current State (Phase 1-2)

### Implemented
- OAuth Device Code authentication with Keychain storage
- `tidal://track/{id}` protocol handler (input_decoder)
- Stream URL resolution with quality fallback (DRM cascade)
- Stream URL caching (15-minute TTL)
- Preferences page (quality selection, debug logging)
- Browser panel (search, results table, album art thumbnails)
- Drag-drop from browser to SimPlaylist
- Double-click to play
- Context menu (Play, Add to Playlist, Copy URL)
- Reconnect button for expired tokens

### Current API Methods (TidalAPI.h)
- `requestDeviceCodeWithCompletion:` - OAuth device code
- `pollForTokenWithDeviceCode:completion:` - OAuth token polling
- `refreshTokenWithCompletion:` - Token refresh
- `getPlaybackInfoForTrackID:quality:completion:` - Stream URLs
- `getTrackMetadataForTrackID:completion:` - Track metadata
- `searchTracksWithQuery:limit:offset:completion:` - Track search
- `requestWithURL:method:body:completion:` - Generic authenticated request

### Known Issues (In Progress)
- Album art not displayed for Tidal tracks in playlist (extractor added, needs testing)
- Quality fallback may cascade to LOW unnecessarily (logging added, needs testing)

---

## Phase 3: Extended Search & Album Browsing -- COMPLETE

**Priority**: High
**Complexity**: Medium
**Status**: Implemented 2026-02-11

### 3.1 Album Search

Add album search to the browser panel. Currently only track search is supported.

**API endpoints needed:**
- `GET /v1/search?types=ALBUMS&query={q}` - Search albums
- `GET /v1/albums/{id}` - Album metadata
- `GET /v1/albums/{id}/tracks` - Album track listing

**New API methods:**
```objc
- (void)searchAlbumsWithQuery:(NSString *)query
                        limit:(NSInteger)limit
                       offset:(NSInteger)offset
                   completion:(JLTidalAlbumsCompletion)completion;

- (void)getAlbumTracksForAlbumID:(NSString *)albumID
                      completion:(JLTidalTracksCompletion)completion;
```

**New models:**
```objc
@interface JLTidalAlbum : NSObject
@property (nonatomic, copy, readonly) NSString *albumID;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *artist;
@property (nonatomic, copy, readonly, nullable) NSString *coverID;
@property (nonatomic, readonly) NSInteger numberOfTracks;
@property (nonatomic, readonly) NSInteger duration;
@property (nonatomic, copy, readonly, nullable) NSString *audioQuality;
@property (nonatomic, copy, readonly, nullable) NSDate *releaseDate;
@end
```

**UI changes:**
- Add search type selector (Tracks | Albums | Artists) to browser
- Album results show as expandable rows or separate album detail view
- Click album to show its tracks ordered by track number
- Track number column in results when viewing album tracks

### 3.2 Artist Search

**API endpoints:**
- `GET /v1/search?types=ARTISTS&query={q}` - Search artists
- `GET /v1/artists/{id}/toptracks` - Artist top tracks
- `GET /v1/artists/{id}/albums` - Artist albums

**UI:** Click artist to see top tracks and albums.

### 3.3 Search Improvements
- Pagination (load more on scroll)
- Search history / recent searches
- Combined search (tracks + albums + artists in one view)

---

## Phase 4: User Library & Favorites

**Priority**: High
**Complexity**: Medium

### 4.1 Favorites

**API endpoints:**
- `GET /v1/users/{userId}/favorites/tracks?limit=100&offset=0` - Favorite tracks
- `GET /v1/users/{userId}/favorites/albums` - Favorite albums
- `GET /v1/users/{userId}/favorites/artists` - Favorite artists
- `PUT /v1/users/{userId}/favorites/tracks` - Add to favorites
- `DELETE /v1/users/{userId}/favorites/tracks/{id}` - Remove from favorites

**UI:**
- "My Library" section in browser (Favorites, Playlists, Recent)
- Heart icon in context menu to add/remove favorites
- Favorites sync on login

### 4.2 Recently Played

**API endpoints:**
- `GET /v1/users/{userId}/playbackHistory?limit=50` - Playback history (if available)

Note: This endpoint may not be available in the unofficial API. May need to track locally.

---

## Phase 5: Playlist Synchronization

**Priority**: Medium-High
**Complexity**: High

### 5.1 Fetch Tidal Playlists

**API endpoints:**
- `GET /v1/users/{userId}/playlists` - User's playlists
- `GET /v1/playlists/{uuid}/tracks` - Playlist tracks

**Implementation:**
1. On login, fetch user's Tidal playlist list
2. Show in browser panel under "My Playlists" section
3. Click playlist to view tracks
4. Drag-drop playlist to SimPlaylist creates local playlist with tidal:// URLs

### 5.2 Create Local Playlists from Tidal

When user drags a Tidal playlist to SimPlaylist:
1. Create new fb2k playlist with Tidal playlist name
2. Add all tracks as tidal:// URLs
3. Metadata populated by TidalInfoReader on demand

### 5.3 Background Sync

**Concept:** Periodically check if Tidal playlists have changed and update local copies.

**Implementation:**
- `initquit` handler starts sync timer on component load
- Check playlist ETags or modification dates
- Add/remove tracks in local playlists to match Tidal
- User preference to enable/disable auto-sync
- Manual "Sync Now" button in preferences

### 5.4 Two-Way Sync (Future)

**API endpoints:**
- `POST /v1/playlists` - Create playlist
- `POST /v1/playlists/{uuid}/tracks` - Add tracks to playlist
- `DELETE /v1/playlists/{uuid}/tracks/{index}` - Remove track

This is complex and requires conflict resolution. Defer to Phase 6+.

---

## Phase 6: Quality & Metadata Enhancement

**Priority**: Medium
**Complexity**: Low-Medium

### 6.1 Quality Indicators in Browser
- Show audio quality badge (HiFi, Master, Max) next to tracks
- Quality data comes from track metadata: `audioQuality` field
- Color-coded: green for lossless, gold for hi-res

### 6.2 Enhanced Metadata
- Set more fb2k metadata fields from Tidal API:
  - ALBUM, DATE, TRACKNUMBER, TOTALTRACKS
  - GENRE (from album metadata)
  - ISRC (International Standard Recording Code)
  - Copyright, explicit flag
- Persist metadata in a local cache to avoid repeated API calls

### 6.3 Album Art in Playlist
- `album_art_extractor` service for tidal:// URLs (Phase 3 bug fix)
- Multiple sizes: thumbnail (160x160), standard (320x320), large (640x640)

---

## Implementation Order

| Phase | Feature | Priority | Complexity | Dependencies |
|-------|---------|----------|------------|--------------|
| 3.1 | Album search | High | Medium | None |
| 3.2 | Artist search | High | Medium | None |
| 3.3 | Search improvements | Medium | Low | 3.1, 3.2 |
| 4.1 | Favorites | High | Medium | None |
| 4.2 | Recently played | Low | Low | None |
| 5.1 | Fetch Tidal playlists | High | Medium | None |
| 5.2 | Create local from Tidal | High | Medium | 5.1 |
| 5.3 | Background sync | Medium | High | 5.2 |
| 5.4 | Two-way sync | Low | Very High | 5.3 |
| 6.1 | Quality indicators | Medium | Low | None |
| 6.2 | Enhanced metadata | Medium | Low | None |
| 6.3 | Album art in playlist | High | Medium | Bug fix |

## Tidal API Reference

Base URL: `https://api.tidal.com`

All endpoints require `Authorization: Bearer {token}` header and `countryCode` parameter.

### Search
```
GET /v1/search?query={q}&types={TRACKS,ALBUMS,ARTISTS,PLAYLISTS}&limit=50&offset=0&countryCode={cc}
```

### Albums
```
GET /v1/albums/{id}?countryCode={cc}
GET /v1/albums/{id}/tracks?countryCode={cc}&limit=100
```

### Artists
```
GET /v1/artists/{id}?countryCode={cc}
GET /v1/artists/{id}/toptracks?countryCode={cc}&limit=20
GET /v1/artists/{id}/albums?countryCode={cc}&limit=50
```

### Playlists
```
GET /v1/users/{userId}/playlists?countryCode={cc}
GET /v1/playlists/{uuid}/tracks?countryCode={cc}&limit=100&offset=0
```

### Favorites
```
GET /v1/users/{userId}/favorites/tracks?countryCode={cc}&limit=100&offset=0
PUT /v1/users/{userId}/favorites/tracks (body: trackIds=[id])
DELETE /v1/users/{userId}/favorites/tracks/{trackId}?countryCode={cc}
```
