//
//  LastFmErrors.h
//  foo_scrobble_mac
//
//  Last.fm API error codes and error domain
//

#pragma once

#import <Foundation/Foundation.h>

// Error domain for Last.fm errors
static NSString* const LastFmErrorDomain = @"com.foobar2000.foo_scrobble.lastfm";

// Last.fm API error codes
// Reference: https://www.last.fm/api/errorcodes
typedef NS_ENUM(NSInteger, LastFmErrorCode) {
    LastFmErrorNone = 0,
    LastFmErrorInvalidService = 2,        // This service does not exist
    LastFmErrorInvalidMethod = 3,         // No method with that name
    LastFmErrorAuthenticationFailed = 4,  // Invalid authentication token
    LastFmErrorInvalidFormat = 5,         // Invalid format parameter
    LastFmErrorInvalidParameters = 6,     // Invalid method signature/parameters
    LastFmErrorInvalidResource = 7,       // Invalid resource specified
    LastFmErrorOperationFailed = 8,       // Something went wrong
    LastFmErrorInvalidSessionKey = 9,     // Invalid session key - re-auth needed
    LastFmErrorInvalidApiKey = 10,        // Invalid API key
    LastFmErrorServiceOffline = 11,       // Service temporarily offline
    LastFmErrorSubscribersOnly = 12,      // Method requires subscriber account
    LastFmErrorInvalidSignature = 13,     // Invalid method signature
    LastFmErrorNotAuthorized = 14,        // Token not yet authorized by user
    LastFmErrorTokenExpired = 15,         // Token has expired
    LastFmErrorServiceUnavailable = 16,   // Service temporarily unavailable
    LastFmErrorLoginRequired = 17,        // User requires authentication
    LastFmErrorSuspendedApiKey = 26,      // API key suspended
    LastFmErrorRateLimitExceeded = 29,    // Rate limit exceeded
};

// Check if error requires re-authentication
inline bool LastFmErrorRequiresReauth(LastFmErrorCode code) {
    return code == LastFmErrorAuthenticationFailed ||
           code == LastFmErrorInvalidSessionKey;
}

// Check if error is a temporary/retriable error
inline bool LastFmErrorIsRetriable(LastFmErrorCode code) {
    return code == LastFmErrorOperationFailed ||
           code == LastFmErrorServiceOffline ||
           code == LastFmErrorServiceUnavailable ||
           code == LastFmErrorRateLimitExceeded;
}

// Check if error should pause API calls (suspended key)
inline bool LastFmErrorShouldSuspend(LastFmErrorCode code) {
    return code == LastFmErrorInvalidApiKey ||
           code == LastFmErrorSuspendedApiKey;
}

// Create NSError from Last.fm error code and message
inline NSError* LastFmMakeError(LastFmErrorCode code, NSString* message) {
    NSDictionary* userInfo = @{
        NSLocalizedDescriptionKey: message ?: @"Unknown error"
    };
    return [NSError errorWithDomain:LastFmErrorDomain
                               code:code
                           userInfo:userInfo];
}
