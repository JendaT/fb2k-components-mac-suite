#import "CloudLinkResolver.h"
#import "../Core/URLUtils.h"
#import "../Core/CloudConfig.h"
#import "../Services/StreamResolver.h"

namespace cloud_streamer {

bool CloudLinkResolver::is_our_path(const char* p_path, const char* p_extension) {
    if (!p_path || !*p_path) return false;

    std::string path(p_path);
    ParsedCloudURL parsed = URLUtils::parseURL(path);

    // Only accept track URLs from Mixcloud or SoundCloud
    if (parsed.service == CloudService::Unknown) {
        return false;
    }

    // Reject profiles and playlists
    if (parsed.type == JLCloudURLType::Profile ||
        parsed.type == JLCloudURLType::Playlist) {
        logDebug("CloudLinkResolver: rejected non-track URL: " + path);
        return false;
    }

    // Accept tracks and DJ sets
    if (parsed.type == JLCloudURLType::Track ||
        parsed.type == JLCloudURLType::DJSet) {
        logDebug("CloudLinkResolver: accepting " + path);
        return true;
    }

    return false;
}

void CloudLinkResolver::resolve(service_ptr_t<file> p_filehint,
                                 const char* p_path,
                                 pfc::string_base& p_out,
                                 abort_callback& p_abort) {
    if (!p_path || !*p_path) {
        pfc::throw_exception_with_message<exception_io_data>("Empty URL");
    }

    std::string path(p_path);
    ParsedCloudURL parsed = URLUtils::parseURL(path);

    if (parsed.service == CloudService::Unknown) {
        pfc::throw_exception_with_message<exception_io_data>("Unsupported URL");
    }

    // Convert web URL to internal scheme
    std::string internalURL;
    if (URLUtils::isInternalScheme(path)) {
        // Already internal scheme
        internalURL = path;
    } else {
        // Convert from web URL
        internalURL = URLUtils::webURLToInternalScheme(path);
    }

    if (internalURL.empty()) {
        pfc::throw_exception_with_message<exception_io_data>("Failed to convert URL to internal scheme");
    }

    p_out = internalURL.c_str();
    logDebug("CloudLinkResolver: resolved " + path + " -> " + internalURL);

    // Trigger prefetch in background
    StreamResolver::shared().prefetch(internalURL);
}

// Service registration
static service_factory_single_t<CloudLinkResolver> g_cloudLinkResolver;

} // namespace cloud_streamer
