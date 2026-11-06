//
//  TrackMetadataTests.mm
//  foo_jl_album_art_mac
//
//  Unit tests for TrackMetadata (Foundation-only metadata snapshot).
//  Focus: foobar2000 path -> file URL conversion (unencoded "file://"
//  prefixes with spaces broke NSURL string parsing in the original
//  implementation) and searchability rules.
//

#import "TestHarness.h"
#import "../src/Core/TrackMetadata.h"

static TrackMetadata *MakeMetadata(NSString *artist, NSString *albumArtist,
                                   NSString *album, NSString *path) {
    return [[TrackMetadata alloc] initWithArtist:artist
                                     albumArtist:albumArtist
                                           album:album
                                           title:@"Title"
                            musicBrainzReleaseID:nil
                       musicBrainzReleaseGroupID:nil
                                discogsReleaseID:nil
                                       trackPath:path];
}

static void testFileURLParsing(void) {
    TEST_CONTEXT("fileURLFromFB2KPath");

    // fb2k-style prefix with UNENCODED spaces - the critical case
    NSURL *url = [TrackMetadata fileURLFromFB2KPath:@"file:///Users/me/Music/My Album/01 - A Song.mp3"];
    CHECK_NOT_NIL(url, "file:// path with spaces parses");
    CHECK_STR_EQ(url.path, @"/Users/me/Music/My Album/01 - A Song.mp3", "path preserved");
    CHECK_TRUE(url.isFileURL, "is file URL");

    // Percent signs and other URL-hostile characters stay literal
    url = [TrackMetadata fileURLFromFB2KPath:@"file:///Music/100% Hits/track.flac"];
    CHECK_STR_EQ(url.path, @"/Music/100% Hits/track.flac", "percent stays literal");

    // Plain absolute path without prefix
    url = [TrackMetadata fileURLFromFB2KPath:@"/Users/me/track.mp3"];
    CHECK_STR_EQ(url.path, @"/Users/me/track.mp3", "plain path parses");

    // Streams and other schemes yield nil
    CHECK_NIL([TrackMetadata fileURLFromFB2KPath:@"http://example.com/stream"], "http is nil");
    CHECK_NIL([TrackMetadata fileURLFromFB2KPath:@"mms://example.com/radio"], "mms is nil");

    // Degenerate inputs
    CHECK_NIL([TrackMetadata fileURLFromFB2KPath:nil], "nil is nil");
    CHECK_NIL([TrackMetadata fileURLFromFB2KPath:@""], "empty is nil");
    CHECK_NIL([TrackMetadata fileURLFromFB2KPath:@"file://"], "bare prefix is nil");
    CHECK_NIL([TrackMetadata fileURLFromFB2KPath:@"relative/path.mp3"], "relative path is nil");
}

static void testFolderURL(void) {
    TEST_CONTEXT("folderURL");

    TrackMetadata *meta = MakeMetadata(@"Artist", @"", @"Album",
                                       @"file:///Users/me/Music/My Album/track.mp3");
    CHECK_STR_EQ(meta.fileURL.path, @"/Users/me/Music/My Album/track.mp3", "fileURL");
    CHECK_STR_EQ(meta.folderURL.path, @"/Users/me/Music/My Album", "folderURL is parent");

    TrackMetadata *stream = MakeMetadata(@"Artist", @"", @"Album", @"http://stream.example.com/live");
    CHECK_NIL(stream.fileURL, "stream has no fileURL");
    CHECK_NIL(stream.folderURL, "stream has no folderURL");
}

static void testSearchability(void) {
    TEST_CONTEXT("searchability");

    CHECK_TRUE(MakeMetadata(@"Artist", @"", @"Album", nil).isSearchable, "artist+album searchable");
    CHECK_FALSE(MakeMetadata(@"", @"", @"Album", nil).isSearchable, "no artist not searchable");
    CHECK_FALSE(MakeMetadata(@"Artist", @"", @"", nil).isSearchable, "no album not searchable");
}

static void testAlbumArtistFallback(void) {
    TEST_CONTEXT("albumArtist");

    CHECK_STR_EQ(MakeMetadata(@"Artist", @"", @"Album", nil).albumArtist, @"Artist",
                 "empty albumArtist falls back to artist");
    CHECK_STR_EQ(MakeMetadata(@"Artist", @"Various", @"Album", nil).albumArtist, @"Various",
                 "explicit albumArtist wins");
}

static void testMusicBrainzIDs(void) {
    TEST_CONTEXT("musicBrainzIDs");

    TrackMetadata *withID = [[TrackMetadata alloc] initWithArtist:@"A"
                                                      albumArtist:@""
                                                            album:@"B"
                                                            title:@""
                                             musicBrainzReleaseID:@"mbid-123"
                                        musicBrainzReleaseGroupID:nil
                                                 discogsReleaseID:nil
                                                        trackPath:nil];
    CHECK_TRUE(withID.hasMusicBrainzIDs, "release ID counts");
    CHECK_FALSE(MakeMetadata(@"A", @"", @"B", nil).hasMusicBrainzIDs, "no IDs");
}

int main(void) {
    @autoreleasepool {
        testFileURLParsing();
        testFolderURL();
        testSearchability();
        testAlbumArtistFallback();
        testMusicBrainzIDs();
    }
    return test_summary("TrackMetadataTests");
}
