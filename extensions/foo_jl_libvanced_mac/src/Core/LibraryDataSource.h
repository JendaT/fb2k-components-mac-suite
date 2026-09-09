//
//  LibraryDataSource.h
//  foo_jl_libvanced
//
//  Builds and manages the tree hierarchy from foobar2000's media library
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class LibraryTreeNode;

@protocol LibraryDataSourceDelegate <NSObject>
- (void)libraryDataSourceDidUpdate;
- (void)libraryDataSourceDidBeginUpdate;
@end

@interface LibraryDataSource : NSObject

@property (nonatomic, weak, nullable) id<LibraryDataSourceDelegate> delegate;
@property (nonatomic, readonly, strong) LibraryTreeNode *rootNode;
@property (nonatomic, readonly) NSInteger totalTrackCount;

// Group pattern using titleformat with '|' as level separator
// e.g. "%album artist%|[%date% - ]%album%" creates Artist > Album tree
@property (nonatomic, copy) NSString *groupPattern;
@property (nonatomic, copy) NSString *sortPattern;

// Rebuild the entire tree from the media library
- (void)rebuildTree;

// Rebuild with a search/filter query (media library search syntax)
- (void)rebuildTreeWithFilter:(nullable NSString *)filterQuery;

// Get metadb handles for all tracks under a node
- (void)getHandlesForNode:(LibraryTreeNode *)node
                  handles:(void (^)(const metadb_handle_list &handles))completion;

@end

NS_ASSUME_NONNULL_END
