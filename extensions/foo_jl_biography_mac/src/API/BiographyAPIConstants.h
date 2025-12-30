//
//  BiographyAPIConstants.h
//  foo_jl_biography_mac
//
//  API constants and rate limiter configurations
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - API Base URLs

static NSString * const kLastFmApiBaseUrl = @"https://ws.audioscrobbler.com/2.0/";
static NSString * const kMusicBrainzApiBaseUrl = @"https://musicbrainz.org/ws/2/";
static NSString * const kWikipediaApiBaseUrl = @"https://en.wikipedia.org/api/rest_v1/";
static NSString * const kFanartTvApiBaseUrl = @"https://webservice.fanart.tv/v3/music/";
static NSString * const kAudioDbApiBaseUrl = @"https://www.theaudiodb.com/api/v1/json/";

#pragma mark - Rate Limiter Constants

// Last.fm: 5 requests per second, 5 burst
static const double kLastFmRatePerSecond = 1.0;
static const NSInteger kLastFmBurstCapacity = 5;

// MusicBrainz: Strict 1 req/sec, no bursting
static const double kMusicBrainzRatePerSecond = 1.0;
static const NSInteger kMusicBrainzBurstCapacity = 1;

// TheAudioDB: 30/min = 0.5/sec
static const double kAudioDbRatePerSecond = 0.5;
static const NSInteger kAudioDbBurstCapacity = 5;

// Wikipedia: Generous limits
static const double kWikipediaRatePerSecond = 2.0;
static const NSInteger kWikipediaBurstCapacity = 10;

// Fanart.tv: No documented limit, use reasonable defaults
static const double kFanartTvRatePerSecond = 2.0;
static const NSInteger kFanartTvBurstCapacity = 5;

#pragma mark - Timeout Constants

static const NSTimeInterval kDefaultRequestTimeout = 30.0;
static const NSTimeInterval kImageDownloadTimeout = 60.0;

#pragma mark - User Agent

static NSString * const kBiographyUserAgent = @"foo_jl_biography/1.0.0 (foobar2000 macOS component; contact@example.com)";

#pragma mark - Cache TTL (seconds)

static const NSTimeInterval kBiographyCacheTTL = 7 * 24 * 60 * 60;  // 7 days
static const NSTimeInterval kImageCacheTTL = 30 * 24 * 60 * 60;      // 30 days
static const NSTimeInterval kMbidCacheTTL = 365 * 24 * 60 * 60;      // 1 year (permanent)

#pragma mark - Cache Size Limits

static const NSUInteger kMaxCacheSizeBytes = 100 * 1024 * 1024;  // 100 MB
static const NSUInteger kMaxImageCacheSizeBytes = 200 * 1024 * 1024;  // 200 MB

NS_ASSUME_NONNULL_END
