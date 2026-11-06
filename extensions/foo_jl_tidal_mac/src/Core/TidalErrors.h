//
//  TidalErrors.h
//  foo_jl_tidal_mac
//
//  Error types and domain for Tidal integration
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Error domain for all Tidal-related errors
extern NSString * const JLTidalErrorDomain;

// Error codes for Tidal operations
typedef NS_ENUM(NSInteger, JLTidalErrorCode) {
    // Authentication errors (1xx)
    JLTidalErrorNotAuthenticated = 100,
    JLTidalErrorDeviceCodeExpired = 101,
    JLTidalErrorDeviceCodePending = 102,
    JLTidalErrorAuthorizationDenied = 103,
    JLTidalErrorTokenRefreshFailed = 104,
    JLTidalErrorInvalidGrant = 105,

    // API errors (2xx)
    JLTidalErrorNetworkFailure = 200,
    JLTidalErrorInvalidResponse = 201,
    JLTidalErrorRateLimited = 202,
    JLTidalErrorServerError = 203,
    JLTidalErrorTrackNotFound = 204,
    JLTidalErrorSubscriptionRequired = 205,
    JLTidalErrorAccessDenied = 206,       // 403 that is NOT a subscription problem

    // Stream errors (3xx)
    JLTidalErrorStreamNotAvailable = 300,
    JLTidalErrorDRMProtected = 301,
    JLTidalErrorStreamExpired = 302,
    JLTidalErrorQualityNotAvailable = 303,
    JLTidalErrorManifestParseFailed = 304,
    JLTidalErrorPreviewOnly = 305,

    // URL errors (4xx)
    JLTidalErrorInvalidURL = 400,
    JLTidalErrorUnsupportedURLType = 401,

    // Keychain errors (5xx)
    JLTidalErrorKeychainAccess = 500,
    JLTidalErrorKeychainStore = 501,
    JLTidalErrorKeychainDelete = 502,

    // Internal errors (9xx)
    JLTidalErrorInternal = 900,
    JLTidalErrorCancelled = 901
};

// Helper to create NSError with Tidal domain
static inline NSError *JLTidalError(JLTidalErrorCode code, NSString * _Nullable message) {
    NSDictionary *userInfo = nil;
    if (message) {
        userInfo = @{NSLocalizedDescriptionKey: message};
    }
    return [NSError errorWithDomain:JLTidalErrorDomain code:code userInfo:userInfo];
}

// Helper to check if error is retryable
/// A refresh failure the refresh token cannot recover from: the grant itself
/// was rejected, so retrying posts the same dead token forever and only a new
/// device pairing helps. Everything else (offline, 5xx, 429) is transient and
/// must NOT cost the user their stored session.
///
/// The terminal set is the five codes TIDAL's own Auth.md names as logout
/// triggers; anything unrecognised is treated as transient, because wrongly
/// keeping a dead token costs a retry while wrongly wiping a live one costs a
/// full re-pairing.
static inline BOOL JLTidalErrorIsTerminalAuthFailure(NSError *error) {
    return error.code == JLTidalErrorInvalidGrant ||
           error.code == JLTidalErrorAuthorizationDenied;
}

static inline BOOL JLTidalErrorIsRetryable(NSError *error) {
    if (![error.domain isEqualToString:JLTidalErrorDomain]) {
        return NO;
    }

    switch ((JLTidalErrorCode)error.code) {
        case JLTidalErrorNetworkFailure:
        case JLTidalErrorRateLimited:
        case JLTidalErrorServerError:
        case JLTidalErrorStreamExpired:
            return YES;
        default:
            return NO;
    }
}

// Helper to check if error requires re-authentication
static inline BOOL JLTidalErrorRequiresReauth(NSError *error) {
    if (![error.domain isEqualToString:JLTidalErrorDomain]) {
        return NO;
    }

    switch ((JLTidalErrorCode)error.code) {
        case JLTidalErrorNotAuthenticated:
        case JLTidalErrorTokenRefreshFailed:
        case JLTidalErrorInvalidGrant:
            return YES;
        default:
            return NO;
    }
}

NS_ASSUME_NONNULL_END
