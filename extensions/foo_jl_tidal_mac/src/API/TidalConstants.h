//
//  TidalConstants.h
//  foo_jl_tidal_mac
//
//  API endpoints, client credentials, and protocol constants
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - API Endpoints

// OAuth 2.0 Device Authorization endpoints
static NSString * const kTidalAuthBaseURL = @"https://auth.tidal.com";
static NSString * const kTidalDeviceAuthEndpoint = @"/v1/oauth2/device_authorization";
static NSString * const kTidalTokenEndpoint = @"/v1/oauth2/token";

// Main API endpoints
static NSString * const kTidalAPIBaseURL = @"https://api.tidal.com";
static NSString * const kTidalAPIv2BaseURL = @"https://listen.tidal.com/v2";
static NSString * const kTidalPlaybackInfoEndpoint = @"/v1/tracks/%@/playbackinfopostpaywall";
static NSString * const kTidalTrackMetadataEndpoint = @"/v1/tracks/%@";

// CDN endpoints (returned dynamically in playback info)
// These are just for reference - actual URLs come from API responses

#pragma mark - OAuth Client Configuration

// Client credentials for Device Authorization Grant
// Used by python-tidal and other open source projects
static NSString * const kTidalClientID = @"fX2JxdmntZWK0ixT";
static NSString * const kTidalClientSecret = @"1Nn9AfDAjxrgJFJbKNWLeAyKGVGmINuXPPLHVXAvxAg=";

// OAuth scopes
static NSString * const kTidalOAuthScopes = @"r_usr w_usr w_sub";

#pragma mark - Protocol Constants

// URL scheme for tidal:// protocol
static NSString * const kTidalURLScheme = @"tidal";

// Metadata field names
static NSString * const kTidalMetadataQuality = @"TIDAL_QUALITY";
static NSString * const kTidalMetadataTrackID = @"TIDAL_TRACK_ID";

#pragma mark - Audio Quality Tiers

typedef NS_ENUM(NSInteger, JLTidalQuality) {
    JLTidalQualityLow = 0,           // AAC 96kbps
    JLTidalQualityHigh = 1,          // AAC 320kbps
    JLTidalQualityLossless = 2,      // FLAC 16/44.1
    JLTidalQualityHiRes = 3,         // FLAC 24/96 (MQA)
    JLTidalQualityHiResLossless = 4  // FLAC 24/192
};

// String representations for API requests
static inline NSString * JLTidalQualityToString(JLTidalQuality quality) {
    switch (quality) {
        case JLTidalQualityLow: return @"LOW";
        case JLTidalQualityHigh: return @"HIGH";
        case JLTidalQualityLossless: return @"LOSSLESS";
        case JLTidalQualityHiRes: return @"HI_RES";
        case JLTidalQualityHiResLossless: return @"HI_RES_LOSSLESS";
    }
}

// Quality fallback order (highest to lowest)
static const JLTidalQuality kTidalQualityFallbackOrder[] = {
    JLTidalQualityHiResLossless,
    JLTidalQualityHiRes,
    JLTidalQualityLossless,
    JLTidalQualityHigh,
    JLTidalQualityLow
};
static const NSInteger kTidalQualityFallbackCount = 5;

#pragma mark - Timing Constants

// Device code polling interval (seconds) - per RFC 8628
static const NSTimeInterval kTidalDeviceCodePollInterval = 5.0;

// Device code expiration (seconds) - typically 300s from API
static const NSTimeInterval kTidalDeviceCodeDefaultExpiry = 300.0;

// Stream URL cache TTL (seconds) - conservative for signed URLs
static const NSTimeInterval kTidalStreamCacheTTL = 900.0;  // 15 minutes

// Token refresh buffer (seconds) - refresh before actual expiry
static const NSTimeInterval kTidalTokenRefreshBuffer = 300.0;  // 5 minutes

#pragma mark - Rate Limiting

// Initial backoff for 429 responses (seconds)
static const NSTimeInterval kTidalRateLimitInitialBackoff = 1.0;

// Maximum backoff (seconds)
static const NSTimeInterval kTidalRateLimitMaxBackoff = 60.0;

// Backoff multiplier
static const double kTidalRateLimitBackoffMultiplier = 2.0;

#pragma mark - Keychain Configuration

static NSString * const kTidalKeychainService = @"com.foobar2000.tidal";
static NSString * const kTidalKeychainAccessTokenKey = @"access_token";
static NSString * const kTidalKeychainRefreshTokenKey = @"refresh_token";

NS_ASSUME_NONNULL_END
