//
//  MixcloudAPI.mm
//  foo_jl_cloud_streamer_mac
//
//  Direct Mixcloud GraphQL API wrapper implementation
//

#import "MixcloudAPI.h"
#import <dispatch/dispatch.h>

namespace cloud_streamer {

MixcloudAPI& MixcloudAPI::shared() {
    static MixcloudAPI instance;
    return instance;
}

std::string MixcloudAPI::buildSearchQuery(const std::string& term, int maxResults) {
    // GraphQL query for searching cloudcasts
    // The query structure discovered via API introspection:
    // viewer { search { searchQuery(term:) { cloudcasts(first:) { edges { node { ... } } } } } }

    NSString* escapedTerm = [[NSString stringWithUTF8String:term.c_str()]
        stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    // Build the query - need to escape quotes for URL encoding
    NSString* query = [NSString stringWithFormat:
        @"{viewer{search{searchQuery(term:\"%@\"){cloudcasts(first:%d){edges{node{"
        @"name slug audioLength "
        @"owner{username displayName} "
        @"picture(width:200,height:200){url}"
        @"}}}}}}}",
        escapedTerm, maxResults];

    // URL encode the query
    NSString* encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLQueryAllowedCharacterSet]];

    return [encodedQuery UTF8String] ?: "";
}

std::optional<std::vector<MixcloudTrackInfo>> MixcloudAPI::parseSearchResponse(NSData* data) {
    if (!data) {
        return std::nullopt;
    }

    NSError* jsonError = nil;
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        return std::nullopt;
    }

    // Check for errors
    if (json[@"errors"]) {
        return std::nullopt;
    }

    // Navigate: data -> viewer -> search -> searchQuery -> cloudcasts -> edges
    NSDictionary* viewer = json[@"data"][@"viewer"];
    if (![viewer isKindOfClass:[NSDictionary class]]) {
        return std::nullopt;
    }

    NSDictionary* search = viewer[@"search"];
    if (![search isKindOfClass:[NSDictionary class]]) {
        return std::nullopt;
    }

    NSDictionary* searchQuery = search[@"searchQuery"];
    if (![searchQuery isKindOfClass:[NSDictionary class]]) {
        return std::nullopt;
    }

    NSDictionary* cloudcasts = searchQuery[@"cloudcasts"];
    if (![cloudcasts isKindOfClass:[NSDictionary class]]) {
        return std::nullopt;
    }

    NSArray* edges = cloudcasts[@"edges"];
    if (![edges isKindOfClass:[NSArray class]]) {
        return std::nullopt;
    }

    std::vector<MixcloudTrackInfo> tracks;
    tracks.reserve(edges.count);

    for (NSDictionary* edge in edges) {
        if (![edge isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary* node = edge[@"node"];
        if (![node isKindOfClass:[NSDictionary class]]) continue;

        MixcloudTrackInfo info;

        // Name
        NSString* name = node[@"name"];
        if ([name isKindOfClass:[NSString class]]) {
            info.name = [name UTF8String] ?: "";
        }

        // Slug
        NSString* slug = node[@"slug"];
        if ([slug isKindOfClass:[NSString class]]) {
            info.slug = [slug UTF8String] ?: "";
        }

        // Duration (audioLength is in seconds)
        NSNumber* audioLength = node[@"audioLength"];
        if ([audioLength isKindOfClass:[NSNumber class]]) {
            info.duration = [audioLength doubleValue];
        }

        // Owner
        NSDictionary* owner = node[@"owner"];
        if ([owner isKindOfClass:[NSDictionary class]]) {
            NSString* username = owner[@"username"];
            if ([username isKindOfClass:[NSString class]]) {
                info.username = [username UTF8String] ?: "";
            }

            NSString* displayName = owner[@"displayName"];
            if ([displayName isKindOfClass:[NSString class]]) {
                info.displayName = [displayName UTF8String] ?: "";
            }
        }

        // Thumbnail
        NSDictionary* picture = node[@"picture"];
        if ([picture isKindOfClass:[NSDictionary class]]) {
            NSString* url = picture[@"url"];
            if ([url isKindOfClass:[NSString class]]) {
                info.thumbnailURL = [url UTF8String] ?: "";
            }
        }

        // Only add if we have minimum required data
        if (!info.name.empty() && !info.slug.empty() && !info.username.empty()) {
            tracks.push_back(std::move(info));
        }
    }

    return tracks;
}

MixcloudSearchResult MixcloudAPI::search(
    const std::string& query,
    int maxResults,
    std::atomic<bool>* abortFlag
) {
    MixcloudSearchResult result;
    result.success = false;

    if (query.empty()) {
        result.errorMessage = "Empty search query";
        return result;
    }

    // Check abort before starting
    if (abortFlag && abortFlag->load()) {
        result.errorMessage = "Search cancelled";
        return result;
    }

    // Build URL with query
    std::string encodedQuery = buildSearchQuery(query, maxResults);
    NSString* urlString = [NSString stringWithFormat:@"%s?query=%s",
        kGraphQLEndpoint, encodedQuery.c_str()];

    NSURL* url = [NSURL URLWithString:urlString];
    if (!url) {
        result.errorMessage = "Failed to build request URL";
        return result;
    }

    // Create request
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@(kUserAgent) forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.mixcloud.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.mixcloud.com/" forHTTPHeaderField:@"Referer"];
    [request setTimeoutInterval:30.0];

    // Synchronous request using semaphore
    __block NSData* responseData = nil;
    __block NSError* requestError = nil;
    __block NSInteger statusCode = 0;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    NSURLSessionDataTask* task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            responseData = data;
            requestError = error;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                statusCode = [(NSHTTPURLResponse*)response statusCode];
            }
            dispatch_semaphore_signal(semaphore);
        }];

    [task resume];

    // Wait with periodic abort checks
    while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (abortFlag && abortFlag->load()) {
            [task cancel];
            result.errorMessage = "Search cancelled";
            return result;
        }
    }

    // Check for errors
    if (requestError) {
        if (requestError.code == NSURLErrorCancelled) {
            result.errorMessage = "Search cancelled";
        } else {
            result.errorMessage = [[requestError localizedDescription] UTF8String] ?: "Request failed";
        }
        return result;
    }

    if (statusCode != 200) {
        result.errorMessage = "HTTP error: " + std::to_string(statusCode);
        return result;
    }

    // Parse response
    auto tracks = parseSearchResponse(responseData);
    if (!tracks.has_value()) {
        result.errorMessage = "Failed to parse search response";
        return result;
    }

    result.success = true;
    result.tracks = std::move(tracks.value());
    return result;
}

} // namespace cloud_streamer
