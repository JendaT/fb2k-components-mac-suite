//
//  TidalAuthService.mm
//  foo_jl_tidal_mac
//
//  OAuth Device Code authentication implementation
//

#import "TidalAuthService.h"
#import "../API/TidalAPI.h"
#import "../API/TidalConstants.h"
#import "../Core/TidalErrors.h"
#import "../Core/TidalConfig.h"
#import "../Core/KeychainHelper.h"
#import <AppKit/AppKit.h>

NSNotificationName const JLTidalAuthStateDidChangeNotification = @"JLTidalAuthStateDidChange";

@interface JLTidalAuthService ()
@property (nonatomic, readwrite) JLTidalAuthState state;
@property (nonatomic, strong, readwrite, nullable) JLTidalSession *session;
@property (nonatomic, copy, readwrite, nullable) NSString *userCode;
@property (nonatomic, copy, readwrite, nullable) NSURL *verificationURL;
@property (nonatomic, copy, readwrite, nullable) NSString *errorMessage;

@property (nonatomic, strong, nullable) NSTimer *pollTimer;
@property (nonatomic, strong, nullable) NSTimer *timeoutTimer;
@property (nonatomic, copy, nullable) NSString *pendingDeviceCode;
@property (nonatomic, copy, nullable) JLTidalAuthCompletion pendingCompletion;
@property (nonatomic, assign) BOOL isRefreshing;
@end

@implementation JLTidalAuthService

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
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isAuthenticated {
    return _state == JLTidalAuthStateAuthenticated && _session != nil && _session.isValid;
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

        _session = [[JLTidalSession alloc] initWithAccessToken:accessToken
                                                  refreshToken:refreshToken
                                                     expiresIn:expiresIn
                                                        userId:userId
                                                      username:username
                                                   countryCode:countryCode];
        [JLTidalAPI shared].session = _session;

        tidal::logDebug([[NSString stringWithFormat:@"Loaded session: userId=%@, countryCode=%@",
                         userId ?: @"(nil)", countryCode ?: @"(nil)"] UTF8String]);

        if (_session.needsRefresh) {
            // Token expired or expiring soon - refresh it
            tidal::logDebug("Stored token needs refresh");
            [self refreshTokenIfNeededWithCompletion:^(BOOL success) {
                if (success) {
                    self.state = JLTidalAuthStateAuthenticated;
                } else {
                    self.state = JLTidalAuthStateIdle;
                }
            }];
        } else {
            self.state = JLTidalAuthStateAuthenticated;
            tidal::logInfo("Loaded stored session");
        }
    }
}

- (void)storeSession:(JLTidalSession *)session {
    [JLTidalKeychainHelper storeAccessToken:session.accessToken];
    [JLTidalKeychainHelper storeRefreshToken:session.refreshToken];
    [JLTidalKeychainHelper storeTokenExpiry:session.expiryDate];
    [JLTidalKeychainHelper storeUserId:session.userId];
    [JLTidalKeychainHelper storeUsername:session.username];
    [JLTidalKeychainHelper storeCountryCode:session.countryCode];
}

- (void)clearStoredSession {
    [JLTidalKeychainHelper deleteAllTokens];
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

    _session = session;
    [JLTidalAPI shared].session = session;
    [self storeSession:session];

    self.state = JLTidalAuthStateAuthenticated;
    _pendingDeviceCode = nil;
    self.userCode = nil;
    self.verificationURL = nil;

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
    [self clearStoredSession];

    _session = nil;
    [JLTidalAPI shared].session = nil;
    _pendingDeviceCode = nil;
    _pendingCompletion = nil;
    self.errorMessage = nil;
    self.userCode = nil;
    self.verificationURL = nil;
    self.state = JLTidalAuthStateIdle;

    tidal::logInfo("Signed out");
}

#pragma mark - Token Refresh

- (void)refreshTokenIfNeededWithCompletion:(void(^)(BOOL success))completion {
    if (!_session.refreshToken) {
        if (completion) completion(NO);
        return;
    }

    if (!_session.needsRefresh) {
        if (completion) completion(YES);
        return;
    }

    if (_isRefreshing) {
        // Already refreshing - wait and check again
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (completion) completion(self.session.isValid);
        });
        return;
    }

    _isRefreshing = YES;
    tidal::logDebug("Refreshing token...");

    [[JLTidalAPI shared] refreshTokenWithCompletion:^(JLTidalSession *session, NSError *error) {
        self.isRefreshing = NO;

        if (session) {
            self.session = session;
            [JLTidalAPI shared].session = session;
            [self storeSession:session];
            tidal::logDebug("Token refreshed");
            if (completion) completion(YES);
        } else {
            tidal::logError([[NSString stringWithFormat:@"Token refresh failed: %@", error.localizedDescription] UTF8String]);
            if (JLTidalErrorRequiresReauth(error)) {
                [self signOut];
            }
            if (completion) completion(NO);
        }
    }];
}

- (void)ensureValidTokenWithCompletion:(void(^)(NSError *error))completion {
    // Check if we have a session at all
    if (_state != JLTidalAuthStateAuthenticated || !_session) {
        tidal::logDebug([[NSString stringWithFormat:@"ensureValidToken: no session (state=%ld, session=%@)",
                         (long)_state,
                         _session ? @"yes" : @"no"] UTF8String]);
        completion(JLTidalError(JLTidalErrorNotAuthenticated, @"Not authenticated"));
        return;
    }

    // If token is valid and doesn't need refresh, we're good
    if (_session.isValid && !_session.needsRefresh) {
        tidal::logDebug("ensureValidToken: token is valid");
        completion(nil);
        return;
    }

    // Token is expired or expiring - try to refresh
    if (_session.refreshToken.length > 0) {
        tidal::logDebug([[NSString stringWithFormat:@"ensureValidToken: token expired/expiring (valid=%d, needsRefresh=%d), attempting refresh",
                         _session.isValid, _session.needsRefresh] UTF8String]);
        [self refreshTokenIfNeededWithCompletion:^(BOOL success) {
            if (success) {
                tidal::logDebug("ensureValidToken: refresh succeeded");
                completion(nil);
            } else {
                tidal::logDebug("ensureValidToken: refresh failed");
                completion(JLTidalError(JLTidalErrorTokenRefreshFailed, @"Failed to refresh token"));
            }
        }];
    } else {
        tidal::logDebug("ensureValidToken: token invalid and no refresh token");
        completion(JLTidalError(JLTidalErrorNotAuthenticated, @"Token expired and no refresh token"));
    }
}

@end
