//
//  ArtistNameMatcherTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for ArtistNameMatcher (disambiguation rules shared by API clients).
//  Foundation-only, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/ArtistNameMatcher.h"

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

static void testNameMatching() {
    g_context = "name:matchesRequested:";

    // Exact and case-insensitive
    CHECK([ArtistNameMatcher name:@"Muse" matchesRequested:@"Muse"], "exact match");
    CHECK([ArtistNameMatcher name:@"MUSE" matchesRequested:@"muse"], "case-insensitive");

    // Containment only for >= 4 chars (QUAL-16)
    CHECK([ArtistNameMatcher name:@"The Beatles (Remastered)" matchesRequested:@"The Beatles"],
          "returned contains requested");
    CHECK([ArtistNameMatcher name:@"Beatles" matchesRequested:@"The Beatles remaster edition"],
          "containment is bidirectional for >= 4 chars");
    CHECK([ArtistNameMatcher name:@"ABBA Gold" matchesRequested:@"ABBA"], "4-char containment allowed");
    CHECK([ArtistNameMatcher name:@"AC/DC Live" matchesRequested:@"AC"] == NO,
          "short names must not contain-match");

    // Prefix stripping
    CHECK([ArtistNameMatcher name:@"The Who" matchesRequested:@"Who"], "'the' prefix stripped");
    CHECK([ArtistNameMatcher name:@"A Perfect Circle" matchesRequested:@"Perfect Circle"],
          "'a' prefix stripped");
    CHECK([ArtistNameMatcher name:@"An Cafe" matchesRequested:@"Cafe"], "'an' prefix stripped");

    // Negative
    CHECK([ArtistNameMatcher name:@"Metallica" matchesRequested:@"Megadeth"] == NO, "different artists");
    CHECK([ArtistNameMatcher name:nil matchesRequested:@"Muse"] == NO, "nil returned");
    CHECK([ArtistNameMatcher name:@"Muse" matchesRequested:nil] == NO, "nil requested");
}

static void testBestMatch() {
    g_context = "bestMatchInResults:";

    NSDictionary *muse = @{@"name": @"Muse"};
    NSDictionary *museum = @{@"name": @"Museum Mouth"};
    NSDictionary *other = @{@"name": @"Something Else"};

    // Exact match wins even when not first
    NSDictionary *match = [ArtistNameMatcher bestMatchInResults:@[museum, muse, other]
                                                        forName:@"muse"
                                                        nameKey:@"name"];
    CHECK(match == muse, "exact case-insensitive match wins over earlier close match");

    // SEC-9: close match accepted only for first result, term >= 4
    match = [ArtistNameMatcher bestMatchInResults:@[museum, other]
                                          forName:@"museum"
                                          nameKey:@"name"];
    CHECK(match == museum, "first-result containment accepted for >= 4 chars");

    match = [ArtistNameMatcher bestMatchInResults:@[@{@"name": @"ABBA Gold Hits"}]
                                          forName:@"abc"
                                          nameKey:@"name"];
    CHECK(match == nil, "no acceptable match returns nil");

    match = [ArtistNameMatcher bestMatchInResults:@[@{@"name": @"Xyz"}]
                                          forName:@"abc"
                                          nameKey:@"name"];
    CHECK(match == nil, "unrelated first result rejected");

    // Short search terms never containment-match
    match = [ArtistNameMatcher bestMatchInResults:@[@{@"name": @"ACDC Tribute"}]
                                          forName:@"AC"
                                          nameKey:@"name"];
    CHECK(match == nil, "short term cannot close-match");

    // Robustness: empty and malformed input
    CHECK([ArtistNameMatcher bestMatchInResults:@[] forName:@"muse" nameKey:@"name"] == nil,
          "empty results");
    match = [ArtistNameMatcher bestMatchInResults:@[@"not-a-dict", muse]
                                          forName:@"Muse"
                                          nameKey:@"name"];
    CHECK(match == muse, "non-dict entries skipped");
    match = [ArtistNameMatcher bestMatchInResults:@[@{@"name": [NSNull null]}]
                                          forName:@"muse"
                                          nameKey:@"name"];
    CHECK(match == nil, "NSNull name rejected");
}

int main() {
    @autoreleasepool {
        testNameMatching();
        testBestMatch();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
