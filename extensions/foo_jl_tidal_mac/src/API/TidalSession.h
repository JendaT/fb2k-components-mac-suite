//
//  TidalSession.h
//  foo_jl_tidal_mac
//
//  OAuth token container for Tidal authentication
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalConstants.h"

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalSession : NSObject

/// Access token for API requests
@property (nonatomic, copy, readonly) NSString *accessToken;

/// Refresh token for obtaining new access tokens
@property (nonatomic, copy, readonly) NSString *refreshToken;

/// Token expiry date
@property (nonatomic, strong, readonly) NSDate *expiryDate;

/// User ID (if available)
@property (nonatomic, copy, readonly, nullable) NSString *userId;

/// Username (if available)
@property (nonatomic, copy, readonly, nullable) NSString *username;

/// Country code for content availability
@property (nonatomic, copy, readonly, nullable) NSString *countryCode;

/// Initialize with tokens from OAuth response
- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
                          expiresIn:(NSTimeInterval)expiresIn;

/// Initialize with all fields
- (instancetype)initWithAccessToken:(NSString *)accessToken
                       refreshToken:(NSString *)refreshToken
                          expiresIn:(NSTimeInterval)expiresIn
                             userId:(nullable NSString *)userId
                           username:(nullable NSString *)username
                        countryCode:(nullable NSString *)countryCode;

/// Check if access token has expired or will expire soon
@property (nonatomic, readonly, getter=isExpired) BOOL expired;

/// Check if access token needs refresh (includes buffer time)
@property (nonatomic, readonly) BOOL needsRefresh;

/// Check if session is valid (has tokens and not expired)
@property (nonatomic, readonly, getter=isValid) BOOL valid;

/// Create updated session with new access token
- (JLTidalSession *)sessionByUpdatingAccessToken:(NSString *)newAccessToken
                                       expiresIn:(NSTimeInterval)expiresIn;

@end

NS_ASSUME_NONNULL_END
