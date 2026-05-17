//
//  TidalAlbumArtExtractor.mm
//  foo_jl_tidal_mac
//
//  Album art extractor service for tidal:// URLs.
//  Fetches cover art from the Tidal CDN so playlists show album artwork
//  instead of generic music note icons.
//

#include "../fb2k_sdk.h"
#include "../Core/URLUtils.h"
#include "../Core/TidalConfig.h"
#import "../Services/TidalStreamResolver.h"
#import "../UI/TidalAlbumArtCache.h"
#import <dispatch/dispatch.h>

namespace tidal {

// Must match TidalInputEntry GUID for SDK album art routing
// {B2C3D4E5-F6A7-8B9C-0D1E-2F3A4B5C6D7E}
static const GUID g_tidalAlbumArtExtractorGUID =
    { 0xb2c3d4e5, 0xf6a7, 0x8b9c, { 0x0d, 0x1e, 0x2f, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e } };

class TidalAlbumArtExtractorInstance : public album_art_extractor_instance {
public:
    TidalAlbumArtExtractorInstance(const std::string& trackID, abort_callback& p_abort) {
        fetchArt(trackID, p_abort);
    }

    album_art_data_ptr query(const GUID& p_what, abort_callback& p_abort) override {
        p_abort.check();
        album_art_data_ptr result;
        if (!m_data.query(p_what, result)) {
            throw exception_album_art_not_found();
        }
        return result;
    }

private:
    void fetchArt(const std::string& trackID, abort_callback& p_abort) {
        logDebug("TidalAlbumArtExtractor: fetching art for track " + trackID);

        // Fetch track metadata to get coverID
        NSString* trackIDStr = [NSString stringWithUTF8String:trackID.c_str()];
        __block JLTidalTrack* trackResult = nil;
        __block NSError* fetchError = nil;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        [[JLTidalStreamResolver shared] getMetadataForTrackID:trackIDStr
                                                   completion:^(JLTidalTrack* track, NSError* error) {
            trackResult = track;
            fetchError = error;
            dispatch_semaphore_signal(semaphore);
        }];

        // Wait with periodic abort checks (max 10 seconds)
        int attempts = 0;
        while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
            if (p_abort.is_aborting()) {
                logDebug("TidalAlbumArtExtractor: aborted during metadata fetch");
                throw exception_aborted();
            }
            if (++attempts > 100) {
                logDebug("TidalAlbumArtExtractor: metadata fetch timed out");
                throw exception_album_art_not_found();
            }
        }

        if (fetchError || !trackResult) {
            logDebug("TidalAlbumArtExtractor: metadata fetch failed");
            throw exception_album_art_not_found();
        }

        NSString* coverID = trackResult.coverID;
        if (!coverID.length) {
            logDebug("TidalAlbumArtExtractor: no coverID in track metadata");
            throw exception_album_art_not_found();
        }

        // Build CDN URL (640x640 for good quality)
        NSURL* coverURL = [JLTidalAlbumArtCache coverURLForCoverID:coverID size:640];
        logDebug(std::string("TidalAlbumArtExtractor: downloading from ") +
                 [[coverURL absoluteString] UTF8String]);

        // Download image using shared session
        static NSURLSession* session = nil;
        static dispatch_once_t sessionOnce;
        dispatch_once(&sessionOnce, ^{
            NSURLSessionConfiguration* config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            config.timeoutIntervalForRequest = 10;
            config.timeoutIntervalForResource = 15;
            session = [NSURLSession sessionWithConfiguration:config];
        });

        __block NSData* imageData = nil;
        __block NSError* downloadError = nil;
        dispatch_semaphore_t dlSemaphore = dispatch_semaphore_create(0);

        NSURLSessionDataTask* task = [session dataTaskWithURL:coverURL
                                            completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            if (!error) {
                NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
                if (httpResponse.statusCode == 200 && data.length > 0) {
                    imageData = data;
                }
                // Non-200 status: imageData stays nil, handled below
            } else {
                downloadError = error;
            }
            dispatch_semaphore_signal(dlSemaphore);
        }];
        [task resume];

        // Wait with periodic abort checks (max 15 seconds)
        attempts = 0;
        while (dispatch_semaphore_wait(dlSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
            if (p_abort.is_aborting()) {
                [task cancel];
                logDebug("TidalAlbumArtExtractor: aborted during download");
                throw exception_aborted();
            }
            if (++attempts > 150) {
                [task cancel];
                logDebug("TidalAlbumArtExtractor: download timed out");
                throw exception_album_art_not_found();
            }
        }

        if (!imageData || imageData.length == 0) {
            logDebug("TidalAlbumArtExtractor: download failed or empty response");
            throw exception_album_art_not_found();
        }

        logDebug(std::string("TidalAlbumArtExtractor: got image data, ") +
                 std::to_string(imageData.length) + " bytes");

        // Wrap in album_art_data_impl
        album_art_data_ptr artData = album_art_data_impl::g_create(
            imageData.bytes, static_cast<t_size>(imageData.length));

        m_data.set(album_art_ids::cover_front, artData);
    }

    pfc::map_t<GUID, album_art_data_ptr> m_data;
};

class TidalAlbumArtExtractor : public album_art_extractor_v2 {
public:
    bool is_our_path(const char* p_path, const char* p_extension) override {
        if (!p_path || !*p_path) return false;
        bool result = isTidalURL(p_path);
        if (result) {
            logDebug(std::string("AlbumArtExtractor::is_our_path: YES for ") + p_path);
        }
        return result;
    }

    album_art_extractor_instance_ptr open(file_ptr p_filehint, const char* p_path, abort_callback& p_abort) override {
        logDebug(std::string("AlbumArtExtractor::open: ") + (p_path ? p_path : "(null)"));
        auto parsed = parseURL(std::string(p_path));
        if (!parsed.has_value() || parsed->type != TidalContentType::Track) {
            logDebug("AlbumArtExtractor::open: not a track URL, skipping");
            throw exception_album_art_not_found();
        }

        logDebug("AlbumArtExtractor::open: creating instance for track " + parsed->id);
        return new service_impl_t<TidalAlbumArtExtractorInstance>(parsed->id, p_abort);
    }

    GUID get_guid() override {
        return g_tidalAlbumArtExtractorGUID;
    }
};

// Use FB2K_SERVICE_FACTORY (matches cloud streamer pattern)
namespace {
    FB2K_SERVICE_FACTORY(TidalAlbumArtExtractor);
}

} // namespace tidal
