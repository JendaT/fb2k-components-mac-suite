//
//  YtDlpParser.mm
//  foo_jl_cloud_streamer_mac
//
//  Pure parsing of yt-dlp output. Extracted from YtDlpWrapper so the parsing
//  logic is unit-testable without spawning a subprocess.
//

#import <Foundation/Foundation.h>
#include "YtDlpParser.h"
#include "URLUtils.h"

namespace cloud_streamer {

std::optional<TrackInfo> YtDlpParser::parseMetadataJSON(const std::string& json,
                                                        const std::string& originalURL) {
    @autoreleasepool {
        NSData* jsonData = [[NSString stringWithUTF8String:json.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) {
            return std::nullopt;
        }

        NSError* error = nil;
        NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
            return std::nullopt;
        }

        TrackInfo info;
        info.internalURL = originalURL;

        // Parse common fields
        if (NSString* title = dict[@"title"]) {
            info.title = [title UTF8String] ?: "";
        }
        if (NSString* uploader = dict[@"uploader"]) {
            info.uploader = [uploader UTF8String] ?: "";
        }
        if (NSString* artist = dict[@"artist"]) {
            info.artist = [artist UTF8String] ?: "";
        }
        if (NSString* album = dict[@"album"]) {
            info.album = [album UTF8String] ?: "";
        }
        if (NSString* description = dict[@"description"]) {
            info.description = [description UTF8String] ?: "";
        }

        // Duration
        if (NSNumber* duration = dict[@"duration"]) {
            info.duration = [duration doubleValue];
        }

        // Thumbnail
        if (NSString* thumbnail = dict[@"thumbnail"]) {
            info.thumbnailURL = [thumbnail UTF8String] ?: "";
        }

        // Upload date
        if (NSString* uploadDate = dict[@"upload_date"]) {
            info.uploadDate = [uploadDate UTF8String] ?: "";
        }

        // Tags
        if (NSArray* tags = dict[@"tags"]) {
            for (NSString* tag in tags) {
                if ([tag isKindOfClass:[NSString class]]) {
                    info.tags.push_back([tag UTF8String] ?: "");
                }
            }
        }

        // Web URL
        if (NSString* webpageUrl = dict[@"webpage_url"]) {
            info.webURL = [webpageUrl UTF8String] ?: "";
        }

        // Parse chapters/tracklist
        NSArray* chapters = dict[@"chapters"];
        if ([chapters isKindOfClass:[NSArray class]] && chapters.count > 0) {
            for (NSDictionary* chapterDict in chapters) {
                if (![chapterDict isKindOfClass:[NSDictionary class]]) continue;

                Chapter chapter;

                if (NSString* title = chapterDict[@"title"]) {
                    chapter.title = [title UTF8String] ?: "";
                }

                if (NSNumber* startTime = chapterDict[@"start_time"]) {
                    chapter.startTime = [startTime doubleValue];
                }

                if (NSNumber* endTime = chapterDict[@"end_time"]) {
                    chapter.endTime = [endTime doubleValue];
                }

                // Some extractors put artist in a separate field
                if (NSString* artist = chapterDict[@"artist"]) {
                    chapter.artist = [artist UTF8String] ?: "";
                }

                if (!chapter.title.empty()) {
                    info.chapters.push_back(chapter);
                }
            }
        }

        // Extract stream URL from formats array
        // Prefer HTTP format (direct download) over HLS/DASH
        NSArray* formats = dict[@"formats"];
        if ([formats isKindOfClass:[NSArray class]] && formats.count > 0) {
            // Look for HTTP format first (format_id == "http")
            for (NSDictionary* format in formats) {
                if ([format isKindOfClass:[NSDictionary class]]) {
                    NSString* formatId = format[@"format_id"];
                    if ([formatId isEqualToString:@"http"]) {
                        NSString* url = format[@"url"];
                        if (url && [url isKindOfClass:[NSString class]] && url.length > 0) {
                            info.streamURL = [url UTF8String];
                            break;
                        }
                    }
                }
            }

            // If no HTTP format found, use first format with a URL
            if (info.streamURL.empty()) {
                for (NSDictionary* format in formats) {
                    if ([format isKindOfClass:[NSDictionary class]]) {
                        NSString* url = format[@"url"];
                        if (url && [url isKindOfClass:[NSString class]] && url.length > 0) {
                            info.streamURL = [url UTF8String];
                            break;
                        }
                    }
                }
            }
        }

        // Also check for top-level "url" field (simpler extractors)
        if (info.streamURL.empty()) {
            if (NSString* directUrl = dict[@"url"]) {
                if ([directUrl isKindOfClass:[NSString class]] && directUrl.length > 0) {
                    info.streamURL = [directUrl UTF8String];
                }
            }
        }

        // Determine service
        info.service = URLUtils::getService(originalURL);

        // If artist is empty, use uploader
        if (info.artist.empty() && !info.uploader.empty()) {
            info.artist = info.uploader;
        }

        return info;
    }
}

std::vector<YtDlpTrackInfo> YtDlpParser::parseSearchJSON(const std::string& json) {
    std::vector<YtDlpTrackInfo> entries;

    @autoreleasepool {
        NSData* jsonData = [[NSString stringWithUTF8String:json.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) {
            return entries;
        }

        NSError* error = nil;
        NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
            return entries;
        }

        NSArray* entriesArray = dict[@"entries"];
        if (![entriesArray isKindOfClass:[NSArray class]]) {
            return entries;
        }

        for (NSDictionary* entryDict in entriesArray) {
            if (![entryDict isKindOfClass:[NSDictionary class]]) {
                continue;
            }

            YtDlpTrackInfo info;

            // Title
            if (NSString* title = entryDict[@"title"]) {
                if ([title isKindOfClass:[NSString class]]) {
                    info.title = [title UTF8String] ?: "";
                }
            }

            // Uploader (artist)
            if (NSString* uploader = entryDict[@"uploader"]) {
                if ([uploader isKindOfClass:[NSString class]]) {
                    info.uploader = [uploader UTF8String] ?: "";
                }
            }

            // Web URL - prefer webpage_url (actual web page) over url (API endpoint)
            if (NSString* webpageUrl = entryDict[@"webpage_url"]) {
                if ([webpageUrl isKindOfClass:[NSString class]]) {
                    info.webpageUrl = [webpageUrl UTF8String] ?: "";
                }
            }
            // Fallback to url if webpage_url empty
            if (info.webpageUrl.empty()) {
                if (NSString* url = entryDict[@"url"]) {
                    if ([url isKindOfClass:[NSString class]]) {
                        info.webpageUrl = [url UTF8String] ?: "";
                    }
                }
            }

            // Track ID
            if (NSString* trackId = entryDict[@"id"]) {
                if ([trackId isKindOfClass:[NSString class]]) {
                    info.trackId = [trackId UTF8String] ?: "";
                }
            }

            // Duration
            if (NSNumber* duration = entryDict[@"duration"]) {
                if ([duration isKindOfClass:[NSNumber class]]) {
                    info.duration = [duration doubleValue];
                }
            }

            // Thumbnail - prefer "large" (100x100) or "t67x67" for table view
            NSArray* thumbnails = entryDict[@"thumbnails"];
            if ([thumbnails isKindOfClass:[NSArray class]]) {
                // Look for preferred sizes in order
                NSArray* preferredSizes = @[@"large", @"t67x67", @"small", @"badge"];
                for (NSString* preferredId in preferredSizes) {
                    for (NSDictionary* thumb in thumbnails) {
                        if ([thumb isKindOfClass:[NSDictionary class]]) {
                            NSString* thumbId = thumb[@"id"];
                            if ([thumbId isKindOfClass:[NSString class]] &&
                                [thumbId isEqualToString:preferredId]) {
                                NSString* thumbUrl = thumb[@"url"];
                                if ([thumbUrl isKindOfClass:[NSString class]]) {
                                    info.thumbnailUrl = [thumbUrl UTF8String] ?: "";
                                    break;
                                }
                            }
                        }
                    }
                    if (!info.thumbnailUrl.empty()) break;
                }
                // Fallback to first thumbnail with a URL
                if (info.thumbnailUrl.empty()) {
                    for (NSDictionary* thumb in thumbnails) {
                        if ([thumb isKindOfClass:[NSDictionary class]]) {
                            NSString* thumbUrl = thumb[@"url"];
                            if ([thumbUrl isKindOfClass:[NSString class]] && thumbUrl.length > 0) {
                                info.thumbnailUrl = [thumbUrl UTF8String] ?: "";
                                break;
                            }
                        }
                    }
                }
            }

            // Only add entries with at least a title and URL
            if (!info.title.empty() && !info.webpageUrl.empty()) {
                entries.push_back(info);
            }
        }
    }

    return entries;
}

JLCloudError YtDlpParser::parseErrorOutput(const std::string& errorOutput) {
    if (errorOutput.empty()) {
        return JLCloudError::None;
    }

    // Check for common error patterns. Specific patterns first: yt-dlp's
    // "Requested format is not available" would otherwise be swallowed by
    // the broad "not available" check below.
    if (errorOutput.find("no suitable format") != std::string::npos ||
        errorOutput.find("Requested format") != std::string::npos) {
        return JLCloudError::FormatNotFound;
    }

    if (errorOutput.find("This video is not available") != std::string::npos ||
        errorOutput.find("Video unavailable") != std::string::npos ||
        errorOutput.find("not available") != std::string::npos) {
        return JLCloudError::TrackUnavailable;
    }

    if (errorOutput.find("geo") != std::string::npos ||
        errorOutput.find("country") != std::string::npos ||
        errorOutput.find("region") != std::string::npos) {
        return JLCloudError::GeoRestricted;
    }

    if (errorOutput.find("403") != std::string::npos) {
        return JLCloudError::StreamExpired;
    }

    if (errorOutput.find("login") != std::string::npos ||
        errorOutput.find("sign in") != std::string::npos ||
        errorOutput.find("authentication") != std::string::npos) {
        return JLCloudError::AuthRequired;
    }

    if (errorOutput.find("rate limit") != std::string::npos ||
        errorOutput.find("too many") != std::string::npos) {
        return JLCloudError::RateLimited;
    }

    if (errorOutput.find("Unsupported URL") != std::string::npos) {
        return JLCloudError::UnsupportedURL;
    }

    return JLCloudError::YtDlpFailed;
}

} // namespace cloud_streamer
