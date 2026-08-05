//
//  YtDlpParserTests.mm
//  foo_jl_cloud_streamer_mac
//
//  Unit tests for YtDlpParser (metadata JSON -> TrackInfo, search JSON ->
//  entries, stderr error classification). Compiled standalone (Foundation
//  only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/YtDlpParser.h"

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

int main(void) {
    @autoreleasepool {

    // --- Metadata: full JSON maps every field ---
    {
        g_context = "meta-full";
        const char* json = R"({
            "title": "My Track",
            "uploader": "uploader1",
            "artist": "The Artist",
            "album": "The Album",
            "description": "a comment",
            "duration": 123.5,
            "thumbnail": "https://img.example/t.jpg",
            "upload_date": "20240115",
            "tags": ["House", "Techno"],
            "webpage_url": "https://soundcloud.com/uploader1/my-track"
        })";
        auto info = YtDlpParser::parseMetadataJSON(json, "soundcloud://uploader1/my-track");
        CHECK(info.has_value(), "parses");
        CHECK_EQ(info->title, "My Track", "title");
        CHECK_EQ(info->uploader, "uploader1", "uploader");
        CHECK_EQ(info->artist, "The Artist", "artist");
        CHECK_EQ(info->album, "The Album", "album");
        CHECK_EQ(info->description, "a comment", "description");
        CHECK(info->duration == 123.5, "duration");
        CHECK_EQ(info->thumbnailURL, "https://img.example/t.jpg", "thumbnail");
        CHECK_EQ(info->uploadDate, "20240115", "upload date");
        CHECK(info->tags.size() == 2, "two tags");
        CHECK_EQ(info->webURL, "https://soundcloud.com/uploader1/my-track", "web URL");
        CHECK_EQ(info->internalURL, "soundcloud://uploader1/my-track", "internal URL kept");
        CHECK(info->service == CloudService::SoundCloud, "service from original URL");
    }

    // --- Metadata: artist falls back to uploader ---
    {
        g_context = "meta-artist-fallback";
        auto info = YtDlpParser::parseMetadataJSON(
            R"({"title": "T", "uploader": "up"})", "soundcloud://up/t");
        CHECK(info.has_value(), "parses");
        CHECK_EQ(info->artist, "up", "artist falls back to uploader");
    }

    // --- Metadata: stream format selection prefers format_id "http" ---
    {
        g_context = "meta-format-http";
        const char* json = R"({
            "title": "T",
            "formats": [
                {"format_id": "hls", "url": "https://cdn.example/hls.m3u8"},
                {"format_id": "http", "url": "https://cdn.example/direct.mp3"},
                {"format_id": "other", "url": "https://cdn.example/other"}
            ]
        })";
        auto info = YtDlpParser::parseMetadataJSON(json, "soundcloud://u/t");
        CHECK(info.has_value(), "parses");
        CHECK_EQ(info->streamURL, "https://cdn.example/direct.mp3", "http format preferred");
    }

    // --- Metadata: falls back to first format with a URL ---
    {
        g_context = "meta-format-first";
        const char* json = R"({
            "title": "T",
            "formats": [
                {"format_id": "hls"},
                {"format_id": "hls-1", "url": "https://cdn.example/hls.m3u8"}
            ]
        })";
        auto info = YtDlpParser::parseMetadataJSON(json, "soundcloud://u/t");
        CHECK(info.has_value(), "parses");
        CHECK_EQ(info->streamURL, "https://cdn.example/hls.m3u8", "first format with URL");
    }

    // --- Metadata: top-level url fallback when no formats ---
    {
        g_context = "meta-url-fallback";
        auto info = YtDlpParser::parseMetadataJSON(
            R"({"title": "T", "url": "https://cdn.example/plain"})", "soundcloud://u/t");
        CHECK(info.has_value(), "parses");
        CHECK_EQ(info->streamURL, "https://cdn.example/plain", "top-level url used");
    }

    // --- Metadata: chapters parsed, untitled chapters dropped ---
    {
        g_context = "meta-chapters";
        const char* json = R"({
            "title": "Mix",
            "chapters": [
                {"title": "Song A", "start_time": 0, "end_time": 90, "artist": "Artist A"},
                {"start_time": 90, "end_time": 180},
                {"title": "Song B", "start_time": 180}
            ]
        })";
        auto info = YtDlpParser::parseMetadataJSON(json, "mixcloud://u/t");
        CHECK(info.has_value(), "parses");
        CHECK(info->chapters.size() == 2, "untitled chapter dropped");
        CHECK_EQ(info->chapters[0].title, "Song A", "chapter title");
        CHECK_EQ(info->chapters[0].artist, "Artist A", "chapter artist");
        CHECK(info->chapters[0].endTime == 90.0, "chapter end time");
        CHECK(info->chapters[1].startTime == 180.0, "second chapter start");
    }

    // --- Metadata: malformed input rejected ---
    {
        g_context = "meta-malformed";
        CHECK(!YtDlpParser::parseMetadataJSON("not json", "u").has_value(), "garbage -> nullopt");
        CHECK(!YtDlpParser::parseMetadataJSON("[1,2,3]", "u").has_value(), "array -> nullopt");
        CHECK(!YtDlpParser::parseMetadataJSON("", "u").has_value(), "empty -> nullopt");
    }

    // --- Search: entries parsed, incomplete entries dropped ---
    {
        g_context = "search";
        const char* json = R"({
            "entries": [
                {"title": "Track 1", "uploader": "up1", "webpage_url": "https://soundcloud.com/up1/t1",
                 "id": "111", "duration": 60},
                {"title": "", "webpage_url": "https://soundcloud.com/up/x"},
                {"title": "No URL"},
                {"title": "Track 2", "url": "https://api.example/t2"}
            ]
        })";
        auto entries = YtDlpParser::parseSearchJSON(json);
        CHECK(entries.size() == 2, "incomplete entries dropped");
        CHECK_EQ(entries[0].title, "Track 1", "title");
        CHECK_EQ(entries[0].uploader, "up1", "uploader");
        CHECK_EQ(entries[0].webpageUrl, "https://soundcloud.com/up1/t1", "webpage_url preferred");
        CHECK_EQ(entries[0].trackId, "111", "track id");
        CHECK(entries[0].duration == 60.0, "duration");
        CHECK_EQ(entries[1].webpageUrl, "https://api.example/t2", "url fallback");
    }

    // --- Search: thumbnail preference order ---
    {
        g_context = "search-thumbs";
        const char* json = R"({
            "entries": [
                {"title": "A", "webpage_url": "https://x/a", "thumbnails": [
                    {"id": "badge", "url": "https://img/badge"},
                    {"id": "large", "url": "https://img/large"},
                    {"id": "small", "url": "https://img/small"}
                ]},
                {"title": "B", "webpage_url": "https://x/b", "thumbnails": [
                    {"id": "weird", "url": "https://img/weird"},
                    {"id": "odd", "url": "https://img/odd"}
                ]}
            ]
        })";
        auto entries = YtDlpParser::parseSearchJSON(json);
        CHECK(entries.size() == 2, "two entries");
        CHECK_EQ(entries[0].thumbnailUrl, "https://img/large", "large preferred over badge/small");
        CHECK_EQ(entries[1].thumbnailUrl, "https://img/weird", "fallback to first with URL");
    }

    // --- Search: malformed / missing entries ---
    {
        g_context = "search-malformed";
        CHECK(YtDlpParser::parseSearchJSON("not json").empty(), "garbage -> empty");
        CHECK(YtDlpParser::parseSearchJSON(R"({"no_entries": true})").empty(), "no entries key -> empty");
    }

    // --- Error classification ---
    {
        g_context = "errors";
        CHECK(YtDlpParser::parseErrorOutput("") == JLCloudError::None, "empty -> None");
        CHECK(YtDlpParser::parseErrorOutput("ERROR: Video unavailable") == JLCloudError::TrackUnavailable,
              "unavailable");
        CHECK(YtDlpParser::parseErrorOutput("This video is not available in your country") ==
              JLCloudError::TrackUnavailable, "'not available' wins over 'country' (declared order)");
        CHECK(YtDlpParser::parseErrorOutput("blocked in your country") == JLCloudError::GeoRestricted,
              "geo restricted");
        CHECK(YtDlpParser::parseErrorOutput("HTTP Error 403: Forbidden") == JLCloudError::StreamExpired,
              "403 -> expired");
        CHECK(YtDlpParser::parseErrorOutput("Please login to continue") == JLCloudError::AuthRequired,
              "login required");
        CHECK(YtDlpParser::parseErrorOutput("rate limit exceeded") == JLCloudError::RateLimited,
              "rate limited");
        CHECK(YtDlpParser::parseErrorOutput("Requested format is not available") ==
              JLCloudError::FormatNotFound, "format not found");
        CHECK(YtDlpParser::parseErrorOutput("ERROR: Unsupported URL: https://x") ==
              JLCloudError::UnsupportedURL, "unsupported URL");
        CHECK(YtDlpParser::parseErrorOutput("something inexplicable") == JLCloudError::YtDlpFailed,
              "unknown -> generic failure");
    }

    printf("\n%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    }
    return g_failures == 0 ? 0 : 1;
}
