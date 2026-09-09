//
//  LibraryOutlineView.h
//  foo_jl_libvanced
//
//  Custom NSOutlineView with drag/drop, keyboard shortcuts, and context menu
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class LibraryTreeNode;
@protocol LibraryOutlineViewDelegate;

extern NSPasteboardType const LibVancedPasteboardType;

@interface LibraryOutlineView : NSOutlineView <NSDraggingSource>

@property (nonatomic, weak, nullable) id<LibraryOutlineViewDelegate> actionDelegate;

@end

@protocol LibraryOutlineViewDelegate <NSObject>
@optional
- (void)libraryView:(LibraryOutlineView *)view didRequestQueueNodes:(NSArray<LibraryTreeNode *> *)nodes;
- (void)libraryView:(LibraryOutlineView *)view didRequestPlayNodes:(NSArray<LibraryTreeNode *> *)nodes;
- (void)libraryView:(LibraryOutlineView *)view didRequestSendToPlaylistNodes:(NSArray<LibraryTreeNode *> *)nodes;
- (void)libraryView:(LibraryOutlineView *)view didRequestSendToNewPlaylistNodes:(NSArray<LibraryTreeNode *> *)nodes;
- (void)libraryView:(LibraryOutlineView *)view requestContextMenuForNodes:(NSArray<LibraryTreeNode *> *)nodes atPoint:(NSPoint)point;
@end

NS_ASSUME_NONNULL_END
