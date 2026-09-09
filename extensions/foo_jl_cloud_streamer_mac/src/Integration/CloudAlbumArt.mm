#import "CloudAlbumArt.h"
#import "../Core/URLUtils.h"
#import "../Core/MetadataCache.h"
#import "../Core/ThumbnailCache.h"
#import "../Core/CloudConfig.h"
#import "../Services/StreamResolver.h"
#include <memory>

namespace cloud_streamer {

// Must equal CloudInputEntry's GUID — input_manager_v2 matches album art
// extractors to inputs by GUID (see SDK input.cpp:24-35). A mismatched GUID
// means our extractor is silently skipped.
// {7A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D}
static constexpr GUID g_cloudAlbumArtGUID =
    { 0x7a1b2c3d, 0x4e5f, 0x6a7b, { 0x8c, 0x9d, 0x0e, 0x1f, 0x2a, 0x3b, 0x4c, 0x5d } };

// CloudAlbumArtInstance implementation

CloudAlbumArtInstance::CloudAlbumArtInstance(const std::string& internalURL)
    : m_internalURL(internalURL)
    , m_metadataLoaded(false) {
}

CloudAlbumArtInstance::~CloudAlbumArtInstance() {
}

void CloudAlbumArtInstance::loadMetadata(abort_callback& p_abort) {
    if (m_metadataLoaded) return;

    // Try metadata cache first
    auto cached = MetadataCache::shared().get(m_internalURL);
    if (cached.has_value() && !cached->thumbnailURL.empty()) {
        m_thumbnailURL = cached->thumbnailURL;
        m_metadataLoaded = true;
        console::info(("[Cloud Streamer] AlbumArt: cache hit for " + m_internalURL +
                       ", thumbnailURL=" + m_thumbnailURL).c_str());
        return;
    }

    console::info(("[Cloud Streamer] AlbumArt: cache miss for " + m_internalURL +
                   " (cached=" + (cached.has_value() ? "yes/no-thumb" : "no") +
                   "), resolving via yt-dlp...").c_str());

    // Need to resolve to get metadata
    std::atomic<bool> abortFlag(false);

    // Monitor abort callback in a simple way
    auto result = StreamResolver::shared().resolve(m_internalURL, &abortFlag);

    if (p_abort.is_aborting()) {
        throw exception_aborted();
    }

    if (result.success && result.trackInfo.has_value()) {
        m_thumbnailURL = result.trackInfo->thumbnailURL;
        console::info(("[Cloud Streamer] AlbumArt: resolved thumbnailURL=" +
                       (m_thumbnailURL.empty() ? std::string("<empty>") : m_thumbnailURL)).c_str());
    } else {
        console::warning(("[Cloud Streamer] AlbumArt: resolve failed for " + m_internalURL).c_str());
    }

    m_metadataLoaded = true;
}

album_art_data_ptr CloudAlbumArtInstance::query(const GUID& p_what, abort_callback& p_abort) {
    console::info(("[Cloud Streamer] AlbumArt: query() called for " + m_internalURL).c_str());

    // Only support front cover
    if (p_what != album_art_ids::cover_front) {
        console::info("[Cloud Streamer] AlbumArt: not cover_front, skipping");
        throw exception_album_art_not_found();
    }

    // Load metadata if needed
    loadMetadata(p_abort);

    if (m_thumbnailURL.empty()) {
        console::warning(("[Cloud Streamer] AlbumArt: no thumbnail URL for " + m_internalURL).c_str());
        throw exception_album_art_not_found();
    }

    // Check if thumbnail is already cached
    auto cachedPath = ThumbnailCache::shared().getCachedPath(m_thumbnailURL);
    NSString* filePath = nil;

    if (cachedPath.has_value()) {
        filePath = [NSString stringWithUTF8String:cachedPath->c_str()];
        console::info(("[Cloud Streamer] AlbumArt: disk cache hit: " + cachedPath.value()).c_str());
    } else {
        console::info(("[Cloud Streamer] AlbumArt: disk cache miss, fetching " + m_thumbnailURL).c_str());

        // Need to fetch synchronously - use shared_ptr for thread-safe result passing
        auto resultHolder = std::make_shared<ThumbnailResult>();
        auto sem = dispatch_semaphore_create(0);

        ThumbnailCache::shared().fetch(m_thumbnailURL, [resultHolder, sem](const ThumbnailResult& result) {
            *resultHolder = result;
            dispatch_semaphore_signal(sem);
        });

        // Wait with timeout, checking abort
        while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
            if (p_abort.is_aborting()) {
                throw exception_aborted();
            }
        }

        if (!resultHolder->success || resultHolder->filePath.empty()) {
            console::warning(("[Cloud Streamer] AlbumArt: fetch failed: " +
                              (resultHolder->errorMessage.empty() ? std::string("<no error>") :
                               resultHolder->errorMessage)).c_str());
            throw exception_album_art_not_found();
        }
        filePath = [NSString stringWithUTF8String:resultHolder->filePath.c_str()];
    }

    // Read the file data
    NSData* imageData = [NSData dataWithContentsOfFile:filePath];
    if (!imageData || imageData.length == 0) {
        console::warning(("[Cloud Streamer] AlbumArt: empty file at " +
                          std::string([filePath UTF8String])).c_str());
        throw exception_album_art_not_found();
    }

    console::info(("[Cloud Streamer] AlbumArt: returning " +
                   std::to_string(imageData.length) + " bytes").c_str());

    // Create album_art_data using static factory method
    return album_art_data_impl::g_create(imageData.bytes, imageData.length);
}

// CloudAlbumArtExtractor implementation

bool CloudAlbumArtExtractor::is_our_path(const char* p_path, const char* p_extension) {
    if (!p_path) return false;

    std::string path(p_path);
    return URLUtils::isInternalScheme(path);
}

album_art_extractor_instance_ptr CloudAlbumArtExtractor::open(file_ptr p_filehint,
                                                               const char* p_path,
                                                               abort_callback& p_abort) {
    if (!p_path) {
        throw exception_io_not_found();
    }

    std::string path(p_path);
    if (!URLUtils::isInternalScheme(path)) {
        throw exception_io_unsupported_format();
    }

    return new service_impl_t<CloudAlbumArtInstance>(path);
}

GUID CloudAlbumArtExtractor::get_guid() {
    return g_cloudAlbumArtGUID;
}

// Service factory registration
namespace {
    FB2K_SERVICE_FACTORY(CloudAlbumArtExtractor);
}

} // namespace cloud_streamer
