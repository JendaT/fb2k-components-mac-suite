#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@interface AlbumViewVancedController : NSViewController

- (void)handleLibraryItemsAdded;
- (void)handleLibraryItemsRemoved;
- (void)handleLibraryItemsModified;

@end

NS_ASSUME_NONNULL_END
