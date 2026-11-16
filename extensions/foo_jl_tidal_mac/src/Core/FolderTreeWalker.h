//
//  FolderTreeWalker.h
//  foo_jl_tidal_mac
//
//  Walks the v2 playlist folder tree one listing at a time. Foundation-only:
//  the HTTP request is injected as a page-fetch block, so paging, caps and
//  recursion are unit-tested standalone (Tests/FolderTreeWalkerTests.mm).
//
//  A listing returns one level only (live shape in
//  docs/research/2026-11-14-v2-folders-redirect.md), so the walker lists the
//  root for folders, then each folder for its subfolders and playlists.
//
//  Every failure fails the whole walk: a listing error, an unreadable page, an
//  item that cannot be placed, a cursor that does not advance, or a hit cap.
//  A cut-off tree would make the pull planner move foldered playlists back to
//  flat names, so an incomplete tree is never returned as if complete.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TidalModels.h"

NS_ASSUME_NONNULL_BEGIN

/// folderId of the top level of the playlist tree.
extern NSString * const JLTidalRootFolderID;

/// Hard caps of the default walk.
static const NSInteger JLTidalFolderTreeMaxDepth = 8;             // folder nesting levels
static const NSInteger JLTidalFolderTreeMaxPagesPerListing = 100; // pages per listing

typedef void (^JLTidalFolderPageCompletion)(NSDictionary * _Nullable json, NSError * _Nullable error);

/// Fetch one page of the listing of `folderID`. `foldersOnly` asks for
/// folders only (includeOnly=FOLDER). `cursor` is nil for the first page.
typedef void (^JLTidalFolderPageFetch)(NSString *folderID,
                                       BOOL foldersOnly,
                                       NSString * _Nullable cursor,
                                       JLTidalFolderPageCompletion completion);

/// Result of a complete walk.
@interface JLTidalFolderTree : NSObject
/// Top-level folders with subfolders and playlistUUIDs filled in.
@property (nonatomic, copy, readonly) NSArray<JLTidalPlaylistFolder *> *folders;
/// Listing pages requested, including the root listing.
@property (nonatomic, readonly) NSInteger requestCount;

- (instancetype)initWithFolders:(NSArray<JLTidalPlaylistFolder *> *)folders
                   requestCount:(NSInteger)requestCount;
@end

@interface JLTidalFolderTreeWalker : NSObject

/// Walk with the default caps.
+ (void)walkWithFetch:(JLTidalFolderPageFetch)fetch
           completion:(void (^)(JLTidalFolderTree * _Nullable tree, NSError * _Nullable error))completion;

/// Walk with explicit caps (tests use small ones). `maxDepth` counts folder
/// levels: top-level folders are depth 1. A folder below `maxDepth` fails the
/// walk, as does a listing that still has a cursor after `maxPages` pages.
+ (void)walkWithFetch:(JLTidalFolderPageFetch)fetch
             maxDepth:(NSInteger)maxDepth
   maxPagesPerListing:(NSInteger)maxPages
           completion:(void (^)(JLTidalFolderTree * _Nullable tree, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
