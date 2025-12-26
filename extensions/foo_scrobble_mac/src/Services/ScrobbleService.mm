//
//  ScrobbleService.mm
//  foo_scrobble_mac
//
//  Main scrobbling service implementation
//

#include "../fb2k_sdk.h"
#import "ScrobbleService.h"
#import "ScrobbleCache.h"
#import "RateLimiter.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/ScrobbleConfig.h"
#import "../Core/ScrobbleNotifications.h"
#import "../LastFm/LastFmClient.h"
#import "../LastFm/LastFmAuth.h"
#import "../LastFm/LastFmErrors.h"
#import "../LastFm/LastFmConstants.h"

// Exponential backoff constants
static const NSTimeInterval kInitialBackoff = 5.0;
static const NSTimeInterval kMaxBackoff = 300.0;  // 5 minutes
static const double kBackoffMultiplier = 2.0;

@interface ScrobbleService ()
@property (nonatomic, readwrite) ScrobbleServiceState state;
@property (nonatomic, readwrite) NSUInteger sessionScrobbleCount;
@property (nonatomic, strong) RateLimiter* rateLimiter;
@property (nonatomic, strong, nullable) NSTimer* retryTimer;
@property (nonatomic) NSTimeInterval currentBackoff;
@property (nonatomic) NSInteger consecutiveFailures;
@end

@implementation ScrobbleService

#pragma mark - Singleton

+ (instancetype)shared {
    static ScrobbleService* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScrobbleService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = ScrobbleServiceStateUnauthenticated;
        _rateLimiter = [[RateLimiter alloc] initWithTokensPerSecond:LastFm::kTokensPerSecond
                                                      burstCapacity:LastFm::kBurstCapacity];
        _currentBackoff = kInitialBackoff;
        _consecutiveFailures = 0;

        // Observe auth state changes
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(authStateDidChange:)
                                                     name:LastFmAuthStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - State Management

- (void)setState:(ScrobbleServiceState)state {
    if (_state != state) {
        _state = state;
        [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleServiceStateDidChangeNotification
                                                            object:self];
    }
}

- (void)authStateDidChange:(NSNotification*)notification {
    if ([[LastFmAuth shared] isAuthenticated]) {
        if (_state == ScrobbleServiceStateUnauthenticated) {
            self.state = ScrobbleServiceStateIdle;
            [self processQueue];
        }
    } else {
        self.state = ScrobbleServiceStateUnauthenticated;
    }
}

#pragma mark - Lifecycle

- (void)start {
    // Load cached scrobbles
    [[ScrobbleCache shared] loadFromDisk];

    // Load stored session
    [[LastFmAuth shared] loadStoredSession];

    if ([[LastFmAuth shared] isAuthenticated]) {
        self.state = ScrobbleServiceStateIdle;

        // Validate session
        [[LastFmAuth shared] validateSessionWithCompletion:^(BOOL valid) {
            if (valid) {
                [self processQueue];
            }
        }];
    } else {
        self.state = ScrobbleServiceStateUnauthenticated;
    }
}

- (void)stop {
    self.state = ScrobbleServiceStateShuttingDown;

    [_retryTimer invalidate];
    _retryTimer = nil;

    // Save pending scrobbles
    [[ScrobbleCache shared] saveToDisk];

    self.state = ScrobbleServiceStateShutDown;
}

#pragma mark - Properties

- (NSUInteger)pendingCount {
    return [[ScrobbleCache shared] pendingCount];
}

- (NSUInteger)inFlightCount {
    return [[ScrobbleCache shared] inFlightCount];
}

#pragma mark - Scrobbling

- (void)queueTrack:(ScrobbleTrack*)track {
    if (!track || !track.isValid) return;

    // Check if scrobbling is enabled
    if (!scrobble_config::isScrobblingEnabled()) {
        return;
    }

    // Check for duplicates
    if ([[ScrobbleCache shared] isDuplicateTrack:track]) {
        return;
    }

    [[ScrobbleCache shared] enqueueTrack:track];
    [self processQueue];
}

- (void)processQueue {
    // Check if we can process
    if (_state == ScrobbleServiceStateUnauthenticated ||
        _state == ScrobbleServiceStateSuspended ||
        _state == ScrobbleServiceStateShuttingDown ||
        _state == ScrobbleServiceStateShutDown) {
        return;
    }

    if (_state == ScrobbleServiceStateProcessing) {
        return;  // Already processing
    }

    if (_state == ScrobbleServiceStateSleeping) {
        return;  // Waiting for retry timer
    }

    // Check rate limit
    if (![_rateLimiter tryAcquire]) {
        [self scheduleRetry:_rateLimiter.waitTimeForNextToken];
        return;
    }

    // Get batch of tracks
    NSArray<ScrobbleTrack*>* batch = [[ScrobbleCache shared] dequeueTracksWithCount:LastFm::kMaxScrobblesPerBatch];
    if (batch.count == 0) {
        self.state = ScrobbleServiceStateIdle;
        return;
    }

    self.state = ScrobbleServiceStateProcessing;

    // Submit batch
    [[LastFmClient shared] scrobbleTracks:batch completion:^(NSInteger accepted, NSInteger ignored, NSError* error) {
        [self handleScrobbleResult:batch accepted:accepted ignored:ignored error:error];
    }];
}

- (void)handleScrobbleResult:(NSArray<ScrobbleTrack*>*)tracks
                    accepted:(NSInteger)accepted
                     ignored:(NSInteger)ignored
                       error:(NSError*)error {
    if (error) {
        [self handleScrobbleError:error tracks:tracks];
        return;
    }

    // Success
    _consecutiveFailures = 0;
    _currentBackoff = kInitialBackoff;
    _sessionScrobbleCount += accepted;

    // Mark as submitted
    [[ScrobbleCache shared] markTracksAsSubmitted:tracks];

    [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleServiceDidScrobbleNotification
                                                        object:self
                                                      userInfo:@{
                                                          @"accepted": @(accepted),
                                                          @"ignored": @(ignored)
                                                      }];

    // Process more if available
    self.state = ScrobbleServiceStateIdle;
    [self processQueue];
}

- (void)handleScrobbleError:(NSError*)error tracks:(NSArray<ScrobbleTrack*>*)tracks {
    LastFmErrorCode code = (LastFmErrorCode)error.code;

    // Check if we need to re-authenticate
    if (LastFmErrorRequiresReauth(code)) {
        [[LastFmAuth shared] signOut];
        self.state = ScrobbleServiceStateUnauthenticated;
        [[ScrobbleCache shared] requeueTracks:tracks];
        return;
    }

    // Check if API key is suspended
    if (LastFmErrorShouldSuspend(code)) {
        self.state = ScrobbleServiceStateSuspended;
        [[ScrobbleCache shared] requeueTracks:tracks];
        return;
    }

    // Retriable error - use exponential backoff
    if (LastFmErrorIsRetriable(code)) {
        _consecutiveFailures++;
        [[ScrobbleCache shared] requeueTracks:tracks];

        [self scheduleRetry:_currentBackoff];
        _currentBackoff = MIN(_currentBackoff * kBackoffMultiplier, kMaxBackoff);
        return;
    }

    // Non-retriable error - drop the tracks
    [[ScrobbleCache shared] markTracksAsSubmitted:tracks];

    [[NSNotificationCenter defaultCenter] postNotificationName:ScrobbleServiceDidFailNotification
                                                        object:self
                                                      userInfo:@{
                                                          @"error": error,
                                                          @"droppedCount": @(tracks.count)
                                                      }];

    self.state = ScrobbleServiceStateIdle;
    [self processQueue];
}

- (void)scheduleRetry:(NSTimeInterval)delay {
    self.state = ScrobbleServiceStateSleeping;

    __weak typeof(self) weakSelf = self;
    _retryTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                  repeats:NO
                                                    block:^(NSTimer* timer) {
        weakSelf.state = ScrobbleServiceStateIdle;
        [weakSelf processQueue];
    }];
}

#pragma mark - Now Playing

- (void)sendNowPlaying:(ScrobbleTrack*)track {
    if (!track || !track.isValid) {
        console::info("[Scrobble] Now Playing: invalid track");
        return;
    }

    // Check if now playing is enabled
    if (!scrobble_config::isNowPlayingEnabled()) {
        console::info("[Scrobble] Now Playing: disabled in settings");
        return;
    }

    // Check authentication
    if (![[LastFmAuth shared] isAuthenticated]) {
        console::info("[Scrobble] Now Playing: not authenticated");
        return;
    }

    FB2K_console_formatter() << "[Scrobble] Sending Now Playing to API: "
        << track.artist.UTF8String << " - " << track.title.UTF8String;

    [[LastFmClient shared] sendNowPlaying:track completion:^(BOOL success, NSError* error) {
        if (success) {
            console::info("[Scrobble] Now Playing: success");
        } else if (error) {
            FB2K_console_formatter() << "[Scrobble] Now Playing error: "
                << error.localizedDescription.UTF8String;
            // Check for auth errors
            if (LastFmErrorRequiresReauth((LastFmErrorCode)error.code)) {
                [[LastFmAuth shared] signOut];
            }
        }
    }];
}

@end
