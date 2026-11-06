//
//  CueSheetTests.mm
//  foo_jl_cloud_streamer_mac
//
//  Unit tests for TrackInfo::generateCueSheet (embedded CUE generation for DJ
//  sets: track numbering, MM:SS:FF frame math, quote escaping). Compiled
//  standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TrackInfo.h"

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

static bool contains(const std::string& haystack, const std::string& needle) {
    return haystack.find(needle) != std::string::npos;
}

int main(void) {
    @autoreleasepool {

    // --- No chapters -> empty CUE ---
    {
        g_context = "empty";
        TrackInfo info;
        info.title = "Mix";
        CHECK(info.generateCueSheet().empty(), "no chapters -> empty string");
    }

    // --- Full CUE: header, numbering, frame math, per-track performer ---
    {
        g_context = "full";
        TrackInfo info;
        info.title = "My Mix";
        info.artist = "DJ Test";

        Chapter a; a.title = "Song A"; a.artist = "Artist A"; a.startTime = 0.0;
        Chapter b; b.title = "Song B"; b.startTime = 90.5;  // 01:30 + 0.5*75 = 37 frames
        info.chapters.push_back(a);
        info.chapters.push_back(b);

        std::string cue = info.generateCueSheet();

        CHECK(contains(cue, "TITLE \"My Mix\""), "header TITLE");
        CHECK(contains(cue, "PERFORMER \"DJ Test\""), "header PERFORMER");
        CHECK(contains(cue, "FILE \"stream\" WAVE"), "single FILE entry");
        CHECK(contains(cue, "TRACK 01 AUDIO"), "first track zero-padded");
        CHECK(contains(cue, "TRACK 02 AUDIO"), "second track");
        CHECK(contains(cue, "INDEX 01 00:00:00"), "first index at zero");
        CHECK(contains(cue, "INDEX 01 01:30:37"), "MM:SS:FF frame math (90.5s)");
        CHECK(contains(cue, "TITLE \"Song A\""), "chapter title A");
        CHECK(contains(cue, "PERFORMER \"Artist A\""), "chapter performer A");
        CHECK(!contains(cue, "PERFORMER \"Artist B\""), "no performer for chapter B (empty artist)");
    }

    // --- Quote escaping ---
    {
        g_context = "escaping";
        TrackInfo info;
        info.title = "Say \"Hi\"";
        info.artist = "DJ";
        Chapter c; c.title = "Track \"One\""; c.startTime = 0.0;
        info.chapters.push_back(c);

        std::string cue = info.generateCueSheet();
        CHECK(contains(cue, "TITLE \"Say \\\"Hi\\\"\""), "escaped quotes in header title");
        CHECK(contains(cue, "TITLE \"Track \\\"One\\\"\""), "escaped quotes in chapter title");
    }

    // --- Track >= 10 keeps two-digit numbering (no extra zero) ---
    {
        g_context = "numbering";
        TrackInfo info;
        info.title = "Long Mix";
        for (int i = 0; i < 11; i++) {
            Chapter c; c.title = "T"; c.startTime = i * 10.0;
            info.chapters.push_back(c);
        }
        std::string cue = info.generateCueSheet();
        CHECK(contains(cue, "TRACK 09 AUDIO"), "track 9 zero-padded");
        CHECK(contains(cue, "TRACK 10 AUDIO"), "track 10 two digits");
        CHECK(contains(cue, "TRACK 11 AUDIO"), "track 11 two digits");
        CHECK(!contains(cue, "TRACK 010"), "no over-padding past 9");
    }

    printf("\n%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    }
    return g_failures == 0 ? 0 : 1;
}
