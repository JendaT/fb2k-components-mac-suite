//
//  KeychainHelper.h
//  foo_jl_tidal_mac
//
//  Secure storage for Tidal OAuth tokens using macOS Keychain
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalKeychainHelper : NSObject

#pragma mark - Token Storage

/// Store access token securely in Keychain
+ (BOOL)storeAccessToken:(NSString *)token;

/// Retrieve access token from Keychain
+ (nullable NSString *)loadAccessToken;

/// Store refresh token securely in Keychain
+ (BOOL)storeRefreshToken:(NSString *)token;

/// Retrieve refresh token from Keychain
+ (nullable NSString *)loadRefreshToken;

/// Delete all stored tokens (for logout)
+ (BOOL)deleteAllTokens;

#pragma mark - Token Expiry

/// Store token expiry timestamp
+ (void)storeTokenExpiry:(NSDate *)expiryDate;

/// Retrieve token expiry timestamp
+ (nullable NSDate *)loadTokenExpiry;

/// Check if access token is expired (with buffer for refresh)
+ (BOOL)isAccessTokenExpired;

/// Check if any tokens are stored
+ (BOOL)hasStoredCredentials;

#pragma mark - User Profile

/// Store user profile info (userId, username, countryCode)
+ (void)storeUserId:(nullable NSString *)userId;
+ (void)storeUsername:(nullable NSString *)username;
+ (void)storeCountryCode:(nullable NSString *)countryCode;

/// Retrieve user profile info
+ (nullable NSString *)loadUserId;
+ (nullable NSString *)loadUsername;
+ (nullable NSString *)loadCountryCode;

@end

NS_ASSUME_NONNULL_END
