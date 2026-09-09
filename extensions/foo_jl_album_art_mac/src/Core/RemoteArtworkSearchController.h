//
//  RemoteArtworkSearchController.h
//  foo_jl_album_art_mac
//
//  Orchestrates artwork search across multiple sources
//  Aggregates results, handles deduplication, and manages cancellation
//

#pragma once

#import <Foundation/Foundation.h>
#import "TrackMetadata.h"
#import "ArtworkResult.h"
#import "ArtworkSourceProvider.h"

NS_ASSUME_NONNULL_BEGIN

@protocol RemoteArtworkSearchDelegate;

/// Search controller that orchestrates artwork fetching from multiple sources
/// Handles parallel searches, result aggregation, and deduplication
@interface RemoteArtworkSearchController : NSObject

/// Delegate for search progress callbacks
@property (weak, nullable) id<RemoteArtworkSearchDelegate> delegate;

/// Whether a search is currently in progress
@property (readonly, getter=isSearching) BOOL searching;

/// Current search metadata (nil if not searching)
@property (readonly, nullable) TrackMetadata *currentMetadata;

/// The providers queried by this controller, in priority order
@property (readonly, copy) NSArray<id<ArtworkSourceProvider>> *providers;

/// Create a controller with the default provider set
/// (Cover Art Archive, iTunes, Deezer, and Tidal when configured)
- (instancetype)init;

/// Create a controller with an explicit provider set (used by tests)
- (instancetype)initWithProviders:(NSArray<id<ArtworkSourceProvider>> *)providers NS_DESIGNATED_INITIALIZER;

/// Start searching for artwork with the given metadata
/// Cancels any existing search first
/// @param metadata Track metadata to search for
- (void)searchForArtworkWithMetadata:(TrackMetadata *)metadata;

/// Cancel any in-progress search
/// After a caller-initiated cancel, the delegate receives no further callbacks.
/// (The internal global-timeout path also calls this, but then delivers a
/// final searchDidFailWithError:/searchDidComplete pair to report the timeout.)
- (void)cancel;

@end

#pragma mark - Delegate Protocol

@protocol RemoteArtworkSearchDelegate <NSObject>

/// Called when search begins
- (void)searchDidStart;

/// Called with progress updates during search
/// @param message Human-readable progress message (e.g., "Searching iTunes...")
- (void)searchDidUpdateProgress:(NSString *)message;

/// Called when results are found (may be called multiple times as sources respond)
/// @param results Array of ArtworkResult objects (deduplicated)
- (void)searchDidFindResults:(NSArray<ArtworkResult *> *)results;

/// Called when search fails with an error
/// @param error Error describing the failure
- (void)searchDidFailWithError:(NSError *)error;

/// Called when search completes (after all sources have responded or been cancelled)
- (void)searchDidComplete;

@end

NS_ASSUME_NONNULL_END
