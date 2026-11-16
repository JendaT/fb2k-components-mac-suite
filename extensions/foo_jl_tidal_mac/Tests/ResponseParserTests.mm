//
//  ResponseParserTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for JSON -> model parsing of Tidal API responses: token and
//  refresh responses (incl. refresh-token rotation), item lists, the
//  favorites/playlist "item" wrapper, folder filtering, and exact-ISRC
//  matching.
//

#import <Foundation/Foundation.h>
#import "../src/Core/ResponseParser.h"
#include "TestHarness.h"

typedef JLTidalResponseParser Parser;

static NSDictionary *trackDict(NSString *trackID, NSString *title, NSString *isrc) {
    NSMutableDictionary *d = [@{
        @"id": trackID,
        @"title": title,
        @"duration": @200,
        @"artist": @{@"name": @"Artist"},
        @"album": @{@"id": @77, @"title": @"Album", @"cover": @"ab-cd"},
    } mutableCopy];
    if (isrc) d[@"isrc"] = isrc;
    return d;
}

static void testTokenResponse(void) {
    JLTidalSession *s = [Parser sessionFromTokenResponse:@{
        @"access_token": @"acc",
        @"refresh_token": @"ref",
        @"expires_in": @3600,
        @"user": @{@"userId": @12345, @"username": @"jenda", @"countryCode": @"CZ"},
    }];
    CHECK(s != nil, "full token response parses");
    CHECK_STREQ(s.accessToken, @"acc", "access token");
    CHECK_STREQ(s.refreshToken, @"ref", "refresh token");
    CHECK_STREQ(s.userId, @"12345", "numeric userId stringified");
    CHECK_STREQ(s.username, @"jenda", "username");
    CHECK_STREQ(s.countryCode, @"CZ", "countryCode");
    CHECK(s.isValid, "fresh session valid");

    CHECK([Parser sessionFromTokenResponse:@{@"refresh_token": @"ref"}] == nil,
          "missing access_token -> nil");
    CHECK([Parser sessionFromTokenResponse:@{@"access_token": @"acc"}] == nil,
          "missing refresh_token -> nil");

    // No user block is fine
    s = [Parser sessionFromTokenResponse:@{@"access_token": @"a", @"refresh_token": @"r"}];
    CHECK(s != nil && s.userId == nil, "no user block -> nil identity fields");
}

static void testRefreshResponse(void) {
    JLTidalSession *current = [[JLTidalSession alloc] initWithAccessToken:@"old-acc"
                                                             refreshToken:@"old-ref"
                                                                expiresIn:-10
                                                                   userId:@"u1"
                                                                 username:@"jenda"
                                                              countryCode:@"CZ"];

    // Rotation: response carries a new refresh token
    JLTidalSession *s = [Parser sessionFromRefreshResponse:@{
        @"access_token": @"new-acc",
        @"refresh_token": @"new-ref",
        @"expires_in": @3600,
    } currentSession:current];
    CHECK_STREQ(s.accessToken, @"new-acc", "rotated access token");
    CHECK_STREQ(s.refreshToken, @"new-ref", "rotated refresh token");
    CHECK_STREQ(s.userId, @"u1", "identity preserved on rotation");
    CHECK_STREQ(s.countryCode, @"CZ", "countryCode preserved on rotation");

    // No rotation: old refresh token kept
    s = [Parser sessionFromRefreshResponse:@{@"access_token": @"new-acc2", @"expires_in": @3600}
                            currentSession:current];
    CHECK_STREQ(s.accessToken, @"new-acc2", "access token updated");
    CHECK_STREQ(s.refreshToken, @"old-ref", "old refresh token kept without rotation");
    CHECK_STREQ(s.username, @"jenda", "identity preserved without rotation");

    CHECK([Parser sessionFromRefreshResponse:@{@"refresh_token": @"x"} currentSession:current] == nil,
          "missing access_token -> nil");
}

static void testPlainItemLists(void) {
    NSArray *items = @[trackDict(@"1", @"One", nil), trackDict(@"2", @"Two", nil)];
    NSArray<JLTidalTrack *> *tracks = [Parser tracksFromItems:items];
    CHECK_EQ(tracks.count, (NSUInteger)2, "two tracks parsed");
    CHECK_STREQ(tracks[0].trackID, @"1", "track id");
    CHECK_STREQ(tracks[1].title, @"Two", "track title");
    CHECK_STREQ(tracks[0].artist, @"Artist", "nested artist name");
    CHECK_STREQ(tracks[0].albumID, @"77", "numeric album id stringified, for Go to Album");
    CHECK(tracks[0].bpm == 0, "no bpm field -> 0 (no BPM tag)");
    CHECK(tracks[0].key == nil && tracks[0].keyScale == nil, "no key fields -> nil");

    NSMutableDictionary *withTempo = [trackDict(@"3", @"Three", nil) mutableCopy];
    withTempo[@"bpm"] = @(127.6);
    withTempo[@"key"] = @"FSharp";
    withTempo[@"keyScale"] = @"MINOR";
    JLTidalTrack *tempo = [Parser tracksFromItems:@[withTempo]][0];
    CHECK(tempo.bpm == 127.6, "fractional bpm kept as sent");
    CHECK_STREQ(tempo.key, @"FSharp", "key parsed");
    CHECK_STREQ(tempo.keyScale, @"MINOR", "key scale parsed");
    withTempo[@"bpm"] = [NSNull null];
    withTempo[@"key"] = @"UNKNOWN";
    withTempo[@"keyScale"] = @"UNKNOWN";
    tempo = [Parser tracksFromItems:@[withTempo]][0];
    CHECK(tempo.bpm == 0, "null bpm -> 0");
    CHECK(tempo.key == nil && tempo.keyScale == nil, "UNKNOWN key and scale -> nil");

    CHECK_EQ([Parser tracksFromItems:nil].count, (NSUInteger)0, "nil items -> empty, not nil");
    CHECK([Parser tracksFromItems:nil] != nil, "nil items returns array");
    CHECK_EQ([Parser tracksFromItems:@[]].count, (NSUInteger)0, "empty items -> empty");

    NSArray<JLTidalAlbum *> *albums = [Parser albumsFromItems:@[
        @{@"id": @9, @"title": @"LP", @"numberOfTracks": @10}]];
    CHECK_EQ(albums.count, (NSUInteger)1, "album parsed");
    CHECK_STREQ(albums[0].albumID, @"9", "album id stringified");

    NSArray<JLTidalArtist *> *artists = [Parser artistsFromItems:@[
        @{@"id": @7, @"name": @"Band"}]];
    CHECK_EQ(artists.count, (NSUInteger)1, "artist parsed");
    CHECK_STREQ(artists[0].name, @"Band", "artist name");

    NSArray<JLTidalPlaylist *> *playlists = [Parser playlistsFromItems:@[
        @{@"uuid": @"pl-1", @"title": @"Mix", @"numberOfTracks": @3}]];
    CHECK_EQ(playlists.count, (NSUInteger)1, "playlist parsed");
    CHECK_STREQ(playlists[0].playlistUUID, @"pl-1", "playlist uuid");
}

static void testDisplayTitle(void) {
    NSMutableDictionary *d = [trackDict(@"1", @"Breakfast", nil) mutableCopy];
    CHECK_STREQ([Parser tracksFromItems:@[d]][0].displayTitle, @"Breakfast", "no version -> title alone");
    d[@"version"] = @"Kasper Bjorke Remix";
    CHECK_STREQ([Parser tracksFromItems:@[d]][0].displayTitle, @"Breakfast (Kasper Bjorke Remix)",
                "version appended, so remixes on one album differ");
    d[@"title"] = @"Breakfast (Kasper Bjorke remix)";
    CHECK_STREQ([Parser tracksFromItems:@[d]][0].displayTitle, @"Breakfast (Kasper Bjorke remix)",
                "a title already carrying the version is not doubled");
    d[@"version"] = [NSNull null];
    d[@"title"] = @"Breakfast";
    CHECK_STREQ([Parser tracksFromItems:@[d]][0].displayTitle, @"Breakfast", "null version -> title alone");
}

static void testWrappedItemLists(void) {
    // Favorites wrap entries in "item"; bare entries still parse
    NSArray *items = @[
        @{@"item": trackDict(@"10", @"Wrapped", nil), @"created": @"2026-01-01"},
        trackDict(@"11", @"Bare", nil),
    ];
    NSArray<JLTidalTrack *> *tracks = [Parser tracksFromWrappedItems:items];
    CHECK_EQ(tracks.count, (NSUInteger)2, "wrapped and bare both parsed");
    CHECK_STREQ(tracks[0].trackID, @"10", "wrapped track unwrapped");
    CHECK_STREQ(tracks[1].trackID, @"11", "bare track parsed directly");

    NSArray<JLTidalAlbum *> *albums = [Parser albumsFromWrappedItems:@[
        @{@"item": @{@"id": @5, @"title": @"FavLP"}}]];
    CHECK_EQ(albums.count, (NSUInteger)1, "wrapped album parsed");
    CHECK_STREQ(albums[0].title, @"FavLP", "wrapped album title");
}

// Item shapes follow the live v2 response captured on 2026-11-14
// (docs/research/2026-11-14-v2-folders-redirect.md): itemType, trn, name,
// parent and data{id, name, ...}; no "type" key, no nested "items".
static NSDictionary *folderItem(NSString *dataID, NSString *dataName, NSString *trn, NSString *name) {
    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    if (dataID) data[@"id"] = dataID;
    if (dataName) data[@"name"] = dataName;
    data[@"itemType"] = @"FOLDER";
    NSMutableDictionary *item = [@{@"itemType": @"FOLDER", @"data": data,
                                   @"addedAt": @"2026-01-01T00:00:00Z"} mutableCopy];
    if (trn) item[@"trn"] = trn;
    if (name) item[@"name"] = name;
    return item;
}

static void testFolderItems(void) {
    NSArray *items = @[
        folderItem(@"f-1", @"Rock", @"trn:folder:f-1", @"Rock"),
        @{@"itemType": @"PLAYLIST", @"trn": @"trn:playlist:pl-9", @"name": @"Mix",
          @"data": @{@"uuid": @"pl-9", @"title": @"Mix"}},
        folderItem(nil, nil, @"trn:folder:f-2", @"Jazz"),
        folderItem(nil, @"NoID", nil, nil),
        // The dead shape: a "type" key and nested "items" are not folders.
        @{@"type": @"FOLDER", @"id": @"f-old", @"name": @"Old",
          @"items": @[@{@"type": @"PLAYLIST", @"data": @{@"uuid": @"pl-old"}}]},
        @"not a dictionary",
    ];
    NSArray<JLTidalPlaylistFolder *> *folders = [Parser foldersFromItems:items];
    CHECK_EQ(folders.count, (NSUInteger)2, "FOLDER items with an id only, got %lu", (unsigned long)folders.count);
    CHECK_STREQ(folders[0].folderID, @"f-1", "id from data.id");
    CHECK_STREQ(folders[0].name, @"Rock", "name from data.name");
    CHECK_STREQ(folders[1].folderID, @"f-2", "id from the trn suffix");
    CHECK_STREQ(folders[1].name, @"Jazz", "name falls back to the item name");
    CHECK_EQ(folders[0].subfolders.count, (NSUInteger)0, "a listing item has no subfolders");
    CHECK_EQ(folders[0].playlistUUIDs.count, (NSUInteger)0, "a listing item has no playlists");

    JLTidalPlaylistFolder *numeric = [[JLTidalPlaylistFolder alloc] initWithDictionary:@{
        @"itemType": @"FOLDER", @"data": @{@"id": @42}}];
    CHECK_STREQ(numeric.folderID, @"42", "numeric data.id becomes a string");
    CHECK_STREQ(numeric.name, @"Untitled Folder", "missing name falls back");

    NSArray *playlists = @[
        @{@"itemType": @"PLAYLIST", @"trn": @"trn:playlist:ignored", @"data": @{@"uuid": @"pl-1"}},
        @{@"itemType": @"PLAYLIST", @"trn": @"trn:playlist:pl-2", @"data": @{@"title": @"no uuid"}},
        @{@"itemType": @"PLAYLIST", @"trn": @"trn:playlist:pl-3"},
        @{@"itemType": @"PLAYLIST", @"trn": @"trn:folder:not-a-playlist"},
        @{@"itemType": @"PLAYLIST", @"trn": @"trn:playlist:"},
        @{@"itemType": @"PLAYLIST", @"data": @{@"uuid": @""}},
        folderItem(@"f-1", @"Rock", nil, nil),
        @{@"itemType": @"MIX", @"data": @{@"uuid": @"mix-1"}},
    ];
    NSArray<NSString *> *uuids = [Parser playlistUUIDsFromFolderItems:playlists];
    CHECK_EQ(uuids.count, (NSUInteger)3, "three playlist UUIDs, got %lu", (unsigned long)uuids.count);
    CHECK_STREQ(uuids[0], @"pl-1", "data.uuid wins over trn");
    CHECK_STREQ(uuids[1], @"pl-2", "trn suffix when data has no uuid");
    CHECK_STREQ(uuids[2], @"pl-3", "trn suffix when there is no data");
}

static void testFolderListing(void) {
    JLTidalFolderListing *listing = [Parser folderListingFromResponse:@{
        @"cursor": @"next-1",
        @"lastModifiedAt": @"2026-11-14T00:00:00Z",
        @"totalNumberOfItems": @3,
        @"items": @[
            folderItem(@"f-1", @"Rock", nil, nil),
            @{@"itemType": @"PLAYLIST", @"data": @{@"uuid": @"pl-1"}},
            @{@"itemType": @"MIX", @"data": @{}},
        ]}];
    CHECK(listing != nil, "listing parsed");
    CHECK_EQ(listing.folders.count, (NSUInteger)1, "one folder");
    CHECK_EQ(listing.playlistUUIDs.count, (NSUInteger)1, "one playlist");
    CHECK_STREQ(listing.cursor, @"next-1", "cursor carried");
    CHECK_EQ(listing.malformedItemCount, (NSInteger)0, "unknown item types are not malformed");

    listing = [Parser folderListingFromResponse:@{@"cursor": @"", @"items": @[]}];
    CHECK(listing != nil && listing.cursor == nil, "empty cursor ends the listing");
    listing = [Parser folderListingFromResponse:@{@"cursor": [NSNull null], @"items": @[]}];
    CHECK(listing != nil && listing.cursor == nil, "null cursor ends the listing");
    listing = [Parser folderListingFromResponse:@{@"items": @[]}];
    CHECK(listing != nil && listing.cursor == nil, "absent cursor ends the listing");
    listing = [Parser folderListingFromResponse:@{@"cursor": @7, @"items": @[]}];
    CHECK_STREQ(listing.cursor, @"7", "numeric cursor kept as a string");

    listing = [Parser folderListingFromResponse:@{@"items": @[
        folderItem(nil, @"NoID", nil, nil),
        @{@"itemType": @"PLAYLIST", @"data": @{@"title": @"no uuid"}},
        @{@"itemType": @"PLAYLIST", @"data": @{@"uuid": @"pl-ok"}},
    ]}];
    CHECK_EQ(listing.malformedItemCount, (NSInteger)2, "folder without id and playlist without uuid are malformed");
    CHECK_EQ(listing.playlistUUIDs.count, (NSUInteger)1, "the good playlist is still parsed");

    CHECK([Parser folderListingFromResponse:@{@"error": @"bad"}] == nil, "no items array -> nil");
    CHECK([Parser folderListingFromResponse:@{@"items": @"x"}] == nil, "non-array items -> nil");
    CHECK([Parser folderListingFromResponse:@[]] == nil, "non-dictionary -> nil");
    CHECK([Parser folderListingFromResponse:nil] == nil, "nil -> nil");
}

static void testISRCMatching(void) {
    NSArray *items = @[
        trackDict(@"1", @"Exact", @"USRC17607839"),
        trackDict(@"2", @"Other", @"GBUM71029601"),
        trackDict(@"3", @"NoISRC", nil),
        trackDict(@"4", @"Exact2", @"USRC17607839"),
    ];
    NSArray<JLTidalTrack *> *matches = [Parser tracksFromItems:items matchingISRC:@"USRC17607839"];
    CHECK_EQ(matches.count, (NSUInteger)2, "only exact ISRC matches kept, got %lu", (unsigned long)matches.count);
    CHECK_STREQ(matches[0].trackID, @"1", "first match");
    CHECK_STREQ(matches[1].trackID, @"4", "second match");

    CHECK_EQ([Parser tracksFromItems:items matchingISRC:@"NOPE"].count, (NSUInteger)0,
             "no fuzzy matches leak through");
}

int main(void) {
    @autoreleasepool {
        testTokenResponse();
        testRefreshResponse();
        testPlainItemLists();
        testDisplayTitle();
        testWrappedItemLists();
        testFolderItems();
        testFolderListing();
        testISRCMatching();
    }
    return testHarnessFinish("ResponseParser");
}
