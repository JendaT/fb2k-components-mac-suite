//
//  LastFmSession.h
//  foo_scrobble_mac
//
//  Last.fm session model - stores session key and user info
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LastFmSession : NSObject <NSSecureCoding, NSCopying>

/// The session key for authenticated API calls
@property (nonatomic, copy, readonly) NSString* sessionKey;

/// The username associated with this session
@property (nonatomic, copy, readonly) NSString* username;

/// Whether this session is subscriber (premium) account
@property (nonatomic, readonly) BOOL isSubscriber;

/// Initialization
- (instancetype)initWithSessionKey:(NSString*)sessionKey
                          username:(NSString*)username
                      isSubscriber:(BOOL)isSubscriber NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Create from API response dictionary
+ (nullable instancetype)sessionFromResponse:(NSDictionary*)response;

/// Check if session appears valid (non-empty key)
@property (nonatomic, readonly, getter=isValid) BOOL valid;

@end

NS_ASSUME_NONNULL_END
