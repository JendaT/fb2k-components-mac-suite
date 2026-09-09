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
        @"album": @{@"title": @"Album", @"cover": @"ab-cd"},
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

static void testFolderFiltering(void) {
    NSArray *items = @[
        @{@"type": @"FOLDER", @"trn": @"trn:folder:f-1", @"name": @"Rock"},
        @{@"type": @"PLAYLIST", @"data": @{@"uuid": @"pl-9"}},
        @{@"type": @"FOLDER", @"id": @"f-2", @"name": @"Jazz",
          @"items": @[
              @{@"type": @"FOLDER", @"id": @"f-2a", @"name": @"Bebop"},
              @{@"type": @"PLAYLIST", @"data": @{@"uuid": @"pl-2"}},
          ]},
    ];
    NSArray<JLTidalPlaylistFolder *> *folders = [Parser foldersFromItems:items];
    CHECK_EQ(folders.count, (NSUInteger)2, "playlists filtered out, got %lu", (unsigned long)folders.count);
    CHECK_STREQ(folders[0].folderID, @"f-1", "TRN uuid extracted");
    CHECK_STREQ(folders[1].name, @"Jazz", "folder name");
    CHECK_EQ(folders[1].subfolders.count, (NSUInteger)1, "nested subfolder parsed");
    CHECK_STREQ(folders[1].subfolders[0].name, @"Bebop", "subfolder name");
    CHECK_EQ(folders[1].playlistUUIDs.count, (NSUInteger)1, "nested playlist uuid collected");
    CHECK_STREQ(folders[1].playlistUUIDs[0], @"pl-2", "nested playlist uuid");
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
        testWrappedItemLists();
        testFolderFiltering();
        testISRCMatching();
    }
    return testHarnessFinish("ResponseParser");
}
