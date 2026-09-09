# Cloud Browser - Feature Foundation Document

**Status**: Research Complete - Ready for Implementation Planning
**Component**: foo_jl_cloud_streamer_mac (extension)
**Date**: 2025-12-31
**Last Updated**: 2026-01-03 (Review Iteration 5 - FINAL)

---

## 1. Feature Overview

### 1.1 Purpose
Add a browser panel to the Cloud Streamer component that allows users to search for tracks on SoundCloud and browse results without leaving foobar2000.

### 1.2 User Flow (Track-Centric MVP)
1. User opens Cloud Browser panel in layout (search field auto-focuses)
2. User enters search query in search field
3. User clicks Search button (or presses Enter)
4. System displays matching tracks with artist names
5. User clicks a track to add it to the active playlist (converts to internal scheme)
6. User can drag tracks directly to a specific playlist position (Phase 2)

### 1.3 Key Benefits
- **Solves HTTPS URL limitation**: Web URLs don't trigger `is_our_path`. By converting URLs in the browser before adding to playlist, we bypass this issue elegantly.
- **Discovery**: Users can explore content without leaving the player
- **Integration**: Seamless addition to playlists with proper scheme conversion

---

## 2. Prerequisites

### 2.1 SimPlaylist Integration
**Status**: Clarified

SimPlaylist uses pasteboard type `com.foobar2000.simplaylist.rows` with archived row indices - NOT URLs. External drag-drop TO SimPlaylist requires investigation.

**MVP Decision**: For MVP, use `playlist_manager::activeplaylist_add_items()` SDK call directly instead of drag-drop. This bypasses SimPlaylist pasteboard complexity entirely.

**Phase 2 Research**: If drag-drop is desired later:
1. Investigate if SimPlaylist registers as a drop target for external URLs
2. Check if foobar2000 SDK provides a standard URL drop format
3. Consider extending SimPlaylist to accept URL strings

### 2.2 SDK Verification
**Status**: Verified (based on Queue Manager implementation patterns)

| API | Status | Notes |
|-----|--------|-------|
| `ui_element_mac` service factory | Verified | Used by Queue Manager |
| `fb2k::wrapNSObject()` | Verified | Used by Queue Manager |
| `playlist_manager::activeplaylist_add_items()` | Verified | Standard SDK API |
| `metadb::get()->handle_create()` | Verified | Standard SDK API |
| `playback_control::play_or_pause()` | Verified | Standard SDK API |

---

## 3. Research Findings

### 3.1 yt-dlp Capabilities

#### SoundCloud - WORKING
```bash
# Search for tracks (hardcoded limit: 50 results)
yt-dlp --flat-playlist -J "scsearch50:query"

# Returns JSON with "entries" array:
{
  "_type": "playlist",
  "entries": [
    {
      "title": "Track Name",
      "id": "12345678",
      "url": "https://api.soundcloud.com/tracks/...",
      "webpage_url": "https://soundcloud.com/artist/track-name",
      "uploader": "Artist Name",
      "duration": 222.844,
      "_type": "url"
    },
    ...
  ]
}
```

**Key Finding**: `scsearch` returns tracks, not artists. MVP will be track-centric.
**Result Limit**: Hardcoded to 50 via `scsearch50:` prefix in yt-dlp command.

#### Mixcloud - BROKEN (as of 2025-12)
- yt-dlp returns empty results for user pages
- 403 Forbidden errors reported in GitHub issues
- Search functionality not supported

**Implication**: Start with SoundCloud only. Add Mixcloud later when/if yt-dlp support is fixed.

### 3.2 foobar2000 SDK Findings

#### UI Element Registration
```cpp
// WARNING: PLACEHOLDER GUID - DO NOT USE AS-IS
// Generate unique GUID with: uuidgen | awk '{print tolower($0)}'
// Format: { 0xXXXXXXXX, 0xXXXX, 0xXXXX, { 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX, 0xXX } }
static constexpr GUID g_guid_cloud_browser = { /* GENERATE NEW GUID */ };

class cloud_browser_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        @autoreleasepool {
            CloudBrowserController* controller = [[CloudBrowserController alloc] init];
            return fb2k::wrapNSObject(controller);
        }
    }

    bool match_name(const char* name) override {
        return strcmp(name, "Cloud Browser") == 0 ||
               strcmp(name, "cloud_browser") == 0;
    }

    fb2k::stringRef get_name() override {
        return fb2k::makeString("Cloud Browser");
    }

    GUID get_guid() override { return g_guid_cloud_browser; }
};

FB2K_SERVICE_FACTORY(cloud_browser_ui_element);
```

#### Playlist Operations
```cpp
// Add item to active playlist at end
playlist_manager::get()->activeplaylist_add_items(data, selection);

// Start playback on newly added item
playback_control::get()->play_or_pause();
```

#### URL Scheme Conversion (existing)
```cpp
// URLUtils::webURLToInternalScheme() already exists
// "https://soundcloud.com/artist/track" -> "soundcloud://soundcloud.com/artist/track"
```

### 3.3 Drag-and-Drop Pattern (Phase 2)

**Note**: Drag-drop is Phase 2. MVP uses SDK playlist API directly.

```objc
// Custom pasteboard type for our items
static NSPasteboardType const CloudBrowserPasteboardType =
    @"com.foobar2000.cloud-browser.tracks";

// Register in setupDragAndDrop
[_tableView registerForDraggedTypes:@[CloudBrowserPasteboardType]];
[_tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
```

---

## 4. UI Design

### 4.1 Layout Structure

```
+----------------------------------------------------------+
| [Search: ________________________________] [Search]       |
+----------------------------------------------------------+
|  Track 1 Title - Artist Name                       3:45   |
|  Track 2 Title - Artist Name                       5:12   |
|  Track 3 Title - Artist Name                      62:30   |
|  ...                                                      |
+----------------------------------------------------------+
| Status: 42 tracks found                                   |
+----------------------------------------------------------+
```

**Layout Constraints**:
- Minimum panel width: 280px
- Track title: flexible width, truncate with ellipsis
- Duration column: fixed 60px
- Table row height: 24px
- Resizable: table fills available space

**Styling**:
- Empty state text: `fb2k_ui::secondaryTextColor()` for dark mode compatibility
- Status bar: `fb2k_ui::secondaryTextColor()`
- Track list: standard table styling from `shared/UIStyles.h`

**Initial Focus**: Search field receives focus automatically when panel is first shown.

**Status Bar**: Always visible (fixed height). Shows result count after search, "Searching..." during search, or error messages. Empty initially (no text).

### 4.2 View States

| State | Description | UI |
|-------|-------------|-----|
| **Empty** | Initial state | "Search for tracks on SoundCloud" centered, secondary color |
| **Searching** | Query in progress | Spinner + "Searching..." in status bar |
| **Results** | Tracks found | List of tracks with artist names |
| **No Results** | Empty search result | "No tracks found for 'query'" centered |
| **Error** | Search/load failed | Error message + Retry button (see 4.7) |

### 4.3 Mouse Interactions

| Action | Result |
|--------|--------|
| Click track | Add to active playlist (at end), convert to internal scheme |
| Double-click track | Add to playlist, wait for completion, THEN start playback |
| Drag track | (Phase 2) Drag to playlist at specific position |
| Enter in search field | Trigger search (if non-empty query) |

**Double-Click Sequence**:
1. Call `activeplaylist_add_items()` synchronously
2. Wait for add to complete (returns immediately in practice)
3. Call `playback_control::play_or_pause()` to start playback

### 4.4 Keyboard Navigation

| Key | Action |
|-----|--------|
| Up/Down | Move selection in track list |
| Enter (in list) | Add selected track to playlist |
| Cmd+Enter | Add and start playback |
| Cmd+Shift+Enter | Force refresh (bypass cache) |
| Tab | Move focus between search field and results |
| Escape | Cancel search / clear selection |

**Empty Query Handling**: If user presses Enter with empty/whitespace-only search field, do nothing (no search triggered, no error shown).

**Search Field Limit**: Maximum 256 characters. Enforced via NSTextField formatter.

**Selection Behavior**: After new search completes, selection resets to first track (if results exist) or clears (if no results).

### 4.5 Accessibility

```objc
// Panel accessibility
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityGroupRole;
}

- (NSString*)accessibilityLabel {
    return @"Cloud Browser";
}

// Track list accessibility
- NSAccessibilityTableRole for the results table
- Each row announces: "Track: [title] by [artist], [duration]"
- Search field: standard NSTextField accessibility
```

### 4.6 Multiple Panel Instances

If user opens multiple Cloud Browser panels:
- All panels share the `CloudSearchService` singleton
- All panels display identical search results
- Selection state is independent per panel (panel A can select track 3 while panel B selects track 7)

### 4.7 Error States

| Error Type | User Message | Recovery Action |
|------------|--------------|-----------------|
| Network error | "Unable to reach SoundCloud" | Retry button |
| Rate limited | "Too many requests. Please wait." | Auto-retry after delay |
| No results | "No tracks found for 'query'" | Modify search |
| yt-dlp missing | "Search unavailable: yt-dlp not found" | Installation instructions |
| Parse error | "Unable to parse results" | Retry button |
| Timeout | "Search timed out" | Retry button |
| No active playlist | "No active playlist" | User must select a playlist |
| Playlist add failed | "Unable to add track to playlist" | Retry button |

---

## 5. Data Structures

### 5.1 Search Result Models

```objc
// Track result (MVP - track-centric)
@interface CloudTrack : NSObject
@property (nonatomic, strong) NSString* title;
@property (nonatomic, strong) NSString* artist;     // From 'uploader' field
@property (nonatomic, strong) NSString* webURL;     // Web URL for display
@property (nonatomic, strong) NSString* internalURL; // Internal scheme for playlist
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong) NSString* trackId;    // SoundCloud track ID
@end

// Artist model (Phase 4 - artist browsing, not MVP)
@interface CloudArtist : NSObject
@property (nonatomic, strong) NSString* name;
@property (nonatomic, strong) NSString* username;   // URL-safe name
@property (nonatomic, strong) NSString* profileURL;
@property (nonatomic) NSInteger trackCount;
@end
```

### 5.2 Error Handling

Error handling extends existing `JLCloudError` to maintain consistency:

```cpp
// In JLCloudError.h (existing enum class, add new values)
enum class JLCloudError {
    // ... existing values ...

    // Search-specific errors (new)
    SearchNoResults = 100,      // Empty result set
    SearchCancelled = 101,      // User cancelled search
    SearchTimeout = 102,        // Search took too long
    PlaylistAddFailed = 103,    // Failed to add to playlist
    NoActivePlaylist = 104      // No playlist is active
};
```

**Error-to-UI Mapping**:
| JLCloudError | User Message |
|--------------|--------------|
| `NetworkError` | "Unable to reach SoundCloud" |
| `RateLimited` | "Too many requests. Please wait." |
| `YtDlpNotFound` | "Search unavailable: yt-dlp not found" |
| `ParseError` | "Unable to parse results" |
| `SearchNoResults` | "No tracks found for 'query'" |
| `SearchCancelled` | (no UI - silently handled) |
| `SearchTimeout` | "Search timed out" |
| `PlaylistAddFailed` | "Unable to add track to playlist" |
| `NoActivePlaylist` | "No active playlist" |

### 5.3 Search Service

```objc
@interface CloudSearchService : NSObject

+ (instancetype)shared;

// Search for tracks - ASYNCHRONOUS
// Completion always dispatched to main queue
// If search in progress, cancels previous and starts new (non-blocking)
- (void)searchTracks:(NSString*)query
          bypassCache:(BOOL)bypassCache
          completion:(void(^)(NSArray<CloudTrack*>* results, NSError* error))completion;

// Cancel ongoing search (thread-safe, can be called from any thread)
- (void)cancelSearch;

// Check if search is in progress (KVO-observable, main thread only)
@property (nonatomic, readonly) BOOL isSearching;

@end
```

**Search State Machine**:
```
[Idle] --searchTracks:--> [Searching] --completion--> [Idle]
                              |
                              +--(new searchTracks: call)
                              |
                              v
                      [Cancel in-flight, immediately start new search]
                      (Does NOT wait for cancel to complete)
                              |
                              v
                         [Searching]
```

Note: Cancellation is fire-and-forget. A new search immediately starts while the previous process is terminating in the background. The old completion block is never called (marked cancelled atomically).

---

## 6. Technical Specifications

### 6.1 Threading Model

```
Main Thread:
  - CloudBrowserController (all UI)
  - SDK playlist operations (required by SDK)
  - isSearching property access
  - Completion block execution

Background Queue (serial, owned by CloudSearchService):
  - yt-dlp NSTask execution
  - JSON parsing
  - Cache read/write

Synchronization:
  - @synchronized(self) for _currentTask access
  - Completion blocks captured weakly to avoid retain cycles
  - dispatch_async(dispatch_get_main_queue()) for all completion delivery

Cancellation:
  - cancelSearch is thread-safe (uses @synchronized)
  - Sets atomic flag checked before completion dispatch
  - If cancelled during execution, completion is NOT called (silently dropped)
```

### 6.2 YtDlpWrapper Search Extension

**New Operation Type**:
```cpp
enum class YtDlpOperation {
    ExtractStreamURL,
    ExtractMetadata,
    ValidateBinary,
    Search  // NEW: flat-playlist search
};
```

**New Result Structure**:
```cpp
struct YtDlpSearchResult {
    std::vector<YtDlpTrackInfo> entries;
    bool success;
    JLCloudError error;
};

struct YtDlpTrackInfo {
    std::string title;
    std::string uploader;
    std::string webpageUrl;
    std::string trackId;
    double duration;  // seconds
};
```

**Search Command**:
```cpp
// Build search command
std::vector<std::string> args = {
    "--flat-playlist",
    "-J",
    "scsearch50:" + query  // Hardcoded 50 result limit
};

// Timeout: 30 seconds (search may be slower than single extraction)
```

**JSON Parsing**:
```cpp
// Search returns object with "entries" array (not single object)
// Parse entries[].{title, uploader, webpage_url, id, duration}
```

### 6.3 Process Lifecycle

**yt-dlp Process Management**:

```objc
// NSTask setup with stderr capture for rate limit detection
- (void)setupTask {
    _currentTask = [[NSTask alloc] init];
    _currentTask.launchPath = _ytDlpPath;
    _currentTask.arguments = _arguments;

    // Capture stdout for JSON
    NSPipe* stdoutPipe = [NSPipe pipe];
    _currentTask.standardOutput = stdoutPipe;

    // Capture stderr for error detection (rate limiting, etc.)
    NSPipe* stderrPipe = [NSPipe pipe];
    _currentTask.standardError = stderrPipe;
}

- (void)cancelSearch {
    @synchronized(self) {
        _isCancelled = YES;
        if (_currentTask && _currentTask.isRunning) {
            [_currentTask terminate];  // SIGTERM

            // Schedule force kill after 2 seconds if still running
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                          _backgroundQueue, ^{
                @synchronized(self) {
                    if (_currentTask && _currentTask.isRunning) {
                        kill(_currentTask.processIdentifier, SIGKILL);
                    }
                }
            });
        }
    }
}
```

**Behavior Rules**:
- New search cancels any in-flight search (non-blocking)
- Panel dealloc cancels active search
- SIGTERM used for graceful termination
- SIGKILL fallback after 2 second timeout
- Cancelled search's completion block is never called

### 6.4 Rate Limiting Strategy

```objc
// Debounce Configuration (implemented in CloudBrowserController)
static const NSTimeInterval kSearchDebounceInterval = 0.5;  // 500ms

// Backoff Configuration
static const NSTimeInterval kRateLimitBackoffBase = 2.0;    // Start at 2s
static const NSTimeInterval kRateLimitBackoffMax = 30.0;    // Cap at 30s
static const NSInteger kRateLimitMaxRetries = 3;
```

**Debounce Implementation**: CloudBrowserController owns debouncing logic. Uses NSTimer to delay search service call until 500ms after last keystroke.

**Detection**: yt-dlp exit code + stderr (captured via NSPipe) contains "429" or "rate limit"

### 6.5 Cache Strategy

```objc
@interface CloudSearchCache : NSObject

// Cache key: normalized query (lowercase, collapse whitespace, trim)
// TTL: 10 minutes
// Max entries: 50 (LRU eviction)
// Memory estimate: ~50 queries * 50 tracks * 200 bytes = ~500KB max

- (NSArray<CloudTrack*>*)cachedResultsForQuery:(NSString*)query;
- (void)cacheResults:(NSArray<CloudTrack*>*)results forQuery:(NSString*)query;
- (void)invalidateQuery:(NSString*)query;  // Clear single query
- (void)invalidateAll;                      // Clear all cached results

// Query normalization: "  Artist  Name  " -> "artist name"
+ (NSString*)normalizeQuery:(NSString*)query;

@end
```

**Cache Rules**:
- Cache only successful results (not errors)
- Rate limit errors do NOT clear cache (serve stale while backing off)
- `Cmd+Shift+Enter` bypasses cache for forced refresh
- No persistence (memory-only, cleared on quit)
- No memory warning handling (500KB is negligible)

---

## 7. Implementation Architecture

### 7.1 New Files Required

Aligned with existing project structure:

```
src/
├── Core/
│   └── CloudTrack.h/.mm           # Track model
├── Services/
│   ├── CloudSearchService.h/.mm   # yt-dlp search wrapper
│   └── CloudSearchCache.h/.mm     # Result caching
└── UI/
    └── CloudBrowserController.h/.mm  # Main NSViewController
```

### 7.2 Integration Points

1. **Main.mm**: Register new `ui_element_mac` service
2. **YtDlpWrapper**: Add `Search` operation type and `YtDlpSearchResult` struct
3. **JLCloudError**: Add search-specific error codes
4. **URLUtils**: Reuse existing `webURLToInternalScheme()`

### 7.3 Dependencies on Existing Code

| Module | Usage |
|--------|-------|
| `YtDlpWrapper` | Execute yt-dlp with search parameters |
| `URLUtils` | Convert web URLs to internal scheme |
| `JLCloudError` | Error codes and mapping |
| `shared/UIStyles.h` | Consistent styling with other components |

---

## 8. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Mixcloud broken | No Mixcloud support | Start with SoundCloud only, add Mixcloud when fixed |
| yt-dlp rate limiting | Slow/failed searches | Debounce (500ms), cache (10min TTL), exponential backoff |
| SimPlaylist drag-drop | Phase 2 complexity | MVP uses SDK API directly, drag-drop deferred |
| Large result sets | UI lag, memory | Hardcoded limit: 50 results via scsearch50 |
| yt-dlp not installed | Feature unusable | Clear error message with installation instructions |

---

## 9. Implementation Phases

### Phase 1: MVP
- [ ] Generate unique GUID for ui_element (uuidgen)
- [ ] CloudTrack model in Core/
- [ ] CloudSearchService with async search
- [ ] YtDlpWrapper Search operation type
- [ ] CloudBrowserController with table view
- [ ] Click to add track to active playlist
- [ ] Basic status bar and error states
- [ ] Keyboard navigation
- [ ] Accessibility implementation
- [ ] Debouncing in controller

### Phase 2: Drag-Drop
- [ ] Research SimPlaylist drop acceptance
- [ ] Implement drag source from browser
- [ ] Test with SimPlaylist drop target
- [ ] Visual drag feedback

### Phase 3: Polish
- [ ] Search result caching (CloudSearchCache)
- [ ] Rate limiting with backoff
- [ ] Cache bypass (Cmd+Shift+Enter)
- [ ] Empty states refinement

### Phase 4: Artist Browsing (Future)
- [ ] Click artist name to browse their tracks
- [ ] Artist header with back navigation
- [ ] Thumbnail loading (if feasible)

### Phase 5: Mixcloud (Future)
- [ ] Monitor yt-dlp for Mixcloud fix
- [ ] Add Mixcloud service option when available

---

## 10. Resolved Questions

1. **Multiple Panel Instances**: Panels share `CloudSearchService` singleton and display identical results. Selection state is independent per panel.

2. **Search History**: If implemented (Phase 3 optional), use `fb2k::configStore` for persistence.

3. **Localization**: Not in scope for any phase. All strings are English.

4. **Search Field Focus**: Auto-focus on panel open.

5. **Empty Query**: No action taken, no error shown.

6. **Selection After Search**: Reset to first track (or clear if no results).

---

## 11. References

- [yt-dlp SoundCloud extractor](https://github.com/yt-dlp/yt-dlp/issues/1871)
- [Queue Manager implementation](../foo_jl_queue_manager_mac/) - Drag-drop patterns
- [Cloud Streamer FOUNDATION.md](./FOUNDATION.md) - Existing architecture
- SDK `ui_element_mac.h` - UI panel registration
- SDK `playlist.h` - Playlist operations

---

## 12. Sources from Research

- [yt-dlp GitHub Repository](https://github.com/yt-dlp/yt-dlp)
- [SoundCloud flat-playlist metadata issue](https://github.com/yt-dlp/yt-dlp/issues/1871)
- [Mixcloud 403 Forbidden issue](https://github.com/yt-dlp/yt-dlp/issues/7444)
- [Mixcloud JSON parse failures](https://github.com/yt-dlp/yt-dlp/issues/8106)
