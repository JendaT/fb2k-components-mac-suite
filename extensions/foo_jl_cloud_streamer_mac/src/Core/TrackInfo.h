//
//  TrackInfo.h
//  foo_jl_cloud_streamer_mac
//
//  Track metadata structure for cloud content
//

#pragma once

#include <string>
#include <optional>
#include <chrono>
#include <vector>
#include "URLUtils.h"

namespace cloud_streamer {

// Represents a chapter/track within a mix
struct Chapter {
    std::string title;
    std::string artist;     // May be empty
    double startTime = 0.0; // Start time in seconds
    double endTime = 0.0;   // End time in seconds (0 = until next chapter or end)
};

// Represents metadata for a cloud track
struct TrackInfo {
    // Identification
    std::string internalURL;        // mixcloud://user/track or soundcloud://user/track
    std::string webURL;             // Original web URL
    CloudService service = CloudService::Unknown;

    // Basic metadata
    std::string title;
    std::string artist;
    std::string album;              // Usually the show/set name for Mixcloud
    std::string uploader;           // Username of uploader
    std::string description;

    // Duration in seconds (0 if unknown)
    double duration = 0.0;

    // Artwork
    std::string thumbnailURL;       // URL to album art

    // Genre/tags
    std::vector<std::string> tags;

    // Timestamps
    std::string uploadDate;         // YYYYMMDD format from yt-dlp

    // Chapters/tracklist (from yt-dlp chapters or Mixcloud sections)
    std::vector<Chapter> chapters;

    // Stream URL (resolved, cached)
    std::string streamURL;
    std::chrono::system_clock::time_point streamURLExpiry;

    // Check if stream URL is still valid
    bool isStreamURLValid() const {
        if (streamURL.empty()) return false;
        return std::chrono::system_clock::now() < streamURLExpiry;
    }

    // Clear expired stream URL
    void clearStreamURLIfExpired() {
        if (!isStreamURLValid()) {
            streamURL.clear();
        }
    }

    // Get display title (for playlist)
    std::string getDisplayTitle() const {
        if (!title.empty()) {
            return title;
        }
        // Fallback to URL-based title
        ParsedCloudURL parsed = URLUtils::parseURL(internalURL);
        if (!parsed.slug.empty()) {
            // Replace dashes/underscores with spaces
            std::string result = parsed.slug;
            for (char& c : result) {
                if (c == '-' || c == '_') c = ' ';
            }
            return result;
        }
        return internalURL;
    }

    // Get display artist
    std::string getDisplayArtist() const {
        if (!artist.empty()) {
            return artist;
        }
        if (!uploader.empty()) {
            return uploader;
        }
        // Fallback to username from URL
        ParsedCloudURL parsed = URLUtils::parseURL(internalURL);
        return parsed.username;
    }

    // Generate embedded CUE sheet for chapters
    // Returns empty string if no chapters
    std::string generateCueSheet() const {
        if (chapters.empty()) {
            return "";
        }

        std::string cue;

        // CUE header
        if (!title.empty()) {
            cue += "TITLE \"" + escapeQuotes(title) + "\"\n";
        }
        if (!getDisplayArtist().empty()) {
            cue += "PERFORMER \"" + escapeQuotes(getDisplayArtist()) + "\"\n";
        }

        // Single FILE entry for the whole stream
        cue += "FILE \"stream\" WAVE\n";

        // Generate TRACK entries
        int trackNum = 1;
        for (const auto& chapter : chapters) {
            cue += "  TRACK " + (trackNum < 10 ? "0" : "") + std::to_string(trackNum) + " AUDIO\n";

            if (!chapter.title.empty()) {
                cue += "    TITLE \"" + escapeQuotes(chapter.title) + "\"\n";
            }
            if (!chapter.artist.empty()) {
                cue += "    PERFORMER \"" + escapeQuotes(chapter.artist) + "\"\n";
            }

            // Convert seconds to MM:SS:FF (frames = 1/75th of a second)
            int totalSeconds = static_cast<int>(chapter.startTime);
            int minutes = totalSeconds / 60;
            int seconds = totalSeconds % 60;
            int frames = static_cast<int>((chapter.startTime - totalSeconds) * 75);

            cue += "    INDEX 01 " +
                   (minutes < 10 ? "0" : "") + std::to_string(minutes) + ":" +
                   (seconds < 10 ? "0" : "") + std::to_string(seconds) + ":" +
                   (frames < 10 ? "0" : "") + std::to_string(frames) + "\n";

            trackNum++;
        }

        return cue;
    }

private:
    static std::string escapeQuotes(const std::string& s) {
        std::string result;
        for (char c : s) {
            if (c == '"') {
                result += "\\\"";
            } else {
                result += c;
            }
        }
        return result;
    }
};

// Format option strings for yt-dlp
namespace FormatStrings {
    // Mixcloud
    constexpr const char* kMixcloudHTTP = "http";
    constexpr const char* kMixcloudHLS = "hls";

    // SoundCloud
    constexpr const char* kSoundCloudHLS_AAC = "hls_aac_160k";
    constexpr const char* kSoundCloudHTTP_MP3 = "http_mp3_1_0";

    // Get yt-dlp format string for service/preference
    inline const char* getFormatString(CloudService service, int formatPref) {
        switch (service) {
            case CloudService::Mixcloud:
                return (formatPref == 1) ? kMixcloudHLS : kMixcloudHTTP;
            case CloudService::SoundCloud:
                return (formatPref == 1) ? kSoundCloudHTTP_MP3 : kSoundCloudHLS_AAC;
            default:
                return "best";
        }
    }
}

} // namespace cloud_streamer
