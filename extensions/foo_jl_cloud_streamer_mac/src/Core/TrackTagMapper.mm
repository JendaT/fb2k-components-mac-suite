//
//  TrackTagMapper.mm
//  foo_jl_cloud_streamer_mac
//

#import "TrackTagMapper.h"
#import "URLUtils.h"

namespace cloud_streamer {

std::vector<FileInfoField> TrackTagMapper::map(const TrackInfo& info) {
    using Op = FileInfoField::Op;
    std::vector<FileInfoField> out;

    auto meta = [&](const char* key, const std::string& value) {
        out.push_back({Op::MetaSet, key, value, 0.0});
    };

    if (!info.title.empty())  meta("TITLE", info.title);
    if (!info.artist.empty()) meta("ARTIST", info.artist);

    // ALBUM falls back to title so SimPlaylist's [%album artist% - %album%]
    // grouping gives each cloud track its own group.
    if (!info.album.empty()) {
        meta("ALBUM", info.album);
    } else if (!info.title.empty()) {
        meta("ALBUM", info.title);
    }

    // ALBUM ARTIST falls back to artist, then uploader.
    if (!info.artist.empty()) {
        meta("ALBUM ARTIST", info.artist);
    } else if (!info.uploader.empty()) {
        meta("ALBUM ARTIST", info.uploader);
    }

    if (!info.uploader.empty())    meta("UPLOADER", info.uploader);
    if (!info.description.empty()) meta("COMMENT", info.description);
    if (!info.uploadDate.empty())  meta("DATE", info.uploadDate);

    if (info.duration > 0) {
        out.push_back({Op::Length, "", "", info.duration});
    }

    for (const auto& tag : info.tags) {
        out.push_back({Op::MetaAdd, "GENRE", tag, 0.0});
    }

    out.push_back({Op::InfoSet, "CLOUD_SERVICE",
                   info.service == CloudService::Mixcloud ? "Mixcloud" : "SoundCloud", 0.0});
    if (!info.webURL.empty()) {
        out.push_back({Op::InfoSet, "URL", info.webURL, 0.0});
    }

    // Embedded CUE sheet for chapter navigation (empty when no chapters).
    std::string cueSheet = info.generateCueSheet();
    if (!cueSheet.empty()) {
        meta("CUESHEET", cueSheet);
    }

    return out;
}

TrackInfo TrackTagMapper::synthesizeFromURL(const std::string& internalURL) {
    TrackInfo info;
    info.internalURL = internalURL;

    ParsedCloudURL parsed = URLUtils::parseURL(internalURL);
    info.service = parsed.service;

    // Title from slug (dashes/underscores -> spaces).
    if (!parsed.slug.empty()) {
        std::string title = parsed.slug;
        for (char& c : title) {
            if (c == '-' || c == '_') c = ' ';
        }
        info.title = title;
    }

    // Username as artist.
    info.artist = parsed.username;

    return info;
}

} // namespace cloud_streamer
