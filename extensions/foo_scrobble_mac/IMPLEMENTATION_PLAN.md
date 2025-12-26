# foo_scrobble_mac Implementation Plan

## Executive Summary

This document outlines the implementation plan for `foo_scrobble_mac`, a Last.fm scrobbling extension for foobar2000 on macOS. The implementation draws from:
- **3 working foobar2000 macOS extensions** (simplaylist, plorg, waveformseekbar) for proven SDK patterns
- **LastScrobbler app** for browser-based Last.fm authentication
- **Windows foo_scrobble** for core scrobbling logic and state machines

---

## 1. Architecture Overview

### 1.1 High-Level Components

```
foo_scrobble_mac/
├── Core/                     # Platform-agnostic C++ logic
│   ├── ScrobbleConfig.h/mm   # Configuration with fb2k::configStore
│   ├── ScrobbleTrack.h       # Track data model
│   ├── ScrobbleCache.h/mm    # Failed scrobble persistence
│   ├── ScrobbleRules.h       # Eligibility rules (timing, metadata)
│   └── MD5.h/mm              # MD5 hashing for API signatures
│
├── LastFm/                   # Last.fm API layer
│   ├── LastFmClient.h/mm     # HTTP client, request signing, responses
│   ├── LastFmAuth.h/mm       # Browser-based auth flow (from LastScrobbler)
│   ├── LastFmSession.h       # Session model
│   └── LastFmErrors.h        # Error codes and handling
│
├── Services/                 # Scrobbling orchestration
│   ├── ScrobbleService.h/mm  # Main service (state machine, queue)
│   ├── NowPlayingService.h/mm # Now Playing notifications
│   └── RateLimiter.h/mm      # Token bucket rate limiter
│
├── UI/                       # Cocoa user interface
│   ├── ScrobblePreferencesController.h/mm  # Preferences page
│   └── AuthStatusView.h/mm   # Authentication status indicator
│
├── Integration/              # foobar2000 SDK hooks
│   ├── Main.mm               # Component registration
│   ├── PlaybackCallbacks.mm  # play_callback implementation
│   └── InitQuit.mm           # Startup/shutdown handling
│
├── Resources/
│   └── Info.plist            # Bundle metadata
│
└── fb2k_sdk.h                # SDK configuration header
```

### 1.2 Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        foobar2000 SDK                                │
│  ┌──────────────────┐     ┌──────────────────┐                      │
│  │ play_callback    │     │ playback_control │                      │
│  │ (track events)   │     │ (position query) │                      │
│  └────────┬─────────┘     └────────┬─────────┘                      │
└───────────┼────────────────────────┼────────────────────────────────┘
            │                        │
            ▼                        ▼
┌───────────────────────────────────────────────────────────────────┐
│                     PlaybackCallbacks                              │
│  - Accumulates playback time across seeks                          │
│  - Validates against ScrobbleRules                                 │
│  - Dispatches to main thread                                       │
└───────────────────────────┬───────────────────────────────────────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
   ┌────────────────┐ ┌────────────────┐ ┌────────────────┐
   │ NowPlayingServ │ │ ScrobbleService│ │ ScrobbleCache  │
   │ (3s threshold) │ │ (50%/4min)     │ │ (persistence)  │
   └───────┬────────┘ └───────┬────────┘ └───────┬────────┘
           │                  │                  │
           └──────────────────┼──────────────────┘
                              ▼
                    ┌──────────────────┐
                    │   LastFmClient   │
                    │ - Request signing│
                    │ - Rate limiting  │
                    │ - Error handling │
                    └────────┬─────────┘
                             │
                             ▼
                    ┌──────────────────┐
                    │   Last.fm API    │
                    │ ws.audioscrobbler│
                    │     .com/2.0/    │
                    └──────────────────┘
```

---

## 2. Core Components Specification

### 2.1 ScrobbleTrack Model

```cpp
// Core/ScrobbleTrack.h
struct ScrobbleTrack {
    std::string artist;           // Required
    std::string title;            // Required
    std::string album;            // Optional
    std::string albumArtist;      // Optional
    std::string trackNumber;      // Optional
    std::string mbTrackId;        // MusicBrainz ID (optional)
    double duration;              // Seconds
    int64_t timestamp;            // Unix epoch when playback started

    bool isValid() const {
        return !artist.empty() && !title.empty();
    }
};
```

### 2.2 ScrobbleRules

From Windows foo_scrobble analysis:

```cpp
// Core/ScrobbleRules.h
namespace ScrobbleRules {
    // Track must be at least 30 seconds
    constexpr double kMinTrackLength = 30.0;

    // Scrobble after 50% of duration OR 4 minutes, whichever is first
    constexpr double kMaxRequiredPlaytime = 240.0;  // 4 minutes
    constexpr double kScrobblePercentage = 0.5;     // 50%

    // Now Playing sent after 3 seconds
    constexpr double kNowPlayingThreshold = 3.0;

    inline double requiredPlaytime(double duration) {
        return std::min(duration * kScrobblePercentage, kMaxRequiredPlaytime);
    }

    inline bool isEligibleForScrobble(double duration, double playedTime) {
        if (duration < kMinTrackLength) return false;
        return playedTime >= requiredPlaytime(duration);
    }
}
```

### 2.3 ScrobbleConfig

Using `fb2k::configStore` (NOT cfg_var - doesn't persist on macOS):

```cpp
// Core/ScrobbleConfig.h
namespace scrobble_config {

static const char* const kPrefix = "foo_scrobble.";

// Configuration keys
static const char* const kSessionKey = "session_key";
static const char* const kUsername = "username";
static const char* const kEnableScrobbling = "enable_scrobbling";
static const char* const kEnableNowPlaying = "enable_now_playing";
static const char* const kSubmitOnlyInLibrary = "submit_only_library";
static const char* const kSubmitDynamicSources = "submit_dynamic";

// Titleformat mappings (for advanced users)
static const char* const kArtistFormat = "artist_format";
static const char* const kTitleFormat = "title_format";
static const char* const kAlbumFormat = "album_format";
static const char* const kSkipFormat = "skip_format";

// Defaults
static const char* const kDefaultArtistFormat = "[%artist%]";
static const char* const kDefaultTitleFormat = "[%title%]";
static const char* const kDefaultAlbumFormat = "[%album%]";

// Helper functions (inline, with try/catch)
inline std::string getConfigString(const char* key, const char* defaultVal);
inline void setConfigString(const char* key, const std::string& value);
inline bool getConfigBool(const char* key, bool defaultVal);
inline void setConfigBool(const char* key, bool value);

} // namespace scrobble_config
```

### 2.4 ScrobbleCache

Persistent storage for failed scrobbles:

```cpp
// Core/ScrobbleCache.h
class ScrobbleCache {
public:
    static ScrobbleCache& instance();

    void addPending(const ScrobbleTrack& track);
    std::vector<ScrobbleTrack> getPending(size_t maxCount = 50);
    void removePending(const std::vector<ScrobbleTrack>& tracks);
    void markFailed(const ScrobbleTrack& track);

    size_t pendingCount() const;

    void loadFromDisk();
    void saveToDisk();

private:
    std::vector<ScrobbleTrack> m_pending;
    std::mutex m_mutex;
    NSString* cacheFilePath();  // ~/Library/foobar2000-v2/scrobble_cache.json
};
```

---

## 3. Last.fm API Layer

### 3.1 API Constants

```cpp
// LastFm/LastFmClient.h
namespace LastFm {
    static const char* const kBaseUrl = "https://ws.audioscrobbler.com/2.0/";
    static const char* const kAuthUrl = "https://www.last.fm/api/auth/";

    // API credentials (from LastScrobbler - obtain your own for production)
    static const char* const kApiKey = "YOUR_API_KEY";
    static const char* const kApiSecret = "YOUR_API_SECRET";

    // API methods
    static const char* const kMethodGetToken = "auth.getToken";
    static const char* const kMethodGetSession = "auth.getSession";
    static const char* const kMethodScrobble = "track.scrobble";
    static const char* const kMethodNowPlaying = "track.updateNowPlaying";
    static const char* const kMethodGetUserInfo = "user.getInfo";
}
```

### 3.2 LastFmClient

```objc
// LastFm/LastFmClient.h
@interface LastFmClient : NSObject

+ (instancetype)shared;

// Authentication
- (void)requestAuthTokenWithCompletion:(void(^)(NSString* token, NSError* error))completion;
- (void)requestSessionWithToken:(NSString*)token
                     completion:(void(^)(LastFmSession* session, NSError* error))completion;
- (NSURL*)authorizationURLWithToken:(NSString*)token;

// Scrobbling
- (void)sendNowPlaying:(ScrobbleTrack)track
            completion:(void(^)(BOOL success, NSError* error))completion;

- (void)scrobbleTracks:(NSArray<ScrobbleTrack*>*)tracks
            completion:(void(^)(NSInteger accepted, NSInteger ignored, NSError* error))completion;

// Validation
- (void)validateSessionWithCompletion:(void(^)(BOOL valid, NSError* error))completion;

@property (nonatomic, strong, nullable) LastFmSession* session;

@end
```

### 3.3 Request Signing

From LastScrobbler analysis - MD5 signature required:

```objc
// LastFm/LastFmClient.mm
- (NSString*)signatureForParameters:(NSDictionary<NSString*, NSString*>*)params {
    // Sort params alphabetically, excluding "format" and "callback"
    NSMutableArray* sortedKeys = [[params.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    [sortedKeys removeObject:@"format"];
    [sortedKeys removeObject:@"callback"];

    NSMutableString* signatureBase = [NSMutableString string];
    for (NSString* key in sortedKeys) {
        [signatureBase appendString:key];
        [signatureBase appendString:params[key]];
    }
    [signatureBase appendString:@(LastFm::kApiSecret)];

    return [self md5:signatureBase];
}

- (NSString*)md5:(NSString*)input {
    const char* cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);

    NSMutableString* output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}
```

### 3.4 Error Codes

```objc
// LastFm/LastFmErrors.h
typedef NS_ENUM(NSInteger, LastFmErrorCode) {
    LastFmErrorInvalidService = 2,
    LastFmErrorInvalidMethod = 3,
    LastFmErrorAuthenticationFailed = 4,
    LastFmErrorInvalidParameters = 6,
    LastFmErrorOperationFailed = 8,
    LastFmErrorInvalidSessionKey = 9,
    LastFmErrorInvalidApiKey = 10,
    LastFmErrorServiceOffline = 11,
    LastFmErrorNotAuthorized = 14,      // Token not yet authorized
    LastFmErrorSuspendedApiKey = 26,
    LastFmErrorRateLimitExceeded = 29,
};

// Errors requiring re-authentication
inline bool requiresReauth(LastFmErrorCode code) {
    return code == LastFmErrorAuthenticationFailed ||
           code == LastFmErrorInvalidSessionKey;
}
```

---

## 4. Authentication Flow

### 4.1 Browser-Based Authentication (from LastScrobbler)

```objc
// LastFm/LastFmAuth.h
typedef NS_ENUM(NSInteger, LastFmAuthState) {
    LastFmAuthStateNotAuthenticated,
    LastFmAuthStateRequestingToken,
    LastFmAuthStateWaitingForApproval,
    LastFmAuthStateExchangingToken,
    LastFmAuthStateAuthenticated,
    LastFmAuthStateError
};

@interface LastFmAuth : NSObject

@property (nonatomic, readonly) LastFmAuthState state;
@property (nonatomic, strong, nullable) LastFmSession* session;
@property (nonatomic, copy, nullable) NSString* errorMessage;

- (void)startAuthenticationWithCompletion:(void(^)(BOOL success, NSError* error))completion;
- (void)cancelAuthentication;
- (void)signOut;
- (BOOL)isAuthenticated;

@end
```

### 4.2 Authentication State Machine

```
┌─────────────────────┐
│  NotAuthenticated   │◄────────────────────────────────────────┐
└──────────┬──────────┘                                         │
           │ startAuthentication()                              │
           ▼                                                    │
┌─────────────────────┐                                         │
│  RequestingToken    │──────► auth.getToken API call           │
└──────────┬──────────┘                                         │
           │ token received                                     │
           ▼                                                    │
┌─────────────────────┐                                         │
│ WaitingForApproval  │──────► Open browser to Last.fm          │
│                     │        Poll auth.getSession every 3s    │
│                     │        (max 10 minutes)                 │
└──────────┬──────────┘                                         │
           │ user approved (error 14 → session)                 │
           ▼                                                    │
┌─────────────────────┐                                         │
│  ExchangingToken    │──────► auth.getSession succeeds         │
└──────────┬──────────┘                                         │
           │ session key received                               │
           ▼                                                    │
┌─────────────────────┐                                         │
│   Authenticated     │◄──────────────────────────┐             │
│                     │                           │             │
│  - Session stored   │     validateSession()     │             │
│  - Ready to scrobble│     periodic check ───────┘             │
└──────────┬──────────┘                                         │
           │                                                    │
           │ signOut() OR session invalid (error 4/9)           │
           └────────────────────────────────────────────────────┘
```

### 4.3 Polling Implementation

```objc
// LastFm/LastFmAuth.mm
- (void)startPollingForApproval:(NSString*)token {
    __weak typeof(self) weakSelf = self;

    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                 repeats:YES
                                                   block:^(NSTimer* timer) {
        [weakSelf checkTokenApproval:token];
    }];

    // Timeout after 10 minutes
    _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:600.0
                                                    repeats:NO
                                                      block:^(NSTimer* timer) {
        [weakSelf handleAuthTimeout];
    }];
}

- (void)checkTokenApproval:(NSString*)token {
    [[LastFmClient shared] requestSessionWithToken:token
                                        completion:^(LastFmSession* session, NSError* error) {
        if (session) {
            [self handleAuthSuccess:session];
        } else if (error.code == LastFmErrorNotAuthorized) {
            // Keep polling - user hasn't approved yet
        } else {
            [self handleAuthError:error];
        }
    }];
}
```

---

## 5. Scrobble Service

### 5.1 Service State Machine (from Windows foo_scrobble)

```cpp
// Services/ScrobbleService.h
enum class ScrobbleServiceState {
    UnauthenticatedIdle,    // No session key - cannot scrobble
    AuthenticatedIdle,      // Ready, no pending work
    AwaitingResponse,       // Request in flight
    Sleeping,               // Rate limited - waiting to retry
    Suspended,              // API key issue - paused
    ShuttingDown,           // Graceful shutdown in progress
    ShutDown                // Component unloaded
};
```

### 5.2 ScrobbleService Interface

```objc
// Services/ScrobbleService.h
@interface ScrobbleService : NSObject

+ (instancetype)shared;

- (void)start;
- (void)stop;

- (void)queueTrack:(ScrobbleTrack)track;
- (void)processQueue;

@property (nonatomic, readonly) ScrobbleServiceState state;
@property (nonatomic, readonly) NSUInteger pendingCount;

// Notifications
extern NSNotificationName const ScrobbleServiceStateDidChangeNotification;
extern NSNotificationName const ScrobbleServiceDidScrobbleNotification;

@end
```

### 5.3 Rate Limiter

Token bucket algorithm (from Windows foo_scrobble):

```objc
// Services/RateLimiter.h
@interface RateLimiter : NSObject

- (instancetype)initWithTokensPerSecond:(double)rate
                          burstCapacity:(NSInteger)capacity;

- (BOOL)tryAcquire;
- (NSTimeInterval)waitTimeForNextToken;

@end

// Implementation
@implementation RateLimiter {
    double _tokensPerSecond;
    NSInteger _burstCapacity;
    double _availableTokens;
    CFAbsoluteTime _lastRefillTime;
}

- (instancetype)initWithTokensPerSecond:(double)rate burstCapacity:(NSInteger)capacity {
    self = [super init];
    if (self) {
        _tokensPerSecond = rate;              // 5.0
        _burstCapacity = capacity;            // 750 (5min * 5tps / 2)
        _availableTokens = _burstCapacity;
        _lastRefillTime = CFAbsoluteTimeGetCurrent();
    }
    return self;
}

- (BOOL)tryAcquire {
    [self refillTokens];
    if (_availableTokens >= 1.0) {
        _availableTokens -= 1.0;
        return YES;
    }
    return NO;
}

@end
```

---

## 6. SDK Integration

### 6.1 Main.mm - Component Registration

```objc
// Integration/Main.mm
#include "../fb2k_sdk.h"
#import "../UI/ScrobblePreferencesController.h"

DECLARE_COMPONENT_VERSION(
    "Last.fm Scrobbler",
    "1.0.0",
    "Scrobbles played tracks to Last.fm.\n\n"
    "Features:\n"
    "- Automatic scrobbling after 50% or 4 minutes played\n"
    "- Now Playing notifications\n"
    "- Browser-based Last.fm authentication\n"
    "- Offline queue with automatic retry\n\n"
    "Based on foo_scrobble for Windows by gix."
);

VALIDATE_COMPONENT_FILENAME("foo_scrobble_mac.component");

// Preferences page registration
namespace {
    static const GUID g_guid_prefs =
        {0x12345678, 0x1234, 0x1234, {0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0}};

    class scrobble_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            @autoreleasepool {
                return fb2k::wrapNSObject(
                    [[ScrobblePreferencesController alloc] init]
                );
            }
        }

        const char* get_name() override {
            return "Last.fm Scrobbler";
        }

        GUID get_guid() override {
            return g_guid_prefs;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_tools;
        }
    };

    preferences_page_factory_t<scrobble_preferences_page> g_prefs_factory;
}
```

### 6.2 PlaybackCallbacks

```objc
// Integration/PlaybackCallbacks.mm
#include "../fb2k_sdk.h"
#import "../Services/ScrobbleService.h"
#import "../Services/NowPlayingService.h"

namespace {

class ScrobblePlayCallback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_seek |
               flag_on_playback_time |
               flag_on_playback_edited |
               flag_on_playback_dynamic_info_track;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        @autoreleasepool {
            try {
                // Reset accumulated time
                m_accumulatedTime = 0;
                m_lastPositionUpdate = 0;
                m_currentTrack = extractTrackInfo(track);
                m_trackStartTime = (int64_t)[[NSDate date] timeIntervalSince1970];

                if (m_currentTrack.isValid()) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NowPlayingService shared] trackStarted:m_currentTrack];
                    });
                }
            } catch (...) {
                FB2K_console_formatter() << "[Scrobble] Exception in on_playback_new_track";
            }
        }
    }

    void on_playback_time(double time) override {
        @autoreleasepool {
            try {
                // Accumulate actual playback time (handles seeks)
                double delta = time - m_lastPositionUpdate;
                if (delta > 0 && delta < 2.0) {  // Normal playback
                    m_accumulatedTime += delta;
                }
                m_lastPositionUpdate = time;

                // Check Now Playing threshold
                if (!m_sentNowPlaying && m_accumulatedTime >= ScrobbleRules::kNowPlayingThreshold) {
                    m_sentNowPlaying = true;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NowPlayingService shared] sendNowPlaying:m_currentTrack];
                    });
                }
            } catch (...) {}
        }
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        @autoreleasepool {
            try {
                if (reason != play_control::stop_reason_starting_another) {
                    finalizeTrack();
                }
            } catch (...) {}
        }
    }

    void on_playback_seek(double time) override {
        // Reset position tracking (accumulated time preserved)
        m_lastPositionUpdate = time;
    }

private:
    ScrobbleTrack m_currentTrack;
    double m_accumulatedTime = 0;
    double m_lastPositionUpdate = 0;
    int64_t m_trackStartTime = 0;
    bool m_sentNowPlaying = false;

    ScrobbleTrack extractTrackInfo(metadb_handle_ptr track);
    void finalizeTrack();
};

FB2K_SERVICE_FACTORY(ScrobblePlayCallback);

} // anonymous namespace
```

### 6.3 InitQuit Handler

```objc
// Integration/InitQuit.mm
#include "../fb2k_sdk.h"
#import "../Services/ScrobbleService.h"
#import "../Core/ScrobbleCache.h"

namespace {

class ScrobbleInitQuit : public initquit {
public:
    void on_init() override {
        @autoreleasepool {
            console::info("[Scrobble] Initializing...");

            // Load cached scrobbles
            ScrobbleCache::instance().loadFromDisk();

            // Start service (will validate session)
            [[ScrobbleService shared] start];

            console::info("[Scrobble] Initialized successfully");
        }
    }

    void on_quit() override {
        @autoreleasepool {
            console::info("[Scrobble] Shutting down...");

            // Stop service and save pending scrobbles
            [[ScrobbleService shared] stop];
            ScrobbleCache::instance().saveToDisk();

            console::info("[Scrobble] Shut down complete");
        }
    }
};

FB2K_SERVICE_FACTORY(ScrobbleInitQuit);

} // anonymous namespace
```

---

## 7. User Interface

### 7.1 Preferences Controller

```objc
// UI/ScrobblePreferencesController.h
@interface ScrobblePreferencesController : NSViewController

@end

// UI/ScrobblePreferencesController.mm
@interface ScrobblePreferencesController ()
@property (nonatomic, strong) NSButton* authButton;
@property (nonatomic, strong) NSTextField* statusLabel;
@property (nonatomic, strong) NSButton* enableScrobblingCheckbox;
@property (nonatomic, strong) NSButton* enableNowPlayingCheckbox;
@property (nonatomic, strong) NSButton* libraryOnlyCheckbox;
@property (nonatomic, strong) NSProgressIndicator* spinner;
@end

@implementation ScrobblePreferencesController

- (void)loadView {
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 320)];

    CGFloat y = 280;

    // Authentication section
    NSTextField* authHeader = [self createLabel:@"Last.fm Account" at:NSMakePoint(20, y)];
    [container addSubview:authHeader];
    y -= 30;

    _statusLabel = [self createLabel:@"Not authenticated" at:NSMakePoint(20, y)];
    _statusLabel.textColor = [NSColor secondaryLabelColor];
    [container addSubview:_statusLabel];

    _authButton = [NSButton buttonWithTitle:@"Sign In"
                                     target:self
                                     action:@selector(authButtonClicked:)];
    _authButton.frame = NSMakeRect(300, y - 4, 80, 24);
    [container addSubview:_authButton];

    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(270, y, 20, 20)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.hidden = YES;
    [container addSubview:_spinner];

    y -= 50;

    // Scrobbling options section
    NSTextField* optionsHeader = [self createLabel:@"Scrobbling Options" at:NSMakePoint(20, y)];
    [container addSubview:optionsHeader];
    y -= 26;

    _enableScrobblingCheckbox = [NSButton checkboxWithTitle:@"Enable scrobbling"
                                                     target:self
                                                     action:@selector(settingChanged:)];
    _enableScrobblingCheckbox.frame = NSMakeRect(20, y, 250, 20);
    [container addSubview:_enableScrobblingCheckbox];
    y -= 24;

    _enableNowPlayingCheckbox = [NSButton checkboxWithTitle:@"Send 'Now Playing' notifications"
                                                     target:self
                                                     action:@selector(settingChanged:)];
    _enableNowPlayingCheckbox.frame = NSMakeRect(20, y, 250, 20);
    [container addSubview:_enableNowPlayingCheckbox];
    y -= 24;

    _libraryOnlyCheckbox = [NSButton checkboxWithTitle:@"Only scrobble tracks in library"
                                                target:self
                                                action:@selector(settingChanged:)];
    _libraryOnlyCheckbox.frame = NSMakeRect(20, y, 250, 20);
    [container addSubview:_libraryOnlyCheckbox];

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self updateAuthUI];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authStateChanged:)
                                                 name:@"LastFmAuthStateChanged"
                                               object:nil];
}

- (void)authButtonClicked:(id)sender {
    if ([[LastFmAuth shared] isAuthenticated]) {
        [[LastFmAuth shared] signOut];
    } else {
        _spinner.hidden = NO;
        [_spinner startAnimation:nil];
        _authButton.enabled = NO;

        [[LastFmAuth shared] startAuthenticationWithCompletion:^(BOOL success, NSError* error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.spinner.hidden = YES;
                [self.spinner stopAnimation:nil];
                self.authButton.enabled = YES;
                [self updateAuthUI];

                if (!success && error) {
                    [self showError:error.localizedDescription];
                }
            });
        }];
    }
}

- (void)updateAuthUI {
    if ([[LastFmAuth shared] isAuthenticated]) {
        NSString* username = [[LastFmAuth shared] session].username;
        _statusLabel.stringValue = [NSString stringWithFormat:@"Signed in as %@", username];
        _statusLabel.textColor = [NSColor labelColor];
        _authButton.title = @"Sign Out";
    } else {
        _statusLabel.stringValue = @"Not authenticated";
        _statusLabel.textColor = [NSColor secondaryLabelColor];
        _authButton.title = @"Sign In";
    }
}

@end
```

---

## 8. Implementation Phases

### Phase 1: Foundation (Week 1)
1. Set up project structure with fb2k_sdk.h and Prefix.pch
2. Implement ScrobbleConfig with fb2k::configStore
3. Implement ScrobbleTrack model
4. Implement MD5 helper for API signing
5. Create basic Xcode project with build scripts

### Phase 2: Last.fm API (Week 2)
1. Implement LastFmClient with request signing
2. Implement LastFmAuth with browser-based flow
3. Implement polling mechanism for token approval
4. Add session persistence to configStore
5. Test authentication flow end-to-end

### Phase 3: Scrobbling Core (Week 3)
1. Implement PlaybackCallbacks with time accumulation
2. Implement ScrobbleRules validation
3. Implement NowPlayingService
4. Implement ScrobbleService with state machine
5. Implement RateLimiter

### Phase 4: Persistence & UI (Week 4)
1. Implement ScrobbleCache with JSON persistence
2. Implement ScrobblePreferencesController
3. Add queue retry logic
4. Test offline scenarios
5. Polish and bug fixes

### Phase 5: Testing & Hardening
1. Edge case testing (seeks, track changes, network failures)
2. Memory leak testing with Instruments
3. Console logging for debugging
4. Documentation

---

## 9. File Checklist

```
foo_scrobble_mac/
├── src/
│   ├── fb2k_sdk.h                           [ ]
│   ├── Prefix.pch                           [ ]
│   ├── Core/
│   │   ├── ScrobbleConfig.h                 [ ]
│   │   ├── ScrobbleConfig.mm                [ ]
│   │   ├── ScrobbleTrack.h                  [ ]
│   │   ├── ScrobbleCache.h                  [ ]
│   │   ├── ScrobbleCache.mm                 [ ]
│   │   ├── ScrobbleRules.h                  [ ]
│   │   └── MD5.h                            [ ]
│   ├── LastFm/
│   │   ├── LastFmClient.h                   [ ]
│   │   ├── LastFmClient.mm                  [ ]
│   │   ├── LastFmAuth.h                     [ ]
│   │   ├── LastFmAuth.mm                    [ ]
│   │   ├── LastFmSession.h                  [ ]
│   │   └── LastFmErrors.h                   [ ]
│   ├── Services/
│   │   ├── ScrobbleService.h                [ ]
│   │   ├── ScrobbleService.mm               [ ]
│   │   ├── NowPlayingService.h              [ ]
│   │   ├── NowPlayingService.mm             [ ]
│   │   ├── RateLimiter.h                    [ ]
│   │   └── RateLimiter.mm                   [ ]
│   ├── UI/
│   │   ├── ScrobblePreferencesController.h  [ ]
│   │   └── ScrobblePreferencesController.mm [ ]
│   └── Integration/
│       ├── Main.mm                          [ ]
│       ├── PlaybackCallbacks.mm             [ ]
│       └── InitQuit.mm                      [ ]
├── Resources/
│   └── Info.plist                           [ ]
├── Scripts/
│   ├── generate_project.rb                  [ ]
│   ├── build.sh                             [ ]
│   └── install.sh                           [ ]
└── foo_scrobble_mac.xcodeproj/              [ ]
```

---

## 10. Key Technical Decisions

| Decision | Rationale |
|----------|-----------|
| Use `fb2k::configStore` | `cfg_var` doesn't persist on macOS v2 |
| Browser auth (not embedded) | Simpler, more secure, proven in LastScrobbler |
| JSON cache file | Human-readable, easy debugging |
| Singleton services | Matches pattern in working extensions |
| NSNotificationCenter for settings | Decouples preferences from services |
| Token bucket rate limiter | Matches Last.fm rate limits (5 req/sec) |
| Accumulated playback time | Handles seeks correctly (from Windows impl) |
| 50%/4min scrobble rule | Official Last.fm scrobble rules |
| Dispatch to main thread | All SDK callbacks marshaled for safety |

---

## 11. Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Session expiration | Periodic validation + auto re-auth prompt |
| Network failures | Persistent queue with retry logic |
| Rate limiting | Token bucket + exponential backoff |
| Memory leaks | Weak references in callbacks, @autoreleasepool |
| Thread safety | Main thread dispatch for all UI/SDK calls |
| API changes | Version headers, graceful degradation |

---

## 12. Testing Strategy

### Unit Tests
- ScrobbleRules validation
- MD5 signature generation
- Rate limiter token calculation
- Cache serialization/deserialization

### Integration Tests
- Auth flow with mock server
- Scrobble submission
- Now Playing updates
- Error handling for each error code

### Manual Tests
- Full auth flow with real Last.fm account
- Play track, verify scrobble appears on Last.fm
- Seek within track, verify correct playback time
- Offline mode, queue builds, reconnect, queue drains
- Track change before scrobble threshold
- Long track (>4 min rule triggers)

---

## 13. UI Status Component

### 13.1 Overview

A renderable UI element showing scrobbling status, logged-in user, queue stats, and historical statistics.

```
┌─────────────────────────────────────────────────────────┐
│  Last.fm: jendalen                          [Settings]  │
│  ─────────────────────────────────────────────────────  │
│  Now Playing: Artist - Track Title                      │
│                                                         │
│  Queue: 3 pending  │  Today: 47 scrobbled              │
│  Session: 156 scrobbled  │  Failed: 0                  │
└─────────────────────────────────────────────────────────┘
```

### 13.2 UI Element Registration

```objc
// Integration/Main.mm (add to existing)
namespace {
    static const GUID g_guid_status_element =
        {0xaabbccdd, 0x1234, 0x5678, {0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78}};

    class scrobble_status_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                return fb2k::wrapNSObject(
                    [[ScrobbleStatusController alloc] init]
                );
            }
        }

        bool match_name(const char* name) override {
            return strcmp(name, "Last.fm Scrobbler") == 0 ||
                   strcmp(name, "lastfm-scrobbler") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Last.fm Scrobbler");
        }

        GUID get_guid() override {
            return g_guid_status_element;
        }

        ui_element_subclass get_subclass() override {
            return ui_element_subclass_utility;
        }
    };

    FB2K_SERVICE_FACTORY(scrobble_status_element);
}
```

### 13.3 ScrobbleStats Model

```objc
// Core/ScrobbleStats.h
@interface ScrobbleStats : NSObject <NSSecureCoding>

// Session stats (reset on app launch)
@property (nonatomic, readonly) NSUInteger sessionScrobbled;
@property (nonatomic, readonly) NSUInteger sessionNowPlaying;
@property (nonatomic, readonly) NSUInteger sessionFailed;

// Persistent stats
@property (nonatomic, readonly) NSUInteger todayScrobbled;
@property (nonatomic, readonly) NSUInteger totalScrobbled;
@property (nonatomic, readonly) NSDate *lastScrobbleTime;
@property (nonatomic, readonly, copy) NSString *lastScrobbledTrack;

// Queue info (live from ScrobbleCache)
@property (nonatomic, readonly) NSUInteger pendingCount;
@property (nonatomic, readonly) NSUInteger failedCount;

+ (instancetype)shared;

- (void)recordScrobble:(NSString *)trackDescription;
- (void)recordNowPlaying;
- (void)recordFailure;
- (void)resetSessionStats;

- (void)loadFromDisk;
- (void)saveToDisk;

@end

// Notifications
extern NSNotificationName const ScrobbleStatsDidUpdateNotification;
```

### 13.4 Status View Controller

```objc
// UI/ScrobbleStatusController.h
@interface ScrobbleStatusController : NSViewController

@end

// UI/ScrobbleStatusController.mm
@interface ScrobbleStatusController ()
@property (nonatomic, strong) NSTextField *userLabel;
@property (nonatomic, strong) NSTextField *nowPlayingLabel;
@property (nonatomic, strong) NSTextField *queueLabel;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSButton *settingsButton;
@end

@implementation ScrobbleStatusController

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 80)];
    container.wantsLayer = YES;

    // User status line
    _userLabel = [NSTextField labelWithString:@"Last.fm: Not signed in"];
    _userLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _userLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_userLabel];

    // Now playing
    _nowPlayingLabel = [NSTextField labelWithString:@""];
    _nowPlayingLabel.font = [NSFont systemFontOfSize:10];
    _nowPlayingLabel.textColor = [NSColor secondaryLabelColor];
    _nowPlayingLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nowPlayingLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [container addSubview:_nowPlayingLabel];

    // Queue + stats
    _queueLabel = [NSTextField labelWithString:@"Queue: 0 pending"];
    _queueLabel.font = [NSFont systemFontOfSize:10];
    _queueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_queueLabel];

    _statsLabel = [NSTextField labelWithString:@"Session: 0 scrobbled"];
    _statsLabel.font = [NSFont systemFontOfSize:10];
    _statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_statsLabel];

    // Settings button
    _settingsButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"gearshape"
                                                          accessibilityDescription:@"Settings"]
                                         target:self
                                         action:@selector(openSettings:)];
    _settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _settingsButton.bordered = NO;
    [container addSubview:_settingsButton];

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        [_userLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [_userLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],

        [_settingsButton.centerYAnchor constraintEqualToAnchor:_userLabel.centerYAnchor],
        [_settingsButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],

        [_nowPlayingLabel.topAnchor constraintEqualToAnchor:_userLabel.bottomAnchor constant:4],
        [_nowPlayingLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [_nowPlayingLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],

        [_queueLabel.topAnchor constraintEqualToAnchor:_nowPlayingLabel.bottomAnchor constant:8],
        [_queueLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],

        [_statsLabel.topAnchor constraintEqualToAnchor:_queueLabel.topAnchor],
        [_statsLabel.leadingAnchor constraintEqualToAnchor:_queueLabel.trailingAnchor constant:16],
    ]];

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self updateDisplay];

    // Subscribe to updates
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleUpdate:)
                                                 name:ScrobbleStatsDidUpdateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleUpdate:)
                                                 name:LastFmAuthStateDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleUpdate:)
                                                 name:ScrobbleServiceNowPlayingDidChangeNotification
                                               object:nil];
}

- (void)updateDisplay {
    // Auth status
    if ([[LastFmAuth shared] isAuthenticated]) {
        NSString *username = [[LastFmAuth shared] session].username;
        _userLabel.stringValue = [NSString stringWithFormat:@"Last.fm: %@", username];
        _userLabel.textColor = [NSColor labelColor];
    } else {
        _userLabel.stringValue = @"Last.fm: Not signed in";
        _userLabel.textColor = [NSColor secondaryLabelColor];
    }

    // Now playing
    NSString *nowPlaying = [[ScrobbleService shared] currentNowPlayingDescription];
    if (nowPlaying.length > 0) {
        _nowPlayingLabel.stringValue = [NSString stringWithFormat:@"Now Playing: %@", nowPlaying];
    } else {
        _nowPlayingLabel.stringValue = @"";
    }

    // Queue
    ScrobbleStats *stats = [ScrobbleStats shared];
    _queueLabel.stringValue = [NSString stringWithFormat:@"Queue: %lu pending",
                               (unsigned long)stats.pendingCount];

    // Stats
    _statsLabel.stringValue = [NSString stringWithFormat:@"Session: %lu scrobbled | Failed: %lu",
                               (unsigned long)stats.sessionScrobbled,
                               (unsigned long)stats.sessionFailed];
}

@end
```

### 13.5 Public Queue Access API

```objc
// Core/ScrobbleCache.h (updated)
@interface ScrobbleCache : NSObject

+ (instancetype)shared;

// Transaction-based access (thread-safe)
- (void)withTransaction:(void(^)(ScrobbleCacheTransaction *tx))block;

// Read-only stats (atomic)
@property (nonatomic, readonly) NSUInteger pendingCount;
@property (nonatomic, readonly) NSUInteger failedCount;
@property (nonatomic, readonly, copy) NSArray<ScrobbleTrack *> *recentPending;  // Last 10

// Notifications
extern NSNotificationName const ScrobbleCacheDidChangeNotification;

@end

@interface ScrobbleCacheTransaction : NSObject
@property (nonatomic, readonly) NSMutableArray<ScrobbleTrack *> *pending;
- (void)addTrack:(ScrobbleTrack *)track;
- (void)removeTrack:(ScrobbleTrack *)track;
- (void)markInFlight:(ScrobbleTrack *)track;
- (void)markFailed:(ScrobbleTrack *)track error:(NSString *)error;
@end
```

---

## 14. Critical Fixes from Expert Review

### 14.1 Thread Safety in PlaybackCallbacks

**Problem**: SDK callbacks may come from audio thread, causing data races.

```cpp
// Integration/PlaybackCallbacks.mm (FIXED)
class ScrobblePlayCallback : public play_callback_static {
private:
    std::mutex m_trackMutex;  // Protects all member variables
    ScrobbleTrack m_currentTrack;
    double m_accumulatedTime = 0;
    double m_lastPositionUpdate = 0;
    int64_t m_trackStartTime = 0;
    bool m_sentNowPlaying = false;

public:
    void on_playback_new_track(metadb_handle_ptr track) override {
        @autoreleasepool {
            try {
                ScrobbleTrack newTrack = extractTrackInfo(track);
                int64_t startTime = static_cast<int64_t>(
                    std::round([[NSDate date] timeIntervalSince1970])
                );

                {
                    std::lock_guard<std::mutex> lock(m_trackMutex);
                    m_currentTrack = newTrack;
                    m_accumulatedTime = 0;
                    m_lastPositionUpdate = 0;
                    m_trackStartTime = startTime;
                    m_sentNowPlaying = false;
                }

                if (newTrack.isValid()) {
                    // Copy for async block
                    ScrobbleTrack trackCopy = newTrack;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NowPlayingService shared] trackStarted:trackCopy];
                    });
                }
            } catch (const std::exception& e) {
                FB2K_console_formatter() << "[Scrobble] Exception: " << e.what();
            } catch (...) {
                FB2K_console_formatter() << "[Scrobble] Unknown exception";
            }
        }
    }

    void on_playback_time(double time) override {
        @autoreleasepool {
            try {
                ScrobbleTrack trackCopy;
                bool shouldSendNowPlaying = false;

                {
                    std::lock_guard<std::mutex> lock(m_trackMutex);

                    double delta = time - m_lastPositionUpdate;
                    // Accept delta up to 2x normal (handles playback speed changes)
                    if (delta > 0 && delta < 2.0) {
                        m_accumulatedTime += delta;
                    }
                    m_lastPositionUpdate = time;

                    if (!m_sentNowPlaying &&
                        m_accumulatedTime >= ScrobbleRules::kNowPlayingThreshold) {
                        m_sentNowPlaying = true;
                        shouldSendNowPlaying = true;
                        trackCopy = m_currentTrack;
                    }
                }

                if (shouldSendNowPlaying) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[NowPlayingService shared] sendNowPlaying:trackCopy];
                    });
                }
            } catch (...) {}
        }
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        @autoreleasepool {
            try {
                if (reason != play_control::stop_reason_starting_another) {
                    ScrobbleTrack trackCopy;
                    double accumulatedTime;
                    int64_t startTime;

                    {
                        std::lock_guard<std::mutex> lock(m_trackMutex);
                        trackCopy = m_currentTrack;
                        accumulatedTime = m_accumulatedTime;
                        startTime = m_trackStartTime;
                        m_currentTrack = ScrobbleTrack();  // Clear
                    }

                    if (trackCopy.isValid() &&
                        ScrobbleRules::isEligibleForScrobble(trackCopy.duration, accumulatedTime)) {
                        trackCopy.timestamp = startTime;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [[ScrobbleService shared] queueTrack:trackCopy];
                        });
                    }
                }
            } catch (...) {}
        }
    }
};
```

### 14.2 Keychain Storage for Session Key

**Problem**: Session keys in plaintext config is insecure.

```objc
// Core/KeychainHelper.h
@interface KeychainHelper : NSObject

+ (BOOL)setSessionKey:(NSString *)sessionKey forUsername:(NSString *)username;
+ (NSString *)sessionKeyForUsername:(NSString *)username;
+ (BOOL)deleteSessionKey;

@end

// Core/KeychainHelper.mm
#import <Security/Security.h>

static NSString * const kServiceName = @"com.foobar2000.foo_scrobble_mac";

@implementation KeychainHelper

+ (BOOL)setSessionKey:(NSString *)sessionKey forUsername:(NSString *)username {
    // Delete existing first
    [self deleteSessionKey];

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
        (__bridge id)kSecAttrAccount: username,
        (__bridge id)kSecValueData: [sessionKey dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlocked,
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    return status == errSecSuccess;
}

+ (NSString *)sessionKeyForUsername:(NSString *)username {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
        (__bridge id)kSecAttrAccount: username,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };

    CFDataRef dataRef = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&dataRef);

    if (status == errSecSuccess && dataRef) {
        NSData *data = (__bridge_transfer NSData *)dataRef;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return nil;
}

+ (BOOL)deleteSessionKey {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kServiceName,
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess || status == errSecItemNotFound;
}

@end
```

### 14.3 MD5 Deprecation Handling

```objc
// Core/MD5.h
#import <CommonCrypto/CommonDigest.h>

NS_INLINE NSString* MD5Hash(NSString *input) {
    // Note: MD5 is required by Last.fm API specification.
    // Suppress deprecation warning - we have no choice here.
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"

    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);

    #pragma clang diagnostic pop

    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}
```

### 14.4 Exponential Backoff Strategy

```objc
// Services/RetryStrategy.h
@interface RetryStrategy : NSObject

@property (nonatomic, readonly) NSInteger attemptCount;
@property (nonatomic, readonly) NSTimeInterval nextRetryDelay;
@property (nonatomic, readonly) BOOL shouldRetry;

- (void)recordFailure;
- (void)recordSuccess;
- (void)reset;

@end

// Services/RetryStrategy.mm
@implementation RetryStrategy {
    NSInteger _attemptCount;
}

static const NSInteger kMaxRetries = 10;
static const NSTimeInterval kMaxDelay = 300.0;  // 5 minutes

- (NSTimeInterval)nextRetryDelay {
    // Exponential backoff: 1s, 2s, 4s, 8s... max 5min
    // With jitter to prevent thundering herd
    NSTimeInterval base = MIN(pow(2.0, _attemptCount), kMaxDelay);
    NSTimeInterval jitter = (arc4random_uniform(1000) / 1000.0) * base * 0.1;
    return base + jitter;
}

- (BOOL)shouldRetry {
    return _attemptCount < kMaxRetries;
}

- (void)recordFailure {
    _attemptCount++;
}

- (void)recordSuccess {
    _attemptCount = 0;
}

- (void)reset {
    _attemptCount = 0;
}

@end
```

### 14.5 Duplicate Scrobble Prevention

```objc
// Core/ScrobbleTrack.h (updated)
@interface ScrobbleTrack : NSObject <NSSecureCoding>

@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *album;
@property (nonatomic, copy, nullable) NSString *albumArtist;
@property (nonatomic) double duration;
@property (nonatomic) int64_t timestamp;

// Submission tracking
@property (nonatomic, copy) NSString *submissionId;  // UUID for dedup
@property (nonatomic) ScrobbleTrackStatus status;    // queued, inFlight, submitted, failed

- (BOOL)isValid;
- (NSString *)deduplicationKey;  // "artist|title|timestamp"

@end

typedef NS_ENUM(NSInteger, ScrobbleTrackStatus) {
    ScrobbleTrackStatusQueued,
    ScrobbleTrackStatusInFlight,
    ScrobbleTrackStatusSubmitted,
    ScrobbleTrackStatusFailed
};
```

### 14.6 Transaction-Based Cache API

```objc
// Core/ScrobbleCache.mm
@implementation ScrobbleCache {
    NSMutableArray<ScrobbleTrack *> *_pending;
    NSRecursiveLock *_lock;
    dispatch_queue_t _ioQueue;
}

- (void)withTransaction:(void(^)(ScrobbleCacheTransaction *tx))block {
    [_lock lock];
    @try {
        ScrobbleCacheTransaction *tx = [[ScrobbleCacheTransaction alloc]
                                        initWithPending:_pending];
        block(tx);

        if (tx.isDirty) {
            [self scheduleAsyncSave];
            [[NSNotificationCenter defaultCenter]
                postNotificationName:ScrobbleCacheDidChangeNotification object:self];
        }
    } @finally {
        [_lock unlock];
    }
}

- (void)scheduleAsyncSave {
    dispatch_async(_ioQueue, ^{
        [self saveToDiskSync];
    });
}

@end
```

### 14.7 Revised State Machine

```
                                  ┌──────────────────────┐
                                  │    Uninitialized     │
                                  └──────────┬───────────┘
                                             │ on_init()
                                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│  ┌────────────────────┐         ┌────────────────────┐                      │
│  │ UnauthenticatedIdle│◄────────│   AuthInProgress   │                      │
│  │                    │ failure │                    │                      │
│  │  [no session key]  │─────────►  [browser open,    │                      │
│  │                    │  start  │   polling token]   │                      │
│  └────────┬───────────┘  auth   └─────────┬──────────┘                      │
│           │                               │ success                         │
│           │ load stored                   ▼                                 │
│           │ session     ┌────────────────────────────┐                      │
│           │             │    AuthenticatedIdle       │◄──────────────┐      │
│           └────────────►│                            │               │      │
│                         │  [ready, queue empty]      │               │      │
│                         └─────────┬──────────────────┘               │      │
│                                   │ track queued                     │      │
│                                   ▼                                  │      │
│                         ┌────────────────────────────┐               │      │
│                         │    SubmittingBatch         │               │      │
│                         │                            │───────────────┤      │
│                         │  [HTTP request in-flight]  │   success     │      │
│                         └─────────┬──────────────────┘   (queue      │      │
│                                   │                       empty)     │      │
│                                   │ rate limited / network error     │      │
│                                   ▼                                  │      │
│                         ┌────────────────────────────┐               │      │
│                         │    RetryWait               │               │      │
│                         │                            │───────────────┘      │
│                         │  [exponential backoff]     │  timer expired       │
│                         └────────────────────────────┘  → SubmittingBatch   │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                                             │
                                             │ on_quit()
                                             ▼
                                  ┌──────────────────────┐
                                  │    ShuttingDown      │
                                  │  [cancel in-flight,  │
                                  │   save cache]        │
                                  └──────────┬───────────┘
                                             │
                                             ▼
                                  ┌──────────────────────┐
                                  │     Terminated       │
                                  └──────────────────────┘
```

### 14.8 Typed Notification Names

```objc
// Core/ScrobbleNotifications.h
#import <Foundation/Foundation.h>

// Authentication
extern NSNotificationName const LastFmAuthStateDidChangeNotification;
extern NSNotificationName const LastFmAuthDidSignInNotification;
extern NSNotificationName const LastFmAuthDidSignOutNotification;

// Scrobbling
extern NSNotificationName const ScrobbleServiceStateDidChangeNotification;
extern NSNotificationName const ScrobbleServiceDidScrobbleNotification;
extern NSNotificationName const ScrobbleServiceNowPlayingDidChangeNotification;

// Cache
extern NSNotificationName const ScrobbleCacheDidChangeNotification;

// Stats
extern NSNotificationName const ScrobbleStatsDidUpdateNotification;

// Settings
extern NSNotificationName const ScrobbleSettingsDidChangeNotification;

// Core/ScrobbleNotifications.mm
NSNotificationName const LastFmAuthStateDidChangeNotification = @"LastFmAuthStateDidChange";
NSNotificationName const LastFmAuthDidSignInNotification = @"LastFmAuthDidSignIn";
NSNotificationName const LastFmAuthDidSignOutNotification = @"LastFmAuthDidSignOut";
// ... etc
```

### 14.9 Input Validation

```objc
// Core/ScrobbleTrack.mm
- (BOOL)isValid {
    // Basic required fields
    if (_artist.length == 0 || _artist.length > 1024) return NO;
    if (_title.length == 0 || _title.length > 1024) return NO;

    // Duration sanity check (30s minimum, 24h maximum)
    if (_duration < 30.0 || _duration > 86400.0) return NO;

    // Timestamp sanity (not in future, not before Last.fm existed)
    int64_t now = (int64_t)[[NSDate date] timeIntervalSince1970];
    int64_t lastFmEpoch = 1108540800;  // 2005-02-16 (Last.fm launch)
    if (_timestamp > now + 60 || _timestamp < lastFmEpoch) return NO;

    return YES;
}
```

### 14.10 Request Cancellation

```objc
// LastFm/LastFmClient.h (updated)
@interface LastFmClient : NSObject

// Track in-flight requests
- (void)cancelAllRequests;
- (void)cancelAuthRequests;

@end

// LastFm/LastFmClient.mm
@implementation LastFmClient {
    NSMutableSet<NSURLSessionDataTask *> *_activeTasks;
    NSLock *_tasksLock;
}

- (void)cancelAllRequests {
    [_tasksLock lock];
    for (NSURLSessionDataTask *task in _activeTasks) {
        [task cancel];
    }
    [_activeTasks removeAllObjects];
    [_tasksLock unlock];
}

- (void)performRequest:(NSURLRequest *)request
            completion:(void(^)(NSDictionary *, NSError *))completion {
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [self->_tasksLock lock];
            [self->_activeTasks removeObject:task];
            [self->_tasksLock unlock];

            // Handle response...
        }];

    [_tasksLock lock];
    [_activeTasks addObject:task];
    [_tasksLock unlock];

    [task resume];
}

@end
```

---

## 15. Updated File Checklist

```
foo_scrobble_mac/
├── src/
│   ├── fb2k_sdk.h                           [ ]
│   ├── Prefix.pch                           [ ]
│   ├── Core/
│   │   ├── ScrobbleConfig.h                 [ ]
│   │   ├── ScrobbleConfig.mm                [ ]
│   │   ├── ScrobbleTrack.h                  [ ]
│   │   ├── ScrobbleTrack.mm                 [ ]
│   │   ├── ScrobbleCache.h                  [ ]
│   │   ├── ScrobbleCache.mm                 [ ]
│   │   ├── ScrobbleRules.h                  [ ]
│   │   ├── ScrobbleStats.h                  [ ]
│   │   ├── ScrobbleStats.mm                 [ ]
│   │   ├── ScrobbleNotifications.h          [ ]
│   │   ├── ScrobbleNotifications.mm         [ ]
│   │   ├── KeychainHelper.h                 [ ]
│   │   ├── KeychainHelper.mm                [ ]
│   │   └── MD5.h                            [ ]
│   ├── LastFm/
│   │   ├── LastFmClient.h                   [ ]
│   │   ├── LastFmClient.mm                  [ ]
│   │   ├── LastFmAuth.h                     [ ]
│   │   ├── LastFmAuth.mm                    [ ]
│   │   ├── LastFmSession.h                  [ ]
│   │   └── LastFmErrors.h                   [ ]
│   ├── Services/
│   │   ├── ScrobbleService.h                [ ]
│   │   ├── ScrobbleService.mm               [ ]
│   │   ├── NowPlayingService.h              [ ]
│   │   ├── NowPlayingService.mm             [ ]
│   │   ├── RateLimiter.h                    [ ]
│   │   ├── RateLimiter.mm                   [ ]
│   │   ├── RetryStrategy.h                  [ ]
│   │   └── RetryStrategy.mm                 [ ]
│   ├── UI/
│   │   ├── ScrobblePreferencesController.h  [ ]
│   │   ├── ScrobblePreferencesController.mm [ ]
│   │   ├── ScrobbleStatusController.h       [ ]
│   │   └── ScrobbleStatusController.mm      [ ]
│   └── Integration/
│       ├── Main.mm                          [ ]
│       ├── PlaybackCallbacks.mm             [ ]
│       └── InitQuit.mm                      [ ]
├── Resources/
│   └── Info.plist                           [ ]
├── Scripts/
│   ├── generate_project.rb                  [ ]
│   ├── build.sh                             [ ]
│   └── install.sh                           [ ]
└── foo_scrobble_mac.xcodeproj/              [ ]
```

---

## 16. Revised Implementation Phases

### Phase 1: Foundation (Days 1-2)
1. Set up project structure with fb2k_sdk.h and Prefix.pch
2. Implement ScrobbleNotifications (typed notification names)
3. Implement KeychainHelper for secure storage
4. Implement MD5 helper with deprecation handling
5. Implement ScrobbleTrack with validation
6. Implement ScrobbleRules
7. Create basic Xcode project

### Phase 2: Last.fm API (Days 3-4)
1. Implement LastFmClient with request signing and cancellation
2. Implement LastFmAuth with browser-based flow and polling
3. Implement RateLimiter (token bucket)
4. Implement RetryStrategy (exponential backoff)
5. Test authentication flow end-to-end

### Phase 3: Scrobbling Core (Days 5-6)
1. Implement PlaybackCallbacks with thread-safe mutex
2. Implement ScrobbleCache with transaction API
3. Implement NowPlayingService
4. Implement ScrobbleService with full state machine
5. Implement ScrobbleStats for metrics

### Phase 4: UI & Integration (Days 7-8)
1. Implement ScrobblePreferencesController
2. Implement ScrobbleStatusController (UI element)
3. Register both UI components in Main.mm
4. Implement InitQuit for startup/shutdown
5. Test full integration

### Phase 5: Hardening (Days 9-10)
1. Edge case testing (seeks, track changes, network failures)
2. Memory leak testing with Instruments
3. Offline queue testing
4. Duplicate scrobble prevention verification
5. Final polish and documentation

---

## References

- [Last.fm API Documentation](https://www.last.fm/api)
- [Last.fm Scrobbling API](https://www.last.fm/api/scrobbling)
- foobar2000 SDK documentation (knowledge_base/)
- Windows foo_scrobble source (foo_scrobble_src/)
- LastScrobbler reference implementation (~/Projects/LastScrobbler/)
