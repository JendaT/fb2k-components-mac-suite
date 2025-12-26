//
//  LastFmClient.h
//  foo_scrobble_mac
//
//  Last.fm API client - handles all API communication
//

#pragma once

#import <Foundation/Foundation.h>
#import "LastFmSession.h"
#import "LastFmErrors.h"

NS_ASSUME_NONNULL_BEGIN

@class ScrobbleTrack;

/// Completion handler for authentication token request
typedef void (^LastFmTokenCompletion)(NSString* _Nullable token, NSError* _Nullable error);

/// Completion handler for session request
typedef void (^LastFmSessionCompletion)(LastFmSession* _Nullable session, NSError* _Nullable error);

/// Completion handler for Now Playing update
typedef void (^LastFmNowPlayingCompletion)(BOOL success, NSError* _Nullable error);

/// Completion handler for scrobble submission
typedef void (^LastFmScrobbleCompletion)(NSInteger accepted, NSInteger ignored, NSError* _Nullable error);

/// Completion handler for session validation
typedef void (^LastFmValidationCompletion)(BOOL valid, NSString* _Nullable username, NSError* _Nullable error);

/// Completion handler for user info request (includes profile image URL)
typedef void (^LastFmUserInfoCompletion)(NSString* _Nullable username, NSURL* _Nullable imageURL, NSError* _Nullable error);


@interface LastFmClient : NSObject

/// Shared client instance
+ (instancetype)shared;

/// Current session (nil if not authenticated)
@property (nonatomic, strong, nullable) LastFmSession* session;

#pragma mark - Authentication

/// Request a new authentication token
- (void)requestAuthTokenWithCompletion:(LastFmTokenCompletion)completion;

/// Exchange token for session after user approval
- (void)requestSessionWithToken:(NSString*)token
                     completion:(LastFmSessionCompletion)completion;

/// Build the authorization URL for user to approve the token
- (NSURL*)authorizationURLWithToken:(NSString*)token;

/// Validate current session by calling user.getInfo
- (void)validateSessionWithCompletion:(LastFmValidationCompletion)completion;

/// Fetch user info including profile image
- (void)fetchUserInfoWithCompletion:(LastFmUserInfoCompletion)completion;

#pragma mark - Scrobbling

/// Send Now Playing notification
- (void)sendNowPlaying:(ScrobbleTrack*)track
            completion:(LastFmNowPlayingCompletion)completion;

/// Submit a batch of scrobbles (max 50)
- (void)scrobbleTracks:(NSArray<ScrobbleTrack*>*)tracks
            completion:(LastFmScrobbleCompletion)completion;

#pragma mark - Low-level

/// Cancel all pending requests
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
