//
//  GroupPaddingTests.cpp
//  foo_simplaylist_mac
//
//  Unit tests for GroupPadding (padding rows after each group, Inline album
//  art geometry). Pure C++, compiled standalone; run by Scripts/build.sh.
//

#include "../src/Core/GroupPadding.h"
#include "TestHarness.h"

#include <cmath>
#include <cstdio>

using namespace simplaylist;

namespace {

// The formula styles 0, 1 and 3 used before GroupPadding existed (moved
// verbatim from SimPlaylistController). Those styles must not change.
long legacyPadding(long trackCount, long subgroups, double artSize, double rowHeight, long style) {
    artSize = std::min(std::max(artSize, 0.0), 1000.0);
    const double padding = 6.0;
    const long minContentRows = (rowHeight > 0) ? (long)std::ceil((artSize + padding * 2) / rowHeight) : 0;
    const long minPadding = (style == 3) ? 1 : 0;
    const long extraHeaderSpace = (style == 2) ? 1 : 0;
    const long extraTextSpace = (style == 3) ? 1 : 0;
    return std::max(minPadding, minContentRows - trackCount - subgroups - extraHeaderSpace + extraTextSpace);
}

} // namespace

int main() {
    const double rowHeights[] = {18.0, 22.0, 26.0, 30.0};
    const double artSizes[] = {40.0, 64.0, 80.0, 100.0, 150.0, 200.0, 300.0};

    // Styles 0, 1, 3 are unchanged.
    g_context = "other styles unchanged";
    for (long style : {0L, 1L, 3L}) {
        for (double rh : rowHeights) {
            for (double art : artSizes) {
                for (long tracks = 0; tracks <= 20; tracks++) {
                    for (long subs = 0; subs <= 2; subs++) {
                        for (long spacing = 0; spacing <= 2; spacing++) {
                            CHECK_EQ(paddingRowsForGroup(tracks, subs, art, rh, style, spacing),
                                     legacyPadding(tracks, subs, art, rh, style), "same as before");
                        }
                    }
                }
            }
        }
    }

    // Inline: the art fills whole rows, inset 3 px top and bottom.
    g_context = "inline art geometry";
    for (double rh : rowHeights) {
        for (double art : artSizes) {
            const long rows = inlineArtRows(art, rh);
            CHECK(rows >= 1, "at least one row");
            CHECK_FLOAT_EQ(inlineArtSize(art, rh) + 2 * kInlineArtInset, rows * rh, "art plus insets fills its rows");
            CHECK(std::fabs(inlineArtSize(art, rh) - art) <= rh / 2 + 0.001, "within half a row of the setting");
        }
    }
    CHECK_EQ(inlineArtRows(150, 22), 7, "150 px art at 22 px rows covers 7 rows");
    CHECK_FLOAT_EQ(inlineArtSize(150, 22), 148, "and is drawn at 148 px");

    // Inline: the gap after whichever ends lower (tracks or art) is exactly the
    // spacing, for every combination.
    g_context = "inline consistent gap";
    for (double rh : rowHeights) {
        for (double art : artSizes) {
            for (long tracks = 0; tracks <= 30; tracks++) {
                for (long subs = 0; subs <= 3; subs++) {
                    for (long spacing = 0; spacing <= 2; spacing++) {
                        const long contentRows = 1 + subs + tracks;
                        const long groupRows = contentRows + paddingRowsForGroup(tracks, subs, art, rh, 2, spacing);
                        const long occupied = std::max(contentRows, inlineArtRows(art, rh));
                        CHECK_EQ(groupRows - occupied, spacing, "gap equals spacing");
                    }
                }
            }
        }
    }

    // Inline examples matching the reported screenshots (22 px rows, 150 px art).
    g_context = "inline examples";
    CHECK_EQ(paddingRowsForGroup(3, 0, 150, 22, 2, 0), 3, "3 tracks: fill to the art (7 rows) with Close");
    CHECK_EQ(paddingRowsForGroup(3, 0, 150, 22, 2, 1), 4, "3 tracks: plus one row with One row");
    CHECK_EQ(paddingRowsForGroup(14, 2, 150, 22, 2, 0), 0, "long album, Close: next group follows directly");
    CHECK_EQ(paddingRowsForGroup(14, 2, 150, 22, 2, 1), 1, "long album, One row: one empty row");
    CHECK_EQ(paddingRowsForGroup(14, 2, 150, 22, 2, -1), 0, "negative spacing treated as none");

    // Degenerate metrics do not crash or go negative.
    g_context = "degenerate";
    CHECK_EQ(inlineArtRows(150, 0), 0, "zero row height");
    CHECK_EQ(paddingRowsForGroup(3, 0, 150, 0, 2, 1), 1, "zero row height keeps the spacing");
    CHECK(paddingRowsForGroup(3, 0, 1e9, 22, 2, 0) >= 0, "huge art clamps");

    TEST_MAIN_END();
}
