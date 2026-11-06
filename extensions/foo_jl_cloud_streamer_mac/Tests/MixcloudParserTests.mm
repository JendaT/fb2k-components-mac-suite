//
//  MixcloudParserTests.mm
//  foo_jl_cloud_streamer_mac
//
//  Unit tests for MixcloudParser (GraphQL search/tracklist response parsing
//  and query building). Compiled standalone (Foundation only); gating phase
//  of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/MixcloudParser.h"

#include <string>

using namespace cloud_streamer;

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                              \
        if (!(cond)) {                                                           \
            g_failures++;                                                        \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                   \
        }                                                                        \
    } while (0)

#define CHECK_EQ(actual, expected, what)                                         \
    do {                                                                         \
        g_checks++;                                                              \
        if (!((actual) == (expected))) {                                         \
            g_failures++;                                                        \
            printf("FAIL [%s] %s\n  expected: %s\n  actual:   %s\n",             \
                   g_context.c_str(), what,                                      \
                   std::string(expected).c_str(), std::string(actual).c_str());  \
        }                                                                        \
    } while (0)

static NSData* toData(const char* json) {
    return [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
}

static bool contains(const std::string& haystack, const std::string& needle) {
    return haystack.find(needle) != std::string::npos;
}

int main(void) {
    @autoreleasepool {

    // --- Search response: valid payload ---
    {
        g_context = "search-full";
        const char* json = R"({
            "data": {"viewer": {"search": {"searchQuery": {"cloudcasts": {"edges": [
                {"node": {
                    "name": "Deep Mix",
                    "slug": "deep-mix",
                    "audioLength": 3600,
                    "owner": {"username": "dj1", "displayName": "DJ One"},
                    "picture": {"url": "https://img.example/p.jpg"}
                }},
                {"node": {
                    "name": "No Owner", "slug": "no-owner"
                }}
            ]}}}}}
        })";
        auto tracks = MixcloudParser::parseSearchResponse(toData(json));
        CHECK(tracks.has_value(), "parses");
        CHECK(tracks->size() == 1, "node without username dropped");
        const auto& t = tracks->at(0);
        CHECK_EQ(t.name, "Deep Mix", "name");
        CHECK_EQ(t.slug, "deep-mix", "slug");
        CHECK_EQ(t.username, "dj1", "username");
        CHECK_EQ(t.displayName, "DJ One", "display name");
        CHECK_EQ(t.thumbnailURL, "https://img.example/p.jpg", "thumbnail");
        CHECK(t.duration == 3600.0, "duration from audioLength");
        CHECK_EQ(t.webURL(), "https://www.mixcloud.com/dj1/deep-mix/", "computed web URL");
        CHECK_EQ(t.internalURL(), "mixcloud://dj1/deep-mix", "computed internal URL");
    }

    // --- Search response: failure modes ---
    {
        g_context = "search-failures";
        CHECK(!MixcloudParser::parseSearchResponse(nil).has_value(), "nil data -> nullopt");
        CHECK(!MixcloudParser::parseSearchResponse(toData("not json")).has_value(),
              "garbage -> nullopt");
        CHECK(!MixcloudParser::parseSearchResponse(
                  toData(R"({"errors": [{"message": "boom"}]})")).has_value(),
              "GraphQL errors -> nullopt");
        CHECK(!MixcloudParser::parseSearchResponse(toData(R"({"data": {}})")).has_value(),
              "missing viewer -> nullopt");

        auto empty = MixcloudParser::parseSearchResponse(toData(
            R"({"data": {"viewer": {"search": {"searchQuery": {"cloudcasts": {"edges": []}}}}}})"));
        CHECK(empty.has_value() && empty->empty(), "empty edges -> empty vector, not error");
    }

    // --- Tracklist response: valid payload, non-track sections skipped ---
    {
        g_context = "tracklist-full";
        const char* json = R"({
            "data": {"cloudcastLookup": {
                "name": "Friday Mix",
                "owner": {"displayName": "DJ One"},
                "sections": [
                    {"startSeconds": 0, "songName": "Opener", "artistName": "Artist A"},
                    {},
                    {"startSeconds": 300, "songName": "Second"},
                    {"songName": ""}
                ]
            }}
        })";
        auto result = MixcloudParser::parseTracklistResponse(toData(json));
        CHECK(result.success, "success");
        CHECK_EQ(result.cloudcastName, "Friday Mix", "cloudcast name");
        CHECK_EQ(result.uploaderName, "DJ One", "uploader name");
        CHECK(result.sections.size() == 2, "sections without songName skipped");
        CHECK_EQ(result.sections[0].songName, "Opener", "song name");
        CHECK_EQ(result.sections[0].artistName, "Artist A", "artist name");
        CHECK(result.sections[1].startSeconds == 300.0, "start seconds");
        CHECK(result.sections[1].artistName.empty(), "missing artist -> empty");
    }

    // --- Tracklist response: failure modes ---
    {
        g_context = "tracklist-failures";
        auto r1 = MixcloudParser::parseTracklistResponse(nil);
        CHECK(!r1.success, "nil data fails");
        CHECK_EQ(r1.errorMessage, "Empty response", "nil data message");

        auto r2 = MixcloudParser::parseTracklistResponse(toData("not json"));
        CHECK(!r2.success, "garbage fails");
        CHECK_EQ(r2.errorMessage, "Failed to parse JSON response", "garbage message");

        auto r3 = MixcloudParser::parseTracklistResponse(toData(R"({"errors": []})"));
        CHECK(!r3.success, "GraphQL errors fail");
        CHECK_EQ(r3.errorMessage, "GraphQL error", "errors message");

        auto r4 = MixcloudParser::parseTracklistResponse(toData(R"({"data": {"cloudcastLookup": null}})"));
        CHECK(!r4.success, "null lookup fails");
        CHECK_EQ(r4.errorMessage, "Cloudcast not found", "not found message");
    }

    // --- Tracklist with no sections still succeeds (mix without tracklist) ---
    {
        g_context = "tracklist-empty";
        auto result = MixcloudParser::parseTracklistResponse(toData(
            R"({"data": {"cloudcastLookup": {"name": "Mix", "sections": []}}})"));
        CHECK(result.success, "empty tracklist is not an error");
        CHECK(result.sections.empty(), "no sections");
    }

    // --- Query builders ---
    {
        g_context = "build-queries";
        std::string q = MixcloudParser::buildSearchQuery("techno", 10);
        CHECK(contains(q, "techno"), "term embedded");
        CHECK(contains(q, "first:10"), "maxResults embedded");
        CHECK(contains(q, "%22"), "quotes URL-encoded");
        CHECK(!contains(q, "\""), "no raw quotes in encoded query");

        std::string body = MixcloudParser::buildTracklistQuery("dj1", "deep-mix");
        CHECK(contains(body, R"(username:\"dj1\")"), "username in lookup");
        CHECK(contains(body, R"(slug:\"deep-mix\")"), "slug in lookup");
        CHECK(contains(body, "TrackSection"), "TrackSection fragment present");
        CHECK(body.front() == '{' && body.back() == '}', "JSON body shape");
    }

    printf("\n%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    }
    return g_failures == 0 ? 0 : 1;
}
