//
//  CloudBrowserController.h
//  foo_jl_cloud_streamer_mac
//
//  UI controller for Cloud Browser panel - supports SoundCloud and Mixcloud
//

#import <Cocoa/Cocoa.h>
#import "../Services/CloudSearchService.h"

@class CloudTrack;

NS_ASSUME_NONNULL_BEGIN

// Search state enum
typedef NS_ENUM(NSInteger, CloudBrowserState) {
    CloudBrowserStateEmpty,       // Initial state, no search performed
    CloudBrowserStateSearching,   // Search in progress
    CloudBrowserStateResults,     // Search completed with results
    CloudBrowserStateNoResults,   // Search completed with no results
    CloudBrowserStateError        // Search failed with error
};

@interface CloudBrowserController : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

// Current search state
@property (nonatomic, readonly) CloudBrowserState state;

// Current search results
@property (nonatomic, readonly) NSArray<CloudTrack*>* searchResults;

// Selected cloud service for search (SoundCloud or Mixcloud)
@property (nonatomic) CloudServiceType selectedService;

// Transparent background mode (for visual effect views)
@property (nonatomic) BOOL transparentBackground;

// Perform a search
- (void)performSearch:(NSString*)query;

// Cancel current search
- (void)cancelSearch;

// Add selected track to active playlist
- (void)addSelectedTrackToPlaylist;

// Add selected track to playlist and start playback
- (void)addAndPlaySelectedTrack;

@end

NS_ASSUME_NONNULL_END
