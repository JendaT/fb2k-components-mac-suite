//
//  ImportSorter.h
//  foo_simplaylist_mac
//
//  Pure ordering logic for tracks arriving via drop / "add to playlist".
//
//  No foobar2000 SDK dependency so it can be unit-tested standalone.
//  Extracted from SimPlaylistImportNotify::on_completion.
//

#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace simplaylist {

// One track's sort inputs, already formatted by titleformat.
// `albumArtist` is %album artist%, which foobar2000 resolves to %artist% when
// no ALBUMARTIST tag exists — the reason compilations need special handling.
struct ImportSortKey {
    std::string albumArtist;
    std::string album;
    int disc = 0;
    int track = 0;
    std::string path;
};

// Plan the order incoming tracks should be inserted in.
//
// Normally tracks sort by (album artist, album, disc, track, path), which keeps
// an artist's albums together. That breaks down for compilations: sources with
// no ALBUMARTIST tag (streaming tracks, loose files) report each track's own
// artist as the album artist, so a Various Artists album would be scattered
// alphabetically by performer with its track numbers interleaved.
//
// So: when one album title carries more than one distinct album artist, that
// album is treated as a compilation and its tracks sort by (album, disc, track)
// alone, keeping the release contiguous and in running order. Albums with a
// consistent album artist are unaffected. Tracks with no album title are never
// grouped this way — they have no release to keep together.
//
// Returns indices into `keys` in insertion order; ties keep their input order.
std::vector<size_t> planImportOrder(const std::vector<ImportSortKey> &keys);

}  // namespace simplaylist
