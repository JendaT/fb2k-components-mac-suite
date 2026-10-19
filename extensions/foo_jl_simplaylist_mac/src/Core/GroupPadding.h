//
//  GroupPadding.h
//  foo_simplaylist_mac
//
//  Padding rows after each group, and the Inline header style's album art
//  geometry. Pure C++, shared by the controller (row layout) and the view
//  (art drawing) so the two cannot disagree. Unit tested in
//  Tests/GroupPaddingTests.cpp.
//

#pragma once

#include <algorithm>
#include <cmath>

namespace simplaylist {

// Inline style (2): gap between the album art and the edges of the rows it
// covers, top and bottom.
constexpr double kInlineArtInset = 3.0;

// Inline style: rows the album art covers, at least one. The art is sized to
// fill whole rows so it always ends the same distance above whatever follows.
inline long inlineArtRows(double albumArtSize, double rowHeight) {
    if (!(rowHeight > 0.0)) return 0;
    albumArtSize = std::clamp(albumArtSize, 0.0, 1000.0);
    return std::max(1L, std::lround((albumArtSize + 2.0 * kInlineArtInset) / rowHeight));
}

// Inline style: drawn art size, within half a row of the configured size.
inline double inlineArtSize(double albumArtSize, double rowHeight) {
    return static_cast<double>(inlineArtRows(albumArtSize, rowHeight)) * rowHeight - 2.0 * kInlineArtInset;
}

// Empty rows after a group's tracks.
//
// Styles 0, 1, 3: enough to fit the album art plus 6 px above and below,
// rounded up to whole rows (style 3 keeps one row for its text under the art).
//
// Style 2 (Inline): the header row is the group's first row and the art starts
// beside it. Padding fills up to the art's last row, then adds
// `inlineSpacingRows` empty rows, so the gap to the next group is the same
// whether the tracks or the art end lower.
inline long paddingRowsForGroup(long trackCount, long subgroupCount, double albumArtSize,
                                double rowHeight, long headerStyle, long inlineSpacingRows) {
    albumArtSize = std::clamp(albumArtSize, 0.0, 1000.0);

    if (headerStyle == 2) {
        const long contentRows = 1 + subgroupCount + trackCount;
        const long artOverhang = std::max(0L, inlineArtRows(albumArtSize, rowHeight) - contentRows);
        return artOverhang + std::max(0L, inlineSpacingRows);
    }

    const double padding = 6.0;
    const long minContentRows =
        (rowHeight > 0.0) ? static_cast<long>(std::ceil((albumArtSize + padding * 2.0) / rowHeight)) : 0;
    const long minPadding = (headerStyle == 3) ? 1 : 0;
    const long extraTextSpace = (headerStyle == 3) ? 1 : 0;
    return std::max(minPadding, minContentRows - trackCount - subgroupCount + extraTextSpace);
}

} // namespace simplaylist
