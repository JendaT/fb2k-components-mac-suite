//
//  URLUtilsTests.mm
//  foo_jl_cloud_streamer_mac
//
//  Unit tests for URLUtils (web/internal URL parsing, classification, and the
//  malformed-URL correction that strips an accidentally-embedded host).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/URLUtils.h"

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

int main(void) {
    @autoreleasepool {

    // --- SoundCloud web URL -> track ---
    {
        g_context = "soundcloud-web";
        ParsedCloudURL p = URLUtils::parseURL("https://soundcloud.com/artist/track-name");
        CHECK(p.service == CloudService::SoundCloud, "service SoundCloud");
        CHECK(p.type == JLCloudURLType::Track, "type Track");
        CHECK(p.username == "artist", "username");
        CHECK(p.slug == "track-name", "slug");
        CHECK(p.internalURL == "soundcloud://artist/track-name", "internal scheme built");
    }

    // --- Mixcloud web URL (with www + trailing slash) -> track ---
    {
        g_context = "mixcloud-web";
        ParsedCloudURL p = URLUtils::parseURL("https://www.mixcloud.com/dj/mix-set/");
        CHECK(p.service == CloudService::Mixcloud, "service Mixcloud");
        CHECK(p.type == JLCloudURLType::Track, "type Track (mixcloud DJ set)");
        CHECK(p.username == "dj", "username");
        CHECK(p.slug == "mix-set", "slug (trailing slash stripped)");
        CHECK(p.internalURL == "mixcloud://dj/mix-set", "internal scheme built");
    }

    // --- Malformed internal URL with embedded host is corrected ---
    {
        g_context = "malformed-correction";
        ParsedCloudURL p = URLUtils::parseURL("mixcloud://www.mixcloud.com/dj/mix");
        CHECK(p.username == "dj", "host stripped -> username");
        CHECK(p.slug == "mix", "host stripped -> slug");
        CHECK(p.internalURL == "mixcloud://dj/mix", "corrected internal URL");
    }

    // --- Scheme / web classification ---
    {
        g_context = "classification";
        CHECK(URLUtils::isInternalScheme("mixcloud://a/b"), "internal scheme true");
        CHECK(!URLUtils::isInternalScheme("https://soundcloud.com/a/b"), "web URL not internal");
        CHECK(URLUtils::isCloudWebURL("https://soundcloud.com/a/b"), "cloud web URL true");
        CHECK(!URLUtils::isCloudWebURL("https://example.com/a/b"), "foreign host false");
        CHECK(URLUtils::getService("mixcloud://a/b") == CloudService::Mixcloud, "getService scheme");
        CHECK(URLUtils::getService("https://example.com") == CloudService::Unknown, "getService unknown");
    }

    // --- Round-trip conversions ---
    {
        g_context = "round-trip";
        CHECK(URLUtils::webURLToInternalScheme("https://soundcloud.com/a/b") == "soundcloud://a/b",
              "web -> internal");
        CHECK(URLUtils::internalSchemeToWebURL("soundcloud://a/b") == "https://soundcloud.com/a/b",
              "internal -> web (soundcloud, no trailing slash)");
        CHECK(URLUtils::internalSchemeToWebURL("mixcloud://a/b") == "https://www.mixcloud.com/a/b/",
              "internal -> web (mixcloud, trailing slash)");
    }

    // --- Profile URL is not a playable type ---
    {
        g_context = "profile";
        ParsedCloudURL p = URLUtils::parseURL("https://soundcloud.com/just-a-user");
        CHECK(p.type == JLCloudURLType::Profile, "single path segment -> Profile");
        CHECK(!URLUtils::isPlayableType(p.type), "profile not playable");
        CHECK(URLUtils::isPlayableType(JLCloudURLType::Track), "track playable");
    }

    printf("\n%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    }
    return g_failures == 0 ? 0 : 1;
}
