//
//  PathMappingWindowController.h
//  foo_plorg_mac
//
//  Path mapping window for importing playlists with drive letter conversion
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class PathMappingWindowController;

@protocol PathMappingWindowDelegate <NSObject>
- (void)pathMappingDidComplete:(PathMappingWindowController *)controller
                      mappings:(NSDictionary<NSString *, NSString *> *)mappings
                 defaultMapping:(NSString *)defaultMapping;
- (void)pathMappingDidCancel:(PathMappingWindowController *)controller;
@end

@interface PathMappingWindowController : NSWindowController

@property (nonatomic, weak) id<PathMappingWindowDelegate> delegate;
@property (nonatomic, copy) NSString *playlistsDir;  // Directory containing .fplite files
@property (nonatomic, copy) NSString *themeFilePath; // Path to theme.fth for tree structure

// Start scanning and show window
- (void)beginScanningWithPlaylistsDir:(NSString *)playlistsDir
                        themeFilePath:(NSString *)themeFilePath;

@end

NS_ASSUME_NONNULL_END
