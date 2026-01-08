# Design: Tidal Integration for foobar2000 macOS

**Created**: 2026-01-07
**Status**: Draft
**Author**: via Claude Code

## 1. Overview

### Problem Statement

foobar2000 macOS users currently have no way to stream Tidal content within the application. Users who subscribe to Tidal must switch between foobar2000 (for local library) and separate Tidal apps, fragmenting their music listening experience. This integration aims to bring Tidal streaming seamlessly into foobar2000, allowing users to:

- Stream Tidal tracks alongside local library files
- Browse and search Tidal's catalog
- Sync Tidal playlists with foobar2000's playlist system
- Organize Tidal playlists within the Playlist Organizer (plorg)
- Eventually integrate Tidal search with local library faceted browsing

### Goals

**Primary Goals:**
- Authenticate with Tidal using OAuth 2.0 Device Code flow
- Implement `tidal://` protocol for Tidal tracks in playlists
- Stream Tidal audio at user-selected quality (Normal through Max/HiFi)
- Provide a browser panel for searching and browsing Tidal catalog
- Enable drag-and-drop from browser to playlists

**Secondary Goals:**
- Sync Tidal playlists with foobar2000 (two-way or virtual folder)
- Integrate with Playlist Organizer for Tidal playlist organization
- Support mixed playlists (local + Tidal tracks)
- Configurable quality preferences per connection type

**Future Goals (Out of Scope for Initial Design):**
- Facets integration (hybrid local library + Tidal search)
- Auto-search Tidal equivalents for local tracks
- Offline caching of Tidal content
- Scrobbling Tidal plays to Last.fm

### Non-Goals (Out of Scope)

- **Downloading Tidal content** - This would violate Tidal's Terms of Service
- **Bypassing DRM** - We will work within Tidal's playback restrictions
- **Video playback** - Focus on audio streaming only
- **Tidal Connect** - Acting as a Tidal Connect receiver/controller
- **Social features** - Following, sharing, or social playlist features

---

## 2. Background

### Current State

The foobar2000 macOS component ecosystem includes several relevant components:

1. **Cloud Streamer** - Streams Mixcloud/SoundCloud content via yt-dlp
   - Establishes patterns for `input_decoder`, `link_resolver`, caching
   - Uses external tool (yt-dlp) for stream resolution

2. **Playlist Organizer (plorg)** - Hierarchical playlist organization
   - YAML-based tree structure storage
   - Provides folder organization UI
   - Sync with `playlist_manager` via callbacks

3. **Last.fm Scrobbler** - API authentication patterns
   - OAuth flow with browser-based approval
   - Session token storage in Keychain
   - Rate-limited API client

### Prior Art

#### python-tidal (tidalapi)
Unofficial Python library for Tidal API access:
- OAuth 2.0 Device Code authentication
- Full catalog access (search, albums, artists, tracks, playlists)
- Stream URL retrieval via `tracks/{id}/playbackinfopostpaywall`
- Quality tier selection

#### Tidal-Media-Downloader
Reference for API integration patterns:
- Device code authentication flow
- Stream URL formats (Base64 JSON or DASH manifests)
- Quality mapping: Normal (96k) -> High (320k) -> HiFi (16-bit FLAC) -> Master (MQA) -> Max (24-bit)
- Rate limiting: 429 with 20s backoff, random delays for playback endpoints

#### Official Tidal SDK
- Platform SDKs available (iOS, Android, Web)
- Auth module for OAuth flows
- Player module for playback (may have DRM requirements)
- Designed for approved partners

### Key Technical Considerations

1. **Authentication**: Tidal enforces OAuth 2.0 with PKCE. Device Code flow is ideal for desktop apps where browser-based approval is acceptable.

2. **Stream URLs**: Obtained via `playbackinfopostpaywall` endpoint. URLs expire (similar to Cloud Streamer's handling of Mixcloud/SoundCloud).

3. **Audio Formats**:
   - Normal: AAC 96kbps
   - High: AAC 320kbps
   - HiFi: FLAC 16-bit/44.1kHz (may be encrypted)
   - Master: MQA (requires MQA decoder)
   - Max: FLAC 24-bit/192kHz (may be encrypted)

4. **DRM**: HiFi and above tiers may use Widevine or similar DRM. This needs investigation during implementation.

---

## 3. Detailed Design

### 3.1 Component Architecture

Single component: `foo_jl_tidal_mac`

```
foo_jl_tidal_mac/
├── src/
│   ├── Core/
│   │   ├── TidalConfig.h/mm          # Configuration (fb2k::configStore)
│   │   ├── TidalSession.h/mm         # OAuth session management
│   │   ├── TidalAPI.h/mm             # API client
│   │   ├── TidalModels.h             # Data models (Track, Album, Artist, Playlist)
│   │   ├── StreamCache.h/mm          # Thread-safe stream URL cache
│   │   ├── MetadataCache.h/mm        # Persistent track metadata cache
│   │   └── URLUtils.h/mm             # tidal:// URL handling
│   ├── Services/
│   │   ├── TidalAuthService.h/mm     # OAuth Device Code flow
│   │   ├── TidalStreamResolver.h/mm  # Stream URL resolution
│   │   └── TidalPlaylistSync.h/mm    # Playlist synchronization
│   ├── Integration/
│   │   ├── Main.mm                   # Component entry, service registration
│   │   ├── TidalInputDecoder.h/mm    # input_decoder for tidal:// URLs
│   │   ├── TidalLinkResolver.h/mm    # link_resolver for tidal:// URLs
│   │   ├── TidalAlbumArt.h/mm        # album_art_extractor
│   │   └── TidalPlayCallback.h/mm    # Track playback events
│   └── UI/
│       ├── TidalBrowserView.h/mm     # Browser panel UI
│       ├── TidalBrowserController.h/mm
│       ├── TidalSearchView.h/mm      # Search interface
│       ├── TidalResultsView.h/mm     # Results table/grid
│       ├── TidalPreferences.h/mm     # Preferences page
│       └── TidalAuthView.h/mm        # Auth status/login UI
├── Resources/
│   ├── Info.plist
│   └── Assets.xcassets               # Icons, placeholder art
└── Scripts/
    ├── generate_xcode_project.rb
    ├── build.sh
    └── install.sh
```

### 3.2 Authentication Flow

Using OAuth 2.0 Device Authorization Grant (RFC 8628):

```
┌─────────────┐                              ┌──────────────┐
│   foobar    │                              │    Tidal     │
│   Component │                              │    API       │
└──────┬──────┘                              └──────┬───────┘
       │                                            │
       │ 1. POST /oauth2/device_authorization       │
       │    client_id, scope                        │
       │ ─────────────────────────────────────────> │
       │                                            │
       │ 2. device_code, user_code, verification_uri│
       │ <───────────────────────────────────────── │
       │                                            │
       │ 3. Display to user:                        │
       │    "Visit tidal.com/link                   │
       │     Enter code: ABCD-1234"                 │
       │                                            │
       │ 4. Poll: POST /oauth2/token                │
       │    device_code, grant_type=device_code     │
       │ ─────────────────────────────────────────> │
       │                                            │
       │ 5a. { "error": "authorization_pending" }   │
       │ <───────────────────────────────────────── │
       │                                            │
       │    (user approves in browser)              │
       │                                            │
       │ 5b. { access_token, refresh_token, ... }   │
       │ <───────────────────────────────────────── │
       │                                            │
       │ 6. Store tokens securely (Keychain)        │
       │                                            │
```

**Token Storage:**

Keychain schema (matches standard macOS Keychain conventions):
- Service: `"com.foobar2000.tidal"`
- Account for access token: `"access_token"`
- Account for refresh token: `"refresh_token"`

Non-sensitive data in fb2k::configStore:
- `tidal.auth.expiry` - Token expiry timestamp
- `tidal.auth.tokentype` - Token type (typically "Bearer")

**Token Refresh:**
- Check expiry before API calls
- Proactively refresh when <5 minutes remaining
- On 401 response, attempt refresh and retry once

**Authentication Cancellation:**

The auth flow must be cancellable at any point. Following LastFmAuth patterns:

```objc
typedef NS_ENUM(NSInteger, JLTidalAuthState) {
    JLTidalAuthStateIdle,
    JLTidalAuthStateRequestingDeviceCode,
    JLTidalAuthStateWaitingForApproval,   // Polling
    JLTidalAuthStateExchangingToken,
    JLTidalAuthStateAuthenticated,
    JLTidalAuthStateCancelled,
    JLTidalAuthStateError,
};

@interface JLTidalAuthService : NSObject
- (void)startAuthentication;
- (void)cancelAuthentication;           // Stops polling, clears state
- (JLTidalAuthState)currentState;
@property (nonatomic, copy) void (^stateChangeHandler)(JLTidalAuthState);
@end
```

**Polling Loop with Cancellation and Safety Timeout:**
```objc
// 10 minutes safety valve. RFC 8628 expires_in is typically 5-10 minutes,
// so this backstop handles malformed server responses.
static const NSTimeInterval kMaxPollingDuration = 600.0;

- (void)pollForApproval {
    if (self.state == JLTidalAuthStateCancelled) return;

    // Check device_code expiry (from RFC 8628 expires_in)
    if ([[NSDate date] timeIntervalSinceDate:self.deviceCodeExpiry] > 0) {
        [self transitionToState:JLTidalAuthStateError
                      withError:@"Device code expired"];
        return;
    }

    // Safety valve: max polling duration independent of server expiry
    NSTimeInterval elapsedTime = -[self.authStartTime timeIntervalSinceNow];
    if (elapsedTime > kMaxPollingDuration) {
        [self transitionToState:JLTidalAuthStateError
                      withError:@"Authentication timeout (10 minutes)"];
        return;
    }

    [self.api exchangeDeviceCode:self.deviceCode completion:^(NSDictionary *response, NSError *error) {
        if (self.state == JLTidalAuthStateCancelled) return;

        if (error && [error.userInfo[@"error"] isEqualToString:@"authorization_pending"]) {
            // Continue polling after interval (RFC 8628 specifies ~5 seconds)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                          dispatch_get_main_queue(), ^{ [self pollForApproval]; });
        } else if (response[@"access_token"]) {
            [self handleSuccessfulAuth:response];
        } else {
            [self transitionToState:JLTidalAuthStateError withError:error.localizedDescription];
        }
    }];
}
```

**UI Behavior on Cancel:**
- If user closes preferences during auth: `cancelAuthentication` called
- Pending network requests cancelled via NSURLSession invalidation
- State reset to Idle, no partial credentials stored

### 3.3 URL Scheme

Internal URL format for Tidal tracks:

```
tidal://track/{track_id}
tidal://album/{album_id}
tidal://artist/{artist_id}
tidal://playlist/{playlist_uuid}
```

Examples:
```
tidal://track/12345678
tidal://album/87654321
tidal://playlist/abc123-def456-789
```

**URL Detection:**
```objc
typedef NS_ENUM(NSInteger, JLTidalURLType) {
    JLTidalURLTypeUnknown,
    JLTidalURLTypeTrack,
    JLTidalURLTypeAlbum,
    JLTidalURLTypeArtist,
    JLTidalURLTypePlaylist,
};

BOOL JLIsTidalURL(NSString *url);
JLTidalURLType JLParseTidalURLType(NSString *url);  // Function name avoids collision with enum
NSString *JLTidalExtractID(NSString *url);
```

**Web URL Conversion:**
```
https://tidal.com/browse/track/12345678  →  tidal://track/12345678
https://listen.tidal.com/track/12345678  →  tidal://track/12345678
```

**URL Expansion:**
Album and playlist URLs (`tidal://album/{id}`, `tidal://playlist/{uuid}`) are expanded by the `link_resolver` to individual `tidal://track/{id}` URLs. The `input_decoder` only handles single tracks (always returns `get_subsong_count() = 1`).

### 3.4 Stream Resolution

**API Endpoint:** `GET /tracks/{id}/playbackinfopostpaywall`

**Request Parameters:**
- `audioquality`: LOW, HIGH, LOSSLESS, HI_RES, HI_RES_LOSSLESS
- `playbackmode`: STREAM
- `assetpresentation`: FULL

**Response Handling:**
1. Parse manifest format (`vnd.tidal.bt` = Base64 JSON, `dash+xml` = MPEG-DASH)
2. Extract stream URLs from manifest
3. Handle encrypted content (if DRM present, may need fallback)

**Quality Mapping:**
| User Setting | API Parameter | Typical Format |
|--------------|---------------|----------------|
| Normal | LOW | AAC 96kbps |
| High | HIGH | AAC 320kbps |
| HiFi | LOSSLESS | FLAC 16-bit |
| Master | HI_RES | MQA |
| Max | HI_RES_LOSSLESS | FLAC 24-bit |

**Stream URL Caching:**
- Cache stream URLs with TTL
- On 403/401 during playback: invalidate cache, re-resolve, seek to position
- Thread-safe cache using dispatch_queue isolation (pattern from Cloud Streamer)

**TTL Strategy:**

Phase 1 uses a simple fixed TTL matching the existing Cloud Streamer pattern:

```objc
// Fixed TTL - conservative to avoid expired URL errors
static const NSTimeInterval kTidalStreamTTL = 15 * 60;  // 15 minutes

@interface JLStreamCache : NSObject
- (void)cacheStreamURL:(NSString *)streamURL
                forKey:(NSString *)tidalURL
                   TTL:(NSTimeInterval)ttl;
@end

// Usage
[[JLStreamCache shared] cacheStreamURL:resolvedURL
                                forKey:tidalURL
                                   TTL:kTidalStreamTTL];
```

**Phase 2+ Enhancement: Adaptive TTL**

After observing real-world expiration patterns, implement adaptive TTL:
- Track early 403 occurrences relative to cache age
- Reduce TTL if seeing premature expirations
- Increase TTL if URLs consistently valid longer than expected
- Metrics exposed via `tidal.metrics` console command

### 3.5 Input Decoder Implementation

```cpp
class tidal_input_decoder : public input_decoder {
private:
    service_ptr_t<input_decoder> m_decoder;  // Wrapped HTTP/HLS decoder
    pfc::string8 m_tidal_url;                // tidal://track/12345
    pfc::string8 m_stream_url;               // Resolved HTTPS stream
    t_uint32 m_subsong{0};                   // Stored from initialize()
    unsigned m_flags{0};                     // Stored from initialize()
    bool m_403Retry{false};                  // Retry guard
    double m_lastPosition{0};

public:
    void open(service_ptr_t<file> filehint, const char* path,
              input_open_reason reason, abort_callback& abort) override;

    // Required: called between open() and run()
    void initialize(t_uint32 p_subsong, unsigned p_flags, abort_callback& abort) override {
        m_subsong = p_subsong;
        m_flags = p_flags;
        if (m_decoder.is_valid()) {
            m_decoder->initialize(p_subsong, p_flags, abort);
        }
    }

    bool run(audio_chunk& chunk, abort_callback& abort) override;
    void seek(double seconds, abort_callback& abort) override;
    bool can_seek() override { return true; }

    t_uint32 get_subsong_count() override { return 1; }
    void get_info(t_uint32 subsong, file_info& info, abort_callback& abort) override;

private:
    bool tryResolveAndReopen(abort_callback& abort);
};
```

**Open Flow:**
1. Check StreamCache for cached stream URL
2. If miss: call TidalStreamResolver (respects abort_callback)
3. Open underlying HTTP decoder with stream URL
4. On failure: clear cache, throw appropriate exception

**Run Flow (stream expiration handling):**

Following CloudInputDecoder's proven pattern, detect 403 via string matching (not exception type):

```cpp
bool run(audio_chunk& chunk, abort_callback& abort) override {
    try {
        bool result = m_decoder->run(chunk, abort);
        if (result) {
            m_lastPosition = m_decoder->get_position();
        }
        return result;
    } catch (const exception_io& e) {
        // CloudInputDecoder pattern: check error message for 403/Forbidden
        const char* msg = e.what();
        if (msg && (strstr(msg, "403") || strstr(msg, "Forbidden"))) {
            // Stream URL expired - attempt re-resolution
            if (tryResolveAndReopen(abort)) {
                return m_decoder->run(chunk, abort);
            }
        }
        throw;  // Re-throw if not 403 or retry failed
    }
}

bool tryResolveAndReopen(abort_callback& abort) {
    @autoreleasepool {
        // Store position before closing decoder
        double savedPosition = 0;
        try {
            savedPosition = m_decoder->get_position();
        } catch (...) {
            savedPosition = m_lastKnownPosition;  // Fallback to tracked position
        }

        // Invalidate cache and get fresh stream URL
        [[JLStreamCache shared] invalidateKey:@(m_tidal_url.c_str())];

        std::atomic<bool> localAbort{false};
        NSError *error = nil;
        NSString *freshUrl = [[JLTidalStreamResolver shared]
            resolveURL:@(m_tidal_url.c_str())
             abortFlag:&localAbort
                 error:&error];

        if (abort.is_aborting()) {
            throw exception_aborted();
        }

        if (!freshUrl) {
            console::warning("Tidal: Failed to refresh stream URL");
            return false;
        }

        // Reopen decoder with new URL
        m_stream_url = freshUrl.UTF8String;
        try {
            input_open_file_helper(m_decoder, m_stream_url.c_str(), abort, m_reason);
            if (savedPosition > 0 && m_decoder->can_seek()) {
                m_decoder->seek(savedPosition, abort);
            }
            return true;
        } catch (const std::exception& e) {
            console::warning("Tidal: Failed to reopen stream: %s", e.what());
            return false;
        }
    }
}
```

**Position Tracking (thread-safe):**
```cpp
// Track position periodically during playback for recovery
std::atomic<double> m_lastKnownPosition{0};

bool run(audio_chunk& chunk, abort_callback& abort) override {
    bool result = /* ... stream handling ... */;
    if (result) {
        m_lastKnownPosition.store(m_decoder->get_position());
    }
    return result;
}
```

**Prefetch Integration:**
```cpp
// In playback callback, prefetch next track (with race condition guard)
std::atomic<bool> m_prefetchTriggered{false};

void on_playback_new_track(metadb_handle_ptr track) override {
    m_prefetchTriggered.store(false);  // Reset on new track
    // ... existing track setup
}

void on_playback_time(double time) override {
    // Percentage-based fallback for short tracks: max(5s, 10% of duration)
    double prefetchThreshold = std::max(5.0, m_currentTrackDuration * 0.1);
    double triggerTime = m_currentTrackDuration - prefetchThreshold;

    if (time > triggerTime && !m_prefetchTriggered.exchange(true)) {
        prefetchNextTrack();
    }
}

// Prefetch must dispatch to background queue to avoid blocking UI/playback thread
void prefetchNextTrack() {
    NSString* nextTrackURL = [self getNextTidalTrackURL];
    if (!nextTrackURL) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[JLTidalStreamResolver shared] prefetchURL:nextTrackURL];
    });
}
```

**Input Entry and Service Registration:**

Following the `CloudInputEntry` pattern, we need both a full decoder and lightweight info reader:

```cpp
// TidalInputEntry - registers the tidal:// protocol handler
class tidal_input_entry : public input_entry_v2 {
public:
    bool is_our_path(const char* p_full_path, const char* p_extension) override {
        return strncmp(p_full_path, "tidal://", 8) == 0;
    }

    void open_for_decoding(service_ptr_t<input_decoder>& out,
                           service_ptr_t<file> filehint,
                           const char* path,
                           abort_callback& abort) override {
        auto decoder = fb2k::service_new<tidal_input_decoder>();
        decoder->open(filehint, path, input_open_decode, abort);
        out = decoder;
    }

    void open_for_info_read(service_ptr_t<input_info_reader>& out,
                            service_ptr_t<file> filehint,
                            const char* path,
                            abort_callback& abort) override {
        // Lightweight reader - no stream resolution needed
        out = fb2k::service_new<tidal_info_reader>(path);
    }

    void open_for_info_write(service_ptr_t<input_info_writer>& out,
                             service_ptr_t<file> filehint,
                             const char* path,
                             abort_callback& abort) override {
        // Tidal streams are read-only
        pfc::throw_exception_with_message<exception_io_unsupported_format>(
            "Tidal streams are read-only");
    }

    void get_extended_data(service_ptr_t<file> p_filehint,
                           const playable_location& p_location,
                           const GUID& p_guid, mem_block_container& p_out,
                           abort_callback& p_abort) override {
        // No extended data supported
    }

    static GUID g_get_guid() {
        // {UNIQUE-GUID-FOR-TIDAL}
        return { 0x12345678, 0xABCD, 0xEF01, {0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01} };
    }
};

// Use service_factory_single_t to match CloudInputEntry pattern
static service_factory_single_t<tidal_input_entry> g_tidalInputFactory;
```

**TidalInfoReader - Lightweight Metadata:**

Essential for playlist display performance - reads from MetadataCache without stream resolution:

```cpp
class tidal_info_reader : public input_info_reader {
    pfc::string8 m_path;
    std::optional<TidalTrackInfo> m_cachedInfo;

public:
    tidal_info_reader(const char* path) : m_path(path) {
        // Try to load from MetadataCache immediately
        m_cachedInfo = [[JLMetadataCache shared] trackInfoForURL:@(path)];
    }

    void get_info(t_uint32 subsong, file_info& info, abort_callback& abort) override {
        if (m_cachedInfo) {
            // Fast path: cached metadata
            info.set_length(m_cachedInfo->duration);
            info.meta_set("TITLE", m_cachedInfo->title.c_str());
            info.meta_set("ARTIST", m_cachedInfo->artist.c_str());
            info.meta_set("ALBUM", m_cachedInfo->album.c_str());
            info.meta_set("TIDAL_ID", m_cachedInfo->trackId.c_str());
        } else {
            // Fallback: parse what we can from URL
            // tidal://track/12345678 -> ID only
            NSString *trackId = JLTidalExtractID(@(m_path.c_str()));
            info.meta_set("TIDAL_ID", trackId.UTF8String);
        }
    }

    t_filestats get_file_stats(abort_callback& abort) override {
        return filestats_invalid;  // No file stats for streaming
    }
};
```

**Decoder Simplicity (Aligned with CloudInputDecoder):**

Following the proven CloudInputDecoder pattern for simplicity:

```cpp
class tidal_input_decoder : public input_decoder {
private:
    service_ptr_t<input_decoder> m_decoder;
    pfc::string8 m_path;
    pfc::string8 m_streamUrl;
    bool m_403Retry = false;  // Simple retry guard, not atomic

public:
    // ... open/run/seek methods as shown above ...

    // Simplified tryReopen - matches CloudInputDecoder pattern
    bool tryReopen(abort_callback& abort) {
        if (m_403Retry) return false;  // Already tried once
        m_403Retry = true;

        @autoreleasepool {
            [[JLStreamCache shared] invalidateKey:@(m_path.c_str())];

            NSError *error = nil;
            NSString *freshUrl = [[JLTidalStreamResolver shared]
                resolveURL:@(m_path.c_str()) error:&error];

            if (!freshUrl) return false;

            m_streamUrl = freshUrl.UTF8String;
            try {
                input_open_file_helper(m_decoder, m_streamUrl.c_str(), abort, input_open_decode);
                // Note: Position recovery is a Phase 2 enhancement
                // For now, restart from beginning like CloudInputDecoder
                return true;
            } catch (...) {
                return false;
            }
        }
    }
};
```

**Position Recovery (Phase 2 Enhancement):**

Position recovery on stream expiration is desirable for long tracks but adds complexity. Deferred to Phase 2 with explicit tracking:
- Phase 1: Restart playback from beginning on stream expiration (matches CloudInputDecoder)
- Phase 2: Track position, seek after re-resolution (requires testing with Tidal's seek support)

### 3.6 Tidal Browser UI

**Panel Structure:**
```
+------------------------------------------------------------+
| [Search...                                 ] [Gear] [User] |
+------------------------------------------------------------+
| [Albums] [Tracks] [Artists] [Playlists] [My Library]       |
+------------------------------------------------------------+
| +--------------------------------------------------------+ |
| | [note] Track Name                      Artist    3:45  | |
| | [note] Another Track                   Artist    4:12  | |
| | [disc] Album Title                     Artist    2024  | |
| | ...                                                    | |
| +--------------------------------------------------------+ |
+------------------------------------------------------------+
| [lock] Logged in as: username | HiFi subscription          |
+------------------------------------------------------------+
```

**Note:** UI mockup uses text placeholders. Actual implementation uses SF Symbols (requires macOS 11+):
- `note.text` for tracks
- `opticaldisc` for albums
- `person` for artists
- `music.note.list` for playlists
- `gearshape` for settings
- `person.circle` for user account

**Minimum macOS Version:** macOS 11 (Big Sur) for SF Symbols 2.0 support. This aligns with foobar2000 macOS system requirements.

**Features:**
- Search with type filtering (albums, tracks, artists, playlists)
- Browse categories: New releases, Top charts, Genres
- User library: Favorites, My playlists
- Album/Artist detail views (drill-down)
- Drag tracks/albums to foobar playlists
- Double-click to play immediately
- Right-click context menu (add to playlist, add to queue, etc.)

**Implementation:**
- `NSOutlineView` or `NSTableView` for results
- Async loading with pagination
- Album art thumbnails (async, cached via ThumbnailCache)
- Keyboard navigation (arrows, Enter to play, Cmd+C to copy URL)

### 3.7 Playlist Synchronization

**Sync Modes (configurable):**

1. **Virtual Folder Mode** (recommended for MVP):
   - Tidal playlists appear as read-only folder in plorg tree
   - Always fetched live from API (with caching)
   - Changes in Tidal app reflect immediately
   - foobar changes not synced back

2. **Two-Way Sync Mode** (Phase 2+):
   - Tidal playlists imported as local playlists
   - Background sync job compares local vs Tidal
   - Local additions/removals synced to Tidal
   - Conflict resolution: last-write-wins or user prompt

**Mixed Playlists:**
- Local playlists can contain tidal:// URLs
- When syncing to Tidal: only tidal:// tracks synced
- Local file tracks stored as playlist metadata (not synced)

**plorg Integration:**

The existing plorg TreeNode model needs extension to support Tidal sync sources.

**Note:** plorg uses Objective-C++. The following shows the actual implementation changes:

```objc
// TreeNode.h - Add sync source support
typedef NS_ENUM(NSInteger, JLTreeNodeSyncSource) {
    JLTreeNodeSyncSourceLocal = 0,
    JLTreeNodeSyncSourceTidal = 1,
};

@interface JLTreeNode : NSObject
// ... existing properties ...
@property (nonatomic, assign) JLTreeNodeSyncSource syncSource;
@property (nonatomic, copy, nullable) NSString *syncId;  // Tidal playlist UUID
@end

// Implementation: defaults to local if not specified (backward compatible)
- (instancetype)init {
    if (self = [super init]) {
        _syncSource = JLTreeNodeSyncSourceLocal;
        _syncId = nil;
    }
    return self;
}
```

**YAML Format Extension:**
```yaml
tree:
  - folder: Local Music
    items:
      - playlist: Rock Favorites
  - folder: Tidal                    # Virtual or synced
    syncSource: tidal                # New field: indicates Tidal source
    items:
      - playlist: My Mix             # uuid: abc-123
        syncId: "abc-123-def-456"    # Tidal playlist UUID
      - playlist: Discover Weekly
        syncId: "def-456-ghi-789"
```

**Inter-Component Communication:**

Option A: NotificationCenter (recommended for MVP)
```objc
// Tidal component posts when playlists change
[[NSNotificationCenter defaultCenter]
    postNotificationName:@"TidalPlaylistsDidChange"
                  object:nil
                userInfo:@{@"playlists": updatedPlaylists}];

// plorg observes and updates tree
[[NSNotificationCenter defaultCenter]
    addObserver:self
       selector:@selector(handleTidalPlaylistsChange:)
           name:@"TidalPlaylistsDidChange"
         object:nil];
```

Option B: fb2k service pattern (Phase 3+)
```cpp
// Define abstract service interface
class tidal_playlist_provider : public service_base {
    virtual size_t get_playlist_count() = 0;
    virtual void get_playlist_name(size_t idx, pfc::string_base& out) = 0;
    virtual void get_playlist_uuid(size_t idx, pfc::string_base& out) = 0;
    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(tidal_playlist_provider);
};
```

**plorg Migration:**
- Existing YAML configs without `syncSource` field default to `local`
- Migration is backwards-compatible (no version bump required)
- New fields ignored by older plorg versions

### 3.8 Metadata Handling

**Track Metadata Mapping:**

| Tidal Field | foobar2000 Field | Notes |
|-------------|------------------|-------|
| title | %title% | Track name |
| artist.name | %artist% | Primary artist |
| album.title | %album% | Album name |
| album.releaseDate | %date% | Release year |
| duration | %length% | Seconds |
| trackNumber | %tracknumber% | Position in album |
| isrc | %isrc% | International Standard Recording Code |
| audioQuality | %tidal_quality% | Custom field |
| codec | %codec% | AAC, FLAC, MQA for quality transparency |
| id | %tidal_id% | Custom field for re-resolution |

**Album Art:**
- Cover URL from `album.cover` (multiple sizes available)
- Async download and cache (pattern from Cloud Streamer)
- Cache invalidation: album art rarely changes, long TTL

### 3.9 Error Handling

**Error Types:**
```objc
// Error code ranges are intentionally spaced for future expansion:
// 0-9: General errors
// 10-19: Authentication errors
// 20-29: Network errors
// 30-39: Content/subscription errors
// 40-49: Stream errors
typedef NS_ENUM(NSInteger, JLTidalError) {
    JLTidalErrorNone = 0,
    JLTidalErrorCancelled = 1,
    JLTidalErrorTimeout = 2,
    JLTidalErrorNotAuthenticated = 10,
    JLTidalErrorAuthExpired = 11,
    JLTidalErrorAuthFailed = 12,
    JLTidalErrorNetworkError = 20,
    JLTidalErrorRateLimited = 21,
    JLTidalErrorTrackUnavailable = 30,
    JLTidalErrorRegionRestricted = 31,
    JLTidalErrorSubscriptionRequired = 32,
    JLTidalErrorDRMRequired = 33,
    JLTidalErrorStreamExpired = 40,
};
```

**Error-to-Exception Mapping:**

Tidal errors must be translated to foobar2000 SDK exceptions for proper playback handling:

| JLTidalError | SDK Exception | Triggers Retry |
|--------------|---------------|----------------|
| JLTidalErrorNotAuthenticated | exception_io_denied | No (auth UI) |
| JLTidalErrorAuthExpired | exception_io_denied | Yes (refresh) |
| JLTidalErrorNetworkError | exception_io_network | Yes |
| JLTidalErrorRateLimited | exception_io (retry hint) | Yes (backoff) |
| JLTidalErrorTrackUnavailable | exception_io_not_found | No |
| JLTidalErrorRegionRestricted | exception_io_denied | No |
| JLTidalErrorSubscriptionRequired | exception_io_denied | No |
| JLTidalErrorDRMRequired | exception_io_denied | No |
| JLTidalErrorStreamExpired | exception_io_denied | Yes (re-resolve) |

```cpp
// Exception translation in TidalInputDecoder
pfc::exception translateError(JLTidalError error, NSString *message) {
    switch (error) {
        case JLTidalErrorNotAuthenticated:
        case JLTidalErrorAuthExpired:
        case JLTidalErrorRegionRestricted:
        case JLTidalErrorSubscriptionRequired:
        case JLTidalErrorDRMRequired:
        case JLTidalErrorStreamExpired:
            throw exception_io_denied(message.UTF8String);
        case JLTidalErrorNetworkError:
            throw exception_io_network(message.UTF8String);
        case JLTidalErrorTrackUnavailable:
            throw exception_io_not_found(message.UTF8String);
        case JLTidalErrorRateLimited:
            throw exception_io(message.UTF8String);  // run() checks message for backoff
        default:
            throw exception_io(message.UTF8String);
    }
}
```

### 3.10 Threading Model

**Thread Context by Operation:**

| Component | Thread | Synchronization |
|-----------|--------|-----------------|
| input_decoder::open/run/seek | SDK playback thread | Internal to decoder |
| TidalAPI requests | NSURLSession delegate queue | Dispatch to completion queue |
| TidalSession (token access) | Any thread | dispatch_queue isolation |
| StreamCache | Any thread | dispatch_queue isolation |
| MetadataCache | Any thread | dispatch_queue isolation |
| UI updates | Main thread required | GCD dispatch_async |
| Keychain access | Background queue | Cached in memory after first load |

**Shared State Protection:**

```objc
// All caches use serial dispatch queue for isolation
@interface JLTidalCache : NSObject
@property (nonatomic, strong) dispatch_queue_t isolationQueue;

- (instancetype)init {
    if (self = [super init]) {
        _isolationQueue = dispatch_queue_create("com.foobar2000.tidal.cache", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// All reads/writes go through isolation queue
- (id)objectForKey:(NSString *)key {
    __block id result = nil;
    dispatch_sync(_isolationQueue, ^{
        result = _storage[key];
    });
    return result;
}
@end
```

**Session Token Management:**
```objc
@interface JLTidalSession : NSObject
@property (nonatomic, strong) dispatch_queue_t tokenQueue;
@property (nonatomic, copy) NSString *cachedAccessToken;  // Memory cache

- (NSString *)accessToken {
    __block NSString *token = nil;
    dispatch_sync(_tokenQueue, ^{
        if (_cachedAccessToken) {
            token = _cachedAccessToken;
        } else {
            // Load from Keychain (off main thread)
            token = [self loadTokenFromKeychain];
            _cachedAccessToken = token;
        }
    });
    return token;
}
@end
```

**Callback Dispatch Guarantees:**
- All public API completion handlers dispatched to main queue unless specified
- Internal callbacks stay on originating queue
- UI components can safely update from completion handlers

**Main Thread Requirements:**
```objc
// Helper for SDK callbacks
void dispatchToMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}
```

**Rate Limiting:**
- Detect 429 responses
- Implement exponential backoff (20s base, up to 5 minutes)
- Add random jitter to playback info requests (0.5-5s)
- Queue requests to avoid burst patterns

```objc
@interface JLTidalRateLimiter : NSObject
@property (nonatomic, strong) NSDate *rateLimitedUntil;      // nil if not limited
@property (nonatomic) NSInteger consecutiveRateLimits;       // For backoff calculation

+ (instancetype)shared;

// Call before making API requests
- (BOOL)shouldDelay;                    // YES if currently rate-limited
- (NSTimeInterval)currentDelay;         // Time to wait before next request

// Call after receiving responses
- (void)recordRateLimitResponse;        // Increases backoff
- (void)recordSuccessResponse;          // Resets consecutive count

// Backoff calculation: min(20 * 2^consecutiveRateLimits, 300) seconds
@end
```

**User Feedback:**
- Console messages for debugging
- `%tidal_error%` metadata field for playlist visibility
- Status bar indicator in browser panel
- Toast notifications for critical errors (auth failure, etc.)

---

## 4. Implementation

### 4.1 Phase Breakdown

```
Phase 1: Foundation & Playback (MVP)
    │
    ├── Authentication (OAuth Device Code)
    ├── tidal:// protocol handler
    ├── Basic stream playback
    ├── Quality settings
    └── Minimal preferences UI
    │
    v
Phase 2: Browser & Metadata
    │
    ├── Search functionality
    ├── Browse categories
    ├── Results display with drag-drop
    ├── Album art loading
    └── Full metadata mapping
    │
    v
Phase 3: Playlist Sync
    │
    ├── Virtual folder in plorg
    ├── My Library browsing
    ├── Basic two-way sync
    └── Mixed playlist support
    │
    v
Phase 4: Polish & Advanced
    │
    ├── Offline state handling
    ├── Connection quality adaptation
    ├── Advanced sync (conflict resolution)
    └── Performance optimization
    │
    v
Phase 5: Facets Integration
    │
    ├── Hybrid search (local + Tidal)
    ├── Auto-match local tracks to Tidal
    └── Unified library browsing
```

### 4.2 Key Components

| Component | Responsibility |
|-----------|----------------|
| TidalSession | OAuth token management, refresh, Keychain storage |
| TidalAPI | HTTP client, rate limiting, JSON parsing |
| TidalStreamResolver | Stream URL resolution with caching |
| TidalInputDecoder | SDK input_decoder for tidal:// playback |
| TidalLinkResolver | SDK link_resolver for URL normalization |
| TidalBrowserController | UI panel, search, browse, drag-drop |
| TidalPlaylistSync | Playlist synchronization service |
| TidalConfig | Settings storage via fb2k::configStore |

### 4.3 Dependencies

**Internal (existing components):**
- Cloud Streamer patterns (caching, stream resolution)
- Last.fm Scrobbler patterns (OAuth, Keychain storage)
- Playlist Organizer (sync integration)

**External:**
- macOS Security framework (Keychain)
- Foundation/AppKit (networking, UI)
- foobar2000 macOS SDK

**No external libraries required** - all HTTP/JSON handling via NSURLSession and NSJSONSerialization.

### 4.4 Testing Strategy

**Unit Tests:**
- URL parsing (JLTidalURLType, extraction functions)
- Cache logic (TTL expiry, LRU eviction)
- Config read/write
- Metadata mapping

**Integration Tests (Mock API):**
- Auth flow state machine transitions
- Stream resolution with mock responses
- Error handling for various HTTP status codes
- Token refresh scenarios

**Mocking Approach:** NSURLProtocol interception for test isolation:
```objc
@interface JLTidalMockURLProtocol : NSURLProtocol
+ (void)setMockResponse:(NSData *)data forURL:(NSString *)urlPattern;
+ (void)setMockError:(NSError *)error forURL:(NSString *)urlPattern;
@end

// Register in test setup
[NSURLProtocol registerClass:[JLTidalMockURLProtocol class]];
```
This allows testing the full HTTP stack without network access.

**Integration Tests (Real API - requires test account):**
- Full auth flow with real Tidal account
- Search functionality
- Stream URL retrieval
- Playlist listing

**Manual Test Plan:**

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Fresh auth | Open prefs, click Login, complete in browser | Tokens stored, status shows logged in |
| Token refresh | Wait for expiry, trigger API call | Automatic refresh, no user action |
| Playback basic | Add tidal:// URL to playlist, play | Audio plays, metadata shows |
| Stream expiry | Play long track, wait for URL expiry | Transparent re-resolution, no interruption |
| Quality change | Change quality setting mid-session | Next track uses new quality |
| Network error | Disconnect network during playback | Pause, retry, eventually error message |
| Rate limit | Rapid API requests | Backoff applied, requests succeed eventually |

**Testing Without Subscription:**
- Auth flow testable with any Tidal account (free tier)
- Playback requires paid subscription for full coverage
- Mock server can simulate stream responses for development

### 4.5 Observability & Metrics

For debugging user-reported issues without telemetry:

**Metrics Collection:**
```objc
@interface JLTidalMetrics : NSObject
// Authentication
@property (nonatomic) NSUInteger authAttempts;
@property (nonatomic) NSUInteger authSuccesses;
@property (nonatomic) NSUInteger authFailures;

// Stream resolution
@property (nonatomic) NSUInteger resolveAttempts;
@property (nonatomic) NSUInteger resolveSuccesses;
@property (nonatomic) NSUInteger resolveCacheHits;
@property (nonatomic) double resolveLatencyP50;
@property (nonatomic) double resolveLatencyP99;

// Errors by type
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, NSNumber*> *errorCounts;

// Session info
@property (nonatomic) NSTimeInterval sessionUptime;
@property (nonatomic) NSUInteger tracksPlayed;

+ (instancetype)shared;
- (NSString *)diagnosticReport;  // For debug console command
- (void)reset;
@end
```

**Exposure:**
- Console command: `tidal.metrics` outputs diagnostic report
- Debug preference: "Enable verbose logging" logs key events
- Preferences panel: "Copy diagnostic info" button for support requests

**Key Events Logged (when debug enabled):**
- Authentication state transitions
- Stream resolution attempts with latency
- Cache hits/misses
- Error occurrences with context
- Token refresh events

### 4.6 Configuration Migration

**Version Strategy:**
```cpp
namespace tidal_config {
    static const int kConfigVersion = 1;

    void migrateIfNeeded() {
        int storedVersion = getConfigInt("config_version", 0);
        if (storedVersion < kConfigVersion) {
            migrateFromVersion(storedVersion);
            setConfigInt("config_version", kConfigVersion);
        }
    }

    void migrateFromVersion(int fromVersion) {
        switch (fromVersion) {
            case 0:
                // Initial install, no migration needed
                break;
            // Future versions:
            // case 1:
            //     migrateV1ToV2();
            //     [[fallthrough]];
        }
    }
}
```

**Migration Triggers:**
- Component load (initquit::on_init)
- Before any config access

**Backwards Compatibility:**
- New config keys have sensible defaults
- Removed keys are ignored (no cleanup needed)
- Format changes versioned and migrated

### 4.7 Configuration Options

All config keys use `tidal.` prefix to avoid namespace collisions in fb2k::configStore:

```cpp
namespace tidal_config {
    // Config key constants (all prefixed with "tidal.")
    static const char* kKeyQuality = "tidal.quality";
    static const char* kKeyAutoQuality = "tidal.quality.auto";
    static const char* kKeyAutoSync = "tidal.playlist.autosync";
    static const char* kKeySyncInterval = "tidal.playlist.syncinterval";
    static const char* kKeyCacheEnabled = "tidal.cache.enabled";
    static const char* kKeyCacheMaxSize = "tidal.cache.maxsize";
    static const char* kKeyDebug = "tidal.debug";
    static const char* kKeyTokenExpiry = "tidal.auth.expiry";
    static const char* kKeyConfigVersion = "tidal.config.version";

    // Authentication (Keychain storage, not configStore)
    // Keychain service: "com.foobar2000.tidal", accounts: "access_token"/"refresh_token"
    std::string getAccessToken();
    std::string getRefreshToken();
    int64_t getTokenExpiry();           // From configStore: tidal.auth.expiry

    // Quality
    std::string getPreferredQuality();  // "HIGH", "LOSSLESS", etc.
    bool getAutoQuality();              // Adapt based on network

    // Behavior
    bool getAutoSync();                 // Auto-sync playlists
    int getSyncInterval();              // Minutes between syncs

    // Cache
    bool isCacheEnabled();
    int getCacheMaxSize();              // MB

    // Debug
    bool isDebugEnabled();
}
```

---

## 5. Considerations

### 5.1 Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Token expires during long playlist | Auto-refresh in background, retry request |
| Track removed from Tidal | Show error in metadata, remove from sync |
| Region restriction | Display region error, skip track |
| Network disconnection | Buffer drains, pause playback, retry with backoff |
| Duplicate track IDs in playlist | Handle gracefully (same track can appear multiple times) |
| Very long playlists (1000+ tracks) | Paginate API calls, lazy load in browser |
| User logs out | Clear tokens, stop playback, clear caches (StreamCache + ThumbnailCache; retain MetadataCache as track info remains valid) |
| Subscription downgrade | Quality fallback, notify user |
| Subscription full expiration | Clear auth, disable Tidal features, prompt re-auth |
| Cloud Streamer URL collision | No collision: `tidal://` vs `mixcloud://`/`soundcloud://` |
| API unavailability | Auto-disable after repeated failures, one-time notification |

### 5.2 Network Resilience

**Buffering Strategy:**

The foobar2000 SDK handles buffering at the decoder level. For Tidal streams:

1. **Pre-playback buffer**: SDK's default HTTP decoder handles this
2. **Buffer underrun**: SDK pauses playback automatically
3. **Reconnection**: Our `tryResolveAndReopen` handles stream URL expiry

**Network Interruption Behavior:**
```
Network OK → Buffering → Playing → Network Lost → Buffer Draining → Paused
                                                         ↓
                                         Retry with exponential backoff
                                                         ↓
                                              Network Restored → Resume
                                                    or
                                              Max retries → Error displayed
```

**Retry Configuration:**
- Initial delay: 1 second
- Max delay: 60 seconds
- Backoff multiplier: 2x
- Max retries: 5

**Prefetch for Gapless:**
```objc
// Prefetch next track stream URL 30s before current track ends
// This reduces gap between tracks even if network is slow
- (void)prefetchNextTrackIfNeeded:(double)currentPosition duration:(double)trackDuration {
    if (trackDuration - currentPosition < 30.0 && !self.nextTrackPrefetched) {
        NSString *nextTrackURL = [self getNextTrackURL];
        if (nextTrackURL) {
            [[JLTidalStreamResolver shared] prefetchURL:nextTrackURL];
            self.nextTrackPrefetched = YES;
        }
    }
}
```

### 5.3 Error Handling

**Authentication Errors:**
- 401: Attempt token refresh, then re-auth flow
- Token refresh fails: Clear session, prompt re-login

**Playback Errors:**
- Stream 403: Re-resolve URL, seek to position
- Stream 404: Track unavailable, show error
- Network timeout: Retry with exponential backoff

**API Errors:**
- 429: Rate limited, backoff 20+ seconds
- 500/503: Server error, retry with backoff
- Parse error: Log, show generic error to user

### 5.4 Performance

**Targets:**
- Initial playback latency: <3 seconds
- Search response: <2 seconds
- Album art load: <1 second (cached hits instant)

**Optimizations:**
- Prefetch next track stream URL during current playback
- Lazy load album art (visible items first)
- Pagination for large result sets (20-50 items per page)
- Background sync (not blocking UI)

**Memory:**
- Stream URL cache: Limited entries with TTL eviction
- Metadata cache: Persistent to disk, LRU eviction
- Album art cache: Disk-based, size-limited

### 5.5 Security

**Token Security:**
- Access/refresh tokens in macOS Keychain (encrypted)
- Never log tokens to console
- Clear tokens on logout

**Network Security:**
- HTTPS only (Tidal API enforces)
- Certificate validation (default NSURLSession behavior)

**Privacy:**
- User's Tidal account info stored locally only
- No analytics or tracking beyond Tidal's own
- Playback history not persisted (unless scrobbling added later)

### 5.6 DRM Considerations

**CRITICAL: Pre-Implementation Spike Required**

Before Phase 1 implementation begins, a 1-2 day investigation spike must be conducted to determine DRM status. This is a go/no-go blocker for the core value proposition.

**Spike Tasks:**
1. Obtain test Tidal HiFi subscription
2. Test `playbackinfopostpaywall` responses for each quality tier
3. Attempt direct playback of returned stream URLs
4. Document manifest formats and any encryption indicators
5. Test with actual audio decoder to confirm playability

**Decision Matrix:**

| DRM Status | Action |
|------------|--------|
| No DRM on any tier | Full quality support, proceed as designed |
| DRM on HiFi+ only | Support High (320k) max, document limitation, investigate SDK partnership |
| DRM on all tiers | Evaluate official SDK integration or abort feature |

**Fallback Strategy:**
- If HiFi/Master/Max streams are DRM-protected and unplayable:
  1. Default to High (AAC 320k) quality
  2. Display clear user messaging: "Lossless quality requires Tidal's official apps"
  3. Allow users to configure preferred fallback behavior
  4. Track DRM errors via `%tidal_error%` field

**User Expectations:**
- Component will be labeled "experimental" until DRM status is confirmed
- Quality limitations will be documented in README and preferences UI
- Users understand they may not get full HiFi quality

### 5.7 Legal & API Access

**Risk Assessment:**

This integration uses unofficial API access patterns discovered through reverse engineering (python-tidal, Tidal-Media-Downloader). This carries inherent risks:

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| API key revocation | Medium | Complete feature outage | Use user-provided credentials option |
| ToS violation claim | Low | Legal notice | Non-commercial, personal use only |
| API endpoint changes | Medium | Feature breakage | Version detection, graceful degradation |

**Mitigation Strategies:**

1. **Official Developer Program Investigation**
   - Check developer.tidal.com for third-party app registration
   - If available, apply for official API access
   - Document findings in implementation notes

2. **User-Provided Credentials Option**
   - Allow users to provide their own client_id if desired
   - Reduces single point of failure
   - Documented as advanced option

3. **Graceful Degradation**
   - Detect API changes via response format validation
   - Disable feature cleanly rather than crash
   - Clear error messaging for API unavailability

4. **Component Disclaimer**
   - README: "Unofficial integration, may stop working"
   - Preferences: Link to Tidal's official apps
   - No guarantees of continued functionality

**Contingency Plan:**
If Tidal blocks API access:
1. Auto-disable Tidal features (don't spam errors)
2. Display one-time notification to users
3. Preserve user's playlist references for potential restoration
4. Document status in release notes

---

## 6. Alternatives Considered

### 6.1 Use Official Tidal SDK

**Pros:**
- Supported by Tidal
- May handle DRM automatically
- Player module available

**Cons:**
- iOS SDK, would need bridging
- May require partner agreement
- Less control over implementation

**Decision:** Start with direct API access (like python-tidal). Evaluate SDK if DRM becomes blocker.

### 6.2 Use yt-dlp Like Cloud Streamer

**Pros:**
- Consistent with existing Cloud Streamer approach
- Handles many edge cases

**Cons:**
- yt-dlp's Tidal support is limited/broken
- Tidal requires authentication yt-dlp can't easily provide
- Maintenance burden of external tool

**Decision:** Direct API integration is more reliable for Tidal.

### 6.3 Separate Components (Modular Architecture)

**Pros:**
- Smaller, focused components
- Independent versioning

**Cons:**
- More complex inter-component communication
- User installs multiple components
- Shared state management harder

**Decision:** Single component simplifies development and user experience.

### 6.4 Read-Only Playlist Sync Only

**Pros:**
- Simpler implementation
- No conflict resolution needed

**Cons:**
- Users can't manage Tidal playlists from foobar
- Limited integration value

**Decision:** Start with virtual folder (read-only), add two-way sync in Phase 3.

---

## 7. Open Questions

### Resolved (Design Decisions Made)

- [x] **Account Switching**: Users must logout/login to switch accounts. No multi-account support in MVP. Single active session simplifies token management.

- [x] **Error Field Persistence**: `%tidal_error%` is ephemeral - cleared on successful playback retry, persists until track plays successfully or is removed from playlist.

- [x] **plorg Dependency**: NotificationCenter observers are fire-and-forget. If plorg isn't installed, notifications are simply not observed. No dependency check required.

- [x] **Retry UX**: During retry (up to 127 seconds worst case), show spinner in status bar with "Reconnecting..." text. After max retries, display error with "Retry" button.

- [x] **Prefetch Timing**: The 30-second prefetch trigger uses percentage-based fallback for short tracks: `max(5.0, trackDuration * 0.1)` seconds before end. For tracks under 1 minute, this prevents prefetch from dominating playback.

- [x] **Concurrent Stream Limits**: Tidal typically enforces 1 concurrent stream per account (may vary by subscription tier). Our implementation doesn't need to manage this - Tidal server-side handles it, and a 403/409 response would trigger our error handling. Document as known limitation.

- [x] **DASH Manifest Handling**: If `dash+xml` format is returned, defer to Phase 2. For MVP, request only `BTS` (Base64 JSON) format via explicit `manifest_mime_type` parameter. Most AAC/FLAC content supports BTS format.

- [x] **Album Art Size Selection**: Use context-appropriate sizes:
  - Playlist thumbnails: 160x160 (small grid)
  - Browser results: 320x320 (medium)
  - Now playing: 640x640 (large)
  - Full detail view: 1280x1280 (high-res)
  Sizes via URL pattern: `{id}/320x320.jpg`

### Requiring Investigation (DRM Spike)

- [ ] **DRM Status**: Do HiFi/Master/Max streams require Widevine? Need to test with actual subscription.

- [ ] **API Access**: Is there an official API key/client_id for third-party apps, or do we use discovered credentials?

- [ ] **MQA Decoding**: Master quality uses MQA. Does foobar2000 have MQA decoder? Fallback if not?

- [ ] **Rate Limits**: Exact rate limits undocumented. Need empirical testing to establish safe request patterns.

- [ ] **Session Validity**: How long do sessions remain valid? Token refresh interval?

- [ ] **Regional Availability**: How to handle tracks available in some regions but not others?

- [ ] **Playlist Ordering**: Does Tidal API preserve exact track order? Any issues with large playlists?

---

## 8. Future Enhancements

### Phase 5+: Facets Integration
- Unified search across local library and Tidal
- Filter by source (local, Tidal, both)
- Auto-populate missing tracks from Tidal

### Offline Mode
- Cache selected playlists/albums for offline playback
- Background download with queue management
- Storage usage settings

### Last.fm Integration
- Scrobble Tidal plays via existing scrobbler component
- Cross-component communication pattern

### Tidal Connect
- Act as Tidal Connect receiver
- Control playback from Tidal mobile app

### Lyrics Integration
- Fetch lyrics from Tidal API (if available)
- Display in dedicated lyrics panel

---

## Appendix

### References

- [python-tidal (tidalapi)](https://github.com/tamland/python-tidal) - Unofficial Python API
- [tidalapi Documentation](https://tidalapi.netlify.app/) - API usage docs
- [TIDAL Developer Portal](https://developer.tidal.com/) - Official developer resources
- [TIDAL SDK](https://github.com/tidal-music/tidal-sdk) - Official platform SDKs
- [Tidal-Media-Downloader](https://github.com/yaronzz/Tidal-Media-Downloader) - API integration reference
- [OAuth 2.0 Device Authorization Grant (RFC 8628)](https://tools.ietf.org/html/rfc8628)

### API Endpoints Reference

| Endpoint | Method | Purpose |
|----------|--------|---------|
| /oauth2/device_authorization | POST | Start device auth flow |
| /oauth2/token | POST | Exchange code for token / refresh |
| /search | GET | Search catalog |
| /tracks/{id} | GET | Track metadata |
| /tracks/{id}/playbackinfopostpaywall | GET | Stream URL |
| /albums/{id} | GET | Album metadata |
| /albums/{id}/tracks | GET | Album tracks |
| /artists/{id} | GET | Artist metadata |
| /artists/{id}/albums | GET | Artist discography |
| /playlists/{uuid} | GET | Playlist metadata |
| /playlists/{uuid}/tracks | GET | Playlist tracks |
| /users/{id}/playlists | GET | User's playlists |
| /users/{id}/favorites/tracks | GET | Favorited tracks |

**Pagination Parameters** (for list endpoints):
- `limit`: Items per page (default 50, max 100)
- `offset`: Starting index (0-based)
- Response includes `totalNumberOfItems` for calculating pages

### Quality Parameters

| Quality | API Param | Format | Bitrate |
|---------|-----------|--------|---------|
| Normal | LOW | AAC | 96 kbps |
| High | HIGH | AAC | 320 kbps |
| HiFi | LOSSLESS | FLAC | 1411 kbps (16-bit/44.1kHz) |
| Master | HI_RES | MQA | Variable |
| Max | HI_RES_LOSSLESS | FLAC | Up to 9216 kbps (24-bit/192kHz) |

### Changelog

| Date | Change |
|------|--------|
| 2026-01-07 | Initial draft |
| 2026-01-07 | Review 1: Added DRM spike requirement, Legal & API Access section, complete stream re-resolution flow, auth cancellation, testing strategy, config migration, network resilience, plorg integration details |
| 2026-01-07 | Review 2: Added threading model (Section 3.10), decoder lifecycle management, prefetch race condition fix, auth polling safety timeout, TTL validation strategy, observability/metrics, resolved open questions |
| 2026-01-07 | Review 3: Aligned decoder with CloudInputDecoder pattern, added TidalInputEntry/TidalInfoReader, fixed plorg Swift->ObjC, added error-to-exception mapping, fixed config namespace (tidal.* prefix), simplified TTL strategy, resolved open questions (prefetch timing, concurrent streams, DASH handling, album art sizes) |
| 2026-01-07 | Review 4: Fixed service factory pattern (service_factory_single_t), added initialize() method, fixed 403 detection to use string matching, added open_for_info_write/get_extended_data, fixed Keychain schema consistency, added JLTidalRateLimiter class, added URL expansion clarification, specified cache invalidation on logout |
| 2026-01-07 | Review 5 (Final): Updated to input_entry_v2 with correct signature, fixed get_extended_data to use playable_location, fixed duplicate section numbering (5.3->5.4, 5.4->5.5, etc.) |

---

**Status:** Approved for Implementation (pending DRM spike)
