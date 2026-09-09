//
//  ArtworkSourceProvider.h
//  foo_jl_album_art_mac
//
//  Protocol for artwork source providers (CAA, iTunes, Deezer, etc.)
//  Each provider implements this to search a specific API
//

#pragma once

#import <Foundation/Foundation.h>
#import "TrackMetadata.h"
#import "ArtworkResult.h"
#import "RemoteArtworkTypes.h"
#import "../../../../shared/RateLimiter.h"

NS_ASSUME_NONNULL_BEGIN

/// Completion handler for artwork search
/// @param results Array of ArtworkResult objects (may be empty)
/// @param error Error if search failed, nil on success (even if no results)
typedef void (^ArtworkSearchCompletion)(NSArray<ArtworkResult *> *results,
                                        NSError * _Nullable error);

/// Protocol for artwork source providers
/// Each provider searches one API source and returns standardized results
@protocol ArtworkSourceProvider <NSObject>

@required

/// Unique identifier for this source (e.g., "caa", "itunes", "deezer")
@property (readonly, copy) NSString *identifier;

/// Human-readable name for display (e.g., "Cover Art Archive")
@property (readonly, copy) NSString *displayName;

/// Whether this source requires an API key to function
@property (readonly) BOOL requiresAPIKey;

/// Minimum interval between requests (for rate limiting)
@property (readonly) NSTimeInterval rateLimitInterval;

/// Search for artwork matching the given metadata
/// @param metadata Track metadata for search
/// @param completion Called with results or error (always on main queue)
- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(ArtworkSearchCompletion)completion;

/// Cancel any in-progress search
- (void)cancel;

@optional

/// Whether this source can search by MusicBrainz ID directly
/// If YES, provider may provide faster/more accurate results when MBID is available
@property (readonly) BOOL canSearchWithMBID;

/// Whether this source is configured and ready to use
/// For sources requiring API keys, returns NO if key is missing
@property (readonly, getter=isConfigured) BOOL configured;

/// Set API key for sources that require one
/// @param apiKey The API key to use
- (void)setAPIKey:(NSString *)apiKey;

@end

#pragma mark - Base Provider Class

/// Base class for artwork providers with common functionality
/// Subclass this for each source implementation
@interface ArtworkSourceProviderBase : NSObject <ArtworkSourceProvider>

/// Shared URL session for all providers
@property (class, readonly) NSURLSession *sharedSession;

/// Rate limiter for this provider (configured in subclass)
@property (nonatomic, strong, nullable) JLRateLimiter *rateLimiter;

/// Current search task (for cancellation)
@property (nonatomic, strong, nullable) NSURLSessionTask *currentTask;

/// Cancelled flag
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;

/// Create error with domain ArtworkFetchErrorDomain
+ (NSError *)errorWithCode:(ArtworkFetchError)code
                   message:(NSString *)message;

/// Create error from NSURLError
+ (NSError *)errorFromURLError:(NSError *)urlError;

/// User-Agent header value (required for MusicBrainz)
+ (NSString *)userAgentString;

/// Execute request with rate limiting
/// Calls completion on main queue
- (void)executeRequest:(NSURLRequest *)request
            completion:(void(^)(NSData * _Nullable data,
                               NSURLResponse * _Nullable response,
                               NSError * _Nullable error))completion;

/// Reset cancelled state for new search
- (void)resetCancelledState;

@end

NS_ASSUME_NONNULL_END
