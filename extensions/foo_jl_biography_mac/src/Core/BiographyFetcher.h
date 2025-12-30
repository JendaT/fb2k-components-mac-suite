//
//  BiographyFetcher.h
//  foo_jl_biography_mac
//
//  Request coordinator for multi-source biography fetching
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class BiographyData;
@class BiographyRequest;

/// Completion handler for biography fetch operations
typedef void (^BiographyCompletion)(BiographyData * _Nullable data, NSError * _Nullable error);

/// Error domain for biography fetcher errors
extern NSString * const BiographyFetcherErrorDomain;

/// Error codes for biography fetch operations
typedef NS_ENUM(NSInteger, BiographyFetcherErrorCode) {
    BiographyFetcherErrorCodeUnknown = 0,
    BiographyFetcherErrorCodeCancelled = 1,
    BiographyFetcherErrorCodeArtistNotFound = 2,
    BiographyFetcherErrorCodeNetworkError = 3,
    BiographyFetcherErrorCodeOffline = 4,
};

/// Coordinates multi-source fetching with cancellation and deduplication
@interface BiographyFetcher : NSObject

/// Serial queue for API requests - prevents thundering herd
@property (nonatomic, strong, readonly) dispatch_queue_t fetchQueue;

/// Currently in-flight request (nil if idle)
@property (nonatomic, strong, readonly, nullable) BiographyRequest *currentRequest;

/// Singleton accessor
+ (instancetype)shared;

/// Fetch biography with automatic cancellation of any pending request
/// @param artistName The artist to fetch
/// @param ignoreCache If YES, bypasses cache and fetches fresh data
/// @param completion Called on main thread with result or error
- (void)fetchBiographyForArtist:(NSString *)artistName
                          force:(BOOL)ignoreCache
                     completion:(BiographyCompletion)completion;

/// Cancel any in-flight request
- (void)cancelCurrentRequest;

/// Check if a request is currently in progress
@property (nonatomic, assign, readonly, getter=isFetching) BOOL fetching;

/// Prefetch biography for an artist (low priority, no completion)
- (void)prefetchBiographyForArtist:(NSString *)artistName;

@end

NS_ASSUME_NONNULL_END
