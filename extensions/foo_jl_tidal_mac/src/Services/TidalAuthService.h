//
//  TidalAuthService.h
//  foo_jl_tidal_mac
//
//  OAuth Device Code authentication flow state machine
//

#pragma once

#import <Foundation/Foundation.h>
#import "../API/TidalSession.h"

NS_ASSUME_NONNULL_BEGIN

/// Authentication state
typedef NS_ENUM(NSInteger, JLTidalAuthState) {
    JLTidalAuthStateIdle,                   // Not authenticated, not in progress
    JLTidalAuthStateRequestingDeviceCode,   // Requesting device code from API
    JLTidalAuthStateWaitingForApproval,     // Showing code to user, polling for approval
    JLTidalAuthStateExchangingToken,        // User approved, exchanging for token
    JLTidalAuthStateAuthenticated,          // Successfully authenticated
    JLTidalAuthStateCancelled,              // Authentication cancelled
    JLTidalAuthStateError                   // Authentication failed
};

/// Notification posted when auth state changes
extern NSNotificationName const JLTidalAuthStateDidChangeNotification;

/// Completion handler for authentication
typedef void (^JLTidalAuthCompletion)(BOOL success, NSError * _Nullable error);

@interface JLTidalAuthService : NSObject

/// Shared authentication service
+ (instancetype)shared;

/// Current authentication state
@property (nonatomic, readonly) JLTidalAuthState state;

/// Current session (nil if not authenticated). Atomic: read from network
/// callback threads while written on refresh.
@property (atomic, strong, readonly, nullable) JLTidalSession *session;

/// User code to display during authentication
@property (nonatomic, copy, readonly, nullable) NSString *userCode;

/// Verification URL to display during authentication
@property (nonatomic, copy, readonly, nullable) NSURL *verificationURL;

/// Last error message if state is Error
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;

/// Whether user is currently authenticated (state Authenticated AND the access
/// token is still valid). Use -hasSession for UI gating instead: an expiring
/// token refreshes on demand, so this can read NO while everything works.
@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;

/// Whether a usable session exists at all, regardless of access-token freshness.
/// This is the right question for showing or hiding UI.
@property (nonatomic, readonly) BOOL hasSession;

/// YES when the last refresh failed because the grant itself was rejected, as
/// opposed to a transient network or server failure. Only a terminal failure
/// justifies discarding the stored session.
@property (nonatomic, readonly) BOOL lastRefreshWasTerminal;

/// Last token refresh attempt timestamp (nil if never attempted this session)
@property (nonatomic, copy, readonly, nullable) NSDate *lastRefreshAttempt;

/// Last token refresh error (nil if last attempt succeeded or never attempted)
@property (nonatomic, copy, readonly, nullable) NSString *lastRefreshError;

#pragma mark - Authentication Flow

/// Start OAuth Device Code authentication flow
/// Opens browser for user to authorize and polls for approval
- (void)startAuthenticationWithCompletion:(nullable JLTidalAuthCompletion)completion;

/// Cancel ongoing authentication attempt
- (void)cancelAuthentication;

/// Sign out and clear tokens
- (void)signOut;

/// Load session from Keychain (call on startup)
- (void)loadStoredSession;

/// Refresh token if needed
- (void)refreshTokenIfNeededWithCompletion:(nullable void(^)(BOOL success))completion;

/// As above, but `force` posts a refresh grant even when the stored token has
/// not locally expired. The 401 path needs this: the server has already
/// rejected the token, so a local clock check would wave it through and the
/// retry would re-send it.
- (void)refreshTokenForced:(BOOL)force completion:(nullable void(^)(BOOL success))completion;

/// Ensure we have a valid token, refreshing if necessary
- (void)ensureValidTokenWithCompletion:(void(^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
