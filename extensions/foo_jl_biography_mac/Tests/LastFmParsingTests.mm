//
//  LastFmParsingTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for LastFmParsing (artist.getinfo parsing + biography sanitization).
//  Foundation-only, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/LastFmParsing.h"
#import "../src/Core/BiographyData.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what) do { \
    g_checks++; \
    if (!(cond)) { \
        g_failures++; \
        printf("FAIL [%s] %s\n", g_context.c_str(), what); \
    } \
} while (0)

#define CHECK_EQ_STR(actual, expected, what) do { \
    g_checks++; \
    NSString *_a = (actual); NSString *_e = (expected); \
    if (!((_a == nil && _e == nil) || [_a isEqualToString:_e])) { \
        g_failures++; \
        printf("FAIL [%s] %s: got '%s', want '%s'\n", g_context.c_str(), what, \
               _a.UTF8String ?: "(nil)", _e.UTF8String ?: "(nil)"); \
    } \
} while (0)

static void testCleanBiographyText() {
    g_context = "cleanBiographyText";

    CHECK([LastFmParsing cleanBiographyText:nil] == nil, "nil passes through");
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:@""], @"", "empty stays empty");

    // Tag stripping
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:@"Hello <b>world</b>"],
                 @"Hello world", "strips simple tags");

    // Entity decode happens BEFORE tag strip (SEC-4): encoded script must not survive
    NSString *cleaned = [LastFmParsing cleanBiographyText:@"safe &lt;script&gt;alert(1)&lt;/script&gt; text"];
    CHECK([cleaned rangeOfString:@"<script>"].location == NSNotFound, "no script tag survives");
    CHECK([cleaned rangeOfString:@"script"].location == NSNotFound, "encoded script content stripped");

    // Entities
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:@"Simon &amp; Garfunkel"],
                 @"Simon & Garfunkel", "decodes &amp;");
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:@"&quot;quoted&quot; &#39;single&#39;&nbsp;end"],
                 @"\"quoted\" 'single' end", "decodes quot/apos/nbsp");

    // "Read more" suffix removal (case-insensitive, backwards search)
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:
                  @"Great band. <a href=\"x\">Read more on Last.fm</a>"],
                 @"Great band.", "removes read-more suffix");
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:@"Bio text read MORE on last.FM"],
                 @"Bio text", "read-more removal is case-insensitive");

    // Whitespace trim
    CHECK_EQ_STR([LastFmParsing cleanBiographyText:@"  \n padded \n  "],
                 @"padded", "trims whitespace");

    // SEC-8: 50k cap
    NSString *huge = [@"" stringByPaddingToLength:60000 withString:@"a" startingAtIndex:0];
    NSString *capped = [LastFmParsing cleanBiographyText:huge];
    CHECK(capped.length <= 50000, "caps oversized input at 50k");
}

static void testParseArtistInfoResponse() {
    g_context = "parseArtistInfoResponse";

    // Full happy path
    NSDictionary *response = @{
        @"name": @"Radiohead",
        @"mbid": @"a74b1b7f-71a5-4011-9441-d0b5e4122711",
        @"bio": @{
            @"content": @"Radiohead are an <b>English</b> rock band. Read more on Last.fm",
            @"summary": @"English rock band."
        },
        @"tags": @{@"tag": @[@{@"name": @"alternative"}, @{@"name": @"rock"}]},
        @"image": @[
            @{@"#text": @"http://img/small.png", @"size": @"small"},
            @{@"#text": @"http://img/mega.png", @"size": @"mega"}
        ],
        @"stats": @{@"listeners": @"5000000", @"playcount": @"300000000"},
        @"similar": @{@"artist": @[@{@"name": @"Thom Yorke"}]}
    };

    NSDictionary *parsed = [LastFmParsing parseArtistInfoResponse:response];
    CHECK_EQ_STR(parsed[@"name"], @"Radiohead", "name");
    CHECK_EQ_STR(parsed[@"mbid"], @"a74b1b7f-71a5-4011-9441-d0b5e4122711", "mbid");
    CHECK_EQ_STR(parsed[@"biography"], @"Radiohead are an English rock band.", "biography cleaned");
    CHECK_EQ_STR(parsed[@"biographySummary"], @"English rock band.", "summary");
    CHECK([parsed[@"tags"] isEqualToArray:(@[@"alternative", @"rock"])], "tags extracted");
    CHECK_EQ_STR([parsed[@"imageURL"] absoluteString], @"http://img/mega.png",
                 "largest image (reverse enumeration) wins");
    CHECK([parsed[@"listeners"] integerValue] == 5000000, "listeners");
    CHECK([parsed[@"playcount"] integerValue] == 300000000, "playcount");
    CHECK([parsed[@"similarArtists"] count] == 1, "similar artists passed through");

    // Missing/empty mbid omitted
    parsed = [LastFmParsing parseArtistInfoResponse:@{@"name": @"X", @"mbid": @""}];
    CHECK(parsed[@"mbid"] == nil, "empty mbid omitted");

    // SEC-6: malformed containers must not crash or leak wrong types
    parsed = [LastFmParsing parseArtistInfoResponse:@{
        @"name": @"X",
        @"tags": @"not-a-dict",
        @"similar": @[@"not-a-dict"],
        @"image": @"not-an-array"
    }];
    CHECK(parsed[@"tags"] == nil, "string tags container rejected");
    CHECK(parsed[@"similarArtists"] == nil, "array similar container rejected");
    CHECK(parsed[@"imageURL"] == nil, "string image container rejected");

    // Images: all-empty #text yields no imageURL
    parsed = [LastFmParsing parseArtistInfoResponse:@{
        @"name": @"X",
        @"image": @[@{@"#text": @""}, @{@"#text": @""}]
    }];
    CHECK(parsed[@"imageURL"] == nil, "all-empty image urls yield nil");
}

static void testBiographyDataMapping() {
    g_context = "biographyDataFromArtistInfoResponse";

    NSDictionary *response = @{
        @"name": @"Corrected Name",
        @"mbid": @"a74b1b7f-71a5-4011-9441-d0b5e4122711",
        @"bio": @{@"content": @"Bio.", @"summary": @"Sum."},
        @"stats": @{@"listeners": @"10", @"playcount": @"20"},
        @"image": @[@{@"#text": @"https://lastfm.freetls.fastly.net/i/u/300x300/abc123.png"}],
        @"similar": @{@"artist": @[
            @{@"name": @"Friend",
              @"mbid": @"b74b1b7f-71a5-4011-9441-d0b5e4122712",
              @"image": @[@{@"size": @"medium", @"#text": @"http://img/friend.png"}]}
        ]}
    };

    BiographyData *data = [LastFmParsing biographyDataFromArtistInfoResponse:response
                                                                  artistName:@"requested name"];
    CHECK_EQ_STR(data.artistName, @"Corrected Name", "corrected name used");
    CHECK_EQ_STR(data.biography, @"Bio.", "biography set");
    CHECK(data.biographySource == BiographySourceLastFm, "source is Last.fm");
    CHECK(data.listeners == 10 && data.playcount == 20, "stats mapped");
    CHECK(data.artistImageURL != nil, "non-placeholder image kept");
    CHECK(data.similarArtists.count == 1, "similar artist mapped");
    CHECK_EQ_STR(data.similarArtists.firstObject.name, @"Friend", "similar name");
    CHECK_EQ_STR(data.similarArtists.firstObject.thumbnailURL.absoluteString,
                 @"http://img/friend.png", "similar medium thumb");

    // Placeholder image (star icon hash) is skipped
    NSDictionary *placeholderResponse = @{
        @"name": @"X",
        @"image": @[@{@"#text": @"https://lastfm.freetls.fastly.net/i/u/2a96cbd8b46e442fc41c2b86b821562f.png"}]
    };
    data = [LastFmParsing biographyDataFromArtistInfoResponse:placeholderResponse artistName:@"X"];
    CHECK(data.artistImageURL == nil, "placeholder image skipped");

    // Empty corrected name falls back to requested name
    data = [LastFmParsing biographyDataFromArtistInfoResponse:@{} artistName:@"Fallback"];
    CHECK_EQ_STR(data.artistName, @"Fallback", "requested name kept when response empty");
}

int main() {
    @autoreleasepool {
        testCleanBiographyText();
        testParseArtistInfoResponse();
        testBiographyDataMapping();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
