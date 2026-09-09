//
//  MusicBrainzParsingTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for MusicBrainzParsing (artist search + url-rels parsing).
//  Gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/MusicBrainzParsing.h"

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

static NSString * const kValidMBID = @"a74b1b7f-71a5-4011-9441-d0b5e4122711";
static NSString * const kOtherMBID = @"b83c2c8f-82b6-5122-a552-e1c6f5233822";

static void testBestMBID() {
    g_context = "bestMBIDFromSearchResponse";

    // Happy path: high score, matching name
    NSDictionary *response = @{@"artists": @[
        @{@"id": kValidMBID, @"name": @"Radiohead", @"score": @100}
    ]};
    NSString *mbid = [MusicBrainzParsing bestMBIDFromSearchResponse:response requestedName:@"Radiohead"];
    CHECK([mbid isEqualToString:kValidMBID], "exact match accepted");

    // Score as string (older serializations)
    response = @{@"artists": @[
        @{@"id": kValidMBID, @"name": @"Radiohead", @"score": @"95"}
    ]};
    mbid = [MusicBrainzParsing bestMBIDFromSearchResponse:response requestedName:@"radiohead"];
    CHECK([mbid isEqualToString:kValidMBID], "string score parsed, case-insensitive name");

    // Low score rejected even with matching name
    response = @{@"artists": @[
        @{@"id": kValidMBID, @"name": @"Radiohead", @"score": @60}
    ]};
    CHECK([MusicBrainzParsing bestMBIDFromSearchResponse:response requestedName:@"Radiohead"] == nil,
          "score below 90 rejected");

    // High score but wrong name rejected
    response = @{@"artists": @[
        @{@"id": kValidMBID, @"name": @"Completely Different", @"score": @100}
    ]};
    CHECK([MusicBrainzParsing bestMBIDFromSearchResponse:response requestedName:@"Radiohead"] == nil,
          "name mismatch rejected despite score");

    // First qualifying result wins; earlier disqualified ones skipped
    response = @{@"artists": @[
        @{@"id": kOtherMBID, @"name": @"Radiohead Tribute Band", @"score": @85},
        @{@"id": kValidMBID, @"name": @"Radiohead", @"score": @100},
    ]};
    mbid = [MusicBrainzParsing bestMBIDFromSearchResponse:response requestedName:@"Radiohead"];
    CHECK([mbid isEqualToString:kValidMBID], "skips low-score entry to qualifying one");

    // Malformed MBID rejected
    response = @{@"artists": @[
        @{@"id": @"not-a-uuid", @"name": @"Radiohead", @"score": @100}
    ]};
    CHECK([MusicBrainzParsing bestMBIDFromSearchResponse:response requestedName:@"Radiohead"] == nil,
          "malformed id rejected");

    // Robustness
    CHECK([MusicBrainzParsing bestMBIDFromSearchResponse:@{} requestedName:@"X"] == nil, "no artists key");
    CHECK([MusicBrainzParsing bestMBIDFromSearchResponse:@{@"artists": @"zzz"} requestedName:@"X"] == nil,
          "non-array artists");
    CHECK([MusicBrainzParsing bestMBIDFromSearchResponse:@{@"artists": @[@"zzz"]} requestedName:@"X"] == nil,
          "non-dict artist entries");
}

static void testWikidataQID() {
    g_context = "wikidataQIDFromArtistResponse";

    NSDictionary *response = @{@"relations": @[
        @{@"type": @"official homepage", @"url": @{@"resource": @"https://radiohead.com"}},
        @{@"type": @"wikidata", @"url": @{@"resource": @"https://www.wikidata.org/wiki/Q11647"}},
    ]};
    NSString *qid = [MusicBrainzParsing wikidataQIDFromArtistResponse:response];
    CHECK([qid isEqualToString:@"Q11647"], "QID extracted from wikidata relation");

    // No wikidata relation
    response = @{@"relations": @[
        @{@"type": @"discogs", @"url": @{@"resource": @"https://www.discogs.com/artist/3840"}}
    ]};
    CHECK([MusicBrainzParsing wikidataQIDFromArtistResponse:response] == nil, "no wikidata relation");

    // Malformed QID in the URL rejected
    response = @{@"relations": @[
        @{@"type": @"wikidata", @"url": @{@"resource": @"https://www.wikidata.org/wiki/NotAQid"}}
    ]};
    CHECK([MusicBrainzParsing wikidataQIDFromArtistResponse:response] == nil, "non-Q path rejected");

    // Robustness
    CHECK([MusicBrainzParsing wikidataQIDFromArtistResponse:@{}] == nil, "no relations");
    CHECK([MusicBrainzParsing wikidataQIDFromArtistResponse:@{@"relations": @"zzz"}] == nil,
          "non-array relations");
    response = @{@"relations": @[@{@"type": @"wikidata", @"url": @"not-a-dict"}]};
    CHECK([MusicBrainzParsing wikidataQIDFromArtistResponse:response] == nil, "non-dict url");
}

int main() {
    @autoreleasepool {
        testBestMBID();
        testWikidataQID();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
