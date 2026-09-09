//
//  WikipediaParsingTests.mm
//  foo_jl_biography_mac
//
//  Unit tests for WikipediaParsing (Wikidata sitelinks + REST summary).
//  Gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/WikipediaParsing.h"

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

static void testEnwikiTitle() {
    g_context = "enwikiTitleFromWikidataResponse";

    NSDictionary *response = @{@"entities": @{
        @"Q11647": @{@"sitelinks": @{
            @"enwiki": @{@"site": @"enwiki", @"title": @"Radiohead"}
        }}
    }};
    NSString *title = [WikipediaParsing enwikiTitleFromWikidataResponse:response];
    CHECK([title isEqualToString:@"Radiohead"], "title extracted without knowing the QID key");

    // No enwiki sitelink
    response = @{@"entities": @{
        @"Q11647": @{@"sitelinks": @{
            @"dewiki": @{@"site": @"dewiki", @"title": @"Radiohead"}
        }}
    }};
    CHECK([WikipediaParsing enwikiTitleFromWikidataResponse:response] == nil,
          "no enwiki sitelink yields nil");

    // Robustness
    CHECK([WikipediaParsing enwikiTitleFromWikidataResponse:@{}] == nil, "no entities");
    CHECK([WikipediaParsing enwikiTitleFromWikidataResponse:@{@"entities": @"zzz"}] == nil,
          "non-dict entities");
    response = @{@"entities": @{@"Q1": @{@"sitelinks": @{@"enwiki": @{@"title": @""}}}}};
    CHECK([WikipediaParsing enwikiTitleFromWikidataResponse:response] == nil, "empty title rejected");
}

static void testSummaryExtract() {
    g_context = "summaryExtractFromResponse";

    NSDictionary *response = @{
        @"type": @"standard",
        @"title": @"Radiohead",
        @"extract": @"Radiohead are an English rock band formed in Abingdon in 1985."
    };
    NSString *extract = [WikipediaParsing summaryExtractFromResponse:response];
    CHECK([extract hasPrefix:@"Radiohead are an English rock band"], "extract returned");

    // Disambiguation pages rejected
    response = @{@"type": @"disambiguation", @"extract": @"Genesis may refer to:"};
    CHECK([WikipediaParsing summaryExtractFromResponse:response] == nil, "disambiguation rejected");

    // Empty/whitespace extract rejected
    CHECK([WikipediaParsing summaryExtractFromResponse:@{@"extract": @"  \n "}] == nil,
          "whitespace-only extract rejected");
    CHECK([WikipediaParsing summaryExtractFromResponse:@{}] == nil, "missing extract");
    CHECK([WikipediaParsing summaryExtractFromResponse:@{@"extract": @123}] == nil,
          "non-string extract rejected");

    // Trimming
    response = @{@"extract": @"  Padded bio.  \n"};
    CHECK([[WikipediaParsing summaryExtractFromResponse:response] isEqualToString:@"Padded bio."],
          "extract trimmed");
}

int main() {
    @autoreleasepool {
        testEnwikiTitle();
        testSummaryExtract();

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
