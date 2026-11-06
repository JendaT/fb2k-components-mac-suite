//
//  MixcloudParser.mm
//  foo_jl_cloud_streamer_mac
//
//  Pure parsing/building of Mixcloud GraphQL API payloads. Extracted from
//  MixcloudAPI so the parsing logic is unit-testable without network access.
//

#import "MixcloudParser.h"

namespace cloud_streamer {

std::string MixcloudParser::buildSearchQuery(const std::string& term, int maxResults) {
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

std::string MixcloudParser::buildTracklistQuery(const std::string& username,
                                                const std::string& slug) {
    // GraphQL query for tracklist lookup, sent as a JSON POST body.
    // Uses cloudcastLookup and inline fragments for TrackSection.
    NSString* queryTemplate = @"{\"query\":\"{cloudcastLookup(lookup:{username:\\\"%@\\\",slug:\\\"%@\\\"}){name owner{displayName} sections{... on TrackSection{startSeconds songName artistName}}}}\"}";
    NSString* query = [NSString stringWithFormat:queryTemplate,
        [NSString stringWithUTF8String:username.c_str()],
        [NSString stringWithUTF8String:slug.c_str()]];

    return [query UTF8String] ?: "";
}

std::optional<std::vector<MixcloudTrackInfo>> MixcloudParser::parseSearchResponse(NSData* data) {
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

MixcloudTracklistResult MixcloudParser::parseTracklistResponse(NSData* data) {
    MixcloudTracklistResult result;
    result.success = false;

    if (!data) {
        result.errorMessage = "Empty response";
        return result;
    }

    NSError* jsonError = nil;
    NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        result.errorMessage = "Failed to parse JSON response";
        return result;
    }

    // Check for GraphQL errors
    if (json[@"errors"]) {
        result.errorMessage = "GraphQL error";
        return result;
    }

    // Navigate: data -> cloudcastLookup
    NSDictionary* cloudcast = json[@"data"][@"cloudcastLookup"];
    if (![cloudcast isKindOfClass:[NSDictionary class]]) {
        result.errorMessage = "Cloudcast not found";
        return result;
    }

    // Extract cloudcast name
    NSString* name = cloudcast[@"name"];
    if ([name isKindOfClass:[NSString class]]) {
        result.cloudcastName = [name UTF8String] ?: "";
    }

    // Extract owner display name
    NSDictionary* owner = cloudcast[@"owner"];
    if ([owner isKindOfClass:[NSDictionary class]]) {
        NSString* displayName = owner[@"displayName"];
        if ([displayName isKindOfClass:[NSString class]]) {
            result.uploaderName = [displayName UTF8String] ?: "";
        }
    }

    // Parse sections (tracklist)
    NSArray* sections = cloudcast[@"sections"];
    if ([sections isKindOfClass:[NSArray class]]) {
        for (NSDictionary* sectionDict in sections) {
            if (![sectionDict isKindOfClass:[NSDictionary class]]) continue;

            // Only process TrackSection entries (they have songName)
            NSString* songName = sectionDict[@"songName"];
            if (![songName isKindOfClass:[NSString class]] || songName.length == 0) {
                continue;
            }

            MixcloudSection section;
            section.songName = [songName UTF8String] ?: "";

            NSNumber* startSeconds = sectionDict[@"startSeconds"];
            if ([startSeconds isKindOfClass:[NSNumber class]]) {
                section.startSeconds = [startSeconds doubleValue];
            }

            NSString* artistName = sectionDict[@"artistName"];
            if ([artistName isKindOfClass:[NSString class]]) {
                section.artistName = [artistName UTF8String] ?: "";
            }

            result.sections.push_back(std::move(section));
        }
    }

    result.success = true;
    return result;
}

} // namespace cloud_streamer
