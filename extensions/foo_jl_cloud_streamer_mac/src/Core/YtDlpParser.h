//
//  YtDlpParser.h
//  foo_jl_cloud_streamer_mac
//
//  Pure parsing of yt-dlp output (metadata JSON, search JSON, stderr error
//  classification). No SDK, no subprocess - unit-testable standalone.
//

#pragma once

#include "CloudErrors.h"
#include "TrackInfo.h"
#include <string>
#include <optional>
#include <vector>

namespace cloud_streamer {

// Track info from search results (--flat-playlist entries)
struct YtDlpTrackInfo {
    std::string title;
    std::string uploader;
    std::string webpageUrl;
    std::string trackId;
    std::string thumbnailUrl;  // Artwork URL (typically "large" size - 100x100)
    double duration = 0.0;
};

class YtDlpParser {
public:
    // Parse `yt-dlp -j` metadata JSON into TrackInfo: common fields, chapters,
    // and stream URL selection (prefer format_id "http", then first format
    // with a URL, then top-level "url"). Returns nullopt on malformed JSON.
    static std::optional<TrackInfo> parseMetadataJSON(const std::string& json,
                                                      const std::string& originalURL);

    // Parse `yt-dlp --flat-playlist -J` search JSON into entries. Entries
    // without a title or URL are dropped. Thumbnail preference order:
    // large, t67x67, small, badge, then first with a URL.
    static std::vector<YtDlpTrackInfo> parseSearchJSON(const std::string& json);

    // Classify yt-dlp stderr output into an error code. Returns None for
    // empty output, YtDlpFailed when no known pattern matches.
    static JLCloudError parseErrorOutput(const std::string& errorOutput);
};

} // namespace cloud_streamer
