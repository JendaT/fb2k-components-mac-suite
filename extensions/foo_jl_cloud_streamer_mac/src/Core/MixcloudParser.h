//
//  MixcloudParser.h
//  foo_jl_cloud_streamer_mac
//
//  Pure parsing/building of Mixcloud GraphQL API payloads. No network -
//  unit-testable standalone. MixcloudAPI handles the HTTP transport.
//

#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <optional>

namespace cloud_streamer {

// Search result track info
struct MixcloudTrackInfo {
    std::string name;
    std::string slug;
    std::string username;
    std::string displayName;
    std::string thumbnailURL;
    double duration;  // seconds

    // Computed properties
    std::string webURL() const {
        return "https://www.mixcloud.com/" + username + "/" + slug + "/";
    }

    std::string internalURL() const {
        return "mixcloud://" + username + "/" + slug;
    }
};

// Tracklist section (individual track in a mix)
struct MixcloudSection {
    double startSeconds;
    std::string songName;
    std::string artistName;
};

// Tracklist result
struct MixcloudTracklistResult {
    bool success;
    std::string errorMessage;
    std::string cloudcastName;     // Name of the mix
    std::string uploaderName;      // Display name of uploader
    std::vector<MixcloudSection> sections;
};

class MixcloudParser {
public:
    // Build the URL-encoded GraphQL search query string (goes after "?query=").
    static std::string buildSearchQuery(const std::string& term, int maxResults);

    // Build the JSON POST body for a cloudcast tracklist lookup.
    static std::string buildTracklistQuery(const std::string& username,
                                           const std::string& slug);

    // Parse a search response. Returns nullopt on malformed JSON or GraphQL
    // errors. Entries missing name, slug, or username are dropped.
    static std::optional<std::vector<MixcloudTrackInfo>> parseSearchResponse(NSData* data);

    // Parse a tracklist response. Sections without a songName (non-track
    // sections) are skipped. On failure returns success=false with a message.
    static MixcloudTracklistResult parseTracklistResponse(NSData* data);
};

} // namespace cloud_streamer
