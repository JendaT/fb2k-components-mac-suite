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
    // The shape JLTidalFolderTreeWalker builds: one folder per listing, with
    // subfolders and playlists attached as each folder is listed.
    JLTidalPlaylistFolder *root = [[JLTidalPlaylistFolder alloc] initWithFolderID:@"f1" name:@"Moods"];
    JLTidalPlaylistFolder *evening = [[JLTidalPlaylistFolder alloc] initWithFolderID:@"f2" name:@"Evening"];
    [evening.playlistUUIDs addObject:@"pl-deep"];
    [root.subfolders addObject:evening];
    [root.playlistUUIDs addObject:@"pl-top"];

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

#pragma mark - Pull plan with Moves

static JLTidalPlaylist *remote(NSString *uuid, NSString *title) {
    return [[JLTidalPlaylist alloc] initWithDictionary:@{@"uuid": uuid, @"title": title}];
}

static NSSet<NSString *> *ids(NSArray<NSString *> *list) {
    return [NSSet setWithArray:list];
}

// Favorites present and unchanged, so tests see only the playlists they set up.
static JLTidalPullSnapshot *snapshotWith(NSArray<JLTidalPlaylist *> *playlists,
                                         NSDictionary<NSString *, NSString *> *nameByUUID,
                                         NSDictionary<NSString *, NSArray<NSString *> *> *remoteTrackIDs,
                                         NSDictionary<NSString *, NSArray<NSString *> *> *localTrackIDs) {
    JLTidalPullSnapshot *s = [[JLTidalPullSnapshot alloc] init];
    s.playlists = playlists;
    s.nameByUUID = nameByUUID;
    NSMutableDictionary *byUUID = [NSMutableDictionary dictionary];
    for (NSString *uuid in remoteTrackIDs) byUUID[uuid] = tracks(remoteTrackIDs[uuid]);
    s.tracksByUUID = byUUID;
    NSMutableDictionary *counts = [@{[Planner favoriteTracksName]: @0} mutableCopy];
    NSMutableDictionary *localIDs = [NSMutableDictionary dictionary];
    for (NSString *name in localTrackIDs) {
        counts[name] = @(localTrackIDs[name].count);
        localIDs[name] = ids(localTrackIDs[name]);
    }
    s.localCountsByName = counts;
    s.localTrackIDsByName = localIDs;
    return s;
}

static NSArray<JLTidalSyncChange *> *ofType(NSArray<JLTidalSyncChange *> *changes, JLTidalSyncChangeType type) {
    NSMutableArray *result = [NSMutableArray array];
    for (JLTidalSyncChange *c in changes) if (c.changeType == type) [result addObject:c];
    return result;
}

static JLTidalSyncChange *named(NSArray<JLTidalSyncChange *> *changes, NSString *name) {
    for (JLTidalSyncChange *c in changes) if ([c.playlistName isEqualToString:name]) return c;
    return nil;
}

static void testMoveCandidate(void) {
    CHECK_STREQ([Planner moveCandidateForTargetName:@"TIDAL » Moods » Chill" title:@"Chill"
                                         mappedName:@"TIDAL » Chill"],
                @"TIDAL » Chill", "mapped name differing from the target");
    CHECK_STREQ([Planner moveCandidateForTargetName:@"TIDAL » Moods » Chill" title:@"Chill"
                                         mappedName:nil],
                @"TIDAL » Chill", "no mapping -> flat legacy name");
    CHECK_STREQ([Planner moveCandidateForTargetName:@"TIDAL » Moods » Chill" title:@"Chill"
                                         mappedName:@"TIDAL » Moods » Chill"],
                @"TIDAL » Chill", "mapping equal to the target -> flat legacy name");
    CHECK_STREQ([Planner moveCandidateForTargetName:@"TIDAL » New" title:@"New"
                                         mappedName:@"TIDAL » Old"],
                @"TIDAL » Old", "renamed on TIDAL at the root");
    CHECK([Planner moveCandidateForTargetName:@"TIDAL » Chill" title:@"Chill" mappedName:nil] == nil,
          "root playlist without mapping has no candidate");
    CHECK([Planner moveCandidateForTargetName:@"TIDAL » Chill" title:@"Chill"
                                   mappedName:@"TIDAL » Chill"] == nil,
          "root playlist mapped to its own name has no candidate");

    CHECK([Planner isFavoritesName:@"TIDAL » Favorite Tracks"], "favorite tracks is a favorites name");
    CHECK([Planner isFavoritesName:@"TIDAL » Favorite Albums » LP"], "album is a favorites name");
    CHECK(![Planner isFavoritesName:@"TIDAL » Chill"], "regular name is not");
}

static void testMovePlanned(void) {
    JLTidalPullSnapshot *s = snapshotWith(@[remote(@"u1", @"Chill")],
                                          @{@"u1": @"TIDAL » Moods » Chill"},
                                          @{@"u1": @[@"1", @"2", @"3"]},
                                          @{@"TIDAL » Chill": @[@"1", @"2"]});
    s.uuidToName = @{@"u1": @"TIDAL » Chill"};
    s.nameToUUID = @{@"TIDAL » Chill": @"u1"};
    NSArray *changes = [Planner pullChangesForSnapshot:s];

    NSArray *moves = ofType(changes, JLTidalSyncChangeTypeRename);
    CHECK_EQ(moves.count, (NSUInteger)1, "one move, got %lu", (unsigned long)moves.count);
    JLTidalSyncChange *m = moves.firstObject;
    CHECK_STREQ(m.previousName, @"TIDAL » Chill", "old name");
    CHECK_STREQ(m.playlistName, @"TIDAL » Moods » Chill", "new name");
    CHECK_STREQ(m.tidalUUID, @"u1", "uuid carried");
    CHECK_EQ(m.tracksAdded, (NSInteger)1, "diff against the old playlist: +1");
    CHECK_EQ(m.tracksRemoved, (NSInteger)0, "diff against the old playlist: -0");
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeCreate).count, (NSUInteger)0, "no create");
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeDelete).count, (NSUInteger)0, "old name is not deleted");

    // Without any mapping the flat legacy name is the candidate.
    s.uuidToName = @{};
    s.nameToUUID = @{};
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)1, "legacy name moves");
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeDelete).count, (NSUInteger)0, "and is not deleted");
}

static void testMoveIdenticalTracks(void) {
    JLTidalPullSnapshot *s = snapshotWith(@[remote(@"u1", @"Chill")],
                                          @{@"u1": @"TIDAL » Moods » Chill"},
                                          @{@"u1": @[@"1", @"2"]},
                                          @{@"TIDAL » Chill": @[@"2", @"1"]});
    JLTidalSyncChange *m = ofType([Planner pullChangesForSnapshot:s], JLTidalSyncChangeTypeRename).firstObject;
    CHECK(m != nil, "move planned");
    CHECK(m.tracksAdded == 0 && m.tracksRemoved == 0, "identical set -> pure rename");
}

static void testMoveFromMappedName(void) {
    // Renamed on TIDAL, still at the root: the map remembers the old name.
    JLTidalPullSnapshot *s = snapshotWith(@[remote(@"u1", @"New")],
                                          @{@"u1": @"TIDAL » New"},
                                          @{@"u1": @[@"1"]},
                                          @{@"TIDAL » Old": @[@"1"]});
    s.uuidToName = @{@"u1": @"TIDAL » Old"};
    s.nameToUUID = @{@"TIDAL » Old": @"u1"};
    JLTidalSyncChange *m = ofType([Planner pullChangesForSnapshot:s], JLTidalSyncChangeTypeRename).firstObject;
    CHECK_STREQ(m.previousName, @"TIDAL » Old", "renamed from the mapped name");
    CHECK_STREQ(m.playlistName, @"TIDAL » New", "to the new title");

    // Without the mapping a root rename cannot be recognised: Create + Delete.
    s.uuidToName = @{};
    s.nameToUUID = @{};
    NSArray *changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "no candidate, no move");
    CHECK(named(changes, @"TIDAL » New").changeType == JLTidalSyncChangeTypeCreate, "create as before");
    CHECK(named(changes, @"TIDAL » Old").changeType == JLTidalSyncChangeTypeDelete, "delete as before");
}

static void testMoveCollisions(void) {
    // Target already exists locally: Update or Unchanged, as today.
    JLTidalPullSnapshot *s = snapshotWith(@[remote(@"u1", @"Chill")],
                                          @{@"u1": @"TIDAL » Moods » Chill"},
                                          @{@"u1": @[@"1"]},
                                          @{@"TIDAL » Chill": @[@"1"], @"TIDAL » Moods » Chill": @[@"1"]});
    NSArray *changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "target exists -> no move");
    CHECK(named(changes, @"TIDAL » Moods » Chill").changeType == JLTidalSyncChangeTypeUnchanged,
          "target exists -> unchanged");

    // Two remote "X" in different folders both fall back to "TIDAL » X".
    s = snapshotWith(@[remote(@"u1", @"X"), remote(@"u2", @"X")],
                     @{@"u1": @"TIDAL » A » X", @"u2": @"TIDAL » B » X"},
                     @{@"u1": @[@"1"], @"u2": @[@"2"]},
                     @{@"TIDAL » X": @[@"1"]});
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "two claimants -> no move");
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeCreate).count, (NSUInteger)2, "both created as before");

    // Candidate mapped to another UUID.
    s = snapshotWith(@[remote(@"u1", @"Chill")],
                     @{@"u1": @"TIDAL » Moods » Chill"},
                     @{@"u1": @[@"1"]},
                     @{@"TIDAL » Chill": @[@"1"]});
    s.nameToUUID = @{@"TIDAL » Chill": @"u9"};
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "candidate owned by another uuid");
    CHECK(named(changes, @"TIDAL » Moods » Chill").changeType == JLTidalSyncChangeTypeCreate, "-> create");

    // Favorites names are never moved.
    s = snapshotWith(@[remote(@"u1", @"Favorite Tracks")],
                     @{@"u1": @"TIDAL » Moods » Favorite Tracks"},
                     @{@"u1": @[@"1"]},
                     @{});
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "favorite tracks never moves");
    CHECK(named(changes, @"TIDAL » Favorite Tracks").changeType == JLTidalSyncChangeTypeUnchanged,
          "favorites untouched");

    s = snapshotWith(@[remote(@"u1", @"LP")],
                     @{@"u1": @"TIDAL » Moods » LP"},
                     @{@"u1": @[@"1"]},
                     @{@"TIDAL » Favorite Albums » LP": @[@"1"]});
    s.uuidToName = @{@"u1": @"TIDAL » Favorite Albums » LP"};
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "favorite album never moves");

    // Candidate is another remote playlist's target: that one keeps it.
    s = snapshotWith(@[remote(@"u1", @"X"), remote(@"u2", @"X")],
                     @{@"u1": @"TIDAL » F » X", @"u2": @"TIDAL » X"},
                     @{@"u1": @[@"1"], @"u2": @[@"2"]},
                     @{@"TIDAL » X": @[@"1"]});
    s.uuidToName = @{@"u1": @"TIDAL » X"};
    s.nameToUUID = @{@"TIDAL » X": @"u1"};
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "candidate is a target -> no move");
    CHECK(named(changes, @"TIDAL » X").changeType == JLTidalSyncChangeTypeUpdate, "root playlist updates it");
    CHECK(named(changes, @"TIDAL » F » X").changeType == JLTidalSyncChangeTypeCreate, "folder one is created");

    // Two remote playlists with the same new target never both move there.
    s = snapshotWith(@[remote(@"u1", @"C"), remote(@"u2", @"C")],
                     @{@"u1": @"TIDAL » F » C", @"u2": @"TIDAL » F » C"},
                     @{@"u1": @[@"1"], @"u2": @[@"2"]},
                     @{@"TIDAL » A": @[@"1"], @"TIDAL » B": @[@"2"]});
    s.uuidToName = @{@"u1": @"TIDAL » A", @"u2": @"TIDAL » B"};
    s.nameToUUID = @{@"TIDAL » A": @"u1", @"TIDAL » B": @"u2"};
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0, "shared target -> no move");
}

static void testDeleteDetection(void) {
    JLTidalPullSnapshot *s = snapshotWith(@[remote(@"u1", @"Chill")],
                                          @{@"u1": @"TIDAL » Moods » Chill"},
                                          @{@"u1": @[@"1"]},
                                          @{@"TIDAL » Chill": @[@"1"], @"TIDAL » Gone": @[@"7", @"8"],
                                            @"My List": @[]});
    s.nameToUUID = @{@"TIDAL » Gone": @"u-gone"};
    NSArray *changes = [Planner pullChangesForSnapshot:s];
    NSArray *deletes = ofType(changes, JLTidalSyncChangeTypeDelete);
    CHECK_EQ(deletes.count, (NSUInteger)1, "only the stale TIDAL playlist, got %lu", (unsigned long)deletes.count);
    JLTidalSyncChange *d = deletes.firstObject;
    CHECK_STREQ(d.playlistName, @"TIDAL » Gone", "stale playlist deleted");
    CHECK_EQ(d.tracksRemoved, (NSInteger)2, "delete reports its item count");
    CHECK_STREQ(d.tidalUUID, @"u-gone", "delete carries the mapped uuid");
    CHECK(named(changes, @"TIDAL » Chill") == nil, "consumed name has no change of its own");
}

static void testFailedFetchProtectsCandidates(void) {
    // u1's track fetch failed. u2 (fetched) is also called "Chill" and would
    // fall back to the same flat name.
    JLTidalPullSnapshot *s = snapshotWith(@[remote(@"u1", @"Chill"), remote(@"u2", @"Chill")],
                                          @{@"u1": @"TIDAL » Moods » Chill", @"u2": @"TIDAL » Other » Chill"},
                                          @{@"u2": @[@"5"]},
                                          @{@"TIDAL » Chill": @[@"1"], @"TIDAL » Chill Old": @[@"1"]});
    s.failedUUIDs = [NSSet setWithObject:@"u1"];
    s.uuidToName = @{@"u1": @"TIDAL » Chill Old"};
    NSArray *changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeDelete).count, (NSUInteger)0,
             "neither the mapped nor the flat name of a failed playlist is deleted");
    CHECK(named(changes, @"TIDAL » Moods » Chill") == nil, "failed playlist is not planned");
    CHECK_EQ(ofType(changes, JLTidalSyncChangeTypeRename).count, (NSUInteger)0,
             "a name a failed playlist may own is not taken by a move");
    CHECK(named(changes, @"TIDAL » Other » Chill").changeType == JLTidalSyncChangeTypeCreate,
          "the fetched one is created instead");
}

static void testFavoritesInPlan(void) {
    JLTidalAlbum *lp = [[JLTidalAlbum alloc] initWithDictionary:@{@"id": @7, @"title": @"LP", @"numberOfTracks": @3}];
    JLTidalPullSnapshot *s = snapshotWith(@[], @{}, @{}, @{@"TIDAL » Favorite Albums » Old LP": @[]});
    s.favoriteTracks = tracks(@[@"1", @"2"]);
    s.favoriteAlbums = @[lp];
    NSArray *changes = [Planner pullChangesForSnapshot:s];
    CHECK(named(changes, @"TIDAL » Favorite Tracks").changeType == JLTidalSyncChangeTypeUpdate,
          "favorite tracks count differs -> update");
    CHECK(named(changes, @"TIDAL » Favorite Albums » LP").changeType == JLTidalSyncChangeTypeCreate,
          "new favorite album -> create");
    CHECK(named(changes, @"TIDAL » Favorite Albums » Old LP").changeType == JLTidalSyncChangeTypeDelete,
          "unfavorited album -> delete");

    s.favoriteTracksFailed = YES;
    s.favoriteAlbumsFailed = YES;
    changes = [Planner pullChangesForSnapshot:s];
    CHECK_EQ(changes.count, (NSUInteger)0, "failed favorites fetches plan nothing and delete nothing, got %lu",
             (unsigned long)changes.count);
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

    JLTidalSyncChange *move = [[JLTidalSyncChange alloc] initRenameFromName:@"TIDAL » X"
                                                                     toName:@"TIDAL » F » X"
                                                                tracksAdded:0
                                                              tracksRemoved:0
                                                                  tidalUUID:@"u1"];
    CHECK_EQ(move.changeType, JLTidalSyncChangeTypeRename, "rename type");
    CHECK_STREQ(move.previousName, @"TIDAL » X", "rename keeps the old name");
    CHECK([[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate name:@"a" tracksAdded:0
                                    tracksRemoved:0 tidalUUID:nil].previousName == nil,
          "other changes have no old name");

    JLTidalSyncReport *withMoves = [[JLTidalSyncReport alloc] initWithChanges:@[
        [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeCreate name:@"a" tracksAdded:1 tracksRemoved:0 tidalUUID:nil],
        move,
        [[JLTidalSyncChange alloc] initRenameFromName:@"TIDAL » Y" toName:@"TIDAL » F » Y" tracksAdded:2 tracksRemoved:0 tidalUUID:@"u2"],
        [[JLTidalSyncChange alloc] initWithType:JLTidalSyncChangeTypeUnchanged name:@"d" tracksAdded:0 tracksRemoved:0 tidalUUID:nil],
    ]];
    CHECK_EQ(withMoves.totalRenamed, (NSInteger)2, "renamed count");
    CHECK_EQ(withMoves.totalUpdated, (NSInteger)0, "a move with new tracks is not also an update");
    CHECK_STREQ([withMoves summary], @"1 new, 2 moved, 1 unchanged", "summary counts moves");

    JLTidalSyncReport *movesOnly = [[JLTidalSyncReport alloc] initWithChanges:@[move]];
    CHECK_STREQ([movesOnly summary], @"1 moved", "moves-only summary");
    CHECK_EQ(movesOnly.totalCreated + movesOnly.totalUpdated + movesOnly.totalDeleted, (NSInteger)0,
             "a moves-only report has nothing else, so the browser must count moves");
}

int main(void) {
    @autoreleasepool {
        testNaming();
        testFolderPaths();
        testPullChanges();
        testFavoritesChanges();
        testPushPlanning();
        testTrackIDDiff();
        testMoveCandidate();
        testMovePlanned();
        testMoveIdenticalTracks();
        testMoveFromMappedName();
        testMoveCollisions();
        testDeleteDetection();
        testFailedFetchProtectsCandidates();
        testFavoritesInPlan();
        testReportSummary();
    }
    return testHarnessFinish("SyncPlanner");
}
