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

@end

NS_ASSUME_NONNULL_END
