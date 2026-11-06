//
//  BrowserState.h
//  foo_jl_tidal_mac
//
//  Browser panel state enums. Foundation-only so the pure decision logic
//  (BrowserLogic) and its tests can use them without importing the
//  Cocoa view controller.
//

#pragma once

#import <Foundation/Foundation.h>

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
