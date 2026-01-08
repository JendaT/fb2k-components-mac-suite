//
//  TidalAPI.h
//  foo_jl_tidal_mac
//
//  HTTP client for Tidal API requests
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalSession.h"
#import "TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

/// Device code response from OAuth device authorization
@interface JLTidalDeviceCode : NSObject
@property (nonatomic, copy, readonly) NSString *deviceCode;
@property (nonatomic, copy, readonly) NSString *userCode;
@property (nonatomic, copy, readonly) NSURL *verificationURI;
@property (nonatomic, copy, readonly, nullable) NSURL *verificationURIComplete;
@property (nonatomic, readonly) NSTimeInterval expiresIn;
@property (nonatomic, readonly) NSTimeInterval interval;

- (instancetype)initWithDeviceCode:(NSString *)deviceCode
                          userCode:(NSString *)userCode
                   verificationURI:(NSURL *)verificationURI
           verificationURIComplete:(nullable NSURL *)verificationURIComplete
                         expiresIn:(NSTimeInterval)expiresIn
                          interval:(NSTimeInterval)interval;
@end

@class JLTidalTrack;

/// Completion handlers
typedef void (^JLTidalDeviceCodeCompletion)(JLTidalDeviceCode * _Nullable deviceCode, NSError * _Nullable error);
typedef void (^JLTidalSessionCompletion)(JLTidalSession * _Nullable session, NSError * _Nullable error);
typedef void (^JLTidalDataCompletion)(NSDictionary * _Nullable json, NSError * _Nullable error);
typedef void (^JLTidalTracksCompletion)(NSArray<JLTidalTrack *> * _Nullable tracks, NSError * _Nullable error);

@interface JLTidalAPI : NSObject

/// Shared API client instance
+ (instancetype)shared;

/// Current session (set after successful authentication)
@property (nonatomic, strong, nullable) JLTidalSession *session;

#pragma mark - OAuth Device Authorization

/// Request device code for OAuth flow
- (void)requestDeviceCodeWithCompletion:(JLTidalDeviceCodeCompletion)completion;

/// Poll for access token using device code
/// Returns JLTidalErrorDeviceCodePending if user hasn't approved yet
- (void)pollForTokenWithDeviceCode:(NSString *)deviceCode
                        completion:(JLTidalSessionCompletion)completion;

/// Refresh access token using refresh token
- (void)refreshTokenWithCompletion:(JLTidalSessionCompletion)completion;

#pragma mark - Track API

/// Get playback info for a track
/// Returns stream URL and manifest information
- (void)getPlaybackInfoForTrackID:(NSString *)trackID
                          quality:(JLTidalQuality)quality
                       completion:(JLTidalDataCompletion)completion;

/// Get track metadata
- (void)getTrackMetadataForTrackID:(NSString *)trackID
                        completion:(JLTidalDataCompletion)completion;

#pragma mark - Search API

/// Search for tracks
- (void)searchTracksWithQuery:(NSString *)query
                        limit:(NSInteger)limit
                       offset:(NSInteger)offset
                   completion:(JLTidalTracksCompletion)completion;

#pragma mark - Generic Request

/// Make authenticated API request
- (void)requestWithURL:(NSURL *)url
                method:(NSString *)method
                  body:(nullable NSDictionary *)body
            completion:(JLTidalDataCompletion)completion;

@end

NS_ASSUME_NONNULL_END
