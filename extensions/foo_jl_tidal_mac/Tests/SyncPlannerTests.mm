//
//  SyncPlannerTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for playlist-sync planning: naming round-trip, folder-path
//  building, pull/push change decisions, and track-ID diffing.
//

#import <Foundation/Foundation.h>
#import "../src/Core/SyncPlanner.h"
#include "TestHarness.h"

typedef JLTidalSyncPlanner Planner;

static JLTidalTrack *track(NSString *trackID) {
    return [[JLTidalTrack alloc] initWithDictionary:@{@"id": trackID, @"title": trackID}];
}

static NSArray<JLTidalTrack *> *tracks(NSArray<NSString *> *ids) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *i in ids) [result addObject:track(i)];
    return result;
}

static void testNaming(void) {
    CHECK_STREQ([Planner foobarNameForTitle:@"Chill" folderPath:nil],
                @"TIDAL » Chill", "no folder");
    CHECK_STREQ([Planner foobarNameForTitle:@"Chill" folderPath:@"Moods"],
                @"TIDAL » Moods » Chill", "one folder");
    CHECK_STREQ([Planner foobarNameForTitle:@"Chill" folderPath:@"Moods » Evening"],
                @"TIDAL » Moods » Evening » Chill", "nested folder path");

    CHECK([Planner isTidalSyncedName:@"TIDAL » Chill"], "synced name recognized");
    CHECK(![Planner isTidalSyncedName:@"TIDALX » Chill"], "wrong prefix rejected");
    CHECK(![Planner isTidalSyncedName:@"TIDAL"], "bare prefix without delimiter rejected");
    CHECK(![Planner isTidalSyncedName:@"My Playlist"], "unrelated name rejected");

    CHECK_STREQ([Planner tidalTitleFromFoobarName:@"TIDAL » Moods » Evening » Chill"],
                @"Chill", "title is last component");
    CHECK([Planner tidalTitleFromFoobarName:@"Not Synced"] == nil, "non-synced -> nil");

    // Round-trip
    NSString *name = [Planner foobarNameForTitle:@"My Mix" folderPath:@"A » B"];
    CHECK_STREQ([Planner tidalTitleFromFoobarName:name], @"My Mix", "name round-trips");

    CHECK_STREQ([Planner favoriteTracksName], @"TIDAL » Favorite Tracks", "favorites name");
    CHECK_STREQ([Planner favoriteAlbumNameForTitle:@"OK Computer"],
                @"TIDAL » Favorite Albums » OK Computer", "favorite album name");

    CHECK_STREQ([Planner favoriteAlbumKeyForAlbumID:@"42"], @"__favalbum_42__", "album key");
    CHECK_STREQ([Planner albumIDFromFavoriteAlbumKey:@"__favalbum_42__"], @"42", "album key round-trip");
}

static void testFolderPaths(void) {
    JLTidalPlaylistFolder *root = [[JLTidalPlaylistFolder alloc] initWithDictionary:@{
        @"id": @"f1", @"name": @"Moods",
        @"items": @[
            @{@"type": @"FOLDER", @"id": @"f2", @"name": @"Evening",
              @"items": @[@{@"type": @"PLAYLIST", @"data": @{@"uuid": @"pl-deep"}}]},
            @{@"type": @"PLAYLIST", @"data": @{@"uuid": @"pl-top"}},
        ],
    }];

    NSDictionary *paths = [Planner folderPathsForFolders:@[root]];
    CHECK_STREQ(paths[@"f1"], @"Moods", "root folder path");
    CHECK_STREQ(paths[@"f2"], @"Moods » Evening", "nested folder path");

    NSDictionary *playlistPaths = [Planner playlistFolderPathsForFolders:@[root] folderPaths:paths];
    CHECK_STREQ(playlistPaths[@"pl-top"], @"Moods", "playlist in root folder");
    CHECK_STREQ(playlistPaths[@"pl-deep"], @"Moods » Evening", "playlist in nested folder");
}

static void testPullChanges(void) {
    NSArray *tidal = tracks(@[@"1", @"2", @"3"]);

    // Absent foobar playlist -> Create with full count
    JLTidalSyncChange *c = [Planner pullChangeForName:@"TIDAL » X" uuid:@"u1"
                                          tidalTracks:tidal foobarTrackIDs:nil];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeCreate, "absent -> create");
    CHECK_EQ(c.tracksAdded, (NSInteger)3, "create adds all tracks");
    CHECK_STREQ(c.tidalUUID, @"u1", "uuid carried");

    // Identical sets -> Unchanged
    c = [Planner pullChangeForName:@"TIDAL » X" uuid:@"u1"
                       tidalTracks:tidal
                    foobarTrackIDs:[NSSet setWithArray:@[@"1", @"2", @"3"]]];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeUnchanged, "same sets -> unchanged");

    // Divergent sets -> Update with add/remove counts
    c = [Planner pullChangeForName:@"TIDAL » X" uuid:@"u1"
                       tidalTracks:tidal
                    foobarTrackIDs:[NSSet setWithArray:@[@"2", @"9", @"10"]]];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeUpdate, "diff -> update");
    CHECK_EQ(c.tracksAdded, (NSInteger)2, "adds 1,3 -> 2 tracks");
    CHECK_EQ(c.tracksRemoved, (NSInteger)2, "removes 9,10 -> 2 tracks");
}

static void testFavoritesChanges(void) {
    JLTidalSyncChange *c = [Planner favoritesPullChangeForName:@"TIDAL » Favorite Tracks"
                                                          uuid:@"__favorites__"
                                                    tidalCount:50 existingCount:-1];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeCreate, "absent favorites -> create");
    CHECK_EQ(c.tracksAdded, (NSInteger)50, "create count");

    c = [Planner favoritesPullChangeForName:@"n" uuid:@"u" tidalCount:50 existingCount:40];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeUpdate, "count mismatch -> update");
    CHECK_EQ(c.tracksAdded, (NSInteger)50, "update reports tidal count");
    CHECK_EQ(c.tracksRemoved, (NSInteger)40, "update reports existing count");

    c = [Planner favoritesPullChangeForName:@"n" uuid:@"u" tidalCount:50 existingCount:50];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeUnchanged, "same count -> unchanged");

    JLTidalAlbum *album = [[JLTidalAlbum alloc] initWithDictionary:@{
        @"id": @7, @"title": @"LP", @"numberOfTracks": @11}];
    c = [Planner favoriteAlbumPullChangeForAlbum:album exists:NO];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeCreate, "absent album -> create");
    CHECK_EQ(c.tracksAdded, (NSInteger)11, "album track count");
    CHECK_STREQ(c.tidalUUID, @"__favalbum_7__", "album key as uuid");
    CHECK_STREQ(c.playlistName, @"TIDAL » Favorite Albums » LP", "album playlist name");

    c = [Planner favoriteAlbumPullChangeForAlbum:album exists:YES];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeUnchanged, "existing album -> unchanged");
}

static void testPushPlanning(void) {
    CHECK([Planner shouldSkipPushForName:@"My Playlist"], "non-synced skipped");
    CHECK([Planner shouldSkipPushForName:@"TIDAL » Favorite Tracks"], "favorite tracks skipped");
    CHECK([Planner shouldSkipPushForName:@"TIDAL » Favorite Albums » X"], "favorite albums skipped");
    CHECK(![Planner shouldSkipPushForName:@"TIDAL » Mix"], "regular synced name pushes");

    NSSet *known = [NSSet setWithArray:@[@"u1", @"u2"]];

    JLTidalSyncChange *c = [Planner pushChangeForName:@"TIDAL » Mix" uuid:nil
                                      knownTidalUUIDs:known itemCount:12];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeCreate, "no mapping -> create");
    CHECK_EQ(c.tracksAdded, (NSInteger)12, "create carries item count");
    CHECK(c.tidalUUID == nil, "create has no uuid");

    c = [Planner pushChangeForName:@"TIDAL » Mix" uuid:@"gone"
                   knownTidalUUIDs:known itemCount:12];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeCreate, "uuid deleted on Tidal -> create");

    c = [Planner pushChangeForName:@"TIDAL » Mix" uuid:@"u1"
                   knownTidalUUIDs:known itemCount:12];
    CHECK_EQ(c.changeType, JLTidalSyncChangeTypeUpdate, "known uuid -> update");
    CHECK_STREQ(c.tidalUUID, @"u1", "update carries uuid");
}

static void testTrackIDDiff(void) {
    NSArray *tidal = tracks(@[@"1", @"2"]);
    NSArray *toAdd = [Planner trackIDsToAddFromLocalIDs:@[@"1", @"2", @"3", @"4"] tidalTracks:tidal];
    NSSet *added = [NSSet setWithArray:toAdd];
    CHECK_EQ(added.count, (NSUInteger)2, "two new tracks");
    CHECK([added containsObject:@"3"] && [added containsObject:@"4"], "3 and 4 are new");

    CHECK_EQ([Planner trackIDsToAddFromLocalIDs:@[@"1"] tidalTracks:tidal].count, (NSUInteger)0,
             "subset adds nothing");
    CHECK_EQ([Planner trackIDsToAddFromLocalIDs:@[] tidalTracks:tidal].count, (NSUInteger)0,
             "empty local adds nothing");
}

static void testReportSummary(void) {
    JLTidalSyncReport *report = [[JLTidalSyncReport alloc] initWithChanges:@[
        [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate name:@"a" tracksAdded:1 tracksRemoved:0 tidalUUID:nil],
        [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUpdate name:@"b" tracksAdded:1 tracksRemoved:1 tidalUUID:nil],
        [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeDelete name:@"c" tracksAdded:0 tracksRemoved:5 tidalUUID:nil],
        [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUnchanged name:@"d" tracksAdded:0 tracksRemoved:0 tidalUUID:nil],
    ]];
    CHECK_EQ(report.totalCreated, (NSInteger)1, "created count");
    CHECK_EQ(report.totalUpdated, (NSInteger)1, "updated count");
    CHECK_EQ(report.totalDeleted, (NSInteger)1, "deleted count");
    CHECK_EQ(report.totalUnchanged, (NSInteger)1, "unchanged count");
    CHECK_STREQ([report summary], @"1 new, 1 updated, 1 removed, 1 unchanged", "summary string");

    JLTidalSyncReport *empty = [[JLTidalSyncReport alloc] initWithChanges:@[]];
    CHECK_STREQ([empty summary], @"No changes", "empty summary");
}

int main(void) {
    @autoreleasepool {
        testNaming();
        testFolderPaths();
        testPullChanges();
        testFavoritesChanges();
        testPushPlanning();
        testTrackIDDiff();
        testReportSummary();
    }
    return testHarnessFinish("SyncPlanner");
}
