//
//  QueuePersistenceTests.cpp
//  foo_jl_queue_manager
//
//  Unit tests for QueuePersistence (queue save/restore serialization).
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/QueuePersistence.h"

#include <cstdio>
#include <string>
#include <vector>

using queue_persist::SavedEntry;
using queue_persist::kNoPlaylist;

static int g_failures = 0;
static int g_checks = 0;

static void check(bool condition, const char* name) {
    g_checks++;
    if (!condition) {
        g_failures++;
        printf("FAIL [%s]\n", name);
    }
}

static SavedEntry entry(const std::string& path, uint32_t subsong, size_t playlist, size_t item) {
    SavedEntry e;
    e.path = path;
    e.subsong = subsong;
    e.playlist = playlist;
    e.item = item;
    return e;
}

static void checkRoundTrip(const std::vector<SavedEntry>& in, const char* name) {
    auto out = queue_persist::deserialize(queue_persist::serialize(in));
    check(out == in, name);
}

int main() {
    // Round trips
    checkRoundTrip({}, "empty");
    checkRoundTrip({entry("file:///Music/a.flac", 0, 0, 0)}, "single playlist entry");
    checkRoundTrip({entry("file:///Music/a.cue", 7, kNoPlaylist, 0)}, "orphan with subsong");
    checkRoundTrip({entry("file:///a.flac", 0, 2, 15),
                    entry("file:///b.flac", 0, kNoPlaylist, 0),
                    entry("file:///a.flac", 0, 2, 15)},
                   "order and duplicates preserved");
    checkRoundTrip({entry("file:///we\tird\\na\nme\r.mp3", 0, 1, 1)},
                   "tab/backslash/newline/CR in path");
    checkRoundTrip({entry("file:///\xC4\x8D" "es\xC3\xA1.flac", 0, 0, 3)}, "UTF-8 path");
    checkRoundTrip({entry("file:///x.flac", UINT32_MAX, kNoPlaylist - 1, kNoPlaylist - 1)},
                   "max field values");

    // Orphan item index is not persisted
    {
        auto out = queue_persist::deserialize(
            queue_persist::serialize({entry("file:///o.flac", 0, kNoPlaylist, 42)}));
        check(out.size() == 1 && out[0].playlist == kNoPlaylist && out[0].item == 0,
              "orphan item index normalized");
    }

    // Header handling
    check(queue_persist::deserialize("").empty(), "empty blob");
    check(queue_persist::deserialize("QMQ2\n0\t0\t0\tfile:///a\n").empty(), "unknown version");
    check(queue_persist::deserialize("0\t0\t0\tfile:///a\n").empty(), "missing header");
    check(queue_persist::deserialize("QMQ1").empty(), "header only, no newline");

    // Malformed lines are skipped, good lines kept
    {
        std::string blob =
            "QMQ1\n"
            "0\t1\t0\tfile:///good1\n"
            "garbage\n"
            "x\t1\t0\tfile:///badplaylist\n"
            "0\t-1\t0\tfile:///baditem\n"
            "0\t1\t4294967296\tfile:///subsongoverflow\n"
            "0\t1\t0\t\n"
            "0\t1\t0\tfile:///bad\\escape\n"
            "0\t1\t0\tfile:///trailing\\\n"
            "0\t1\t0\n"
            "99999999999999999999999\t1\t0\tfile:///hugeplaylist\n"
            "\n"
            "-\t0\t3\tfile:///good2\n";
        auto out = queue_persist::deserialize(blob);
        check(out.size() == 2, "malformed lines skipped");
        if (out.size() == 2) {
            check(out[0].path == "file:///good1" && out[0].playlist == 0 && out[0].item == 1,
                  "first good line");
            check(out[1].path == "file:///good2" && out[1].playlist == kNoPlaylist &&
                  out[1].subsong == 3, "second good line");
        }
    }

    // Missing trailing newline on last entry
    {
        auto out = queue_persist::deserialize("QMQ1\n-\t0\t0\tfile:///last");
        check(out.size() == 1 && out[0].path == "file:///last", "no trailing newline");
    }

    // Large queue
    {
        std::vector<SavedEntry> big;
        for (size_t i = 0; i < 5000; i++) {
            big.push_back(entry("file:///t" + std::to_string(i) + ".flac", (uint32_t)(i % 3),
                                (i % 4 == 0) ? kNoPlaylist : i % 7, i));
        }
        checkRoundTrip(big, "5000 entries");
    }

    if (g_failures > 0) {
        printf("QueuePersistenceTests: %d of %d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("QueuePersistenceTests: all %d checks passed\n", g_checks);
    return 0;
}
