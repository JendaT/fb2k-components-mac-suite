//
//  MixcloudAPI.h
//  foo_jl_cloud_streamer_mac
//
//  Direct Mixcloud GraphQL API wrapper for search functionality.
//  yt-dlp doesn't support Mixcloud search, so we implement it natively.
//

#pragma once

#import <Foundation/Foundation.h>
#include <string>
#include <vector>
#include <atomic>
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

// Search result
struct MixcloudSearchResult {
    bool success;
    std::string errorMessage;
    std::vector<MixcloudTrackInfo> tracks;
};

// Mixcloud GraphQL API wrapper
class MixcloudAPI {
public:
    static MixcloudAPI& shared();

    // Search for cloudcasts (DJ sets/mixes)
    // Query: search term
    // maxResults: maximum number of results (default 50)
    // abortFlag: optional atomic flag for cancellation
    MixcloudSearchResult search(
        const std::string& query,
        int maxResults = 50,
        std::atomic<bool>* abortFlag = nullptr
    );

private:
    MixcloudAPI() = default;
    ~MixcloudAPI() = default;
    MixcloudAPI(const MixcloudAPI&) = delete;
    MixcloudAPI& operator=(const MixcloudAPI&) = delete;

    // Build GraphQL search query
    std::string buildSearchQuery(const std::string& term, int maxResults);

    // Parse search response JSON
    std::optional<std::vector<MixcloudTrackInfo>> parseSearchResponse(NSData* data);

    static constexpr const char* kGraphQLEndpoint = "https://app.mixcloud.com/graphql";
    static constexpr const char* kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
};

} // namespace cloud_streamer
