//
//  CloudErrors.h
//  foo_jl_cloud_streamer_mac
//
//  Error codes for cloud streaming operations
//

#pragma once

#include <cstdint>

namespace cloud_streamer {

// Error codes for cloud streaming operations
enum class JLCloudError : uint32_t {
    None = 0,

    // Operation control
    Cancelled = 1,      // User cancelled the operation
    Timeout = 2,        // Operation timed out

    // yt-dlp errors (10-19)
    YtDlpNotFound = 10,    // yt-dlp binary not found
    YtDlpNotExecutable = 11, // yt-dlp not executable
    YtDlpInvalidPath = 12,   // yt-dlp path failed security validation
    YtDlpFailed = 13,        // yt-dlp execution failed
    YtDlpParseError = 14,    // Failed to parse yt-dlp output

    // Network errors (20-29)
    NetworkError = 20,      // General network error
    GeoRestricted = 21,     // Content is geo-restricted
    TrackUnavailable = 22,  // Track not found or removed
    AuthRequired = 23,      // Authentication required
    RateLimited = 24,       // Rate limited by service

    // Stream errors (30-39)
    StreamExpired = 30,     // Stream URL has expired (403)
    StreamUnavailable = 31, // Stream temporarily unavailable
    FormatNotFound = 32,    // Requested format not available

    // URL errors (40-49)
    UnsupportedURL = 40,    // URL format not supported
    ProfileURL = 41,        // URL is a profile, not a track
    PlaylistURL = 42,       // URL is a playlist, not a track
    InvalidURL = 43,        // URL is malformed

    // Search errors (100-109)
    SearchNoResults = 100,  // Search returned no results
    SearchCancelled = 101,  // Search was cancelled
    SearchTimeout = 102,    // Search timed out
};

// Convert error code to string for logging
inline const char* errorToString(JLCloudError error) {
    switch (error) {
        case JLCloudError::None: return "None";
        case JLCloudError::Cancelled: return "Cancelled";
        case JLCloudError::Timeout: return "Timeout";
        case JLCloudError::YtDlpNotFound: return "yt-dlp not found";
        case JLCloudError::YtDlpNotExecutable: return "yt-dlp not executable";
        case JLCloudError::YtDlpInvalidPath: return "yt-dlp path failed security validation";
        case JLCloudError::YtDlpFailed: return "yt-dlp execution failed";
        case JLCloudError::YtDlpParseError: return "Failed to parse yt-dlp output";
        case JLCloudError::NetworkError: return "Network error";
        case JLCloudError::GeoRestricted: return "Geo-restricted";
        case JLCloudError::TrackUnavailable: return "Track unavailable";
        case JLCloudError::AuthRequired: return "Authentication required";
        case JLCloudError::RateLimited: return "Rate limited";
        case JLCloudError::StreamExpired: return "Stream URL expired";
        case JLCloudError::StreamUnavailable: return "Stream unavailable";
        case JLCloudError::FormatNotFound: return "Format not found";
        case JLCloudError::UnsupportedURL: return "Unsupported URL";
        case JLCloudError::ProfileURL: return "Profile URL not supported";
        case JLCloudError::PlaylistURL: return "Playlist URL not supported";
        case JLCloudError::InvalidURL: return "Invalid URL";
        case JLCloudError::SearchNoResults: return "No results found";
        case JLCloudError::SearchCancelled: return "Search cancelled";
        case JLCloudError::SearchTimeout: return "Search timed out";
        default: return "Unknown error";
    }
}

// Metadata field name for storing error in track info
constexpr const char* kCloudErrorField = "CLOUD_ERROR";

} // namespace cloud_streamer
