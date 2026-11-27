//
//  SVAlbumPageViewController.h
//  foo_jl_shellvanced_mac
//
//  Spotify-style album page: cover, title, "Artist • year • N songs, H hr M min",
//  Play / Shuffle, and the track table. Objective-C header (Cocoa only);
//  the implementation is Objective-C++. Main thread only.
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SVAlbumPageViewController : NSViewController

/// The artist name was clicked (only offered when the artist exists in the index).
@property (nonatomic, copy, nullable) void (^onOpenArtist)(NSString *artistName);

/// The album could not be found in the library (reported for the key that was asked for).
@property (nonatomic, copy, nullable) void (^onUnresolved)(NSString *albumKey);

/// Key of the album being shown or loaded.
@property (nonatomic, copy, readonly, nullable) NSString *albumKey;

/// The track list, for focus handling.
@property (nonatomic, readonly) NSTableView *tableView;

/// Shows an album. `info` is the AlbumViewVanced dictionary (key, title, artist,
/// year, paths); without it (or when its paths no longer resolve) the library is
/// scanned off the main thread for the key.
- (void)showAlbumKey:(NSString *)key info:(nullable NSDictionary<NSString *, id> *)info;

@end

NS_ASSUME_NONNULL_END
