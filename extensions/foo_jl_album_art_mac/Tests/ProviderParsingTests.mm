//
//  ProviderParsingTests.mm
//  foo_jl_album_art_mac
//
//  Unit tests for the API response parsers of all artwork providers.
//  Private parse methods are reached through category declarations -
//  Objective-C dispatch resolves them at runtime.
//

#import "TestHarness.h"
#import "../src/Core/iTunesProvider.h"
#import "../src/Core/DeezerProvider.h"
#import "../src/Core/CoverArtArchiveProvider.h"
#import "../src/Core/MusicBrainzProvider.h"
#import "../src/Core/TidalProvider.h"

#pragma mark - Private method declarations (implemented in the providers)

@interface iTunesProvider (Testing)
- (NSArray<ArtworkResult *> *)parseArtworkFromData:(NSData *)data;
- (NSString *)highResURLFromThumbnail:(NSString *)thumbnailURL;
@end

@interface DeezerProvider (Testing)
- (NSArray<ArtworkResult *> *)parseArtworkFromData:(NSData *)data;
- (NSString *)escapeDeezerQuotes:(NSString *)input;
@end

@interface CoverArtArchiveProvider (Testing)
- (NSArray<ArtworkResult *> *)parseArtworkFromData:(NSData *)data mbid:(NSString *)mbid;
@end

@interface MusicBrainzProvider (Testing)
- (nullable NSString *)parseMBIDFromData:(NSData *)data;
- (NSString *)escapeLucene:(NSString *)input;
@end

@interface TidalProvider (Testing)
- (BOOL)parseTokenFromData:(NSData *)data
                     token:(NSString **)outToken
                 expiresIn:(NSTimeInterval *)outExpiresIn;
- (NSArray<NSString *> *)parseAlbumIDsFromSearchData:(NSData *)data;
- (NSArray<ArtworkResult *> *)parseArtworkFromAlbumsData:(NSData *)data;
@end

static NSData *JSONData(NSString *json) {
    return [json dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - iTunes

static void testITunesParsing(void) {
    TEST_CONTEXT("iTunes");

    iTunesProvider *provider = [iTunesProvider sharedInstance];

    NSData *data = JSONData(@"{\"results\":["
        "{\"artworkUrl100\":\"https://is1.mzstatic.com/image/a/100x100bb.jpg\"},"
        "{\"artworkUrl100\":\"https://is1.mzstatic.com/image/a/100x100bb.jpg\"},"
        "{\"artworkUrl100\":\"https://is1.mzstatic.com/image/b/nonstandard.jpg\"},"
        "{\"noArtwork\":true}"
        "]}");

    NSArray<ArtworkResult *> *results = [provider parseArtworkFromData:data];
    CHECK_EQ(results.count, 2, "duplicates and missing artwork skipped");

    CHECK_STR_EQ(results[0].fullResolutionURL.absoluteString,
                 @"https://is1.mzstatic.com/image/a/1200x1200bb.jpg", "upscaled URL");
    CHECK_EQ((long)results[0].resolution.width, 1200, "known resolution");
    CHECK_STR_EQ(results[0].thumbnailURL.absoluteString,
                 @"https://is1.mzstatic.com/image/a/500x500bb.jpg", "500px thumbnail");

    // Non-matching URL pattern keeps original with unknown small resolution
    CHECK_STR_EQ(results[1].fullResolutionURL.absoluteString,
                 @"https://is1.mzstatic.com/image/b/nonstandard.jpg", "pattern miss keeps URL");
    CHECK_EQ((long)results[1].resolution.width, 100, "pattern miss resolution");

    CHECK_EQ([provider parseArtworkFromData:JSONData(@"not json")].count, 0, "invalid JSON");
    CHECK_EQ([provider parseArtworkFromData:JSONData(@"{}")].count, 0, "missing results key");
}

#pragma mark - Deezer

static void testDeezerParsing(void) {
    TEST_CONTEXT("Deezer");

    DeezerProvider *provider = [DeezerProvider sharedInstance];

    NSData *data = JSONData(@"{\"data\":["
        "{\"cover_xl\":\"https://cdn.deezer.com/a/1000x1000.jpg\","
         "\"cover_medium\":\"https://cdn.deezer.com/a/250x250.jpg\"},"
        "{\"cover_xl\":\"https://cdn.deezer.com/a/1000x1000.jpg\"},"
        "{\"cover_medium\":\"https://cdn.deezer.com/b/250x250.jpg\"},"
        "{\"cover_xl\":\"https://cdn.deezer.com/c/1000x1000.jpg\"}"
        "]}");

    NSArray<ArtworkResult *> *results = [provider parseArtworkFromData:data];
    CHECK_EQ(results.count, 2, "dupes and xl-less entries skipped");
    CHECK_STR_EQ(results[0].thumbnailURL.absoluteString,
                 @"https://cdn.deezer.com/a/250x250.jpg", "medium as thumbnail");
    CHECK_STR_EQ(results[1].thumbnailURL.absoluteString,
                 @"https://cdn.deezer.com/c/1000x1000.jpg", "xl fallback thumbnail");

    CHECK_STR_EQ([provider escapeDeezerQuotes:@"Album \"Deluxe\""], @"Album Deluxe",
                 "embedded quotes stripped");
}

#pragma mark - Cover Art Archive

static void testCAAParsing(void) {
    TEST_CONTEXT("CoverArtArchive");

    CoverArtArchiveProvider *provider = [CoverArtArchiveProvider sharedInstance];

    NSData *data = JSONData(@"{\"images\":["
        "{\"image\":\"https://caa.org/f.jpg\",\"types\":[\"Front\"],"
         "\"thumbnails\":{\"500\":\"https://caa.org/f-500.jpg\",\"250\":\"https://caa.org/f-250.jpg\"}},"
        "{\"image\":\"https://caa.org/b.jpg\",\"types\":[\"Back\"],"
         "\"thumbnails\":{\"250\":\"https://caa.org/b-250.jpg\"}},"
        "{\"image\":\"https://caa.org/m.jpg\",\"types\":[\"Medium\"],\"comment\":\"CD 1\"},"
        "{\"types\":[\"Front\"]}"
        "]}");

    NSArray<ArtworkResult *> *results = [provider parseArtworkFromData:data mbid:@"mbid"];
    CHECK_EQ(results.count, 3, "image-less entry skipped");

    CHECK_EQ(results[0].artworkType, RemoteArtworkTypeFront, "front type");
    CHECK_STR_EQ(results[0].thumbnailURL.absoluteString, @"https://caa.org/f-500.jpg", "prefers 500 thumb");

    CHECK_EQ(results[1].artworkType, RemoteArtworkTypeBack, "back type");
    CHECK_STR_EQ(results[1].thumbnailURL.absoluteString, @"https://caa.org/b-250.jpg", "250 fallback");

    CHECK_EQ(results[2].artworkType, RemoteArtworkTypeDisc, "Medium maps to disc");
    CHECK_EQ(results[2].variants.count, 1, "comment becomes variant");
    CHECK_STR_EQ(results[2].variants.firstObject, @"CD 1", "variant text");
    CHECK_STR_EQ(results[2].thumbnailURL.absoluteString, @"https://caa.org/m.jpg", "full image as thumb fallback");
}

#pragma mark - MusicBrainz

static void testMusicBrainzParsing(void) {
    TEST_CONTEXT("MusicBrainz");

    MusicBrainzProvider *provider = [MusicBrainzProvider sharedInstance];

    // Low-score releases are skipped; first high-score wins
    NSData *data = JSONData(@"{\"releases\":["
        "{\"id\":\"low-id\",\"score\":40},"
        "{\"id\":\"good-id\",\"score\":95},"
        "{\"id\":\"other-id\",\"score\":100}"
        "]}");
    CHECK_STR_EQ([provider parseMBIDFromData:data], @"good-id", "first release with score >= 80");

    CHECK_NIL([provider parseMBIDFromData:JSONData(@"{\"releases\":[{\"id\":\"x\",\"score\":10}]}")],
              "all low scores rejected");
    CHECK_NIL([provider parseMBIDFromData:JSONData(@"{\"releases\":[]}")], "empty releases");
    CHECK_NIL([provider parseMBIDFromData:JSONData(@"garbage")], "invalid JSON");

    CHECK_STR_EQ([provider escapeLucene:@"AC/DC: \"Back\" (1980)"],
                 @"AC\\/DC\\: \\\"Back\\\" \\(1980\\)", "lucene special chars escaped");
}

#pragma mark - TIDAL

static void testTidalTokenParsing(void) {
    TEST_CONTEXT("TIDAL token");

    TidalProvider *provider = [TidalProvider sharedInstance];

    NSString *token = nil;
    NSTimeInterval expiresIn = 0;
    BOOL ok = [provider parseTokenFromData:JSONData(@"{\"access_token\":\"tok123\",\"expires_in\":86400}")
                                     token:&token
                                 expiresIn:&expiresIn];
    CHECK_TRUE(ok, "valid token parses");
    CHECK_STR_EQ(token, @"tok123", "token value");
    CHECK_EQ((long)expiresIn, 86400, "expiry value");

    CHECK_FALSE([provider parseTokenFromData:JSONData(@"{\"error\":\"invalid_client\"}")
                                       token:&token expiresIn:&expiresIn], "error response rejected");
    CHECK_FALSE([provider parseTokenFromData:JSONData(@"[]") token:&token expiresIn:&expiresIn],
                "non-dictionary rejected");
}

static void testTidalSearchParsing(void) {
    TEST_CONTEXT("TIDAL search");

    TidalProvider *provider = [TidalProvider sharedInstance];

    // Relationship linkage order wins; included is a fallback; capped at 5, deduped
    NSData *data = JSONData(@"{"
        "\"data\":{\"id\":\"q\",\"type\":\"searchResults\",\"relationships\":{"
            "\"albums\":{\"data\":[{\"id\":\"11\",\"type\":\"albums\"},{\"id\":\"22\",\"type\":\"albums\"}]}}},"
        "\"included\":["
            "{\"id\":\"22\",\"type\":\"albums\"},"
            "{\"id\":\"33\",\"type\":\"albums\"},"
            "{\"id\":\"99\",\"type\":\"artists\"}"
        "]}");

    NSArray<NSString *> *ids = [provider parseAlbumIDsFromSearchData:data];
    CHECK_EQ(ids.count, 3, "deduped album IDs");
    CHECK_STR_EQ(ids[0], @"11", "relationship order first");
    CHECK_STR_EQ(ids[1], @"22", "no duplicate from included");
    CHECK_STR_EQ(ids[2], @"33", "included fallback appended");

    CHECK_EQ([provider parseAlbumIDsFromSearchData:JSONData(@"{}")].count, 0, "empty response");
}

static void testTidalAlbumsParsing(void) {
    TEST_CONTEXT("TIDAL albums");

    TidalProvider *provider = [TidalProvider sharedInstance];

    NSData *data = JSONData(@"{"
        "\"data\":["
            "{\"id\":\"11\",\"type\":\"albums\",\"relationships\":{"
                "\"coverArt\":{\"data\":[{\"id\":\"art-1\",\"type\":\"artworks\"}]}}},"
            "{\"id\":\"22\",\"type\":\"albums\",\"relationships\":{"
                "\"coverArt\":{\"data\":{\"id\":\"art-2\",\"type\":\"artworks\"}}}},"
            "{\"id\":\"33\",\"type\":\"albums\",\"relationships\":{}}"
        "],"
        "\"included\":["
            "{\"id\":\"art-1\",\"type\":\"artworks\",\"attributes\":{\"files\":["
                "{\"href\":\"https://resources.tidal.com/a/640x640.jpg\",\"meta\":{\"width\":640,\"height\":640}},"
                "{\"href\":\"https://resources.tidal.com/a/1280x1280.jpg\",\"meta\":{\"width\":1280,\"height\":1280}},"
                "{\"href\":\"https://resources.tidal.com/a/160x160.jpg\",\"meta\":{\"width\":160,\"height\":160}}"
            "]}},"
            "{\"id\":\"art-2\",\"type\":\"artworks\",\"attributes\":{\"files\":["
                "{\"href\":\"https://resources.tidal.com/b/320x320.jpg\",\"meta\":{\"width\":320,\"height\":320}}"
            "]}}"
        "]}");

    NSArray<ArtworkResult *> *results = [provider parseArtworkFromAlbumsData:data];
    CHECK_EQ(results.count, 2, "albums with cover art parsed");

    CHECK_STR_EQ(results[0].fullResolutionURL.absoluteString,
                 @"https://resources.tidal.com/a/1280x1280.jpg", "largest file is full-res");
    CHECK_STR_EQ(results[0].thumbnailURL.absoluteString,
                 @"https://resources.tidal.com/a/640x640.jpg", "closest to 500px is thumbnail");
    CHECK_EQ((long)results[0].resolution.width, 1280, "resolution from meta");
    CHECK_EQ(results[0].artworkType, RemoteArtworkTypeFront, "front cover type");

    // Single-object coverArt.data ref also works
    CHECK_STR_EQ(results[1].fullResolutionURL.absoluteString,
                 @"https://resources.tidal.com/b/320x320.jpg", "single ref parsed");

    CHECK_EQ([provider parseArtworkFromAlbumsData:JSONData(@"{\"data\":[]}")].count, 0, "no albums");
}

int main(void) {
    @autoreleasepool {
        testITunesParsing();
        testDeezerParsing();
        testCAAParsing();
        testMusicBrainzParsing();
        testTidalTokenParsing();
        testTidalSearchParsing();
        testTidalAlbumsParsing();
    }
    return test_summary("ProviderParsingTests");
}
