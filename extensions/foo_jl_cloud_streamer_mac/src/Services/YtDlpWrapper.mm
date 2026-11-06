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
        result.trackInfo = YtDlpParser::parseMetadataJSON(result.streamURL, cloudURL);
        if (!result.trackInfo.has_value()) {
            logDebug("Failed to parse yt-dlp JSON");
        } else if (!result.trackInfo->chapters.empty()) {
            logDebug("Parsed " + std::to_string(result.trackInfo->chapters.size()) +
                     " chapters from yt-dlp");
        }
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
            result.error = YtDlpParser::parseErrorOutput(errorOutput);
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

YtDlpSearchResult YtDlpWrapper::search(
    const std::string& query,
    int maxResults,
    std::atomic<bool>* abortFlag,
    int timeoutSeconds
) {
    YtDlpSearchResult result;

    if (query.empty()) {
        result.error = JLCloudError::SearchNoResults;
        result.errorMessage = "Empty search query";
        return result;
    }

    // Clamp maxResults to 1-50 range
    maxResults = std::max(1, std::min(50, maxResults));

    // Build search query: scsearch<N>:<query>
    std::string searchQuery = "scsearch" + std::to_string(maxResults) + ":" + query;

    std::vector<std::string> args;
    args.push_back("--flat-playlist");  // Don't extract full info for each entry
    args.push_back("-J");               // JSON output
    args.push_back("--no-warnings");
    args.push_back(searchQuery);

    YtDlpResult execResult = execute(args, YtDlpOperation::Search, abortFlag, timeoutSeconds);

    if (!execResult.success) {
        result.error = execResult.error;
        result.errorMessage = execResult.errorMessage;

        // Map specific errors for search context
        if (result.error == JLCloudError::Cancelled) {
            result.error = JLCloudError::SearchCancelled;
        } else if (result.error == JLCloudError::Timeout) {
            result.error = JLCloudError::SearchTimeout;
        }
        return result;
    }

    // Parse JSON output
    result.entries = YtDlpParser::parseSearchJSON(execResult.streamURL);

    if (result.entries.empty()) {
        result.error = JLCloudError::SearchNoResults;
        result.errorMessage = "No results found";
        return result;
    }

    result.success = true;
    logDebug("Search returned " + std::to_string(result.entries.size()) + " results");
    return result;
}

} // namespace cloud_streamer
