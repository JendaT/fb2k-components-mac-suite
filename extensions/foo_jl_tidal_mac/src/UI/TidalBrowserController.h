//
//  TidalBrowserController.h
//  foo_jl_tidal_mac
//
//  Browser panel for searching and browsing Tidal catalog
//

#pragma once

#import <Cocoa/Cocoa.h>
#import "../Core/BrowserState.h"

NS_ASSUME_NONNULL_BEGIN

@class JLTidalTrack;
@class JLTidalAlbum;
@class JLTidalArtist;
@class JLTidalPlaylist;

/// Main controller for the Tidal Browser panel
/// Registered as ui_element_mac service for embedding in foobar2000 layout
@interface JLTidalBrowserController : NSViewController <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>

/// Perform search with the given query
- (void)searchWithQuery:(NSString *)query;

/// Clear search results
- (void)clearResults;

@end

NS_ASSUME_NONNULL_END
