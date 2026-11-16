//
//  FolderTreeWalkerTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the v2 playlist folder walk: recursion into subfolders,
//  cursor paging, and the rule that every failure or hit cap fails the whole
//  walk. Listings are served by a fake fetch block in the live item shape.
//

#import <Foundation/Foundation.h>
#import "../src/Core/FolderTreeWalker.h"
#import "../src/Core/SyncPlanner.h"
#include "TestHarness.h"

static NSDictionary *folderItem(NSString *folderID, NSString *name) {
    return @{@"itemType": @"FOLDER", @"trn": [@"trn:folder:" stringByAppendingString:folderID],
             @"name": name, @"parent": @{},
             @"data": @{@"id": folderID, @"name": name, @"itemType": @"FOLDER"}};
}

static NSDictionary *playlistItem(NSString *uuid) {
    return @{@"itemType": @"PLAYLIST", @"trn": [@"trn:playlist:" stringByAppendingString:uuid],
             @"name": uuid, @"data": @{@"uuid": uuid}};
}

static NSDictionary *page(NSArray *items, NSString *cursor) {
    NSMutableDictionary *json = [@{@"items": items, @"totalNumberOfItems": @(items.count)} mutableCopy];
    if (cursor) json[@"cursor"] = cursor;
    return json;
}

// Serves responses keyed "folderID|cursor" (empty cursor for the first page)
// and logs every request as "folderID|foldersOnly|cursor". Completions run
// synchronously, so the walk finishes before the walker call returns.
static JLTidalFolderPageFetch fakeFetch(NSDictionary *responses, NSMutableArray<NSString *> *log) {
    return ^(NSString *folderID, BOOL foldersOnly, NSString *cursor, JLTidalFolderPageCompletion completion) {
        [log addObject:[NSString stringWithFormat:@"%@|%d|%@", folderID, foldersOnly ? 1 : 0, cursor ?: @""]];
        id response = responses[[NSString stringWithFormat:@"%@|%@", folderID, cursor ?: @""]];
        if ([response isKindOfClass:[NSError class]]) {
            completion(nil, response);
        } else if (response) {
            completion(response, nil);
        } else {
            completion(nil, [NSError errorWithDomain:@"test" code:404 userInfo:nil]);
        }
    };
}

static JLTidalFolderTree *g_tree;
static NSError *g_error;
static int g_calls;

static void walk(JLTidalFolderPageFetch fetch, NSInteger maxDepth, NSInteger maxPages) {
    g_tree = nil;
    g_error = nil;
    g_calls = 0;
    [JLTidalFolderTreeWalker walkWithFetch:fetch maxDepth:maxDepth maxPagesPerListing:maxPages
                                completion:^(JLTidalFolderTree *tree, NSError *error) {
        g_tree = tree;
        g_error = error;
        g_calls++;
    }];
}

static void testNestedTree(void) {
    NSMutableArray *log = [NSMutableArray array];
    NSDictionary *responses = @{
        @"root|": page(@[folderItem(@"A", @"Moods"), folderItem(@"B", @"Work")], nil),
        @"A|": page(@[playlistItem(@"p1"), folderItem(@"A1", @"Evening"), playlistItem(@"p2")], nil),
        @"B|": page(@[playlistItem(@"p4")], nil),
        @"A1|": page(@[playlistItem(@"p3")], nil),
    };
    walk(fakeFetch(responses, log), 8, 100);

    CHECK_EQ(g_calls, 1, "completion called once");
    CHECK(g_error == nil, "no error: %s", g_error.localizedDescription.UTF8String ?: "");
    CHECK_EQ(g_tree.requestCount, (NSInteger)4, "root + 3 folders, got %ld", (long)g_tree.requestCount);
    CHECK_EQ(g_tree.folders.count, (NSUInteger)2, "two top-level folders");
    CHECK_STREQ(g_tree.folders[0].name, @"Moods", "response order kept");
    CHECK_EQ(g_tree.folders[0].subfolders.count, (NSUInteger)1, "subfolder attached");
    CHECK_STREQ(g_tree.folders[0].subfolders[0].name, @"Evening", "subfolder name");
    CHECK_EQ(g_tree.folders[0].playlistUUIDs.count, (NSUInteger)2, "folder playlists");
    CHECK_STREQ(g_tree.folders[0].subfolders[0].playlistUUIDs.firstObject, @"p3", "nested playlist");

    NSArray *expected = @[@"root|1|", @"A|0|", @"B|0|", @"A1|0|"];
    CHECK([log isEqualToArray:expected], "root asks for folders only, folders for everything: %s",
          [log componentsJoinedByString:@" "].UTF8String);

    // End to end with the planner: the tree yields the folder paths.
    NSDictionary *paths = [JLTidalSyncPlanner folderPathsForFolders:g_tree.folders];
    NSDictionary *byPlaylist = [JLTidalSyncPlanner playlistFolderPathsForFolders:g_tree.folders
                                                                     folderPaths:paths];
    CHECK_STREQ(byPlaylist[@"p1"], @"Moods", "p1 path");
    CHECK_STREQ(byPlaylist[@"p3"], @"Moods » Evening", "p3 nested path");
    CHECK_STREQ(byPlaylist[@"p4"], @"Work", "p4 path");
}

static void testEmptyRoot(void) {
    NSMutableArray *log = [NSMutableArray array];
    walk(fakeFetch(@{@"root|": page(@[], nil)}, log), 8, 100);
    CHECK(g_error == nil && g_tree != nil, "empty tree is a valid tree");
    CHECK_EQ(g_tree.folders.count, (NSUInteger)0, "no folders");
    CHECK_EQ(g_tree.requestCount, (NSInteger)1, "one request");
}

static void testCursorPaging(void) {
    NSMutableArray *log = [NSMutableArray array];
    NSDictionary *responses = @{
        @"root|": page(@[folderItem(@"A", @"Moods")], @"r1"),
        @"root|r1": page(@[folderItem(@"B", @"Work")], nil),
        @"A|": page(@[playlistItem(@"p1")], @"c1"),
        @"A|c1": page(@[playlistItem(@"p2"), folderItem(@"A1", @"Evening")], @"c2"),
        @"A|c2": page(@[playlistItem(@"p3")], @""),
        @"B|": page(@[], nil),
        @"A1|": page(@[], nil),
    };
    walk(fakeFetch(responses, log), 8, 100);
    CHECK(g_error == nil, "paged walk succeeds: %s", g_error.localizedDescription.UTF8String ?: "");
    CHECK_EQ(g_tree.folders.count, (NSUInteger)2, "root pages merged");
    CHECK_EQ(g_tree.folders[0].playlistUUIDs.count, (NSUInteger)3, "folder pages merged");
    CHECK_EQ(g_tree.folders[0].subfolders.count, (NSUInteger)1, "subfolder from page 2");
    CHECK_EQ(g_tree.requestCount, (NSInteger)7, "every page counted, got %ld", (long)g_tree.requestCount);
    CHECK([log containsObject:@"root|1|r1"], "root cursor sent with includeOnly kept");
    CHECK([log containsObject:@"A|0|c2"], "folder cursor sent");
}

static void testCursorDoesNotAdvance(void) {
    NSMutableArray *log = [NSMutableArray array];
    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods")], nil),
        @"A|": page(@[playlistItem(@"p1")], @"c1"),
        @"A|c1": page(@[playlistItem(@"p2")], @"c1"),
    }, log), 8, 100);
    CHECK(g_tree == nil && g_error != nil, "repeated cursor fails the walk");
    CHECK_EQ(log.count, (NSUInteger)3, "stops at once");

    log = [NSMutableArray array];
    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods")], nil),
        @"A|": page(@[], @"c1"),
        @"A|c1": page(@[], @"c2"),
        @"A|c2": page(@[], @"c1"),
    }, log), 8, 100);
    CHECK(g_tree == nil && g_error != nil, "cursor loop fails the walk");
}

static void testPageCap(void) {
    NSMutableArray *log = [NSMutableArray array];
    __block int n = 0;
    JLTidalFolderPageFetch endless = ^(NSString *folderID, BOOL foldersOnly, NSString *cursor,
                                       JLTidalFolderPageCompletion completion) {
        [log addObject:folderID];
        if ([folderID isEqualToString:@"root"]) {
            completion(page(@[folderItem(@"A", @"Moods")], nil), nil);
        } else {
            NSString *uuid = [NSString stringWithFormat:@"p%d", n];
            n++;
            completion(page(@[playlistItem(uuid)], [NSString stringWithFormat:@"c%d", n]), nil);
        }
    };
    walk(endless, 8, 3);
    CHECK(g_tree == nil && g_error != nil, "listing over the page cap fails the walk");
    CHECK_EQ(log.count, (NSUInteger)4, "root + 3 pages, got %lu", (unsigned long)log.count);

    // Exactly at the cap is fine.
    log = [NSMutableArray array];
    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods")], nil),
        @"A|": page(@[], @"c1"),
        @"A|c1": page(@[], @"c2"),
        @"A|c2": page(@[playlistItem(@"p1")], nil),
    }, log), 8, 3);
    CHECK(g_error == nil && g_tree != nil, "three pages with cap 3 succeed");
}

static void testDepthCap(void) {
    NSDictionary *responses = @{
        @"root|": page(@[folderItem(@"L1", @"One")], nil),
        @"L1|": page(@[folderItem(@"L2", @"Two")], nil),
        @"L2|": page(@[folderItem(@"L3", @"Three")], nil),
        @"L3|": page(@[playlistItem(@"deep")], nil),
    };
    walk(fakeFetch(responses, [NSMutableArray array]), 2, 100);
    CHECK(g_tree == nil && g_error != nil, "folder below the depth cap fails the walk");

    walk(fakeFetch(responses, [NSMutableArray array]), 3, 100);
    CHECK(g_error == nil && g_tree != nil, "three levels with cap 3 succeed");
    NSDictionary *paths = [JLTidalSyncPlanner folderPathsForFolders:g_tree.folders];
    NSDictionary *byPlaylist = [JLTidalSyncPlanner playlistFolderPathsForFolders:g_tree.folders
                                                                     folderPaths:paths];
    CHECK_STREQ(byPlaylist[@"deep"], @"One » Two » Three", "deep path");
}

static void testFailures(void) {
    NSError *boom = [NSError errorWithDomain:@"test" code:500 userInfo:nil];
    NSMutableArray *log = [NSMutableArray array];
    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods"), folderItem(@"B", @"Work")], nil),
        @"A|": page(@[playlistItem(@"p1")], nil),
        @"B|": boom,
    }, log), 8, 100);
    CHECK(g_tree == nil, "one failed listing fails the walk");
    CHECK(g_error == boom, "the listing's error is passed on");
    CHECK_EQ(g_calls, 1, "completion called once on failure");

    walk(fakeFetch(@{@"root|": boom}, [NSMutableArray array]), 8, 100);
    CHECK(g_tree == nil && g_error == boom, "failed root listing fails the walk");

    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods")], nil),
        @"A|": @{@"status": @404},
    }, [NSMutableArray array]), 8, 100);
    CHECK(g_tree == nil && g_error != nil, "listing without items fails the walk");

    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods")], nil),
        @"A|": page(@[playlistItem(@"p1"), @{@"itemType": @"PLAYLIST", @"data": @{}}], nil),
    }, [NSMutableArray array]), 8, 100);
    CHECK(g_tree == nil && g_error != nil, "playlist that cannot be placed fails the walk");

    walk(fakeFetch(@{
        @"root|": page(@[@{@"itemType": @"FOLDER", @"name": @"No id"}], nil),
    }, [NSMutableArray array]), 8, 100);
    CHECK(g_tree == nil && g_error != nil, "folder without an id fails the walk");
}

static void testRepeatedFolders(void) {
    NSMutableArray *log = [NSMutableArray array];
    walk(fakeFetch(@{
        @"root|": page(@[folderItem(@"A", @"Moods"), folderItem(@"B", @"Work")], nil),
        // A lists itself and B again: neither is listed twice or re-parented.
        @"A|": page(@[folderItem(@"A", @"Moods"), folderItem(@"B", @"Work"), playlistItem(@"p1")], nil),
        @"B|": page(@[folderItem(@"root", @"Root?")], nil),
    }, log), 8, 100);
    CHECK(g_error == nil && g_tree != nil, "repeated folders do not fail the walk");
    CHECK_EQ(g_tree.requestCount, (NSInteger)3, "each folder listed once, got %ld", (long)g_tree.requestCount);
    CHECK_EQ(g_tree.folders[0].subfolders.count, (NSUInteger)0, "no cycle in the tree");
    CHECK_EQ(g_tree.folders[1].subfolders.count, (NSUInteger)0, "root is never a subfolder");
}

int main(void) {
    @autoreleasepool {
        testNestedTree();
        testEmptyRoot();
        testCursorPaging();
        testCursorDoesNotAdvance();
        testPageCap();
        testDepthCap();
        testFailures();
        testRepeatedFolders();
        g_tree = nil;
        g_error = nil;
    }
    return testHarnessFinish("FolderTreeWalker");
}
