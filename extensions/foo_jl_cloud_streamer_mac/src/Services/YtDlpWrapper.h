//
//  YtDlpWrapper.h
//  foo_jl_cloud_streamer_mac
//
//  yt-dlp subprocess wrapper with abort support and security validation
//

#pragma once

#include "../Core/CloudErrors.h"
#include "../Core/TrackInfo.h"
#include "../Core/URLUtils.h"
#include <string>
#include <optional>
#include <atomic>
#include <functional>

namespace cloud_streamer {

// Result of yt-dlp execution
struct YtDlpResult {
    bool success = false;
    JLCloudError error = JLCloudError::None;
    std::string errorMessage;

    // For stream URL extraction
    std::string streamURL;

    // For metadata extraction
    std::optional<TrackInfo> trackInfo;
};

// yt-dlp operation types
enum class YtDlpOperation {
    ExtractStreamURL,   // Get playable stream URL (-g)
    ExtractMetadata,    // Get JSON metadata (-j)
    ValidateBinary      // Verify binary is valid (--version)
};

// Default timeout values in seconds
constexpr int kDefaultTimeoutSeconds = 30;
constexpr int kMetadataTimeoutSeconds = 60;  // Metadata extraction can be slower

class YtDlpWrapper {
public:
    // Singleton access
    static YtDlpWrapper& shared();

    // Validate yt-dlp binary at path
    // Performs security checks: absolute path, executable, version output
    bool validateBinary(const std::string& path);

    // Check if we have a valid yt-dlp path configured
    bool isAvailable();

    // Extract stream URL for a cloud URL
    // abortFlag: poll this to cancel operation
    YtDlpResult extractStreamURL(
        const std::string& cloudURL,
        const std::string& formatSpec,
        std::atomic<bool>* abortFlag = nullptr,
        int timeoutSeconds = kDefaultTimeoutSeconds
    );

    // Extract metadata for a cloud URL
    YtDlpResult extractMetadata(
        const std::string& cloudURL,
        std::atomic<bool>* abortFlag = nullptr,
        int timeoutSeconds = kMetadataTimeoutSeconds
    );

    // Get the currently configured yt-dlp path
    std::string getYtDlpPath() const;

    // Set the yt-dlp path (automatically validates)
    bool setYtDlpPath(const std::string& path);

    // Clear cached path
    void clearPath();

private:
    YtDlpWrapper();
    ~YtDlpWrapper();

    // Non-copyable
    YtDlpWrapper(const YtDlpWrapper&) = delete;
    YtDlpWrapper& operator=(const YtDlpWrapper&) = delete;

    // Execute yt-dlp with arguments
    YtDlpResult execute(
        const std::vector<std::string>& arguments,
        YtDlpOperation operation,
        std::atomic<bool>* abortFlag,
        int timeoutSeconds
    );

    // Parse JSON output from yt-dlp
    std::optional<TrackInfo> parseMetadataJSON(const std::string& json, const std::string& originalURL);

    // Map yt-dlp error output to error code
    JLCloudError parseErrorOutput(const std::string& errorOutput);

    // Security check for path
    bool isValidYtDlpBinary(const std::string& path);

    // Cached validated path
    std::string m_validatedPath;
    bool m_pathValidated = false;
};

} // namespace cloud_streamer
