//
//  FolderTreeWalker.mm
//  foo_jl_tidal_mac
//

#import "FolderTreeWalker.h"
#import "ResponseParser.h"
#import "TidalErrors.h"
#include "TidalLog.h"

NSString * const JLTidalRootFolderID = @"root";

typedef void (^JLTidalFolderWalkCompletion)(JLTidalFolderTree * _Nullable tree, NSError * _Nullable error);
typedef void (^JLTidalListingCompletion)(NSArray<JLTidalPlaylistFolder *> * _Nullable folders,
                                         NSArray<NSString *> * _Nullable playlistUUIDs,
                                         NSError * _Nullable error);

@implementation JLTidalFolderTree

- (instancetype)initWithFolders:(NSArray<JLTidalPlaylistFolder *> *)folders
                   requestCount:(NSInteger)requestCount {
    self = [super init];
    if (self) {
        _folders = [folders copy];
        _requestCount = requestCount;
    }
    return self;
}

@end

/// A folder waiting to be listed, with its nesting level.
@interface JLTidalPendingFolder : NSObject
@property (nonatomic, strong) JLTidalPlaylistFolder *folder;
@property (nonatomic) NSInteger depth;
@end

@implementation JLTidalPendingFolder
@end

/// State of one walk. Requests run strictly one after another, so the state
/// is only ever touched by one completion at a time.
@interface JLTidalFolderWalk : NSObject
@property (nonatomic, copy) JLTidalFolderPageFetch fetch;
@property (nonatomic, copy) JLTidalFolderWalkCompletion completion;
@property (nonatomic) NSInteger maxDepth;
@property (nonatomic) NSInteger maxPages;
@property (nonatomic) NSInteger requestCount;
@property (nonatomic, strong) NSMutableArray<JLTidalPlaylistFolder *> *roots;
@property (nonatomic, strong) NSMutableArray<JLTidalPendingFolder *> *pending;
@property (nonatomic, strong) NSMutableSet<NSString *> *visited;
@end

@implementation JLTidalFolderWalk

- (void)start {
    self.roots = [NSMutableArray array];
    self.pending = [NSMutableArray array];
    self.visited = [NSMutableSet setWithObject:JLTidalRootFolderID];

    [self listFolder:JLTidalRootFolderID foldersOnly:YES
          completion:^(NSArray<JLTidalPlaylistFolder *> *folders, NSArray<NSString *> *uuids, NSError *error) {
        if (error) {
            [self failWithError:error];
            return;
        }
        // Playlists at the root need no folder path, and includeOnly=FOLDER
        // leaves them out anyway.
        for (JLTidalPlaylistFolder *folder in folders) {
            if (![self claimFolder:folder]) continue;
            [self.roots addObject:folder];
            [self enqueueFolder:folder depth:1];
        }
        [self listNextFolder];
    }];
}

// Breadth-first, one listing at a time.
- (void)listNextFolder {
    if (self.pending.count == 0) {
        JLTidalFolderWalkCompletion completion = self.completion;
        self.completion = nil;
        if (completion) {
            completion([[JLTidalFolderTree alloc] initWithFolders:self.roots
                                                     requestCount:self.requestCount], nil);
        }
        return;
    }

    JLTidalPendingFolder *entry = self.pending.firstObject;
    [self.pending removeObjectAtIndex:0];

    [self listFolder:entry.folder.folderID foldersOnly:NO
          completion:^(NSArray<JLTidalPlaylistFolder *> *subfolders, NSArray<NSString *> *uuids, NSError *error) {
        if (error) {
            [self failWithError:error];
            return;
        }
        [entry.folder.playlistUUIDs addObjectsFromArray:uuids];
        for (JLTidalPlaylistFolder *subfolder in subfolders) {
            if (entry.depth + 1 > self.maxDepth) {
                [self failWithError:JLTidalError(JLTidalErrorInvalidResponse,
                    [NSString stringWithFormat:@"Playlist folders are nested deeper than %ld levels",
                     (long)self.maxDepth])];
                return;
            }
            if (![self claimFolder:subfolder]) continue;
            [entry.folder.subfolders addObject:subfolder];
            [self enqueueFolder:subfolder depth:entry.depth + 1];
        }
        [self listNextFolder];
    }];
}

// A folder that turns up twice (a cycle, or the same folder under two
// parents) is listed once and placed where it was first seen.
- (BOOL)claimFolder:(JLTidalPlaylistFolder *)folder {
    if ([self.visited containsObject:folder.folderID]) {
        tidal::logInfo([[NSString stringWithFormat:
            @"Playlist folders: folder \"%@\" listed more than once; keeping the first place",
            folder.name] UTF8String]);
        return NO;
    }
    [self.visited addObject:folder.folderID];
    return YES;
}

- (void)enqueueFolder:(JLTidalPlaylistFolder *)folder depth:(NSInteger)depth {
    JLTidalPendingFolder *entry = [[JLTidalPendingFolder alloc] init];
    entry.folder = folder;
    entry.depth = depth;
    [self.pending addObject:entry];
}

- (void)failWithError:(NSError *)error {
    JLTidalFolderWalkCompletion completion = self.completion;
    self.completion = nil;
    if (completion) completion(nil, error);
}

#pragma mark Listing (all pages of one folder)

- (void)listFolder:(NSString *)folderID
       foldersOnly:(BOOL)foldersOnly
        completion:(JLTidalListingCompletion)completion {
    [self fetchPageOfFolder:folderID
                foldersOnly:foldersOnly
                     cursor:nil
                sentCursors:[NSMutableSet set]
                  pageCount:0
                    folders:[NSMutableArray array]
              playlistUUIDs:[NSMutableArray array]
                 completion:completion];
}

- (void)fetchPageOfFolder:(NSString *)folderID
              foldersOnly:(BOOL)foldersOnly
                   cursor:(NSString *)cursor
              sentCursors:(NSMutableSet<NSString *> *)sentCursors
                pageCount:(NSInteger)pageCount
                  folders:(NSMutableArray<JLTidalPlaylistFolder *> *)folders
            playlistUUIDs:(NSMutableArray<NSString *> *)playlistUUIDs
               completion:(JLTidalListingCompletion)completion {
    self.requestCount++;
    self.fetch(folderID, foldersOnly, cursor, ^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }
        JLTidalFolderListing *listing = [JLTidalResponseParser folderListingFromResponse:json];
        if (!listing) {
            completion(nil, nil, JLTidalError(JLTidalErrorInvalidResponse,
                @"Playlist folder listing has no items"));
            return;
        }
        if (listing.malformedItemCount > 0) {
            completion(nil, nil, JLTidalError(JLTidalErrorInvalidResponse,
                [NSString stringWithFormat:@"Playlist folder listing has %ld item(s) without an id",
                 (long)listing.malformedItemCount]));
            return;
        }
        [folders addObjectsFromArray:listing.folders];
        [playlistUUIDs addObjectsFromArray:listing.playlistUUIDs];

        NSInteger pages = pageCount + 1;
        NSString *next = listing.cursor;
        if (!next) {
            completion(folders, playlistUUIDs, nil);
            return;
        }
        if ([sentCursors containsObject:next]) {
            completion(nil, nil, JLTidalError(JLTidalErrorInvalidResponse,
                @"Playlist folder listing cursor did not advance"));
            return;
        }
        if (pages >= self.maxPages) {
            completion(nil, nil, JLTidalError(JLTidalErrorInvalidResponse,
                [NSString stringWithFormat:@"Playlist folder listing has more than %ld pages",
                 (long)self.maxPages]));
            return;
        }
        [sentCursors addObject:next];
        [self fetchPageOfFolder:folderID
                    foldersOnly:foldersOnly
                         cursor:next
                    sentCursors:sentCursors
                      pageCount:pages
                        folders:folders
                  playlistUUIDs:playlistUUIDs
                     completion:completion];
    });
}

@end

@implementation JLTidalFolderTreeWalker

+ (void)walkWithFetch:(JLTidalFolderPageFetch)fetch
           completion:(JLTidalFolderWalkCompletion)completion {
    [self walkWithFetch:fetch
               maxDepth:JLTidalFolderTreeMaxDepth
     maxPagesPerListing:JLTidalFolderTreeMaxPagesPerListing
             completion:completion];
}

+ (void)walkWithFetch:(JLTidalFolderPageFetch)fetch
             maxDepth:(NSInteger)maxDepth
   maxPagesPerListing:(NSInteger)maxPages
           completion:(JLTidalFolderWalkCompletion)completion {
    JLTidalFolderWalk *walk = [[JLTidalFolderWalk alloc] init];
    walk.fetch = fetch;
    walk.completion = completion;
    walk.maxDepth = maxDepth;
    walk.maxPages = maxPages;
    // The walk keeps itself alive through the blocks it hands to fetch.
    [walk start];
}

@end
