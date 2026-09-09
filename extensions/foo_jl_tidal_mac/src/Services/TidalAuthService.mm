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
        [JLTidalAPI shared].tokenRefreshHandler = ^(void (^completion)(BOOL success)) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) {
                completion(NO);
                return;
            }
            [strongSelf refreshTokenIfNeededWithCompletion:completion];
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

#pragma mark - Session Storage

- (void)loadStoredSession {
    NSString *accessToken = [JLTidalKeychainHelper loadAccessToken];
    NSString *refreshToken = [JLTidalKeychainHelper loadRefreshToken];
    NSDate *expiry = [JLTidalKeychainHelper loadTokenExpiry];
    NSString *userId = [JLTidalKeychainHelper loadUserId];
    NSString *username = [JLTidalKeychainHelper loadUsername];
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
                    [self scheduleProactiveRefresh];
                } else {
                    self.state = JLTidalAuthStateIdle;
                }
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

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                               repeats:NO
                                                                 block:^(NSTimer *timer) {
            tidal::logDebug("Proactive token refresh triggered");
            [weakSelf refreshTokenIfNeededWithCompletion:^(BOOL success) {
                if (success) {
                    tidal::logInfo("Proactive token refresh succeeded");
                    // Schedule next refresh for the new token
                    [weakSelf scheduleProactiveRefresh];
                } else {
                    tidal::logError("Proactive token refresh failed");
                    // Retry in 5 minutes
                    dispatch_async(dispatch_get_main_queue(), ^{
                        weakSelf.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:300
                                                                               repeats:NO
                                                                                 block:^(NSTimer *retryTimer) {
                            [weakSelf scheduleProactiveRefresh];
                        }];
                    });
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
        self.verificationURL = deviceCode.verificationURIComplete ?: deviceCode.verificationURI;
        self.state = JLTidalAuthStateWaitingForApproval;

        // Open browser for user to authorize
        // Use known working URL - link.tidal.com handles device authorization
        NSURL *linkURL = [NSURL URLWithString:@"https://link.tidal.com"];
        tidal::logDebug("Opening https://link.tidal.com for device authorization");
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
    if (!_pendingDeviceCode) {
        [self stopTimers];
        return;
    }

    [[JLTidalAPI shared] pollForTokenWithDeviceCode:_pendingDeviceCode
                                         completion:^(JLTidalSession *session, NSError *error) {
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
    JLTidalSession *session = self.session;
    if (!session.refreshToken) {
        tidal::logInfo("refreshToken: no refresh token available");
        if (completion) completion(NO);
        return;
    }

    if (!session.needsRefresh) {
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
        tidal::logInfo([[NSString stringWithFormat:@"refreshToken: success, new expiry in %.0fs",
                         [newSession.expiryDate timeIntervalSinceNow]] UTF8String]);
    } else {
        self.lastRefreshError = error.localizedDescription ?: @"unknown error";
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
    JLTidalSession *session = self.session;
    if (_state != JLTidalAuthStateAuthenticated || !session) {
        tidal::logError([[NSString stringWithFormat:@"ensureValidToken: not authenticated (state=%ld, session=%@) — playback will fail",
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
