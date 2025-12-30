//
//  YtDlpWrapper.mm
//  foo_jl_cloud_streamer_mac
//
//  yt-dlp subprocess wrapper with abort support and security validation
//

#import <Foundation/Foundation.h>
#include "YtDlpWrapper.h"
#include "../Core/CloudConfig.h"
#include <dispatch/dispatch.h>
#include <regex>

namespace cloud_streamer {

YtDlpWrapper& YtDlpWrapper::shared() {
    static YtDlpWrapper instance;
    return instance;
}

YtDlpWrapper::YtDlpWrapper() {
    // Try to load configured path
    std::string path = CloudConfig::getYtDlpPath();
    if (!path.empty()) {
        validateBinary(path);
    }
}

YtDlpWrapper::~YtDlpWrapper() = default;

bool YtDlpWrapper::isValidYtDlpBinary(const std::string& path) {
    @autoreleasepool {
        // Security check 1: Must be absolute path
        if (path.empty() || path[0] != '/') {
            logDebug("yt-dlp path is not absolute");
            return false;
        }

        // Security check 2: Must be in allowed directory
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        NSArray<NSString*>* allowedPrefixes = @[
            @"/opt/homebrew/bin/",
            @"/usr/local/bin/",
            @"/opt/local/bin/"  // MacPorts
        ];

        BOOL inAllowedDir = NO;
        for (NSString* prefix in allowedPrefixes) {
            if ([nsPath hasPrefix:prefix]) {
                inAllowedDir = YES;
                break;
            }
        }

        if (!inAllowedDir) {
            logDebug("yt-dlp path not in allowed directory");
            return false;
        }

        // Security check 3: Must exist and be executable
        NSFileManager* fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:nsPath isDirectory:&isDir] || isDir) {
            logDebug("yt-dlp path does not exist");
            return false;
        }

        if (![fm isExecutableFileAtPath:nsPath]) {
            logDebug("yt-dlp is not executable");
            return false;
        }

        return YES;
    }
}

bool YtDlpWrapper::validateBinary(const std::string& path) {
    @autoreleasepool {
        if (!isValidYtDlpBinary(path)) {
            m_pathValidated = false;
            m_validatedPath.clear();
            return false;
        }

        // Security check 4: Run --version and verify output format (YYYY.MM.DD)
        NSTask* task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        task.arguments = @[@"--version"];

        NSPipe* outputPipe = [NSPipe pipe];
        task.standardOutput = outputPipe;
        task.standardError = [NSPipe pipe];

        NSError* error = nil;
        if (![task launchAndReturnError:&error]) {
            logDebug("Failed to launch yt-dlp for version check");
            m_pathValidated = false;
            return false;
        }

        // Wait for completion with timeout
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        task.terminationHandler = ^(NSTask* t) {
            dispatch_semaphore_signal(semaphore);
        };

        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
        if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
            // Timeout - terminate and wait for cleanup
            [task terminate];
            dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
            logDebug("yt-dlp version check timed out");
            m_pathValidated = false;
            return false;
        }

        if (task.terminationStatus != 0) {
            logDebug("yt-dlp version check failed with non-zero exit");
            m_pathValidated = false;
            return false;
        }

        // Read version output
        NSData* outputData = [outputPipe.fileHandleForReading readDataToEndOfFile];
        NSString* versionOutput = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

        // Verify version format: YYYY.MM.DD (possibly with suffix like -nightly)
        std::string version = [versionOutput UTF8String] ?: "";
        std::regex versionRegex(R"(^\d{4}\.\d{2}\.\d{2})");
        if (!std::regex_search(version, versionRegex)) {
            logDebug("yt-dlp version output doesn't match expected format");
            m_pathValidated = false;
            return false;
        }

        logDebug(std::string("yt-dlp validated: ") + version);
        m_validatedPath = path;
        m_pathValidated = true;
        return true;
    }
}

bool YtDlpWrapper::isAvailable() {
    if (m_pathValidated && !m_validatedPath.empty()) {
        return true;
    }

    // Try to validate from config
    std::string path = CloudConfig::getYtDlpPath();
    if (!path.empty()) {
        return validateBinary(path);
    }

    return false;
}

std::string YtDlpWrapper::getYtDlpPath() const {
    return m_validatedPath;
}

bool YtDlpWrapper::setYtDlpPath(const std::string& path) {
    if (validateBinary(path)) {
        CloudConfig::setYtDlpPath(path);
        return true;
    }
    return false;
}

void YtDlpWrapper::clearPath() {
    m_validatedPath.clear();
    m_pathValidated = false;
}

YtDlpResult YtDlpWrapper::extractStreamURL(
    const std::string& cloudURL,
    const std::string& formatSpec,
    std::atomic<bool>* abortFlag,
    int timeoutSeconds
) {
    // Convert internal URL to web URL
    std::string webURL = URLUtils::internalSchemeToWebURL(cloudURL);
    if (webURL.empty()) {
        webURL = cloudURL;  // Already a web URL
    }

    std::vector<std::string> args;
    args.push_back("-g");  // Get URL only
    args.push_back("--no-playlist");
    args.push_back("--no-warnings");

    if (!formatSpec.empty()) {
        args.push_back("-f");
        args.push_back(formatSpec);
    }

    args.push_back(webURL);

    return execute(args, YtDlpOperation::ExtractStreamURL, abortFlag, timeoutSeconds);
}

YtDlpResult YtDlpWrapper::extractMetadata(
    const std::string& cloudURL,
    std::atomic<bool>* abortFlag,
    int timeoutSeconds
) {
    // Convert internal URL to web URL
    std::string webURL = URLUtils::internalSchemeToWebURL(cloudURL);
    if (webURL.empty()) {
        webURL = cloudURL;
    }

    std::vector<std::string> args;
    args.push_back("-j");  // JSON output
    args.push_back("--no-playlist");
    args.push_back("--no-download");
    args.push_back("--no-warnings");
    args.push_back(webURL);

    YtDlpResult result = execute(args, YtDlpOperation::ExtractMetadata, abortFlag, timeoutSeconds);

    if (result.success && !result.streamURL.empty()) {
        // streamURL contains JSON in this case
        result.trackInfo = parseMetadataJSON(result.streamURL, cloudURL);
        // Get stream URL from parsed trackInfo
        if (result.trackInfo.has_value() && !result.trackInfo->streamURL.empty()) {
            result.streamURL = result.trackInfo->streamURL;
            logDebug("Extracted stream URL: " + result.streamURL.substr(0, 80) + "...");
        } else {
            result.streamURL.clear();
            logDebug("No stream URL found in metadata");
        }
    }

    return result;
}

YtDlpResult YtDlpWrapper::execute(
    const std::vector<std::string>& arguments,
    YtDlpOperation operation,
    std::atomic<bool>* abortFlag,
    int timeoutSeconds
) {
    @autoreleasepool {
        YtDlpResult result;

        if (!isAvailable()) {
            result.error = JLCloudError::YtDlpNotFound;
            result.errorMessage = "yt-dlp not available";
            return result;
        }

        // Check abort before starting
        if (abortFlag && abortFlag->load()) {
            result.error = JLCloudError::Cancelled;
            result.errorMessage = "Operation cancelled";
            return result;
        }

        NSTask* task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:m_validatedPath.c_str()]];

        NSMutableArray<NSString*>* nsArgs = [NSMutableArray array];
        for (const auto& arg : arguments) {
            [nsArgs addObject:[NSString stringWithUTF8String:arg.c_str()]];
        }
        task.arguments = nsArgs;

        NSPipe* outputPipe = [NSPipe pipe];
        NSPipe* errorPipe = [NSPipe pipe];
        task.standardOutput = outputPipe;
        task.standardError = errorPipe;

        // Set up async reading to prevent pipe buffer deadlock
        // (yt-dlp blocks if pipe fills before we read)
        __block NSMutableData* outputData = [NSMutableData data];
        __block NSMutableData* errorData = [NSMutableData data];
        dispatch_semaphore_t readSemaphore = dispatch_semaphore_create(0);
        __block int readCount = 0;

        NSFileHandle* outputHandle = outputPipe.fileHandleForReading;
        NSFileHandle* errorHandle = errorPipe.fileHandleForReading;

        // Read stdout asynchronously
        outputHandle.readabilityHandler = ^(NSFileHandle* handle) {
            NSData* data = [handle availableData];
            if (data.length > 0) {
                @synchronized(outputData) {
                    [outputData appendData:data];
                }
            } else {
                // EOF
                handle.readabilityHandler = nil;
                if (++readCount == 2) dispatch_semaphore_signal(readSemaphore);
            }
        };

        // Read stderr asynchronously
        errorHandle.readabilityHandler = ^(NSFileHandle* handle) {
            NSData* data = [handle availableData];
            if (data.length > 0) {
                @synchronized(errorData) {
                    [errorData appendData:data];
                }
            } else {
                // EOF
                handle.readabilityHandler = nil;
                if (++readCount == 2) dispatch_semaphore_signal(readSemaphore);
            }
        };

        NSError* launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            outputHandle.readabilityHandler = nil;
            errorHandle.readabilityHandler = nil;
            result.error = JLCloudError::YtDlpFailed;
            result.errorMessage = std::string("Failed to launch yt-dlp: ") +
                                  [[launchError localizedDescription] UTF8String];
            return result;
        }

        // Wait for completion with abort polling and timeout
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        __block BOOL taskCompleted = NO;

        task.terminationHandler = ^(NSTask* t) {
            taskCompleted = YES;
            dispatch_semaphore_signal(semaphore);
        };

        // Poll abort flag every 100ms until timeout
        int iterations = timeoutSeconds * 10;  // 100ms intervals
        for (int i = 0; i < iterations; i++) {
            // Check abort flag
            if (abortFlag && abortFlag->load()) {
                [task terminate];
                outputHandle.readabilityHandler = nil;
                errorHandle.readabilityHandler = nil;
                // Wait for termination handler to fire
                dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
                result.error = JLCloudError::Cancelled;
                result.errorMessage = "Operation cancelled";
                return result;
            }

            // Wait 100ms for completion
            if (dispatch_semaphore_wait(semaphore,
                dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0) {
                // Task completed
                break;
            }
        }

        // Check if we timed out
        if (!taskCompleted) {
            [task terminate];
            outputHandle.readabilityHandler = nil;
            errorHandle.readabilityHandler = nil;
            // Wait for termination handler to clean up
            dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC));
            result.error = JLCloudError::Timeout;
            result.errorMessage = "yt-dlp timed out";
            return result;
        }

        // Wait for async reads to complete (with timeout)
        dispatch_semaphore_wait(readSemaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        outputHandle.readabilityHandler = nil;
        errorHandle.readabilityHandler = nil;

        NSString* outputStr = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding] ?: @"";
        NSString* errorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";

        std::string output = [outputStr UTF8String] ?: "";
        std::string errorOutput = [errorStr UTF8String] ?: "";

        if (task.terminationStatus != 0) {
            result.error = parseErrorOutput(errorOutput);
            if (result.error == JLCloudError::None) {
                result.error = JLCloudError::YtDlpFailed;
            }
            result.errorMessage = errorOutput.empty() ? "yt-dlp failed" : errorOutput;
            return result;
        }

        // Trim whitespace from output
        while (!output.empty() && (output.back() == '\n' || output.back() == '\r')) {
            output.pop_back();
        }

        result.success = true;
        result.streamURL = output;  // Contains URL or JSON depending on operation
        return result;
    }
}

std::optional<TrackInfo> YtDlpWrapper::parseMetadataJSON(const std::string& json, const std::string& originalURL) {
    @autoreleasepool {
        NSData* jsonData = [[NSString stringWithUTF8String:json.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) {
            return std::nullopt;
        }

        NSError* error = nil;
        NSDictionary* dict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (!dict || ![dict isKindOfClass:[NSDictionary class]]) {
            logDebug("Failed to parse yt-dlp JSON");
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

            if (!info.chapters.empty()) {
                logDebug("Parsed " + std::to_string(info.chapters.size()) + " chapters from yt-dlp");
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

JLCloudError YtDlpWrapper::parseErrorOutput(const std::string& errorOutput) {
    if (errorOutput.empty()) {
        return JLCloudError::None;
    }

    // Check for common error patterns
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

    if (errorOutput.find("no suitable format") != std::string::npos ||
        errorOutput.find("Requested format") != std::string::npos) {
        return JLCloudError::FormatNotFound;
    }

    if (errorOutput.find("Unsupported URL") != std::string::npos) {
        return JLCloudError::UnsupportedURL;
    }

    return JLCloudError::YtDlpFailed;
}

} // namespace cloud_streamer
