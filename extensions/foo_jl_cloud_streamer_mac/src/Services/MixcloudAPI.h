//
//  MixcloudAPI.h
//  foo_jl_cloud_streamer_mac
//
//  Direct Mixcloud GraphQL API wrapper for search functionality.
//  yt-dlp doesn't support Mixcloud search, so we implement it natively.
//

#pragma once

#import <Foundation/Foundation.h>
#include "../Core/MixcloudParser.h"
#include <string>
#include <vector>
#include <atomic>
#include <optional>

namespace cloud_streamer {

// MixcloudTrackInfo, MixcloudSection, and MixcloudTracklistResult are
// defined in Core/MixcloudParser.h

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

    // Fetch tracklist (sections) for a cloudcast
    // username: Mixcloud username
    // slug: cloudcast slug
    // abortFlag: optional atomic flag for cancellation
    MixcloudTracklistResult fetchTracklist(
        const std::string& username,
        const std::string& slug,
        std::atomic<bool>* abortFlag = nullptr
    );

private:
    MixcloudAPI() = default;
    ~MixcloudAPI() = default;
    MixcloudAPI(const MixcloudAPI&) = delete;
    MixcloudAPI& operator=(const MixcloudAPI&) = delete;

    static constexpr const char* kGraphQLEndpoint = "https://app.mixcloud.com/graphql";
    static constexpr const char* kUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
};

} // namespace cloud_streamer
