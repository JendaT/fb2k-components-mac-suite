//
//  KeychainHelper.h
//  foo_scrobble_mac
//
//  Secure storage for Last.fm session key using macOS Keychain
//

#pragma once

#import <Foundation/Foundation.h>

@interface KeychainHelper : NSObject

/// Store session key securely in Keychain
+ (BOOL)setSessionKey:(NSString *)sessionKey forUsername:(NSString *)username;

/// Retrieve session key from Keychain
+ (nullable NSString *)sessionKeyForUsername:(NSString *)username;

/// Get the stored username (if any)
+ (nullable NSString *)storedUsername;

/// Delete all stored credentials
+ (BOOL)deleteCredentials;

#pragma mark - Generic Password API

/// Save a password for an account
+ (BOOL)savePassword:(NSString *)password forAccount:(NSString *)account;

/// Load a password for an account
+ (nullable NSString *)loadPassword:(NSString *)account;

/// Delete a password for an account
+ (BOOL)deletePassword:(NSString *)account;

@end
