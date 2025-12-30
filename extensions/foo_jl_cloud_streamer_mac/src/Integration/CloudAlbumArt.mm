#import "CloudAlbumArt.h"
#import "../Core/URLUtils.h"
#import "../Core/MetadataCache.h"
#import "../Core/ThumbnailCache.h"
#import "../Core/CloudConfig.h"
#import "../Services/StreamResolver.h"
#include <memory>

namespace cloud_streamer {

// GUID for our album art extractor (matches CloudInputEntry GUID)
// {B8F5A432-1E89-4C56-9D3A-5E7F8B2C4D6E}
static constexpr GUID g_cloudAlbumArtGUID =
    { 0xb8f5a432, 0x1e89, 0x4c56, { 0x9d, 0x3a, 0x5e, 0x7f, 0x8b, 0x2c, 0x4d, 0x6e } };

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
        return;
    }

    // Need to resolve to get metadata
    std::atomic<bool> abortFlag(false);

    // Monitor abort callback in a simple way
    auto result = StreamResolver::shared().resolve(m_internalURL, &abortFlag);

    if (p_abort.is_aborting()) {
        throw exception_aborted();
    }

    if (result.success && result.trackInfo.has_value()) {
        m_thumbnailURL = result.trackInfo->thumbnailURL;
    }

    m_metadataLoaded = true;
}

album_art_data_ptr CloudAlbumArtInstance::query(const GUID& p_what, abort_callback& p_abort) {
    // Only support front cover
    if (p_what != album_art_ids::cover_front) {
        throw exception_album_art_not_found();
    }

    // Load metadata if needed
    loadMetadata(p_abort);

    if (m_thumbnailURL.empty()) {
        throw exception_album_art_not_found();
    }

    // Check if thumbnail is already cached
    auto cachedPath = ThumbnailCache::shared().getCachedPath(m_thumbnailURL);
    NSString* filePath = nil;

    if (cachedPath.has_value()) {
        filePath = [NSString stringWithUTF8String:cachedPath->c_str()];
    } else {
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
            if (!resultHolder->errorMessage.empty()) {
                logDebug("Failed to fetch thumbnail: " + resultHolder->errorMessage);
            }
            throw exception_album_art_not_found();
        }
        filePath = [NSString stringWithUTF8String:resultHolder->filePath.c_str()];
    }

    // Read the file data
    NSData* imageData = [NSData dataWithContentsOfFile:filePath];
    if (!imageData || imageData.length == 0) {
        throw exception_album_art_not_found();
    }

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
