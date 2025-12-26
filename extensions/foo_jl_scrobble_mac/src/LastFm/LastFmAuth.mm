//
//  LastFmAuth.mm
//  foo_scrobble_mac
//
//  Browser-based authentication implementation
//

#import "LastFmAuth.h"
#import "LastFmClient.h"
#import "LastFmConstants.h"
#import "LastFmErrors.h"
#import "../Core/KeychainHelper.h"
#import "../Core/ScrobbleNotifications.h"
#import <AppKit/AppKit.h>

// Keychain account for session key
static NSString* const kKeychainSessionAccount = @"lastfm_session";

@interface LastFmAuth ()
@property (nonatomic, readwrite) LastFmAuthState state;
@property (nonatomic, strong, readwrite, nullable) LastFmSession* session;
@property (nonatomic, copy, readwrite, nullable) NSString* errorMessage;
@property (nonatomic, copy, readwrite, nullable) NSURL* profileImageURL;
@property (nonatomic, strong, readwrite, nullable) NSImage* profileImage;

@property (nonatomic, strong, nullable) NSTimer* pollTimer;
@property (nonatomic, strong, nullable) NSTimer* timeoutTimer;
@property (nonatomic, copy, nullable) NSString* pendingToken;
@property (nonatomic, copy, nullable) LastFmAuthCompletion pendingCompletion;
@end

@implementation LastFmAuth

#pragma mark - Singleton

+ (instancetype)shared {
    static LastFmAuth* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LastFmAuth alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = LastFmAuthStateNotAuthenticated;
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isAuthenticated {
    return _state == LastFmAuthStateAuthenticated && _session != nil && _session.isValid;
}

- (NSString*)username {
    return _session.username;
}

- (void)setState:(LastFmAuthState)state {
    if (_state != state) {
        _state = state;
        [[NSNotificationCenter defaultCenter] postNotificationName:LastFmAuthStateDidChangeNotification
                                                            object:self];
    }
}

#pragma mark - Session Storage

- (void)loadStoredSession {
    NSString* sessionKey = [KeychainHelper loadPassword:kKeychainSessionAccount];
    NSString* username = [KeychainHelper loadPassword:@"lastfm_username"];

    if (sessionKey.length > 0 && username.length > 0) {
        _session = [[LastFmSession alloc] initWithSessionKey:sessionKey
                                                    username:username
                                                isSubscriber:NO];
        [LastFmClient shared].session = _session;
        self.state = LastFmAuthStateAuthenticated;

        // Fetch profile image
        [self fetchProfileImage];
    }
}

- (void)storeSession:(LastFmSession*)session {
    [KeychainHelper savePassword:session.sessionKey forAccount:kKeychainSessionAccount];
    [KeychainHelper savePassword:session.username forAccount:@"lastfm_username"];
}

- (void)clearStoredSession {
    [KeychainHelper deletePassword:kKeychainSessionAccount];
    [KeychainHelper deletePassword:@"lastfm_username"];
}

#pragma mark - Authentication Flow

- (void)startAuthenticationWithCompletion:(LastFmAuthCompletion)completion {
    // Cancel any existing auth attempt
    [self cancelAuthentication];

    _pendingCompletion = [completion copy];
    self.errorMessage = nil;
    self.state = LastFmAuthStateRequestingToken;

    // Request auth token
    [[LastFmClient shared] requestAuthTokenWithCompletion:^(NSString* token, NSError* error) {
        if (error) {
            [self handleAuthError:error];
            return;
        }

        self.pendingToken = token;
        self.state = LastFmAuthStateWaitingForApproval;

        // Open browser for user to approve
        NSURL* authURL = [[LastFmClient shared] authorizationURLWithToken:token];
        [[NSWorkspace sharedWorkspace] openURL:authURL];

        // Start polling for approval
        [self startPolling];

        // Set timeout
        [self startTimeout];
    }];
}

- (void)startPolling {
    __weak typeof(self) weakSelf = self;

    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:LastFm::kAuthPollInterval
                                                 repeats:YES
                                                   block:^(NSTimer* timer) {
        [weakSelf checkTokenApproval];
    }];
}

- (void)startTimeout {
    __weak typeof(self) weakSelf = self;

    _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:LastFm::kAuthTimeout
                                                    repeats:NO
                                                      block:^(NSTimer* timer) {
        [weakSelf handleTimeout];
    }];
}

- (void)checkTokenApproval {
    if (!_pendingToken) {
        [self stopTimers];
        return;
    }

    self.state = LastFmAuthStateExchangingToken;

    [[LastFmClient shared] requestSessionWithToken:_pendingToken
                                        completion:^(LastFmSession* session, NSError* error) {
        if (session) {
            [self handleAuthSuccess:session];
        } else if (error.code == LastFmErrorNotAuthorized) {
            // Token not yet authorized - keep polling
            self.state = LastFmAuthStateWaitingForApproval;
        } else {
            // Other error - fail
            [self handleAuthError:error];
        }
    }];
}

- (void)handleAuthSuccess:(LastFmSession*)session {
    [self stopTimers];

    _session = session;
    [LastFmClient shared].session = session;
    [self storeSession:session];

    self.state = LastFmAuthStateAuthenticated;
    _pendingToken = nil;

    // Fetch user profile info including image
    [self fetchProfileImage];

    LastFmAuthCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        completion(YES, nil);
    }
}

- (void)fetchProfileImage {
    [[LastFmClient shared] fetchUserInfoWithCompletion:^(NSString* username, NSURL* imageURL, NSError* error) {
        if (imageURL) {
            self.profileImageURL = imageURL;
            [self downloadProfileImage:imageURL];
        }
    }];
}

- (void)downloadProfileImage:(NSURL*)url {
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (data && !error) {
            NSImage* image = [[NSImage alloc] initWithData:data];
            if (image) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.profileImage = image;
                    // Notify observers that auth state changed (to trigger UI update)
                    [[NSNotificationCenter defaultCenter] postNotificationName:LastFmAuthStateDidChangeNotification
                                                                        object:self];
                });
            }
        }
    }];
    [task resume];
}

- (void)handleAuthError:(NSError*)error {
    [self stopTimers];

    self.errorMessage = error.localizedDescription;
    self.state = LastFmAuthStateError;
    _pendingToken = nil;

    LastFmAuthCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        completion(NO, error);
    }
}

- (void)handleTimeout {
    [self stopTimers];

    self.errorMessage = @"Authentication timed out. Please try again.";
    self.state = LastFmAuthStateError;
    _pendingToken = nil;

    LastFmAuthCompletion completion = _pendingCompletion;
    _pendingCompletion = nil;
    if (completion) {
        NSError* error = LastFmMakeError(LastFmErrorOperationFailed, self.errorMessage);
        completion(NO, error);
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
    _pendingToken = nil;
    _pendingCompletion = nil;

    if (_state != LastFmAuthStateAuthenticated) {
        self.state = LastFmAuthStateNotAuthenticated;
    }
}

- (void)signOut {
    [self stopTimers];
    [self clearStoredSession];

    _session = nil;
    [LastFmClient shared].session = nil;
    _pendingToken = nil;
    _pendingCompletion = nil;
    self.errorMessage = nil;
    self.profileImageURL = nil;
    self.profileImage = nil;
    self.state = LastFmAuthStateNotAuthenticated;
}

#pragma mark - Session Validation

- (void)validateSessionWithCompletion:(void(^)(BOOL valid))completion {
    if (!self.isAuthenticated) {
        if (completion) completion(NO);
        return;
    }

    [[LastFmClient shared] validateSessionWithCompletion:^(BOOL valid, NSString* username, NSError* error) {
        if (!valid && LastFmErrorRequiresReauth((LastFmErrorCode)error.code)) {
            // Session is invalid - sign out
            [self signOut];
        }
        if (completion) completion(valid);
    }];
}

@end
