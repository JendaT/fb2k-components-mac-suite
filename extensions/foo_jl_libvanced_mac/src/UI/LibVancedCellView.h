//
//  LibVancedCellView.h
//  foo_jl_libvanced
//
//  Custom cell view for library outline rows
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class LibraryTreeNode;

@interface LibVancedCellView : NSTableCellView

- (void)configureWithNode:(LibraryTreeNode *)node
             showAlbumArt:(BOOL)showArt
           showTrackCount:(BOOL)showCount;

@end

NS_ASSUME_NONNULL_END
