# foo_jl_biography_mac - Foundation Document

## Project Overview

A foobar2000 macOS component that displays artist biography, images, and related information for the currently playing track. Fetches data from Last.fm (primary), with fallback to Wikipedia and supplementary data from Fanart.tv and TheAudioDB.

**Component Name:** `foo_jl_biography_mac`
**Target Platform:** foobar2000 v2.x (macOS)
**SDK Version:** foobar2000 SDK 2025-03-07
**License:** Personal/Non-commercial use
**Component Type:** UI Element (Layout Component via `ui_element_mac`)

> Follows the same architecture as `foo_jl_album_art_mac`, `foo_jl_simplaylist_mac`, `foo_jl_plorg_mac`, and `foo_jl_wave_seekbar_mac`.

---

## Core Features

### MVP (Phase 1-2)

1. **Artist Biography Display**
   - Fetch biography text from Last.fm
   - Fallback to Wikipedia extract
   - Rich text formatting with HTML support
   - Scrollable text view

2. **Artist Image Display**
   - Primary: Fanart.tv high-resolution images (requires MusicBrainz ID)
   - Secondary: TheAudioDB images
   - Fallback: Last.fm images
   - Aspect-ratio preserving display

3. **Track Change Integration**
   - Automatic update on playback changes
   - Extract artist name from track metadata
   - Debounce rapid track changes
   - Request cancellation on artist change

4. **Caching System**
   - SQLite database for text data and metadata
   - File-based cache for images with metadata tracking
   - Configurable cache lifetime
   - LRU eviction when cache exceeds size limit

### Extended Features (Phase 3+)

5. **Similar Artists**
   - Display related artists from Last.fm
   - Clickable to switch artist view

6. **Tags/Genres**
   - Display artist tags/genres
   - Visual tag cloud option

7. **Multiple Display Modes**
   - Full (image + bio + extras)
   - Compact (small image + short bio)
   - Image only
   - Text only

8. **Preferences**
   - Data source priorities
   - Cache management
   - Display customization
   - API key configuration (stored in Keychain)

---

## Architecture

### Component Structure

```
foo_jl_biography_mac/
├── src/
│   ├── Core/
│   │   ├── BiographyData.h/mm          # Immutable data models
│   │   ├── BiographyCache.h/mm         # SQLite + file caching
│   │   ├── BiographyCacheManager.h/mm  # LRU eviction, size management
│   │   ├── BiographyFetcher.h/mm       # Request coordinator
│   │   ├── BiographyRequest.h/mm       # Cancellable request token
│   │   └── RateLimiter.h/mm            # API rate limiting (reuse from scrobbler)
│   │
│   ├── API/
│   │   ├── LastFmBioClient.h/mm        # Last.fm integration
│   │   ├── MusicBrainzClient.h/mm      # MBID lookup (required for Fanart.tv)
│   │   ├── WikipediaClient.h/mm        # Wikipedia integration
│   │   ├── FanartTvClient.h/mm         # Fanart.tv integration
│   │   ├── AudioDbClient.h/mm          # TheAudioDB integration
│   │   ├── SecretConfig.h              # Default API keys (git-ignored)
│   │   └── KeychainHelper.h/mm         # User API key storage (reuse from scrobbler)
│   │
│   ├── UI/
│   │   ├── BiographyController.h/mm    # Main view controller
│   │   ├── BiographyContentView.h/mm   # Main content container
│   │   ├── BiographyImageView.h/mm     # Image display
│   │   ├── BiographyTextView.h/mm      # Text display
│   │   ├── BiographyLoadingView.h/mm   # Loading state
│   │   ├── BiographyErrorView.h/mm     # Error state with retry
│   │   ├── BiographyEmptyView.h/mm     # No track playing state
│   │   └── BiographyPreferences.h/mm   # Preferences panel
│   │
│   ├── Integration/
│   │   ├── Main.mm                     # Service registration
│   │   ├── PlaybackCallbacks.mm        # Track change handling
│   │   └── CallbackManager.h/mm        # Controller notifications
│   │
│   ├── fb2k_sdk.h                      # SDK configuration
│   └── Prefix.pch                      # Precompiled header
│
├── Resources/
│   ├── Info.plist
│   ├── Preferences.xib
│   └── placeholder_artist.png
│
├── Scripts/
│   ├── generate_xcode_project.rb
│   ├── build.sh
│   └── install.sh
│
└── README.md
```

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        foobar2000                               │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐      │
│  │   Playback   │───►│  Callbacks   │───►│  Biography   │      │
│  │   Engine     │    │  (C++)       │    │  Controller  │      │
│  └──────────────┘    └──────────────┘    └──────┬───────┘      │
└────────────────────────────────────────────────│───────────────┘
                                                  │
                            ┌─────────────────────┼─────────────────────┐
                            │ Cancel previous     │ Start new request   │
                            ▼                     ▼                     │
                    ┌───────────────────────────────────────────┐       │
                    │           BiographyFetcher                │       │
                    │  ┌─────────────────────────────────────┐  │       │
                    │  │ fetchQueue (serial dispatch queue)  │  │       │
                    │  │ currentRequest (cancellable)        │  │       │
                    │  └─────────────────────────────────────┘  │       │
                    └───────────────────┬───────────────────────┘       │
                                        │                               │
          ┌─────────────────────────────┼─────────────────────────────┐ │
          │                             │                             │ │
          ▼                             ▼                             ▼ │
┌─────────────────┐           ┌─────────────────┐           ┌─────────────────┐
│  BiographyCache │           │   API Clients   │           │   RateLimiter   │
│  (SQLite/Files) │           │                 │           │  (per-service)  │
│                 │           │  - LastFm       │           └─────────────────┘
│  CacheManager   │           │  - MusicBrainz  │
│  (LRU eviction) │           │  - Wikipedia    │
└─────────────────┘           │  - FanartTv     │
                              │  - AudioDb      │
                              └─────────────────┘
```

---

## Data Models

### BiographySource Enum

```objc
typedef NS_ENUM(NSInteger, BiographySource) {
    BiographySourceUnknown = 0,
    BiographySourceLastFm,
    BiographySourceWikipedia,
    BiographySourceAudioDb,
    BiographySourceFanartTv,
    BiographySourceCache
};

typedef NS_ENUM(NSInteger, BiographyImageType) {
    BiographyImageTypeThumb = 0,
    BiographyImageTypeBackground,
    BiographyImageTypeLogo,
    BiographyImageTypeBanner
};
```

### BiographyData (Immutable)

```objc
@class SimilarArtistRef;

/// Immutable data model - construct via builder, thread-safe after creation
@interface BiographyData : NSObject

// Artist identification
@property (nonatomic, copy, readonly) NSString *artistName;
@property (nonatomic, copy, readonly, nullable) NSString *musicBrainzId;

// Biography content
@property (nonatomic, copy, readonly, nullable) NSString *biography;
@property (nonatomic, copy, readonly, nullable) NSString *biographySummary;
@property (nonatomic, assign, readonly) BiographySource biographySource;
@property (nonatomic, copy, readonly, nullable) NSString *language;

// Images
@property (nonatomic, strong, readonly, nullable) NSImage *artistImage;
@property (nonatomic, copy, readonly, nullable) NSURL *artistImageURL;
@property (nonatomic, assign, readonly) BiographySource imageSource;
@property (nonatomic, assign, readonly) BiographyImageType imageType;

// Metadata
@property (nonatomic, copy, readonly, nullable) NSArray<NSString *> *tags;
@property (nonatomic, copy, readonly, nullable) NSArray<SimilarArtistRef *> *similarArtists;
@property (nonatomic, copy, readonly, nullable) NSString *genre;
@property (nonatomic, copy, readonly, nullable) NSString *country;

// Statistics (from Last.fm)
@property (nonatomic, assign, readonly) NSUInteger listeners;
@property (nonatomic, assign, readonly) NSUInteger playcount;

// Cache metadata
@property (nonatomic, strong, readonly) NSDate *fetchedAt;
@property (nonatomic, assign, readonly) BOOL isFromCache;
@property (nonatomic, assign, readonly) BOOL isStale;  // TTL expired but still usable

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithBuilder:(BiographyDataBuilder *)builder NS_DESIGNATED_INITIALIZER;

@end

/// Builder for constructing BiographyData
@interface BiographyDataBuilder : NSObject

@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy, nullable) NSString *musicBrainzId;
@property (nonatomic, copy, nullable) NSString *biography;
@property (nonatomic, copy, nullable) NSString *biographySummary;
@property (nonatomic, assign) BiographySource biographySource;
@property (nonatomic, copy, nullable) NSString *language;
@property (nonatomic, strong, nullable) NSImage *artistImage;
@property (nonatomic, copy, nullable) NSURL *artistImageURL;
@property (nonatomic, assign) BiographySource imageSource;
@property (nonatomic, assign) BiographyImageType imageType;
@property (nonatomic, copy, nullable) NSArray<NSString *> *tags;
@property (nonatomic, copy, nullable) NSArray<SimilarArtistRef *> *similarArtists;
@property (nonatomic, copy, nullable) NSString *genre;
@property (nonatomic, copy, nullable) NSString *country;
@property (nonatomic, assign) NSUInteger listeners;
@property (nonatomic, assign) NSUInteger playcount;
@property (nonatomic, strong) NSDate *fetchedAt;
@property (nonatomic, assign) BOOL isFromCache;
@property (nonatomic, assign) BOOL isStale;

- (BiographyData *)build;

@end
```

### SimilarArtistRef (Lightweight)

```objc
/// Lightweight reference for similar artists - avoids recursive BiographyData
@interface SimilarArtistRef : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSURL *thumbnailURL;
@property (nonatomic, copy, readonly, nullable) NSString *musicBrainzId;

- (instancetype)initWithName:(NSString *)name
                thumbnailURL:(nullable NSURL *)thumbnailURL
               musicBrainzId:(nullable NSString *)mbid;

@end
```

### BiographyRequest (Cancellation Token)

```objc
/// Cancellation token for in-flight requests
@interface BiographyRequest : NSObject

@property (nonatomic, copy, readonly) NSString *artistName;
@property (nonatomic, assign, readonly, getter=isCancelled) BOOL cancelled;
@property (nonatomic, strong, readonly) NSDate *startedAt;

- (instancetype)initWithArtistName:(NSString *)artistName;
- (void)cancel;

@end
```

---

## BiographyFetcher (Request Coordinator)

```objc
typedef void (^BiographyCompletion)(BiographyData * _Nullable data, NSError * _Nullable error);

/// Coordinates multi-source fetching with cancellation and deduplication
@interface BiographyFetcher : NSObject

/// Serial queue for API requests - prevents thundering herd
@property (nonatomic, strong, readonly) dispatch_queue_t fetchQueue;

/// Currently in-flight request (nil if idle)
@property (nonatomic, strong, readonly, nullable) BiographyRequest *currentRequest;

/// Singleton accessor
+ (instancetype)shared;

/// Fetch biography with automatic cancellation of any pending request
/// @param artistName The artist to fetch
/// @param ignoreCache If YES, bypasses cache and fetches fresh data
/// @param completion Called on main thread with result or error
- (void)fetchBiographyForArtist:(NSString *)artistName
                          force:(BOOL)ignoreCache
                     completion:(BiographyCompletion)completion;

/// Cancel any in-flight request
- (void)cancelCurrentRequest;

/// Check if a request is currently in progress
@property (nonatomic, assign, readonly, getter=isFetching) BOOL fetching;

@end
```

### Fetcher Threading Model

- All API calls execute on `fetchQueue` (serial)
- Completions always dispatch to main thread
- Previous request cancelled before starting new one
- Deduplication: if same artist requested, reuse in-flight request

---

## API Integration

### Rate Limiter Configuration

```objc
// Rate limiter constants - reuse RateLimiter from foo_jl_scrobble_mac
static const double kLastFmRatePerSecond = 1.0;
static const NSInteger kLastFmBurstCapacity = 5;

static const double kMusicBrainzRatePerSecond = 1.0;   // Strict - no bursting
static const NSInteger kMusicBrainzBurstCapacity = 1;

static const double kAudioDbRatePerSecond = 0.5;       // 30/min = 0.5/sec
static const NSInteger kAudioDbBurstCapacity = 5;

static const double kWikipediaRatePerSecond = 2.0;     // Generous
static const NSInteger kWikipediaBurstCapacity = 10;

// Fanart.tv has no documented limit, use reasonable defaults
static const double kFanartTvRatePerSecond = 2.0;
static const NSInteger kFanartTvBurstCapacity = 5;
```

### Last.fm Client

```objc
@interface LastFmBioClient : NSObject

+ (instancetype)shared;

- (void)fetchArtistInfo:(NSString *)artistName
                  token:(BiographyRequest *)token
             completion:(void(^)(NSDictionary * _Nullable response, NSError * _Nullable error))completion;

- (void)fetchSimilarArtists:(NSString *)artistName
                      token:(BiographyRequest *)token
                 completion:(void(^)(NSArray * _Nullable artists, NSError * _Nullable error))completion;

@end
```

**Request:**
```
GET https://ws.audioscrobbler.com/2.0/
    ?method=artist.getinfo
    &artist={name}
    &api_key={key}
    &format=json
    &lang=en
    &autocorrect=1
```

### MusicBrainz Client

```objc
/// MusicBrainz client for MBID lookup - required for Fanart.tv
/// Note: Strict 1 req/sec rate limit, must set proper User-Agent
@interface MusicBrainzClient : NSObject

+ (instancetype)shared;

/// Look up artist by name, returns MusicBrainz ID
- (void)lookupArtist:(NSString *)artistName
               token:(BiographyRequest *)token
          completion:(void(^)(NSString * _Nullable mbid, NSError * _Nullable error))completion;

@end
```

**Request:**
```
GET https://musicbrainz.org/ws/2/artist/
    ?query=artist:{name}
    &fmt=json

Headers:
    User-Agent: foo_jl_biography/1.0.0 (contact@example.com)
```

### Wikipedia Client

```objc
@interface WikipediaClient : NSObject

+ (instancetype)shared;

- (void)fetchArtistSummary:(NSString *)artistName
                     token:(BiographyRequest *)token
                completion:(void(^)(NSString * _Nullable summary,
                                    NSURL * _Nullable imageURL,
                                    NSError * _Nullable error))completion;

@end
```

### Fanart.tv Client

```objc
@interface FanartTvClient : NSObject

+ (instancetype)shared;

/// Fetch artist images - requires MusicBrainz ID
- (void)fetchArtistImages:(NSString *)musicBrainzId
                    token:(BiographyRequest *)token
               completion:(void(^)(NSArray<NSURL *> * _Nullable imageURLs,
                                   NSError * _Nullable error))completion;

@end
```

### TheAudioDB Client

```objc
@interface AudioDbClient : NSObject

+ (instancetype)shared;

- (void)searchArtist:(NSString *)artistName
               token:(BiographyRequest *)token
          completion:(void(^)(NSDictionary * _Nullable artistData,
                              NSError * _Nullable error))completion;

@end
```

---

## Caching Strategy

### Cache Structure

```
~/Library/Application Support/foobar2000-v2/biography_cache/
├── biography.db              # SQLite database
└── images/
    └── {hash}/
        └── {type}_{source}.jpg
```

### SQLite Schema

```sql
-- Artists table with permanent MBID storage
CREATE TABLE artists (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    name_normalized TEXT NOT NULL,      -- Lowercase, trimmed
    musicbrainz_id TEXT,                -- Permanent once resolved
    created_at INTEGER NOT NULL,
    last_accessed INTEGER NOT NULL,     -- For LRU eviction
    UNIQUE(name_normalized)
);

-- Biographies - one per source per artist
CREATE TABLE biographies (
    artist_id INTEGER NOT NULL,
    source INTEGER NOT NULL,            -- BiographySource enum
    language TEXT DEFAULT 'en',
    content TEXT,
    summary TEXT,
    priority INTEGER NOT NULL,          -- Source priority at fetch time
    cached_at INTEGER NOT NULL,
    PRIMARY KEY(artist_id, source),
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE
);

-- Metadata from various sources
CREATE TABLE metadata (
    artist_id INTEGER NOT NULL PRIMARY KEY,
    tags TEXT,                          -- JSON array
    similar_artists TEXT,               -- JSON array of {name, mbid, thumb_url}
    genre TEXT,
    country TEXT,
    listeners INTEGER,
    playcount INTEGER,
    cached_at INTEGER NOT NULL,
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE
);

-- Image cache metadata (actual files stored on disk)
CREATE TABLE cached_images (
    id INTEGER PRIMARY KEY,
    artist_id INTEGER NOT NULL,
    source INTEGER NOT NULL,            -- BiographySource enum
    image_type INTEGER NOT NULL,        -- BiographyImageType enum
    original_url TEXT NOT NULL,
    local_path TEXT NOT NULL,           -- Relative path in cache dir
    width INTEGER,
    height INTEGER,
    file_size INTEGER,
    cached_at INTEGER NOT NULL,
    last_accessed INTEGER NOT NULL,
    FOREIGN KEY(artist_id) REFERENCES artists(id) ON DELETE CASCADE,
    UNIQUE(artist_id, source, image_type)
);

-- Cache statistics for LRU eviction
CREATE TABLE cache_stats (
    key TEXT PRIMARY KEY,
    value INTEGER
);

-- Indexes
CREATE INDEX idx_artists_normalized ON artists(name_normalized);
CREATE INDEX idx_artists_accessed ON artists(last_accessed);
CREATE INDEX idx_bio_priority ON biographies(artist_id, priority);
CREATE INDEX idx_images_accessed ON cached_images(last_accessed);
```

### Cache Manager

```objc
@interface BiographyCacheManager : NSObject

+ (instancetype)shared;

/// Current cache size in bytes (text + images)
@property (nonatomic, readonly) NSUInteger currentCacheSizeBytes;

/// Maximum cache size (default 500MB)
@property (nonatomic, assign) NSUInteger maxCacheSizeBytes;

/// Enforce size limit using LRU eviction
/// Called automatically after cache writes
- (void)enforceMaxSizeWithCompletion:(void(^ _Nullable)(NSUInteger bytesFreed))completion;

/// Get oldest accessed entries for manual eviction
- (NSArray<NSString *> *)entriesForEvictionCount:(NSUInteger)count;

/// Update access time for an artist (call when data is displayed)
- (void)touchArtist:(NSString *)artistName;

/// Clear all cached data
- (void)clearAllWithCompletion:(void(^ _Nullable)(void))completion;

/// Clear only expired entries
- (void)clearExpiredWithCompletion:(void(^ _Nullable)(NSUInteger bytesFreed))completion;

@end
```

### TTL Configuration

| Data Type | Default TTL | Configurable |
|-----------|-------------|--------------|
| Biography text | 7 days | Yes |
| Artist metadata | 7 days | Yes |
| Images | 30 days | Yes |
| MusicBrainz IDs | Permanent | No |

---

## UI Implementation

### Timing Constants

```objc
/// Delay before starting fetch after track change (avoids rapid requests during skip)
static const NSTimeInterval kTrackChangeDebounceDelay = 0.3;  // 300ms

/// Delay before showing loading indicator (avoids flicker for cached data)
static const NSTimeInterval kLoadingIndicatorDelay = 0.2;     // 200ms

/// Timeout for API requests
static const NSTimeInterval kAPIRequestTimeout = 15.0;        // 15 seconds

/// Timeout for image downloads
static const NSTimeInterval kImageDownloadTimeout = 30.0;     // 30 seconds
```

### BiographyController

```objc
typedef NS_ENUM(NSInteger, BiographyDisplayMode) {
    BiographyDisplayModeFull,        // Image + Bio + Extras
    BiographyDisplayModeCompact,     // Small image + Short bio
    BiographyDisplayModeImageOnly,   // Large image
    BiographyDisplayModeTextOnly     // Bio text only
};

typedef NS_ENUM(NSInteger, BiographyViewState) {
    BiographyViewStateEmpty,         // No track playing
    BiographyViewStateLoading,       // Fetching data
    BiographyViewStateContent,       // Showing biography
    BiographyViewStateError,         // Error with retry option
    BiographyViewStateOffline        // Showing stale cache, offline
};

@interface BiographyController : NSViewController

// Current state
@property (nonatomic, strong, readonly, nullable) BiographyData *currentData;
@property (nonatomic, copy, readonly, nullable) NSString *currentArtist;
@property (nonatomic, assign, readonly) BiographyViewState viewState;

// Cancellation
@property (nonatomic, strong, nullable) BiographyRequest *currentFetchToken;

// Display mode
@property (nonatomic, assign) BiographyDisplayMode displayMode;

// Playback integration
- (void)onTrackChanged:(NSString *)artistName;
- (void)onPlaybackStopped;

// Manual actions
- (void)refresh;
- (void)retry;

@end
```

### View Hierarchy

```
BiographyController.view (NSView)
├── stateContainerView (NSStackView - for state switching)
│   │
│   ├── contentView (hidden when loading/error/empty)
│   │   └── NSScrollView
│   │       └── NSStackView (vertical)
│   │           ├── BiographyImageView
│   │           │   └── NSImageView (aspect-fit)
│   │           ├── BiographyTextView
│   │           │   └── NSTextView (rich text, non-editable)
│   │           ├── TagsView (optional)
│   │           │   └── NSStackView (horizontal, wrap)
│   │           └── SimilarArtistsView (optional)
│   │               └── NSCollectionView
│   │
│   ├── loadingView (centered spinner + "Loading...")
│   │   ├── NSProgressIndicator (spinning)
│   │   └── NSTextField ("Loading biography...")
│   │
│   ├── errorView (error message + retry button)
│   │   ├── NSImageView (error icon)
│   │   ├── NSTextField (error message)
│   │   └── NSButton ("Retry")
│   │
│   └── emptyView (placeholder when no track)
│       ├── NSImageView (placeholder icon)
│       └── NSTextField ("Play a track to see artist info")
│
└── offlineIndicator (subtle banner at top, hidden when online)
    └── NSTextField ("Offline - showing cached data")
```

### Track Change Handling with Cancellation

```objc
// In BiographyController
- (void)onTrackChanged:(NSString *)artistName {
    // Same artist? No action needed
    if ([artistName isEqualToString:self.currentArtist]) {
        return;
    }

    // Cancel any pending work for previous artist
    [self.currentFetchToken cancel];
    self.currentFetchToken = nil;

    // Debounce rapid track changes
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(fetchBiographyForArtist:)
                                               object:nil];

    _currentArtist = [artistName copy];

    [self performSelector:@selector(startFetch)
               withObject:nil
               afterDelay:kTrackChangeDebounceDelay];
}

- (void)startFetch {
    BiographyRequest *token = [[BiographyRequest alloc] initWithArtistName:self.currentArtist];
    self.currentFetchToken = token;

    // Show loading after delay (avoid flicker for cache hits)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kLoadingIndicatorDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!token.isCancelled && self.viewState != BiographyViewStateContent) {
            [self transitionToState:BiographyViewStateLoading];
        }
    });

    __weak typeof(self) weakSelf = self;
    [[BiographyFetcher shared] fetchBiographyForArtist:self.currentArtist
                                                 force:NO
                                            completion:^(BiographyData *data, NSError *error) {
        if (token.isCancelled) return;  // Ignore stale response

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            [strongSelf handleFetchError:error];
        } else {
            [strongSelf displayBiography:data];
        }
    }];
}
```

---

## Service Registration

### Main.mm

```cpp
#include "fb2k_sdk.h"
#include "BiographyController.h"
#include "CallbackManager.h"

namespace {

class biography_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        BiographyController* controller = [[BiographyController alloc] init];
        BiographyCallbackManager::instance().registerController(controller);
        return fb2k::wrapNSObject(controller);
    }

    void cleanup(service_ptr arg) override {
        BiographyController* controller = fb2k::unwrapNSObject<BiographyController>(arg);
        [controller.currentFetchToken cancel];  // Cancel any in-flight requests
        BiographyCallbackManager::instance().unregisterController(controller);
    }

    bool match_name(const char* name) override {
        return strcmp(name, "biography") == 0 ||
               strcmp(name, "Biography") == 0 ||
               strcmp(name, "artist_biography") == 0 ||
               strcmp(name, "artist-biography") == 0 ||
               strcmp(name, "Artist Biography") == 0 ||
               strcmp(name, "foo_jl_biography") == 0 ||
               strcmp(name, "jl_biography") == 0;
    }

    GUID get_guid() override {
        // {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}
        static const GUID guid = { ... };
        return guid;
    }

    fb2k::stringRef get_name() override {
        return "Artist Biography";
    }
};

FB2K_SERVICE_FACTORY(biography_ui_element);

} // anonymous namespace
```

---

## Configuration

### Preferences with Keychain Storage

```objc
@interface BiographyPreferences : NSObject

// Data sources
@property (nonatomic, assign) BOOL useLastFm;
@property (nonatomic, assign) BOOL useWikipedia;
@property (nonatomic, assign) BOOL useFanartTv;
@property (nonatomic, assign) BOOL useAudioDb;

// Display
@property (nonatomic, assign) BiographyDisplayMode displayMode;
@property (nonatomic, assign) CGFloat maxImageHeight;
@property (nonatomic, assign) BOOL showSimilarArtists;
@property (nonatomic, assign) BOOL showTags;

// Cache
@property (nonatomic, assign) NSInteger biographyTTLDays;
@property (nonatomic, assign) NSInteger imageTTLDays;
@property (nonatomic, assign) NSInteger maxCacheSizeMB;

+ (instancetype)shared;
- (void)save;
- (void)resetToDefaults;
- (void)clearCache;

// API Keys - stored in Keychain, not NSUserDefaults
- (nullable NSString *)apiKeyForService:(BiographySource)source;
- (void)setApiKey:(nullable NSString *)key forService:(BiographySource)source;

@end
```

### Keychain Storage for API Keys

```objc
// Use existing KeychainHelper from foo_jl_scrobble_mac
static NSString * const kKeychainServiceLastFm = @"foo_jl_biography.lastfm_api_key";
static NSString * const kKeychainServiceFanartTv = @"foo_jl_biography.fanart_api_key";
static NSString * const kKeychainServiceAudioDb = @"foo_jl_biography.audiodb_api_key";

- (nullable NSString *)apiKeyForService:(BiographySource)source {
    NSString *service = [self keychainServiceForSource:source];
    if (!service) return nil;
    return [KeychainHelper passwordForService:service];
}

- (void)setApiKey:(nullable NSString *)key forService:(BiographySource)source {
    NSString *service = [self keychainServiceForSource:source];
    if (!service) return;

    if (key) {
        [KeychainHelper setPassword:key forService:service];
    } else {
        [KeychainHelper deletePasswordForService:service];
    }
}
```

### Default Values

```objc
static const BOOL kDefaultUseLastFm = YES;
static const BOOL kDefaultUseWikipedia = YES;
static const BOOL kDefaultUseFanartTv = YES;
static const BOOL kDefaultUseAudioDb = YES;

static const BiographyDisplayMode kDefaultDisplayMode = BiographyDisplayModeFull;
static const CGFloat kDefaultMaxImageHeight = 300.0;
static const BOOL kDefaultShowSimilarArtists = YES;
static const BOOL kDefaultShowTags = YES;

static const NSInteger kDefaultBiographyTTLDays = 7;
static const NSInteger kDefaultImageTTLDays = 30;
static const NSInteger kDefaultMaxCacheSizeMB = 500;
```

---

## Security Considerations

### Image URL Validation

```objc
/// Validates image URL before downloading
- (BOOL)isValidImageURL:(NSURL *)url {
    // HTTPS only
    if (![url.scheme isEqualToString:@"https"]) {
        return NO;
    }

    // Allowed domains only
    NSSet *allowedDomains = [NSSet setWithArray:@[
        @"lastfm.freetls.fastly.net",
        @"assets.fanart.tv",
        @"www.theaudiodb.com",
        @"upload.wikimedia.org"
    ]];

    return [allowedDomains containsObject:url.host];
}

/// Validates downloaded image data
- (BOOL)isValidImageData:(NSData *)data response:(NSHTTPURLResponse *)response {
    // Check Content-Type header
    NSString *contentType = response.allHeaderFields[@"Content-Type"];
    if (![contentType hasPrefix:@"image/"]) {
        return NO;
    }

    // Enforce size limit (10MB max)
    if (data.length > 10 * 1024 * 1024) {
        return NO;
    }

    // Verify it's actually image data
    NSImage *image = [[NSImage alloc] initWithData:data];
    return image != nil;
}
```

### Network Reachability

```objc
// Use SCNetworkReachability for offline detection
@interface BiographyReachability : NSObject

+ (instancetype)shared;

@property (nonatomic, assign, readonly, getter=isReachable) BOOL reachable;

- (void)startMonitoring;
- (void)stopMonitoring;

// Notification posted when reachability changes
extern NSNotificationName const BiographyReachabilityChangedNotification;

@end
```

---

## Error Handling

### Error Types

```objc
extern NSString * const BiographyErrorDomain;

typedef NS_ENUM(NSInteger, BiographyErrorCode) {
    BiographyErrorNetworkUnavailable = 1001,
    BiographyErrorRateLimited = 1002,
    BiographyErrorArtistNotFound = 1003,
    BiographyErrorAPIKeyInvalid = 1004,
    BiographyErrorCacheCorrupted = 1005,
    BiographyErrorImageLoadFailed = 1006,
    BiographyErrorRequestCancelled = 1007,
    BiographyErrorInvalidResponse = 1008,
};
```

### Fallback Behavior

1. **Network Failure:**
   - Check cache for stale data (expired but available)
   - Display cached content with "Offline" indicator
   - Monitor reachability, retry when back online

2. **Artist Not Found:**
   - Try alternative spellings via Last.fm autocorrect
   - Try without featuring artists (strip "feat.", "&", etc.)
   - Display "No biography available" with search link

3. **Rate Limited:**
   - Queue request for later retry
   - Use cached data if available
   - Show subtle "Loading delayed" indicator

4. **Image Load Failed:**
   - Try next source in priority order
   - Fall back to embedded album art (via album_art_manager)
   - Show placeholder image as last resort

---

## Implementation Plan

### Phase 1: Foundation (MVP Core)

1. **Project Setup**
   - Create directory structure
   - Configure Xcode project generation
   - Set up SDK integration
   - Create service registration stubs

2. **Basic UI Element**
   - Implement `ui_element_mac` interface
   - Create `BiographyController` with state management
   - Implement all view states (empty, loading, content, error)
   - Register with layout editor

3. **Last.fm Integration**
   - Implement `LastFmBioClient` with cancellation support
   - Parse `artist.getInfo` response
   - Extract biography, images, MBID
   - Handle errors gracefully

4. **Basic Caching**
   - Implement SQLite cache with schema
   - File-based image cache
   - Basic TTL management

**Deliverable:** Working component that displays Last.fm biography and images for current artist.

### Phase 2: Multi-Source & Polish

5. **MusicBrainz Integration** (prerequisite for Fanart.tv)
   - Implement `MusicBrainzClient` with strict rate limiting
   - MBID lookup and caching
   - Proper User-Agent header

6. **Fanart.tv Integration**
   - Implement `FanartTvClient`
   - Fetch high-resolution images using MBID
   - Image type selection (thumb, background, logo)

7. **Wikipedia Fallback**
   - Implement `WikipediaClient`
   - Artist disambiguation logic
   - Extract summary and images

8. **TheAudioDB Integration**
   - Implement `AudioDbClient`
   - Additional metadata (mood, style)
   - Fallback images

9. **Cache Management**
   - Implement `BiographyCacheManager`
   - LRU eviction policy
   - Cache size monitoring

10. **Rate Limiting**
    - Reuse `RateLimiter` from foo_jl_scrobble_mac
    - Configure per-service limits
    - Request queuing

11. **Offline Support**
    - Network reachability monitoring
    - Stale-while-revalidate behavior
    - Offline UI indicator

**Deliverable:** Robust multi-source biography with intelligent fallback, caching, and offline support.

### Phase 3: UI Refinement

12. **Display Modes**
    - Implement Compact mode
    - Implement Image-only mode
    - Implement Text-only mode
    - Mode switching in preferences

13. **Similar Artists**
    - Parse similar artists from Last.fm
    - Display as clickable list using `SimilarArtistRef`
    - Switch view on click

14. **Tags/Genres Display**
    - Parse tags from Last.fm
    - Visual tag display
    - Optional tag cloud

15. **Preferences Panel**
    - Data source toggles
    - Display customization
    - Cache management UI
    - API key configuration (Keychain)

**Deliverable:** Polished component with full configuration and multiple display modes.

### Phase 4: Advanced Features

16. **Rich Text Formatting**
    - Parse HTML from biographies
    - Clickable links
    - Styled text rendering

17. **Image Gallery**
    - Multiple artist images
    - Swipe/scroll through images
    - Background image option

18. **Performance Optimization**
    - Lazy image loading
    - Background fetch on app launch
    - Prefetch for playlist artists

**Deliverable:** Feature-complete biography component with advanced capabilities.

---

## Code Reuse from Existing Components

| Module | Source | Purpose |
|--------|--------|---------|
| `RateLimiter.h/mm` | foo_jl_scrobble_mac | API rate limiting |
| `KeychainHelper.h/mm` | foo_jl_scrobble_mac | Secure API key storage |
| HTTP patterns | foo_jl_scrobble_mac/LastFmClient | NSURLSession usage |
| Callback manager | foo_jl_album_art_mac | Controller notifications |
| Image loading | foo_jl_album_art_mac/AlbumArtFetcher | NSImage from URL |

---

## Dependencies

### Required
- foobar2000 SDK 2025-03-07
- macOS 10.15+ (Catalina or later)
- Xcode 14+

### System Frameworks
- Cocoa
- SQLite3
- Security (Keychain)
- SystemConfiguration (Reachability)

### API Keys Required
- Last.fm API key (free) - https://www.last.fm/api/account/create
- Fanart.tv API key (free) - https://fanart.tv/get-an-api-key/
- TheAudioDB API key (free with registration) - https://www.theaudiodb.com/register.php

---

## Testing Strategy

### Unit Tests
- API response parsing
- Cache read/write/eviction
- Artist name normalization
- Rate limiter behavior
- Request cancellation
- BiographyData builder

### Integration Tests
- Full fetch cycle with mock server
- Cache hit/miss scenarios
- Fallback chain behavior
- Multi-source aggregation
- Offline mode transitions

### Manual Testing
- Various artist types (solo, band, classical, DJ)
- Non-ASCII artist names (Japanese, Cyrillic, etc.)
- Unicode/emoji in artist names
- Very long biographies (performance)
- Very large images (memory)
- Simultaneous rapid track changes (debounce)
- Network failure during image download
- API returning malformed JSON
- Cache corruption recovery
- Missing data scenarios
- Rate limit exhaustion

---

## References

### Documentation
- [Pre-Research Document](./research/foo_jl_biography_research.md)
- [foobar2000 SDK](https://www.foobar2000.org/SDK)
- [Last.fm API](https://www.last.fm/api/)
- [MusicBrainz API](https://musicbrainz.org/doc/MusicBrainz_API)
- [Wikipedia API](https://www.mediawiki.org/wiki/API:Main_page)
- [Fanart.tv API](https://fanarttv.docs.apiary.io/)
- [TheAudioDB API](https://www.theaudiodb.com/free_music_api)

### Reference Implementations
- [Wil-B/Biography](https://github.com/Wil-B/Biography)
- `foo_jl_scrobble_mac` - Last.fm patterns, RateLimiter, KeychainHelper
- `foo_jl_album_art_mac` - Image handling, callback manager

---

*Document Version: 2.0*
*Created: 2025-12-28*
*Updated: 2025-12-29 (Architect review incorporated)*
*Author: Claude Code*
