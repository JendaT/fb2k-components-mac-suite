# Design: Fetch Missing Album Art

**Created**: 2025-01-03
**Status**: Approved
**Author**: via Claude Code
**Reviewed**: 5 iterations (2025-01-03)

## 1. Overview

### Problem Statement

Users with incomplete album artwork in their music libraries currently have no way to fetch missing images from within the album art component. They must manually search for artwork online, download it, and either save it alongside their files or embed it using external tagging software. This is time-consuming and breaks the listening workflow.

### Goals

- Enable users to search for and fetch missing album artwork directly from the album art component
- Support multiple artwork types: front cover, back cover, disc art, and artist images
- Provide a preview and selection interface before saving
- Allow saving as external files (folder-based) and/or embedding into ID3 tags
- Use reliable, free API sources that don't require complex authentication

### Non-Goals (Out of Scope)

- Batch processing (fetching artwork for entire library at once)
- User artwork upload/contribution to external databases
- Automatic saving without user confirmation
- Integration with sources requiring OAuth (Discogs, Spotify) - deferred to Phase 2

## 2. Background

### Current State

The album art component (`foo_jl_album_art_mac`) displays artwork from:
1. Embedded metadata (ID3 tags, Vorbis comments)
2. External files (folder.jpg, cover.png) based on foobar2000 configuration

When artwork is missing, the component shows a placeholder. Users have no built-in way to fetch missing artwork.

### Prior Art

- **Wil-B/Biography** (Windows Spider Monkey Panel): Multi-source image fetching with caching
- **foo_jl_biography_mac**: Existing research on Last.fm, Fanart.tv, TheAudioDB APIs
- **MusicBrainz Picard**: Cover Art Archive integration for tagging

### Data Source Research

Comprehensive research was conducted on available APIs. See [Appendix A](#appendix-a-api-comparison) for full comparison.

**Selected sources by tier:**

| Tier | Sources | Auth Required | Notes |
|------|---------|---------------|-------|
| 1 (Primary) | Cover Art Archive, iTunes, Deezer | None | No API keys needed |
| 2 (Secondary) | TheAudioDB, Fanart.tv | Free API key | User-provided or bundled |
| 3 (Future) | Discogs | OAuth | Phase 2 implementation |

## 3. Detailed Design

### 3.1 User Experience

#### Entry Point

Right-click context menu on the album art component:

```
Context Menu
├── Artwork Type     >  [Front, Back, Disc, Artist]
├── ─────────────────
├── Fetch Missing...
└── Preferences...
```

#### Fetch Flow

```
┌─────────────────────────────────────────────────────────────┐
│  1. User clicks "Fetch Missing..."                          │
│     ↓                                                       │
│  2. Footer shows progress: "Searching Cover Art Archive..." │
│     ↓                                                       │
│  3. Results appear as thumbnail previews in footer area     │
│     [img1] [img2] [img3]  "3 images found"                  │
│     ↓                                                       │
│  4. User clicks thumbnail → Lightbox opens                  │
│     ┌─────────────────────────────────┐                     │
│     │    ┌─────────────────────┐      │                     │
│     │    │                     │      │                     │
│     │    │   [Large Preview]   │      │                     │
│     │    │                     │      │                     │
│     │    └─────────────────────┘      │                     │
│     │                                 │                     │
│     │  [<]  2 of 5 - Front Cover  [>] │                     │
│     │                                 │                     │
│     │  Source: Cover Art Archive      │                     │
│     │  Resolution: 1200x1200          │                     │
│     │                                 │                     │
│     │        [Use This Image]         │                     │
│     └─────────────────────────────────┘                     │
│     ↓                                                       │
│  5. User clicks "Use This Image" → Confirmation modal       │
│     ┌─────────────────────────────────┐                     │
│     │  Save Artwork                   │                     │
│     │                                 │                     │
│     │  ☑ Save as file in folder       │                     │
│     │    (front.jpg next to files)    │                     │
│     │                                 │                     │
│     │  ☑ Embed in music file(s)       │                     │
│     │    (ID3 tag of focused track)   │                     │
│     │                                 │                     │
│     │  ☐ Remember and don't ask again │                     │
│     │                                 │                     │
│     │     [Cancel]  [Save]            │                     │
│     └─────────────────────────────────┘                     │
└─────────────────────────────────────────────────────────────┘
```

#### Footer Progress States

| State | Display |
|-------|---------|
| Idle | (empty or current artwork info) |
| Searching | Spinner + "Searching [Source Name]..." |
| Found | Thumbnails grouped by type + "N images found" |
| Not Found | "No artwork found" |
| Error | "Search failed: [reason]" |
| Offline | "Offline mode - search unavailable" |

#### Multiple Artwork Types Display

When search returns multiple artwork types (e.g., 5 front, 3 back, 2 disc):

**Footer thumbnails:**
- Show all types with visual grouping (subtle separator between types)
- Order: Front first, then Back, Disc, Artist
- Example: `[F1][F2][F3] | [B1][B2] | [D1]` with `"8 images found (3 types)"`

**Lightbox:**
- Add type filter tabs at top: `[Front (5)] [Back (3)] [Disc (2)]`
- Navigation (`<` `>`) stays within selected type
- Position indicator includes type: "2 of 5 - Front Cover"
- If variants exist: "2 of 5 - Front Cover (Vinyl)"
- Default to Front tab on open

#### Lightbox Features

- Large preview of selected image
- Navigation: `<` Previous / Next `>` buttons
- Current position indicator: "2 of 5"
- Artwork type label (Front Cover, Back Cover, etc.)
- Source attribution
- Resolution display
- "Use This Image" action button
- Close via X button, Escape key, or clicking outside

**Keyboard Navigation:**
| Key | Action |
|-----|--------|
| Left Arrow | Previous image |
| Right Arrow | Next image |
| Enter / Space | Use this image (opens save dialog) |
| Escape | Close lightbox |

#### Save Behavior

**Save to Folder:**
- Saves to the folder containing the **focused track only**
- UI shows destination: "Save to: /path/to/album/"
- If folder is read-only, show error and suggest alternate location

**Embed in Music File:**
- Embeds in the **focused track only** (single file)
- Uses appropriate tag format (ID3v2.4 for MP3, Vorbis for FLAC, etc.)
- If file is read-only, show error dialog
- Future enhancement: "Embed in all album tracks" as separate option

**Confirmation Modal (updated):**
```
┌─────────────────────────────────────┐
│  Save Artwork                       │
│                                     │
│  ☑ Save as file in folder           │
│    → /Music/Artist/Album/front.jpg  │
│                                     │
│  ☑ Embed in current track           │
│    → 01 - Song Title.mp3            │
│                                     │
│  ☐ Remember and don't ask again     │
│                                     │
│     [Cancel]  [Save]                │
└─────────────────────────────────────┘
```

**"Remember choice" behavior:**
- Applies globally to all future saves
- Can be reset in Preferences
- Preferences panel shows current defaults and "Reset to ask again" button

**Atomic Save Strategy:**

When user selects both save options, operations are NOT atomic (no rollback). Instead:

1. **Pre-flight check**: Before starting, verify:
   - Folder is writable (for "Save as file")
   - File is writable (for "Embed in track")
   - If either fails, show error dialog BEFORE attempting any save

2. **Independent execution**: Execute each selected operation independently

3. **Result reporting**: Show result dialog with status for each:
   ```
   ┌─────────────────────────────────────┐
   │  Save Complete                      │
   │                                     │
   │  ✓ Saved to folder: front.jpg      │
   │  ✗ Embed failed: File is read-only │
   │                                     │
   │              [OK]                   │
   └─────────────────────────────────────┘
   ```

4. **Partial success is acceptable**: User sees exactly what happened and can retry the failed operation

### 3.2 Technical Approach

#### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    AlbumArtView (UI)                        │
│  - Context menu                                             │
│  - Footer progress area                                     │
│  - Thumbnail display                                        │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                  ArtworkFetchController                      │
│  - Coordinates search across sources                        │
│  - Manages search state                                     │
│  - Aggregates results                                       │
└─────────────────────────┬───────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         │                │                │
┌────────▼──────┐ ┌───────▼───────┐ ┌──────▼───────┐
│SourceProvider │ │SourceProvider │ │SourceProvider│
│ (CAA)         │ │ (iTunes)      │ │ (Deezer)     │
└───────────────┘ └───────────────┘ └──────────────┘
         │                │                │
         └────────────────┼────────────────┘
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    NetworkManager                            │
│  - HTTP requests via NSURLSession                           │
│  - Respects offline mode                                    │
│  - Rate limiting per source (token bucket)                  │
│  - Per-request timeout: 15 seconds                          │
│  - Aggregate search timeout: 30 seconds                     │
└─────────────────────────────────────────────────────────────┘

**Rate Limiting (per source):**

| Source | Rate Limit | Implementation |
|--------|------------|----------------|
| MusicBrainz | 1 req/sec | Strict queue, mandatory delay |
| Cover Art Archive | None | No limiting needed |
| iTunes | ~20 req/min | Token bucket, 3-second refill |
| Deezer | Per-hour | Track hourly count, backoff on 429 |
| TheAudioDB | 30 req/min | Token bucket, 2-second refill |
| Fanart.tv | None | No limiting needed |

Reuse `RateLimiter` pattern from `shared/` directory (token bucket with configurable rate).

**Timeout Behavior:**
- Per-request timeout: 15 seconds (configurable)
- Aggregate search timeout: 30 seconds
- After aggregate timeout, return whatever results are available
- Sources still in-flight are cancelled

```
                          │
┌─────────────────────────▼───────────────────────────────────┐
│                    ImageCache                                │
│  - In-memory cache for session                              │
│  - Disk cache for thumbnails                                │
│  - Max cache size: 500MB                                    │
└─────────────────────────────────────────────────────────────┘
```

**Cache Management:**
- Maximum disk cache size: 500MB (configurable)
- LRU eviction when limit reached
- Manual clear via Preferences or context menu "Clear artwork cache"
- "Search again" bypasses cache for current album

#### Search Strategy

```
1. Extract metadata from focused track:
   - Artist name
   - Album title
   - MusicBrainz Release ID (if available)
   - MusicBrainz Release Group ID (if available)
   - Discogs Release ID (if available, for Phase 2)

2. Determine search path:
   IF MusicBrainz ID available:
     → Direct CAA lookup (fastest, most accurate)
   ELSE:
     → MusicBrainz search by artist+album → get MBID → CAA lookup
     → Parallel: iTunes search, Deezer search

3. Aggregate results:
   - Deduplicate by image hash
   - Sort by: resolution (desc), source priority
   - Group by artwork type

4. Return combined results to UI
```

#### Source Priority and Fallback

```
┌─────────────────┐
│ Has MBID tag?   │
└────────┬────────┘
         │
    YES  │  NO
    ↓    │  ↓
┌────────▼────────┐  ┌─────────────────────────────┐
│ CAA Direct      │  │ Parallel Search:            │
│ Lookup          │  │ - MusicBrainz → CAA         │
└────────┬────────┘  │ - iTunes                    │
         │           │ - Deezer                    │
    Found│Not Found  │ - TheAudioDB (if key)       │
         │  ↓        │ - Fanart.tv (if key+MBID)   │
         │  ├────────┴─────────────────────────────┘
         │  │
         ▼  ▼
    ┌────────────┐
    │ Aggregate  │
    │ Results    │
    └────────────┘
```

### 3.3 API / Interface

#### TrackMetadata

```objc
@interface TrackMetadata : NSObject

@property (readonly, copy) NSString *artist;
@property (readonly, copy) NSString *albumArtist;      // May differ for compilations
@property (readonly, copy) NSString *album;
@property (readonly, copy, nullable) NSString *musicBrainzReleaseID;
@property (readonly, copy, nullable) NSString *musicBrainzReleaseGroupID;
@property (readonly, copy, nullable) NSString *discogsReleaseID;  // For Phase 2
@property (readonly, strong) NSURL *fileURL;           // For determining save location
@property (readonly, strong) NSURL *folderURL;         // Parent folder of fileURL

+ (instancetype)metadataFromTrack:(metadb_handle_ptr)track;

@end
```

**TrackMetadata Usage Notes:**
- Capture at search start (when user clicks "Fetch Missing...")
- Called on main thread, stores immutable snapshot
- Stale metadata is acceptable for search purposes (album/artist don't change)
- If track changes during search, search is cancelled and new TrackMetadata captured

#### RemoteArtworkSearchController

Named "Remote" to distinguish from existing local `AlbumArtFetcher`. Handles all remote API searches.

```objc
@protocol RemoteArtworkSearchDelegate <NSObject>
- (void)searchDidStart;
- (void)searchDidUpdateProgress:(NSString *)message;
- (void)searchDidFindResults:(NSArray<ArtworkResult *> *)results;
- (void)searchDidFailWithError:(NSError *)error;
- (void)searchDidComplete;
@end

@interface RemoteArtworkSearchController : NSObject

@property (weak) id<RemoteArtworkSearchDelegate> delegate;
@property (readonly, getter=isSearching) BOOL searching;

- (void)searchForArtworkWithMetadata:(TrackMetadata *)metadata;
- (void)cancel;

@end
```

**Cancellation Behavior:**
- `cancel` sets internal `_cancelled` flag
- All in-flight `NSURLSessionTask` objects are cancelled via `[task cancel]`
- Each source provider checks `_cancelled` before processing results
- Delegate receives no further callbacks after `cancel`

**On user-initiated cancel** (Escape key, close button): Discard all results.

**On track change during search**: Cache partial results with `isPartial=YES` flag. If user navigates back to same album, show cached results with "Search may be incomplete - tap to refresh" indicator.

#### ArtworkResult

```objc
@interface ArtworkResult : NSObject

@property (readonly, copy) NSString *sourceIdentifier;  // "caa", "itunes", "deezer"
@property (readonly, copy) NSString *sourceName;        // "Cover Art Archive"
@property (readonly, strong) NSURL *thumbnailURL;       // 250-500px
@property (readonly, strong) NSURL *fullResolutionURL;  // Original/max
@property (readonly) CGSize resolution;                       // From API metadata, or CGSizeZero if unknown
@property (readonly) RemoteArtworkType artworkType;           // Front, Back, Disc, Artist
@property (readonly, copy) NSString *imageHash;               // For deduplication
@property (readonly, copy, nullable) NSArray<NSString *> *variants;  // e.g., @[@"Vinyl", @"Limited Edition"]

@end
```

**Resolution Display:**
- CAA, Fanart.tv, TheAudioDB: Resolution from API metadata
- iTunes: Infer 1200x1200 from URL pattern
- Deezer: Infer 1000x1000 for XL size
- If unknown: Display "Resolution: Available after download"

**Image Hash Algorithm:**

For deduplication across sources, `imageHash` is computed as:
1. Download thumbnail (500px version preferred)
2. Compute SHA-256 hash of raw image data
3. Store as lowercase hex string (64 characters)

```objc
+ (NSString *)hashForImageData:(NSData *)data {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return [hex copy];
}
```

Note: This deduplicates identical images from different sources. It does not detect visually similar images at different resolutions (perceptual hashing could be added later if needed).

#### RemoteArtworkType Enum

Named `RemoteArtworkType` to avoid conflicts with existing `albumart_config::ArtworkType` C++ enum.

```objc
typedef NS_ENUM(NSInteger, RemoteArtworkType) {
    RemoteArtworkTypeFront = 0,
    RemoteArtworkTypeBack,
    RemoteArtworkTypeDisc,
    RemoteArtworkTypeIcon,      // Aligned with existing enum
    RemoteArtworkTypeArtist,
    RemoteArtworkTypeBooklet,   // Extended - not in existing enum
    RemoteArtworkTypeOther
};
```

**Mapping to Existing Enum:**

```objc
// Convert for display/local storage
albumart_config::ArtworkType toLocalType(RemoteArtworkType remote) {
    switch (remote) {
        case RemoteArtworkTypeFront:   return albumart_config::Front;
        case RemoteArtworkTypeBack:    return albumart_config::Back;
        case RemoteArtworkTypeDisc:    return albumart_config::Disc;
        case RemoteArtworkTypeIcon:    return albumart_config::Icon;
        case RemoteArtworkTypeArtist:  return albumart_config::Artist;
        case RemoteArtworkTypeBooklet: return albumart_config::Front; // Fallback
        case RemoteArtworkTypeOther:   return albumart_config::Front; // Fallback
    }
}
```

#### Source Provider Protocol

```objc
@protocol ArtworkSourceProvider <NSObject>

@property (readonly) NSString *identifier;
@property (readonly) NSString *displayName;
@property (readonly) BOOL requiresAPIKey;
@property (readonly) NSTimeInterval rateLimitInterval;

- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(void(^)(NSArray<ArtworkResult *> *, NSError *))completion;
- (void)cancel;

@optional
- (BOOL)canSearchWithMBID;
- (BOOL)isConfigured;  // For sources requiring API keys

@end
```

### 3.4 Data Model

#### Preferences Storage

```objc
// NSUserDefaults keys
static NSString *const kArtworkSaveToFolder = @"artwork.save.toFolder";        // BOOL
static NSString *const kArtworkSaveToFile = @"artwork.save.toFile";            // BOOL
static NSString *const kArtworkRememberChoice = @"artwork.save.rememberChoice"; // BOOL
static NSString *const kTheAudioDBAPIKey = @"artwork.api.theaudiodb";          // NSString
static NSString *const kFanartTVAPIKey = @"artwork.api.fanarttv";              // NSString
```

#### File Naming Convention

| Artwork Type | Filename Pattern |
|--------------|------------------|
| Front | `front.jpg`, `cover.jpg`, `folder.jpg` |
| Back | `back.jpg` |
| Disc | `disc.jpg`, `cd.jpg` |
| Artist | `artist.jpg` |

**Resolution**: Save at original resolution.

**Image Format Handling**:
- Preserve original format when possible (JPEG stays JPEG, PNG stays PNG)
- Convert to JPEG only if:
  - Original is an uncommon format (BMP, TIFF, WebP)
  - User preference is set to "Always save as JPEG"
- PNG is preferred for disc art (may have transparency)
- JPEG quality: 95% when conversion is needed
- Filename extension matches actual format (`.jpg` for JPEG, `.png` for PNG)

#### Cache Structure

```
~/Library/Application Support/foobar2000-v2/artwork_cache/
├── thumbnails/
│   └── {hash}.jpg          # 500px thumbnails
├── pending/
│   └── {hash}.jpg          # Full-res pending save
└── metadata.json           # Cache index with TTL
```

Cache TTL: 7 days for search results, 30 days for thumbnails.

## 4. Implementation

### 4.1 Key Components

| Component | Responsibility | Files |
|-----------|----------------|-------|
| `RemoteArtworkSearchController` | Orchestrates multi-source search | `RemoteArtworkSearchController.h/.m` |
| `CoverArtArchiveProvider` | CAA API integration | `CoverArtArchiveProvider.h/.m` |
| `MusicBrainzProvider` | MB search for MBID lookup | `MusicBrainzProvider.h/.m` |
| `iTunesProvider` | iTunes Search API | `iTunesProvider.h/.m` |
| `DeezerProvider` | Deezer catalog API | `DeezerProvider.h/.m` |
| `TheAudioDBProvider` | TheAudioDB API (optional) | `TheAudioDBProvider.h/.m` |
| `FanartTVProvider` | Fanart.tv API (optional) | `FanartTVProvider.h/.m` |
| `ArtworkLightboxController` | Preview/selection UI | `ArtworkLightboxController.h/.m` |
| `ArtworkSaveController` | File/ID3 saving logic | `ArtworkSaveController.h/.m` |
| `NetworkManager` | HTTP with rate limiting | `NetworkManager.h/.m` (shared) |
| `ImageCache` | Thumbnail/result caching | `ImageCache.h/.m` (shared) |

### 4.2 Dependencies

**Internal:**
- foobar2000 SDK (metadb, playback control, preferences)
- Shared networking code from `foo_jl_scrobble_mac`
- Shared image handling from current album art component

**External:**
- NSURLSession (system)
- Core Graphics / AppKit for image processing
- No third-party libraries required

### 4.3 Implementation Phases

#### Phase 1: Core Functionality (MVP)

1. Cover Art Archive integration (via MusicBrainz lookup)
2. iTunes Search API integration
3. Deezer API integration
4. Basic footer progress display
5. Lightbox preview with navigation
6. Save to folder functionality
7. Preferences for save options

#### Phase 2: Enhanced Sources

1. TheAudioDB integration (user-provided key)
2. Fanart.tv integration (user-provided key)
3. Discogs OAuth integration
4. API key management in preferences

#### Phase 3: Polish

1. ID3 tag embedding
2. Batch selection (save multiple types at once)
3. Improved deduplication
4. Search history/favorites

### 4.4 Tag Embedding Technical Specification (Phase 3)

Tag embedding uses the foobar2000 SDK's `album_art_editor` service to write artwork directly into music files.

#### SDK API

```cpp
// Get the album art editor service
static_api_ptr_t<album_art_editor> editor;

// Open file for editing
album_art_editor_instance_ptr instance;
try {
    instance = editor->open(
        nullptr,                    // parent window (null for background)
        track->get_path(),          // file path
        abort_callback_dummy()      // abort callback
    );
} catch (exception_io& e) {
    // File cannot be opened for editing (read-only, locked, etc.)
    return SaveResultError;
}

// Set the artwork
try {
    album_art_data_ptr art_data = album_art_data_impl::g_create(
        image_data.bytes,           // raw image bytes
        image_data.length           // data length
    );

    instance->set(
        album_art_ids::cover_front, // artwork type (from album_art_ids namespace)
        art_data,                   // the image data
        abort_callback_dummy()
    );

    instance->commit(abort_callback_dummy());
} catch (exception_io& e) {
    // Write failed
    return SaveResultError;
}
```

#### Artwork Type Mapping

| RemoteArtworkType | SDK album_art_ids |
|-------------------|-------------------|
| Front | `album_art_ids::cover_front` |
| Back | `album_art_ids::cover_back` |
| Disc | `album_art_ids::disc` |
| Artist | `album_art_ids::artist` |
| Icon | `album_art_ids::icon` |

#### ArtworkSaveController Interface

```objc
@interface ArtworkSaveController : NSObject

// Save to external file
- (BOOL)saveImage:(NSData *)imageData
           toPath:(NSURL *)folderURL
         withName:(NSString *)filename
            error:(NSError **)error;

// Embed in music file (Phase 3)
- (BOOL)embedImage:(NSData *)imageData
           inTrack:(metadb_handle_ptr)track
              type:(RemoteArtworkType)artworkType
             error:(NSError **)error;

// Pre-flight check
- (BOOL)canSaveToFolder:(NSURL *)folderURL;
- (BOOL)canEmbedInTrack:(metadb_handle_ptr)track;

@end
```

#### Supported File Formats

| Format | Support | Notes |
|--------|---------|-------|
| MP3 | Full | ID3v2.4 APIC frame |
| FLAC | Full | Vorbis comment METADATA_BLOCK_PICTURE |
| M4A/AAC | Full | iTunes-style covr atom |
| OGG | Full | Vorbis comment |
| WMA | Partial | May require Windows Media Format SDK |
| WAV | Limited | ID3v2 chunk (not all players support) |

#### Backup Strategy

foobar2000 handles file modification atomically internally. No additional backup is required. If the write fails mid-operation, the original file remains intact.

#### Limitations

- Only focused track is modified (not all album tracks)
- File must be writable (not on read-only filesystem, not locked by another process)
- Very large images may fail on some formats (FLAC has 16MB limit per picture block)
- Network paths may have permission issues

## 5. Considerations

### 5.1 Edge Cases

| Edge Case | Handling |
|-----------|----------|
| No network / offline mode | Show "Offline mode" message, disable search |
| No metadata on track | Show "Insufficient metadata" message |
| Artist-only (no album) | Search for artist images only |
| Compilation albums | Use album artist if available, fall back to first artist |
| Special characters in names | URL-encode for API calls |
| Very long album names | Truncate for display, use full for search |
| Multiple releases (same album) | Show all results, let user choose |

### 5.2 Error Handling

| Error | Response |
|-------|----------|
| Network timeout | Retry once, then show "Connection timed out" |
| API error (4xx) | Log error, continue to next source |
| API error (5xx) | Retry with backoff, continue to next source |
| Rate limit (429) | Respect Retry-After header, queue request |
| No results from all sources | Show "No artwork found for [Album]" |
| Image download failed | Skip image, log warning |
| File save failed | Show error dialog with reason |

#### Error Domain and Codes

```objc
extern NSString *const ArtworkFetchErrorDomain;

typedef NS_ENUM(NSInteger, ArtworkFetchError) {
    ArtworkFetchErrorNetworkUnavailable = 1001,
    ArtworkFetchErrorTimeout = 1002,
    ArtworkFetchErrorAPIError = 1003,
    ArtworkFetchErrorRateLimited = 1004,
    ArtworkFetchErrorNoResults = 1005,
    ArtworkFetchErrorInvalidMetadata = 1006,
    ArtworkFetchErrorSaveFailed = 2001,
    ArtworkFetchErrorFileReadOnly = 2002,
    ArtworkFetchErrorEmbedFailed = 2003,
    ArtworkFetchErrorImageTooLarge = 2004,
};
```

#### Offline Mode Detection

Use `NWPathMonitor` (Network framework, macOS 10.14+) to monitor network status:

```objc
@interface NetworkReachability : NSObject
@property (readonly, getter=isOnline) BOOL online;
+ (instancetype)sharedInstance;
- (void)startMonitoring;
@end

// Implementation uses NWPathMonitor
// Updates `online` property on path status changes
// Posts NSNotification when status changes
```

When offline:
- "Fetch Missing..." context menu item is disabled (grayed out)
- If search in progress when going offline, cancel with appropriate error
- Resume monitoring on app foreground

### 5.3 Performance

| Concern | Mitigation |
|---------|------------|
| Multiple API calls | Parallel requests where allowed |
| Large images | Download thumbnails first, full-res on demand |
| UI responsiveness | All network on background queue |
| Memory usage | Limit in-memory cache to 50 thumbnails |
| Repeated searches | Cache results for 7 days |

### 5.4 Security

- All API calls over HTTPS
- No credentials stored for Tier 1 sources
- API keys stored in NSUserDefaults (not Keychain - low sensitivity)
- No execution of remote code or scripts

**MusicBrainz User-Agent Requirement:**

MusicBrainz requires a specific User-Agent format. Requests without proper identification are rejected.

```
User-Agent: foo_jl_album_art_mac/1.0.0 ( https://github.com/user/repo )
```

Format: `AppName/Version ( ContactURL-or-Email )`

This header must be set on all requests to:
- `musicbrainz.org`
- `coverartarchive.org`

Implementation:
```objc
NSString *userAgent = [NSString stringWithFormat:@"%@/%@ ( %@ )",
    @"foo_jl_album_art_mac",
    [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
    @"https://github.com/jendalen/foobar2000-mac-components"];
[request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
```

## 6. Alternatives Considered

### Alternative A: Single Source (CAA Only)

- **Pros**: Simpler implementation, no fallback logic, best quality
- **Cons**: Lower coverage for obscure releases, requires MBID
- **Why rejected**: Multi-source approach significantly improves hit rate

### Alternative B: Automatic Fetch on Missing

- **Pros**: Seamless UX, no manual action needed
- **Cons**: Network usage without consent, may fetch wrong artwork
- **Why rejected**: User control is important; can revisit as opt-in preference later

### Alternative C: Embed in All Album Files

- **Pros**: Complete coverage, works everywhere
- **Cons**: Modifies many files, large storage increase, slow
- **Why rejected**: Too invasive; focused-file-only is safer default

### Alternative D: OAuth-First (Discogs/Spotify)

- **Pros**: High quality sources, official APIs
- **Cons**: Complex auth flow, maintenance burden, 2025 Spotify restrictions
- **Why rejected**: Tier 1 sources provide good coverage without auth complexity

## 7. Open Questions

- [x] ~~Should we support fetching artwork for entire album (all tracks) or just focused track?~~
  **Resolved**: Focused track only for Phase 1. "Embed in all album tracks" deferred to Phase 3.
- [x] ~~Should there be a "Search again" button if initial results are unsatisfactory?~~
  **Resolved**: Yes, "Search again" in context menu bypasses cache for current album.
- [x] ~~Should we show artwork resolution in the lightbox before downloading full-res?~~
  **Resolved**: Use API metadata when available; infer from URL patterns for iTunes/Deezer; show "Available after download" if unknown.
- [x] ~~What's the preferred behavior when multiple artwork types are found? Show all or filter by requested type?~~
  **Resolved**: Footer shows all with visual grouping. Lightbox has type filter tabs, navigation within type.
- [x] ~~Should the "Remember choice" preference apply globally or per-component instance?~~
  **Resolved**: Globally, with reset option in Preferences.
- [x] ~~What happens if user changes tracks while search is in progress?~~
  **Resolved**: Cancel current search, cache partial results, start new search for new track.
- [x] ~~How to handle CAA returning multiple front covers for same release (vinyl vs CD)?~~
  **Resolved**: Show all in lightbox. Display variant in position indicator: "2 of 5 - Front Cover (Vinyl)". Added `variants` property to ArtworkResult.

## 8. Future Enhancements

- **Discogs OAuth integration**: High-quality source with good metadata (Phase 2)
- **Batch processing**: Fetch artwork for selected tracks or entire playlist
- **Artwork comparison**: Show existing vs. found artwork side-by-side
- **Quality scoring**: Prefer higher resolution, less compressed images
- **User corrections**: Report incorrect matches to improve future searches
- **Local file search**: Scan folders for existing artwork files before API calls

---

## Appendix A: API Comparison

### Tier 1: No Authentication Required

| API | Rate Limit | Max Resolution | Artwork Types | Coverage |
|-----|------------|----------------|---------------|----------|
| [Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive/API) | None | Original | Front, Back, Disc, Booklet, etc. | Excellent for tagged music |
| [MusicBrainz](https://musicbrainz.org/doc/MusicBrainz_API) | 1/sec | N/A (metadata) | N/A | Required for CAA lookups |
| [iTunes Search](https://performance-partners.apple.com/search-api) | ~20/min | 1200px | Front only | Good mainstream coverage |
| [Deezer](https://developers.deezer.com/api) | Per-hour | 1000px | Front only | Good European coverage |

### Tier 2: Free API Key Required

| API | Rate Limit | Max Resolution | Artwork Types | Key Obtainment |
|-----|------------|----------------|---------------|----------------|
| [TheAudioDB](https://www.theaudiodb.com/free_music_api) | 30/min | 720px | Front, Back, Disc | Public key "123" or register |
| [Fanart.tv](https://fanart.tv/get-an-api-key/) | None (mostly) | 1000px+ | Multiple | Free registration |
| [Last.fm](https://www.last.fm/api) | ~1/sec | 300px | Front only | Free registration (not recommended for art) |

### Tier 3: OAuth Required (Phase 2)

| API | Rate Limit | Max Resolution | Artwork Types | Complexity |
|-----|------------|----------------|---------------|------------|
| [Discogs](https://www.discogs.com/developers) | 60/min | High | Front, Back | OAuth 1.0 |
| Spotify | Low (dev mode) | 640px | Front only | OAuth 2.0 + 2025 restrictions |

### Appendix B: Cover Art Archive Endpoints

```
Base URL: https://coverartarchive.org

GET /release/{mbid}/           → JSON metadata for all artwork
GET /release/{mbid}/front      → Redirect to front cover
GET /release/{mbid}/back       → Redirect to back cover
GET /release/{mbid}/{id}       → Specific image by ID
GET /release/{mbid}/{id}-250   → 250px thumbnail
GET /release/{mbid}/{id}-500   → 500px thumbnail
GET /release/{mbid}/{id}-1200  → 1200px image

GET /release-group/{mbid}/     → Artwork for release group
```

### Appendix C: File Naming Standards

Following common conventions for external artwork files:

| Priority | Front Cover | Back Cover | Disc | Artist |
|----------|-------------|------------|------|--------|
| 1 | `cover.jpg` | `back.jpg` | `disc.jpg` | `artist.jpg` |
| 2 | `front.jpg` | | `cd.jpg` | |
| 3 | `folder.jpg` | | | |
| 4 | `album.jpg` | | | |

---

## Changelog

| Date | Change |
|------|--------|
| 2025-01-03 | Initial draft |
| 2025-01-03 | Review 1: Added TrackMetadata interface, clarified save behavior, added imageHash algorithm, MusicBrainz User-Agent spec, rate limiting details, cache management, keyboard navigation, timeout specs, renamed to RemoteArtworkSearchController |
| 2025-01-03 | Review 2: Renamed ArtworkType to RemoteArtworkType with mapping, added atomic save strategy, added Tag Embedding spec (Section 4.4), added TrackMetadata usage notes, resolved track-change question |
| 2025-01-03 | Review 3: Fixed ArtworkResult to use RemoteArtworkType, added Multiple Artwork Types Display section, added variants property, added resolution display spec, clarified partial results caching behavior |
| 2025-01-03 | Review 4: Added error domain/codes, offline mode detection with NWPathMonitor, image format handling specification |
| 2025-01-03 | Review 5 (Final): Approved for implementation, updated status |
