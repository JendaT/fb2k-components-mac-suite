//
//  TrackTagMapper.h
//  foo_jl_cloud_streamer_mac
//
//  Single source of truth for turning TrackInfo into foobar2000 file_info tags.
//
//  Contains NO foobar2000 SDK dependency: it emits a list of FileInfoField ops
//  that the Integration layer (CloudInputDecoder / CloudInfoReader) applies to a
//  file_info. Previously this mapping was duplicated in both get_info paths and
//  had drifted (the reader omitted UPLOADER/COMMENT/DATE/GENRE/URL). Centralised
//  here so the two paths cannot diverge, and so the fallback logic is
//  unit-testable without instantiating the SDK. See Tests/TrackTagMapperTests.mm.
//

#pragma once

#include <string>
#include <vector>

#include "TrackInfo.h"

namespace cloud_streamer {

// A single operation to apply to a foobar2000 file_info. Kept SDK-free so the
// mapping is testable standalone; the Integration layer translates each op into
// the matching file_info call.
struct FileInfoField {
    enum class Op {
        MetaSet,   // p_info.meta_set(key, value)
        MetaAdd,   // p_info.meta_add(key, value)
        InfoSet,   // p_info.info_set(key, value)
        Length     // p_info.set_length(length)
    };
    Op op;
    std::string key;
    std::string value;
    double length = 0.0;
};

class TrackTagMapper {
public:
    // Map resolved/cached track metadata to file_info fields. Shared by both
    // CloudInputDecoder and CloudInfoReader. Empty fields are skipped, so a
    // sparsely-populated (cached) TrackInfo and a fully-resolved one run through
    // the identical rules.
    //
    // Fallbacks (unchanged behaviour, now in one place):
    //   ALBUM        <- album, else title
    //   ALBUM ARTIST <- artist, else uploader
    static std::vector<FileInfoField> map(const TrackInfo& info);

    // Build a minimal TrackInfo from an internal-scheme URL, for when no
    // resolved or cached metadata exists. Title is the de-slugged path (dashes
    // and underscores become spaces); artist is the username. Feed the result
    // back through map() so the URL fallback shares the same tag rules.
    static TrackInfo synthesizeFromURL(const std::string& internalURL);
};

} // namespace cloud_streamer
