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
    std::string encodedQuery = MixcloudParser::buildSearchQuery(query, maxResults);
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
    auto tracks = MixcloudParser::parseSearchResponse(responseData);
    if (!tracks.has_value()) {
        result.errorMessage = "Failed to parse search response";
        return result;
    }

    result.success = true;
    result.tracks = std::move(tracks.value());
    return result;
}

MixcloudTracklistResult MixcloudAPI::fetchTracklist(
    const std::string& username,
    const std::string& slug,
    std::atomic<bool>* abortFlag
) {
    MixcloudTracklistResult result;
    result.success = false;

    if (username.empty() || slug.empty()) {
        result.errorMessage = "Empty username or slug";
        return result;
    }

    // Check abort before starting
    if (abortFlag && abortFlag->load()) {
        result.errorMessage = "Fetch cancelled";
        return result;
    }

    // Build GraphQL query for tracklist
    std::string queryBody = MixcloudParser::buildTracklistQuery(username, slug);
    NSString* query = [NSString stringWithUTF8String:queryBody.c_str()];

    NSURL* url = [NSURL URLWithString:@(kGraphQLEndpoint)];
    if (!url) {
        result.errorMessage = "Failed to build request URL";
        return result;
    }

    // Create POST request with JSON body
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@(kUserAgent) forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.mixcloud.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.mixcloud.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:[query dataUsingEncoding:NSUTF8StringEncoding]];
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
            result.errorMessage = "Fetch cancelled";
            return result;
        }
    }

    // Check for errors
    if (requestError) {
        if (requestError.code == NSURLErrorCancelled) {
            result.errorMessage = "Fetch cancelled";
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
    return MixcloudParser::parseTracklistResponse(responseData);
}

} // namespace cloud_streamer
