//
//  TidalBrowserController.h
//  foo_jl_tidal_mac
//
//  Browser panel for searching and browsing Tidal catalog
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class JLTidalTrack;
@class JLTidalAlbum;
@class JLTidalArtist;
@class JLTidalPlaylist;

/// Top-level panel mode
typedef NS_ENUM(NSInteger, JLTidalPanelMode) {
    JLTidalPanelModeSearch = 0,
    JLTidalPanelModeLibrary = 1,
};

/// Search type for the browser
typedef NS_ENUM(NSInteger, JLTidalSearchType) {
    JLTidalSearchTypeTracks = 0,
    JLTidalSearchTypeAlbums = 1,
    JLTidalSearchTypeArtists = 2,
};

/// Library section
typedef NS_ENUM(NSInteger, JLTidalLibrarySection) {
    JLTidalLibrarySectionFavTracks = 0,
    JLTidalLibrarySectionFavAlbums = 1,
    JLTidalLibrarySectionPlaylists = 2,
};

/// Browse mode - what the table is currently showing
typedef NS_ENUM(NSInteger, JLTidalBrowseMode) {
    JLTidalBrowseModeSearchResults,    // Top-level search results
    JLTidalBrowseModeAlbumTracks,      // Tracks within an album
    JLTidalBrowseModeArtistTopTracks,  // Top tracks for an artist
    JLTidalBrowseModeArtistAlbums,     // Albums by an artist
    JLTidalBrowseModeLibraryList,      // Library section list (favs, playlists)
    JLTidalBrowseModePlaylistTracks,   // Tracks within a playlist
};

/// Main controller for the Tidal Browser panel
/// Registered as ui_element_mac service for embedding in foobar2000 layout
@interface JLTidalBrowserController : NSViewController <NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>

/// Perform search with the given query
- (void)searchWithQuery:(NSString *)query;

/// Clear search results
- (void)clearResults;

@end

NS_ASSUME_NONNULL_END
