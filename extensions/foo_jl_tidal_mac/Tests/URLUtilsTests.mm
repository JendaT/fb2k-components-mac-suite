//
//  URLUtilsTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for tidal:// and tidal.com URL parsing and generation.
//

#import <Foundation/Foundation.h>
#import "../src/Core/URLUtils.h"
#include "TestHarness.h"

using namespace tidal;

static void testParseTidalScheme(void) {
    auto r = parseURL("tidal://track/123456");
    CHECK(r.has_value(), "tidal://track parses");
    CHECK(r->type == TidalContentType::Track, "type is Track");
    CHECK(r->id == "123456", "id extracted, got %s", r->id.c_str());

    r = parseURL("tidal://album/987");
    CHECK(r.has_value() && r->type == TidalContentType::Album && r->id == "987", "tidal://album parses");

    r = parseURL("tidal://playlist/abc-def-123");
    CHECK(r.has_value() && r->type == TidalContentType::Playlist && r->id == "abc-def-123",
          "tidal://playlist with UUID parses");

    r = parseURL("tidal://artist/42");
    CHECK(r.has_value() && r->type == TidalContentType::Artist && r->id == "42", "tidal://artist parses");

    CHECK(!parseURL("tidal://track/").has_value(), "missing id rejected");
    CHECK(!parseURL("tidal://bogus/1").has_value(), "unknown content type rejected");
    CHECK(!parseURL("").has_value(), "empty string rejected");
    CHECK(!parseURL("not a url").has_value(), "garbage rejected");
}

static void testParseWebURLs(void) {
    auto r = parseURL("https://tidal.com/browse/track/123456");
    CHECK(r.has_value() && r->type == TidalContentType::Track && r->id == "123456",
          "tidal.com/browse/track parses");

    r = parseURL("https://listen.tidal.com/track/777");
    CHECK(r.has_value() && r->type == TidalContentType::Track && r->id == "777",
          "listen.tidal.com/track parses");

    r = parseURL("https://tidal.com/album/55");
    CHECK(r.has_value() && r->type == TidalContentType::Album && r->id == "55",
          "tidal.com/album parses");

    CHECK(!parseURL("https://example.com/track/1").has_value(), "non-tidal host rejected");
    CHECK(!parseURL("https://tidal.com/browse").has_value(), "no content segment rejected");
}

static void testRoundTrip(void) {
    CHECK(makeTrackURL("123") == "tidal://track/123", "makeTrackURL");

    auto r = parseURL(makeTrackURL("456"));
    CHECK(r.has_value() && r->id == "456", "makeTrackURL round-trips through parseURL");

    TidalURL u;
    u.type = TidalContentType::Album;
    u.id = "99";
    CHECK(toExternalURL(u) == "https://tidal.com/browse/album/99", "toExternalURL album");

    TidalURL unknown;
    unknown.type = TidalContentType::Unknown;
    unknown.originalURL = "whatever";
    CHECK(toExternalURL(unknown) == "whatever", "unknown type returns original");
}

static void testIsTidalURL(void) {
    CHECK(isTidalURL("tidal://track/1"), "tidal:// scheme");
    CHECK(isTidalURL("https://tidal.com/track/1"), "tidal.com host");
    CHECK(isTidalURL("https://www.tidal.com/x"), "www.tidal.com host");
    CHECK(isTidalURL("https://listen.tidal.com/x"), "listen.tidal.com host");
    CHECK(!isTidalURL("https://lgf.audio.tidal.com/seg.mp4"), "CDN host is NOT a tidal URL");
    CHECK(!isTidalURL("https://example.com/"), "other host rejected");
    CHECK(!isTidalURL("/Users/x/music.flac"), "local path rejected");
    CHECK(!isTidalURL(""), "empty rejected");
    CHECK(!isTidalURL(nullptr), "null rejected");
}

int main(void) {
    @autoreleasepool {
        testParseTidalScheme();
        testParseWebURLs();
        testRoundTrip();
        testIsTidalURL();
    }
    return testHarnessFinish("URLUtils");
}
