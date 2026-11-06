//
//  ImportSorterTests.cpp
//  foo_simplaylist_mac
//
//  Unit tests for ImportSorter (ordering of dropped / imported tracks).
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/ImportSorter.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using simplaylist::ImportSortKey;
using simplaylist::planImportOrder;

static ImportSortKey key(const char *albumArtist, const char *album, int disc,
                         int track, const char *path = "") {
    ImportSortKey k;
    k.albumArtist = albumArtist;
    k.album = album;
    k.disc = disc;
    k.track = track;
    k.path = path;
    return k;
}

// Returns the track numbers in planned order, so expectations read like the
// playlist the user ends up looking at.
static std::vector<int> orderedTracks(const std::vector<ImportSortKey> &keys) {
    std::vector<int> out;
    for (size_t i : planImportOrder(keys)) out.push_back(keys[i].track);
    return out;
}

static std::string describe(const std::vector<int> &v) {
    std::string s = "[";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) s += ",";
        s += std::to_string(v[i]);
    }
    return s + "]";
}

static void checkOrder(const std::vector<ImportSortKey> &keys,
                       const std::vector<int> &want, const char *what) {
    g_checks++;
    std::vector<int> got = orderedTracks(keys);
    if (got != want) {
        g_failures++;
        printf("FAIL %s: got %s, expected %s\n", what, describe(got).c_str(),
               describe(want).c_str());
    }
}

int main() {
    // A normal album keeps working: one album artist, ordered by track.
    checkOrder({key("Mindex", "Lost Empire", 1, 3),
                key("Mindex", "Lost Empire", 1, 1),
                key("Mindex", "Lost Empire", 1, 2)},
               {1, 2, 3}, "single-artist album sorts by track");

    // Multi-disc: disc precedes track, so discs do not interleave.
    checkOrder({key("A", "Las Cartas", 2, 1), key("A", "Las Cartas", 1, 2),
                key("A", "Las Cartas", 2, 2), key("A", "Las Cartas", 1, 1)},
               {1, 2, 1, 2}, "multi-disc album orders disc before track");

    // The reported bug: a compilation whose tracks each report their own artist
    // as the album artist must stay in running order, not alphabetical by artist.
    checkOrder({key("Gabriel Moraes", "Best Of 2025", 1, 7),
                key("Kase Kochen", "Best Of 2025", 1, 3),
                key("Sammy Legs", "Best Of 2025", 1, 1),
                key("Tom Baker", "Best Of 2025", 1, 2),
                key("Kase Kochen", "Best Of 2025", 1, 5)},
               {1, 2, 3, 5, 7}, "compilation sorts by track, not by artist");

    // A compilation stays contiguous when dropped alongside a normal album.
    {
        std::vector<ImportSortKey> keys = {
            key("Zed", "Solo Record", 1, 1), key("Bee", "VA Comp", 1, 2),
            key("Ann", "VA Comp", 1, 1), key("Zed", "Solo Record", 1, 2)};
        std::vector<size_t> order = planImportOrder(keys);
        std::vector<std::string> albums;
        for (size_t i : order) albums.push_back(keys[i].album);
        CHECK(albums[0] == albums[1] && albums[2] == albums[3],
              "each album stays contiguous");
        CHECK(albums[0] == "VA Comp", "compilation sorts ahead of named artist");
    }

    // Album artists that merely differ in case/spacing are still distinct
    // values, so such an album is treated as a compilation; verify it at least
    // stays contiguous and in track order rather than scattering.
    checkOrder({key("The Band", "Split", 1, 2), key("the band", "Split", 1, 1)},
               {1, 2}, "inconsistent album-artist spelling keeps track order");

    // Tracks with no album are never grouped as a compilation: they keep the
    // artist-first ordering so unrelated singles do not get shuffled together.
    checkOrder({key("Bravo", "", 1, 1), key("Alpha", "", 1, 2)}, {2, 1},
               "album-less tracks still sort by artist");

    // Missing disc/track numbers (parsed as 0) sort first, stably.
    checkOrder({key("A", "Album", 0, 0, "b.flac"), key("A", "Album", 1, 1),
                key("A", "Album", 0, 0, "a.flac")},
               {0, 0, 1}, "missing numbers sort first");

    // Equal keys preserve input order (stable).
    {
        std::vector<ImportSortKey> keys = {key("A", "Album", 1, 1, "second"),
                                           key("A", "Album", 1, 1, "second")};
        std::vector<size_t> order = planImportOrder(keys);
        CHECK(order[0] == 0 && order[1] == 1, "equal keys keep input order");
    }

    // Empty input is not a crash.
    {
        std::vector<ImportSortKey> keys;
        CHECK(planImportOrder(keys).empty(), "empty input yields empty order");
    }

    TEST_MAIN_END();
}
