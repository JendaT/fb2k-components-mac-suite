//
//  SVSpotifyCredentials.h
//  foo_jl_shellvanced_mac
//
//  Spotify Client ID / Secret in the macOS Keychain (service "foo_jl_shellvanced.spotify").
//  Values are never logged or written anywhere else. Thread-safe; reads are cached in memory.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SVSpotifyCredentials : NSObject

/// nil when not stored.
+ (nullable NSString *)clientId;
+ (nullable NSString *)clientSecret;
+ (BOOL)isConfigured;

/// Stores both values (empty/nil for both = delete). Returns NO if the Keychain write failed.
+ (BOOL)saveClientId:(nullable NSString *)clientId secret:(nullable NSString *)secret;

@end

NS_ASSUME_NONNULL_END
