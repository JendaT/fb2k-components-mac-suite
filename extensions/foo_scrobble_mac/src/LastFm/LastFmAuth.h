//
//  LastFmAuth.h
//  foo_scrobble_mac
//
//  Browser-based authentication flow for Last.fm
//

#pragma once

#import <Foundation/Foundation.h>
#import "LastFmSession.h"

NS_ASSUME_NONNULL_BEGIN

/// Authentication state
typedef NS_ENUM(NSInteger, LastFmAuthState) {
    LastFmAuthStateNotAuthenticated,    // No session, not in progress
    LastFmAuthStateRequestingToken,     // Requesting auth token from API
    LastFmAuthStateWaitingForApproval,  // Browser opened, polling for approval
    LastFmAuthStateExchangingToken,     // User approved, getting session
    LastFmAuthStateAuthenticated,       // Successfully authenticated
    LastFmAuthStateError                // Authentication failed
};

/// Notification posted when auth state changes
extern NSNotificationName const LastFmAuthStateDidChangeNotification;

/// Completion handler for authentication
typedef void (^LastFmAuthCompletion)(BOOL success, NSError* _Nullable error);


@interface LastFmAuth : NSObject

/// Shared authentication manager
+ (instancetype)shared;

/// Current authentication state
@property (nonatomic, readonly) LastFmAuthState state;

/// Current session (nil if not authenticated)
@property (nonatomic, strong, readonly, nullable) LastFmSession* session;

/// Authenticated username (convenience accessor)
@property (nonatomic, copy, readonly, nullable) NSString* username;

/// Profile image URL (fetched after authentication)
@property (nonatomic, copy, readonly, nullable) NSURL* profileImageURL;

/// Cached profile image (nil until loaded)
@property (nonatomic, strong, readonly, nullable) NSImage* profileImage;

/// Last error message if state is Error
@property (nonatomic, copy, readonly, nullable) NSString* errorMessage;

/// Whether user is currently authenticated
@property (nonatomic, readonly, getter=isAuthenticated) BOOL authenticated;

#pragma mark - Authentication Flow

/// Start browser-based authentication flow
/// Opens Last.fm in browser and polls for approval
- (void)startAuthenticationWithCompletion:(nullable LastFmAuthCompletion)completion;

/// Cancel ongoing authentication attempt
- (void)cancelAuthentication;

/// Sign out and clear session
- (void)signOut;

/// Load session from Keychain (call on startup)
- (void)loadStoredSession;

/// Validate current session with Last.fm
- (void)validateSessionWithCompletion:(nullable void(^)(BOOL valid))completion;

@end

NS_ASSUME_NONNULL_END
