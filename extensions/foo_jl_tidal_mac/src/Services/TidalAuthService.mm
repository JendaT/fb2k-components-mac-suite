//
//  TidalAuthService.mm
//  foo_jl_tidal_mac
//
//  OAuth Device Code authentication implementation
//

#import "TidalAuthService.h"
#import "../API/TidalAPI.h"
#import "../API/TidalAPIPrivate.h"
#import "../API/TidalConstants.h"
#import "../Core/TidalErrors.h"
#import "../Core/TidalConfig.h"
#import "../Core/KeychainHelper.h"
#import <AppKit/AppKit.h>

NSNotificationName const JLTidalAuthStateDidChangeNotification = @"JLTidalAuthStateDidChange";

@interface JLTidalAuthService ()
@property (nonatomic, readwrite) JLTidalAuthState state;
@property (atomic, strong, readwrite, nullable) JLTidalSession *session;
@property (nonatomic, copy, readwrite, nullable) NSString *userCode;
@property (nonatomic, copy, readwrite, nullable) NSURL *verificationURL;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;
@property (nonatomic, copy, readwrite, nullable) NSDate *lastRefreshAttempt;
@property (nonatomic, copy, readwrite, nullable) NSString *lastRefreshError;

@property (nonatomic, readwrite) BOOL lastRefreshWasTerminal;
/// One poll in flight at a time (L18): the device-code timer used to fire
/// regardless, so a slow response could overlap the next request and a stale
/// answer for an already-redeemed code could flip an authenticated session
/// into Error.
@property (atomic) BOOL pollInFlight;
@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSTimer *timeoutTimer;
@property (nonatomic, strong, nullable) NSTimer *refreshTimer;
@property (nonatomic, copy, nullable) NSString *pendingDeviceCode;
@property (nonatomic, copy, nullable) JLTidalAuthCompletion pendingCompletion;
@end

@implementation JLTidalAuthService {
    // Single-flight refresh state. All three fields are guarded by
    // @synchronized(self); never touch them outside that lock.
    BOOL _isRefreshing;
    NSMutableArray<void (^)(BOOL)> *_pendingRefreshCompletions;
    // Bumped by signOut to invalidate an in-flight refresh so its result
    // cannot resurrect a session after sign-out.
    NSUInteger _refreshGeneration;
}

#pragma mark - Singleton

+ (instancetype)shared {
    static JLTidalAuthService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalAuthService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = JLTidalAuthStateIdle;
        _isRefreshing = NO;
        _pendingRefreshCompletions = [NSMutableArray array];

        // The API layer must not depend on Services, so it delegates token
        // refresh through this handler instead of calling us directly.
        __weak typeof(self) weakSelf = self;
        [JLTidalAPI shared].tokenRefreshHandler = ^(BOOL force, void (^completion)(BOOL success)) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                completion(NO);
                return;
            }
            [strongSelf refreshTokenForced:force completion:completion];
        };
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isAuthenticated {
    JLTidalSession *session = self.session;
    return _state == JLTidalAuthStateAuthenticated && session != nil && session.isValid;
}

- (void)setState:(JLTidalAuthState)state {
    if (_state != state) {
        _state = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:JLTidalAuthStateDidChangeNotification
                                                                object:self];
        });
    }
}

// Auth state is written from URLSession threads and read on main. Mutating it
// from the network thread races the UI that reads it, and a Cancel click
// landing on a successful poll could release the pending completion twice.
// Every terminal transition goes through here first.
- (void)onMain:(dispatch_block_t)block {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

// UI gating asks "is there a session at all", not "is the access token fresh
// this second" -- an expiring token refreshes on demand at the next request.
// Without this the browser said "Not signed in" while Preferences said
// "Signed in, token expired" and playback worked. (L23)
- (BOOL)hasSession {
    JLTidalSession *session = self.session;
    return session != nil && session.refreshToken.length > 0;
}

#pragma mark - Session Storage

- (void)loadStoredSession {
    NSString *accessToken = [JLTidalKeychainHelper loadAccessToken];
    NSString *refreshToken = [JLTidalKeychainHelper loadRefreshToken];
    NSDate *expiry = [JLTidalKeychainHelper loadTokenExpiry];
    NSString *userId = [JLTidalKeychainHelper loadUserId];
    NSString *username = [JLTidalKeychainHelper loadUsername];
    NSString *email = [JLTidalKeychainHelper loadEmail];
    NSString *countryCode = [JLTidalKeychainHelper loadCountryCode];

    // Fallback to system locale if countryCode not stored (migration from old version)
    if (!countryCode.length) {
        countryCode = [[NSLocale currentLocale] countryCode];
        if (countryCode.length) {
            tidal::logDebug([[NSString stringWithFormat:@"Using system locale countryCode: %@", countryCode] UTF8String]);
            [JLTidalKeychainHelper storeCountryCode:countryCode];
        }
    }

    if (accessToken.length > 0 && refreshToken.length > 0) {
        NSTimeInterval expiresIn = expiry ? [expiry timeIntervalSinceNow] : 0;
        if (expiresIn < 0) expiresIn = 0;

        JLTidalSession *session = [[JLTidalSession alloc] initWithAccessToken:accessToken
                                                                 refreshToken:refreshToken
                                                                    expiresIn:expiresIn
                                                                       userId:userId
                                                                     username:username
                                                                        email:email
                                                                  countryCode:countryCode];
        self.session = session;
        [[JLTidalAPI shared] updateSession:session];

        tidal::logDebug([[NSString stringWithFormat:@"Loaded session: userId=%@, countryCode=%@",
                         userId ?: @"(nil)", countryCode ?: @"(nil)"] UTF8String]);

        if (session.needsRefresh) {
            // Token expired or expiring soon - refresh it
            tidal::logDebug("Stored token needs refresh");
            [self refreshTokenIfNeededWithCompletion:^(BOOL success) {
                if (success) {
                    self.state = JLTidalAuthStateAuthenticated;
                    return;  // finishRefreshWithSession already rescheduled
                }
                // Launching offline, or a hiccup inside the refresh window,
                // used to drop the service into Idle with a perfectly good
                // refresh token in the Keychain and no retry armed -- every
                // feature answered "not authenticated" until the app was
                // restarted, and Preferences offered a full re-pairing rather
                // than a retry. A rejected grant is the only thing that
                // genuinely ends the session.
                if (self.lastRefreshWasTerminal) {
                    tidal::logError("Stored refresh token was rejected; sign-in required");
                    self.state = JLTidalAuthStateIdle;
                    return;
                }
                tidal::logInfo("Startup refresh failed (transient); keeping the session and retrying");
                self.state = JLTidalAuthStateAuthenticated;
                [self scheduleRefreshRetry];
            }];
        } else {
            self.state = JLTidalAuthStateAuthenticated;
            [self scheduleProactiveRefresh];
            tidal::logInfo("Loaded stored session");
        }
    }
}

- (void)storeSession:(JLTidalSession *)session {
    BOOL accessStored = [JLTidalKeychainHelper storeAccessToken:session.accessToken];
    BOOL refreshStored = [JLTidalKeychainHelper storeRefreshToken:session.refreshToken];
    if (!accessStored || !refreshStored) {
        tidal::logError([[NSString stringWithFormat:
                          @"AuthService: failed to persist session tokens (access=%@, refresh=%@) — user may be signed out after restart",
                          accessStored ? @"ok" : @"FAILED",
                          refreshStored ? @"ok" : @"FAILED"] UTF8String]);
    }
    [JLTidalKeychainHelper storeTokenExpiry:session.expiryDate];
    [JLTidalKeychainHelper storeUserId:session.userId];
    [JLTidalKeychainHelper storeUsername:session.username];
    // Only overwrite a stored email when the response actually carried one:
    // refresh responses omit the user object, and losing it would silently
    // demote the "Email" status-line mode to its username fallback.
    if (session.email.length > 0) {
        [JLTidalKeychainHelper storeEmail:session.email];
    }
    [JLTidalKeychainHelper storeCountryCode:session.countryCode];
}

- (void)clearStoredSession {
    [JLTidalKeychainHelper deleteAllTokens];
}

- (void)scheduleProactiveRefresh {
    [self cancelRefreshTimer];

    JLTidalSession *session = self.session;
    if (!session.refreshToken.length) return;

    // Schedule refresh kTidalTokenRefreshBuffer seconds before expiry
    NSTimeInterval delay = [session.expiryDate timeIntervalSinceNow] - kTidalTokenRefreshBuffer;
    if (delay < 60) delay = 60; // At least 60s from now

    [self armRefreshTimerAfter:delay isRetry:NO];
}

// Retry cadence after a transient failure. A rejected grant never gets here.
- (void)scheduleRefreshRetry {
    if (self.lastRefreshWasTerminal) {
        tidal::logInfo("refreshToken: grant rejected, not retrying");
        return;
    }
    [self armRefreshTimerAfter:300 isRetry:YES];
}

// Sole owner of refreshTimer (L19). Both the success path and the retry path
// used to schedule, and finishRefreshWithSession scheduled again for every
// drained waiter, leaking one untracked timer per refresh cycle. Creating and
// invalidating in the same main-queue block also keeps the NSTimer on one
// thread instead of being written on main and released off it.
- (void)armRefreshTimerAfter:(NSTimeInterval)delay isRetry:(BOOL)isRetry {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_refreshTimer invalidate];
        strongSelf->_refreshTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                                    repeats:NO
                                                                      block:^(NSTimer *timer) {
            tidal::logDebug(isRetry ? "Token refresh retry triggered" : "Proactive token refresh triggered");
            [weakSelf refreshTokenForced:YES completion:^(BOOL success) {
                if (success) {
                    tidal::logInfo("Token refresh succeeded");
                    // finishRefreshWithSession arms the next one.
                } else {
                    tidal::logError("Token refresh failed");
                    [weakSelf scheduleRefreshRetry];
                }
            }];
        }];
        tidal::logDebug([[NSString stringWithFormat:@"Token refresh scheduled in %.0f seconds", delay] UTF8String]);
    });
}

- (void)cancelRefreshTimer {
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

#pragma mark - Authentication Flow

- (void)startAuthenticationWithCompletion:(JLTidalAuthCompletion)completion {
    // Cancel any existing auth attempt
    [self cancelAuthentication];

    _pendingCompletion = [completion copy];
    self.errorMessage = nil;
    self.state = JLTidalAuthStateRequestingDeviceCode;

    tidal::logInfo("Starting device code authentication...");

    [[JLTidalAPI shared] requestDeviceCodeWithCompletion:^(JLTidalDeviceCode *deviceCode, NSError *error) {
        if (error) {
            [self handleAuthError:error];
            return;
        }

        self.pendingDeviceCode = deviceCode.deviceCode;
        self.userCode = deviceCode.userCode;

        // Prefer the completed URI: it carries the user's code, so the browser
        // lands on an already-filled page instead of asking them to type it.
        // (Both are scheme-normalised at the parse boundary.)
        NSURL *linkURL = deviceCode.verificationURIComplete ?: deviceCode.verificationURI;
        if (!linkURL) linkURL = [NSURL URLWithString:@"https://link.tidal.com"];
        self.verificationURL = linkURL;
        self.state = JLTidalAuthStateWaitingForApproval;

        tidal::logDebug([[NSString stringWithFormat:@"Opening %@ for device authorization",
                          linkURL.host ?: @"link.tidal.com"] UTF8String]);
        [[NSWorkspace sharedWorkspace] openURL:linkURL];

        // Start polling for approval
        [self startPollingWithInterval:deviceCode.interval];

        // Set timeout
        [self startTimeoutWithDuration:deviceCode.expiresIn];
    }];
}

- (void)startPollingWithInterval:(NSTimeInterval)interval {
    __weak typeof(self) weakSelf = self;

    // Use at least the minimum interval
    NSTimeInterval pollInterval = MAX(interval, kTidalDeviceCodePollInterval);

    // Schedule timer on main thread to ensure it fires
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.pollTimer = [NSTimer scheduledTimerWithTimeInterval:pollInterval
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
            [weakSelf pollForToken];
        }];
    });
}

- (void)startTimeoutWithDuration:(NSTimeInterval)duration {
    __weak typeof(self) weakSelf = self;

    // Schedule timer on main thread to ensure it fires
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:duration
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
            [weakSelf handleTimeout];
        }];
    });
}

- (void)pollForToken {
    NSString *deviceCode = _pendingDeviceCode;
    if (!deviceCode) {
        [self stopTimers];
        return;
    }
    // One in flight at a time: overlapping polls let a stale answer for an
    // already-redeemed code arrive after success and flip the state to Error,
    // which then makes ensureValidToken refuse despite a valid session.
    if (self.pollInFlight) {
        tidal::logDebug("Poll still in flight, skipping this tick");
        return;
    }
    self.pollInFlight = YES;

    [[JLTidalAPI shared] pollForTokenWithDeviceCode:deviceCode
                                         completion:^(JLTidalSession *session, NSError *error) {
        self.pollInFlight = NO;

        // Discard anything answering a code we are no longer waiting on, or
        // arriving once the flow already finished.
        if (![deviceCode isEqualToString:self.pendingDeviceCode ?: @""] ||
            self.state == JLTidalAuthStateAuthenticated) {
            tidal::logDebug("Discarding stale device-code poll result");
            return;
        }

        if (session) {
            [self handleAuthSuccess:session];
        } else if (error.code == JLTidalErrorDeviceCodePending) {
            // Still waiting for user - keep polling
            tidal::logDebug("Waiting for user authorization...");
        } else if (error.code == JLTidalErrorDeviceCodeExpired) {
            [self handleAuthError:error];
        } else if (error.code == JLTidalErrorAuthorizationDenied) {
            [self handleAuthError:error];
        } else {
            // Other error - keep trying
            tidal::logDebug([[NSString stringWithFormat:@"Poll error: %@", error.localizedDescription] UTF8String]);
        }
    }];
}

- (void)handleAuthSuccess:(JLTidalSession *)session {
    if (![NSThread isMainThread]) {
        [self onMain:^{ [self handleAuthSuccess:session]; }];
        return;
    }
    [self stopTimers];

    self.session = session;
    [[JLTidalAPI shared] updateSession:session];
    [self storeSession:session];

    self.state = JLTidalAuthStateAuthenticated;
    _pendingDeviceCode = nil;
    self.userCode = nil;
    self.verificationURL = nil;

    [self scheduleProactiveRefresh];
    tidal::logInfo("Authentication successful");

    JLTidalAuthCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, nil);
        });
    }
}

- (void)handleAuthError:(NSError *)error {
    if (![NSThread isMainThread]) {
        [self onMain:^{ [self handleAuthError:error]; }];
        return;
    }
    [self stopTimers];

    self.errorMessage = error.localizedDescription;
    self.state = JLTidalAuthStateError;
    _pendingDeviceCode = nil;
    self.userCode = nil;
    self.verificationURL = nil;

    tidal::logError([[NSString stringWithFormat:@"Authentication failed: %@", error.localizedDescription] UTF8String]);

    JLTidalAuthCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, error);
        });
    }
}

- (void)handleTimeout {
    [self stopTimers];

    self.errorMessage = @"Authentication timed out. Please try again.";
    self.state = JLTidalAuthStateError;
    _pendingDeviceCode = nil;
    self.userCode = nil;
    self.verificationURL = nil;

    tidal::logError("Authentication timed out");

    JLTidalAuthCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        NSError *error = JLTidalError(JLTidalErrorDeviceCodeExpired, self.errorMessage);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, error);
        });
    }
}

- (void)stopTimers {
    [_pollTimer invalidate];
    _pollTimer = nil;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
}

- (void)cancelAuthentication {
    [self stopTimers];
    _pendingDeviceCode = nil;
    _pendingCompletion = nil;
    self.userCode = nil;
    self.verificationURL = nil;

    if (_state != JLTidalAuthStateAuthenticated) {
        self.state = JLTidalAuthStateCancelled;
    }
}

- (void)signOut {
    [self stopTimers];
    [self cancelRefreshTimer];
    [self clearStoredSession];

    // Invalidate any in-flight refresh: bumping the generation makes its
    // eventual result stale (discarded), so a refreshed session cannot
    // resurrect after sign-out. Its waiters are failed here, after the
    // session is cleared, so they observe the signed-out state.
    NSArray<void (^)(BOOL)> *waiters;
    @synchronized (self) {
        _refreshGeneration++;
        _isRefreshing = NO;
        waiters = [_pendingRefreshCompletions copy];
        [_pendingRefreshCompletions removeAllObjects];
    }

    self.session = nil;
    [[JLTidalAPI shared] updateSession:nil];
    _pendingDeviceCode = nil;
    _pendingCompletion = nil;
    self.errorMessage = nil;
    self.userCode = nil;
    self.verificationURL = nil;
    self.state = JLTidalAuthStateIdle;

    for (void (^waiter)(BOOL) in waiters) {
        waiter(NO);
    }

    tidal::logInfo("Signed out");
}

#pragma mark - Token Refresh

- (void)refreshTokenIfNeededWithCompletion:(void(^)(BOOL success))completion {
    [self refreshTokenForced:NO completion:completion];
}

// `force` skips the local-expiry shortcut. A 401 means the server has already
// rejected the token, so answering "not expired yet, carry on" would send it
// straight back and turn a repairable session into a dead one that still
// reports itself healthy in Preferences.
- (void)refreshTokenForced:(BOOL)force completion:(void(^)(BOOL success))completion {
    JLTidalSession *session = self.session;
    if (!session.refreshToken) {
        tidal::logInfo("refreshToken: no refresh token available");
        if (completion) completion(NO);
        return;
    }

    if (!force && !session.needsRefresh) {
        if (completion) completion(YES);
        return;
    }

    // Single-flight: the first caller starts the refresh; concurrent callers
    // just enqueue their completion and are drained with the real result.
    NSUInteger generation;
    @synchronized (self) {
        if (completion) {
            [_pendingRefreshCompletions addObject:[completion copy]];
        }
        if (_isRefreshing) {
            tidal::logInfo("refreshToken: refresh already in flight, waiting for its result");
            return;
        }
        _isRefreshing = YES;
        generation = _refreshGeneration;
    }
    tidal::logInfo("refreshToken: starting refresh");

    [[JLTidalAPI shared] refreshTokenWithCompletion:^(JLTidalSession *newSession, NSError *error) {
        [self finishRefreshWithSession:newSession error:error generation:generation];
    }];
}

- (void)finishRefreshWithSession:(JLTidalSession *)newSession
                           error:(NSError *)error
                      generation:(NSUInteger)generation {
    NSArray<void (^)(BOOL)> *waiters = nil;
    @synchronized (self) {
        if (generation != _refreshGeneration) {
            // signOut ran while this refresh was in flight: it already failed
            // the waiters and cleared the session. Discard the result so a
            // refreshed session cannot resurrect after sign-out.
            tidal::logInfo("refreshToken: result discarded (signed out during refresh)");
            return;
        }
        _isRefreshing = NO;
        waiters = [_pendingRefreshCompletions copy];
        [_pendingRefreshCompletions removeAllObjects];
    }

    self.lastRefreshAttempt = [NSDate date];

    BOOL success = (newSession != nil);
    if (newSession) {
        self.session = newSession;
        // AuthService is the sole writer of the API session.
        [[JLTidalAPI shared] updateSession:newSession];
        [self storeSession:newSession];
        [self scheduleProactiveRefresh];
        self.lastRefreshError = nil;
        self.lastRefreshWasTerminal = NO;
        tidal::logInfo([[NSString stringWithFormat:@"refreshToken: success, new expiry in %.0fs",
                         [newSession.expiryDate timeIntervalSinceNow]] UTF8String]);
    } else {
        self.lastRefreshError = error.localizedDescription ?: @"unknown error";
        self.lastRefreshWasTerminal = JLTidalErrorIsTerminalAuthFailure(error);
        tidal::logError([[NSString stringWithFormat:@"refreshToken: failed - %@", error.localizedDescription] UTF8String]);
        // Don't signOut here - let the caller decide how to handle the failure.
        // Signing out aggressively wipes the refresh token before reconnect
        // fallback can start, and prevents manual retry.
    }

    for (void (^waiter)(BOOL) in waiters) {
        waiter(success);
    }
}

- (void)ensureValidTokenWithCompletion:(void(^)(NSError *error))completion {
    // Check if we have a session at all
    // Gate on the session, not the state enum. A startup refresh that failed
    // for transient reasons leaves a perfectly usable refresh token behind,
    // and refusing here is what made every feature report "not authenticated"
    // until the app was restarted.
    JLTidalSession *session = self.session;
    if (!session || session.refreshToken.length == 0) {
        tidal::logError([[NSString stringWithFormat:@"ensureValidToken: no usable session (state=%ld, session=%@) — playback will fail",
                         (long)_state,
                         session ? @"yes" : @"no"] UTF8String]);
        completion(JLTidalError(JLTidalErrorNotAuthenticated, @"Not authenticated"));
        return;
    }

    // If token is valid and doesn't need refresh, we're good
    if (session.isValid && !session.needsRefresh) {
        completion(nil);
        return;
    }

    // Token is expired or expiring - try to refresh
    if (session.refreshToken.length > 0) {
        tidal::logInfo([[NSString stringWithFormat:@"ensureValidToken: token expired/expiring (valid=%d, needsRefresh=%d), refreshing on-demand",
                         session.isValid, session.needsRefresh] UTF8String]);
        [self refreshTokenIfNeededWithCompletion:^(BOOL success) {
            if (success) {
                completion(nil);
            } else {
                tidal::logError("ensureValidToken: on-demand refresh failed — playback will fail until reconnect");
                completion(JLTidalError(JLTidalErrorTokenRefreshFailed, @"Failed to refresh token"));
            }
        }];
    } else {
        tidal::logError("ensureValidToken: token invalid and no refresh token — reconnect required");
        completion(JLTidalError(JLTidalErrorNotAuthenticated, @"Token expired and no refresh token"));
    }
}

@end
