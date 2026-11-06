//
//  TrackTagMapperTests.mm
//  foo_jl_cloud_streamer_mac
//
//  Unit tests for TrackTagMapper (TrackInfo -> file_info field mapping and the
//  ALBUM / ALBUM ARTIST fallbacks). Compiled standalone (Foundation only);
//  gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TrackTagMapper.h"

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

// Return the value of the first MetaSet/InfoSet field with the given key, or a
// sentinel if absent.
static std::string metaValue(const std::vector<FileInfoField>& fields, const std::string& key) {
    for (const auto& f : fields) {
        if ((f.op == FileInfoField::Op::MetaSet || f.op == FileInfoField::Op::InfoSet) && f.key == key) {
            return f.value;
        }
    }
    return "<absent>";
}

static bool hasKey(const std::vector<FileInfoField>& fields, const std::string& key) {
    for (const auto& f : fields) {
        if (f.key == key) return true;
    }
    return false;
}

int main(void) {
    @autoreleasepool {

    // --- Full metadata maps every field ---
    {
        g_context = "full";
        TrackInfo info;
        info.service = CloudService::SoundCloud;
        info.title = "My Track";
        info.artist = "The Artist";
        info.album = "The Album";
        info.uploader = "uploader1";
        info.description = "a comment";
        info.uploadDate = "20240115";
        info.duration = 123.0;
        info.webURL = "https://soundcloud.com/uploader1/my-track";
        info.tags = {"House", "Techno"};

        auto f = TrackTagMapper::map(info);
        CHECK(metaValue(f, "TITLE") == "My Track", "TITLE");
        CHECK(metaValue(f, "ARTIST") == "The Artist", "ARTIST");
        CHECK(metaValue(f, "ALBUM") == "The Album", "ALBUM uses album when present");
        CHECK(metaValue(f, "ALBUM ARTIST") == "The Artist", "ALBUM ARTIST uses artist when present");
        CHECK(metaValue(f, "UPLOADER") == "uploader1", "UPLOADER");
        CHECK(metaValue(f, "COMMENT") == "a comment", "COMMENT from description");
        CHECK(metaValue(f, "DATE") == "20240115", "DATE from uploadDate");
        CHECK(metaValue(f, "CLOUD_SERVICE") == "SoundCloud", "CLOUD_SERVICE");
        CHECK(metaValue(f, "URL") == info.webURL, "URL from webURL");

        // Length op present with the right value.
        bool foundLen = false;
        for (const auto& x : f) {
            if (x.op == FileInfoField::Op::Length) { foundLen = (x.length == 123.0); }
        }
        CHECK(foundLen, "Length op = duration");

        // Two GENRE add ops.
        int genres = 0;
        for (const auto& x : f) {
            if (x.op == FileInfoField::Op::MetaAdd && x.key == "GENRE") genres++;
        }
        CHECK(genres == 2, "two GENRE add ops");
    }

    // --- ALBUM falls back to title when album empty ---
    {
        g_context = "album-fallback";
        TrackInfo info;
        info.service = CloudService::Mixcloud;
        info.title = "Only Title";
        auto f = TrackTagMapper::map(info);
        CHECK(metaValue(f, "ALBUM") == "Only Title", "ALBUM falls back to title");
        CHECK(metaValue(f, "CLOUD_SERVICE") == "Mixcloud", "Mixcloud service name");
    }

    // --- ALBUM ARTIST falls back artist -> uploader -> absent ---
    {
        g_context = "albumartist-fallback";

        TrackInfo a;
        a.artist = "A";
        a.uploader = "U";
        CHECK(metaValue(TrackTagMapper::map(a), "ALBUM ARTIST") == "A", "prefers artist");

        TrackInfo b;
        b.uploader = "U";
        CHECK(metaValue(TrackTagMapper::map(b), "ALBUM ARTIST") == "U", "falls back to uploader");

        TrackInfo c;
        c.title = "T";  // no artist, no uploader
        CHECK(!hasKey(TrackTagMapper::map(c), "ALBUM ARTIST"), "absent when no artist/uploader");
    }

    // --- Empty fields are skipped ---
    {
        g_context = "empty-skipped";
        TrackInfo info;  // everything empty, service Unknown
        auto f = TrackTagMapper::map(info);
        CHECK(!hasKey(f, "TITLE"), "no TITLE when empty");
        CHECK(!hasKey(f, "ARTIST"), "no ARTIST when empty");
        CHECK(!hasKey(f, "ALBUM"), "no ALBUM when title empty");
        CHECK(!hasKey(f, "CUESHEET"), "no CUESHEET without chapters");
        // CLOUD_SERVICE is always emitted (defaults to SoundCloud for Unknown).
        CHECK(hasKey(f, "CLOUD_SERVICE"), "CLOUD_SERVICE always present");
    }

    // --- CUESHEET present when chapters exist ---
    {
        g_context = "cuesheet";
        TrackInfo info;
        info.title = "Mix";
        info.artist = "DJ";
        Chapter ch; ch.title = "Song"; ch.startTime = 0.0;
        info.chapters.push_back(ch);
        auto f = TrackTagMapper::map(info);
        CHECK(hasKey(f, "CUESHEET"), "CUESHEET emitted with chapters");
    }

    // --- synthesizeFromURL: de-slug + username, run through map() ---
    {
        g_context = "synthesize";
        TrackInfo info = TrackTagMapper::synthesizeFromURL("soundcloud://dj-mike/late-night_set");
        CHECK(info.title == "late night set", "slug de-slugged (dashes+underscores -> spaces)");
        CHECK(info.artist == "dj-mike", "username as artist");
        CHECK(info.service == CloudService::SoundCloud, "service from scheme");

        auto f = TrackTagMapper::map(info);
        CHECK(metaValue(f, "TITLE") == "late night set", "TITLE from synthesized title");
        CHECK(metaValue(f, "ALBUM") == "late night set", "ALBUM falls back to title");
        CHECK(metaValue(f, "ALBUM ARTIST") == "dj-mike", "ALBUM ARTIST falls back to artist");
    }

    printf("\n%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    }
    return g_failures == 0 ? 0 : 1;
}
