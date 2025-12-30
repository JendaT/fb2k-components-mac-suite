//
//  BiographyController.h
//  foo_jl_biography_mac
//
//  Main controller for Artist Biography component
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// View states for the biography component
typedef NS_ENUM(NSInteger, BiographyViewState) {
    BiographyViewStateEmpty = 0,    // No track playing
    BiographyViewStateLoading,       // Fetching biography
    BiographyViewStateContent,       // Biography displayed
    BiographyViewStateError,         // Error occurred
    BiographyViewStateOffline        // Offline, showing cached data
};

@class BiographyData;

@interface BiographyController : NSViewController

/// Current view state
@property (nonatomic, assign, readonly) BiographyViewState viewState;

/// Current artist name being displayed
@property (nonatomic, copy, readonly, nullable) NSString *currentArtist;

/// Current biography data (nil if not loaded)
@property (nonatomic, strong, readonly, nullable) BiographyData *biographyData;

/// Initialize with layout parameters
- (instancetype)initWithParameters:(nullable NSDictionary<NSString*, NSString*>*)params;

/// Called when artist changes (from BiographyCallbackManager)
- (void)handleArtistChange:(nullable NSString *)artistName;

/// Called when playback stops (from BiographyCallbackManager)
- (void)handlePlaybackStop;

/// Force refresh the current artist (bypass cache)
- (void)forceRefresh;

/// Retry after an error
- (void)retryFetch;

@end

NS_ASSUME_NONNULL_END
