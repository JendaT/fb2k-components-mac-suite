#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@interface AlbumViewVancedController : NSViewController

- (void)handleLibraryItemsAdded;
- (void)handleLibraryItemsRemoved;
- (void)handleLibraryItemsModified;

/// Show only albums by (and appearing-on for) this artist; nil restores everything.
/// Hides the search field while set. Called by the ShellVanced panel.
- (void)setArtistFilter:(nullable NSString *)name;

/// When set (non-nil), a single click on an album card opens the album through the
/// handler instead of expanding it inline. nil restores inline expansion.
/// Album dictionary keys (always present, empty string when unknown): @"key" (album artist
/// + U+001F + album title), @"title", @"artist", @"year", @"paths" (NSArray<NSString*> in track order).
- (void)setOpenAlbumHandler:(nullable void (^)(NSDictionary<NSString *, id> *album))handler;

@end

NS_ASSUME_NONNULL_END
