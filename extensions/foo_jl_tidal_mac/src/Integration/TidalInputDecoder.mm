//
//  TidalInputDecoder.mm
//  foo_jl_tidal_mac
//
//  Input decoder implementation for tidal:// URLs
//

#import "TidalInputDecoder.h"
#import "../Core/URLUtils.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalErrors.h"
#import "../Core/StreamCache.h"
#import "../Services/TidalStreamResolver.h"
#import "../API/TidalConstants.h"
#import <dispatch/dispatch.h>

namespace tidal {

// GUIDs for this input
// {B2C3D4E5-F6A7-8B9C-0D1E-2F3A4B5C6D7E}
static const GUID g_tidalInputGUID =
    { 0xb2c3d4e5, 0xf6a7, 0x8b9c, { 0x0d, 0x1e, 0x2f, 0x3a, 0x4b, 0x5c, 0x6d, 0x7e } };

// TidalInputDecoder implementation

TidalInputDecoder::TidalInputDecoder()
    : m_playbackInfo(nil)
    , m_trackInfo(nil)
    , m_abortFlag(false)
    , m_initialized(false)
    , m_flags(0)
    , m_subsong(0)
    , m_403Retry(false) {
}

TidalInputDecoder::~TidalInputDecoder() {
    m_abortFlag = true;
}

void TidalInputDecoder::open(const char* p_path, abort_callback& p_abort) {
    std::string path(p_path);
    m_abortFlag = false;
    m_403Retry = false;

    logDebug(("open() called with: " + path).c_str());

    // Parse the URL to get track ID
    auto parsed = parseURL(path);
    if (!parsed.has_value()) {
        logError(("URL parsing returned nullopt for: " + path).c_str());
        pfc::throw_exception_with_message<exception_io_data>("Unsupported Tidal URL format");
    }
    if (parsed->type != TidalContentType::Track) {
        logError(("Not a track URL, got type: " + std::to_string(static_cast<int>(parsed->type)) + " id: " + parsed->id).c_str());
        pfc::throw_exception_with_message<exception_io_data>("Unsupported Tidal URL format");
    }

    m_trackID = parsed->id;
    logDebug(("Track ID: " + m_trackID).c_str());

    // Resolve stream URL
    openStream(p_abort);
}

void TidalInputDecoder::openStream(abort_callback& p_abort) {
    logDebug(("Resolving stream for track: " + m_trackID).c_str());

    // Use dispatch semaphore for synchronous resolution
    __block JLTidalPlaybackInfo* resultInfo = nil;
    __block NSError* resultError = nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSString* trackIDStr = [NSString stringWithUTF8String:m_trackID.c_str()];

    [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackIDStr
                                                 completion:^(JLTidalPlaybackInfo *info, NSError *error) {
        resultInfo = info;
        resultError = error;
        dispatch_semaphore_signal(semaphore);
    }];

    // Wait for resolution (with timeout to check abort)
    while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (p_abort.is_aborting() || m_abortFlag) {
            pfc::throw_exception_with_message<exception_aborted>("Operation aborted");
        }
    }

    if (resultError || !resultInfo) {
        std::string errorMsg = resultError ?
            std::string([[resultError localizedDescription] UTF8String]) :
            "Failed to resolve stream";
        logError(("Stream resolution failed: " + errorMsg).c_str());
        pfc::throw_exception_with_message<exception_io_data>(errorMsg.c_str());
    }

    m_playbackInfo = resultInfo;
    m_streamURL = std::string([[resultInfo.streamURL absoluteString] UTF8String]);

    logDebug(("Got stream URL, quality: " + std::string([resultInfo.qualityDescription UTF8String])).c_str());

    // Also fetch metadata
    dispatch_semaphore_t metaSemaphore = dispatch_semaphore_create(0);
    __block JLTidalTrack* trackResult = nil;

    [[JLTidalStreamResolver shared] getMetadataForTrackID:trackIDStr
                                               completion:^(JLTidalTrack *track, NSError *error) {
        trackResult = track;
        dispatch_semaphore_signal(metaSemaphore);
    }];

    // Wait briefly for metadata (non-critical)
    dispatch_semaphore_wait(metaSemaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    m_trackInfo = trackResult;

    // Open underlying decoder for the stream URL
    input_entry::ptr entry;
    if (!input_entry::g_find_service_by_path(entry, m_streamURL.c_str())) {
        logError("No decoder found for stream URL");
        pfc::throw_exception_with_message<exception_io_data>("No decoder found for stream URL");
    }

    entry->open_for_decoding(m_decoder, nullptr, m_streamURL.c_str(), p_abort);

    if (!m_decoder.is_valid()) {
        logError("Failed to open stream decoder");
        pfc::throw_exception_with_message<exception_io_data>("Failed to open stream decoder");
    }

    logDebug("Stream opened successfully");
}

bool TidalInputDecoder::tryReopen(abort_callback& p_abort) {
    if (m_403Retry) {
        return false;  // Already tried once
    }

    m_403Retry = true;
    logDebug("Trying to re-resolve stream (403 retry)");

    try {
        // Invalidate cache and re-resolve
        NSString* trackIDStr = [NSString stringWithUTF8String:m_trackID.c_str()];
        [[JLTidalStreamResolver shared] invalidateCacheForTrackID:trackIDStr];

        // Synchronous re-resolution
        __block JLTidalPlaybackInfo* resultInfo = nil;
        __block NSError* resultError = nil;

        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackIDStr
                                                     completion:^(JLTidalPlaybackInfo *info, NSError *error) {
            resultInfo = info;
            resultError = error;
            dispatch_semaphore_signal(semaphore);
        }];

        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        if (resultError || !resultInfo) {
            return false;
        }

        m_playbackInfo = resultInfo;
        m_streamURL = std::string([[resultInfo.streamURL absoluteString] UTF8String]);

        // Open new decoder
        input_entry::ptr entry;
        if (!input_entry::g_find_service_by_path(entry, m_streamURL.c_str())) {
            return false;
        }

        service_ptr_t<input_decoder> newDecoder;
        entry->open_for_decoding(newDecoder, nullptr, m_streamURL.c_str(), p_abort);

        if (!newDecoder.is_valid()) {
            return false;
        }

        m_decoder = newDecoder;
        m_decoder->initialize(m_subsong, m_flags, p_abort);

        logDebug("Successfully re-resolved stream");
        return true;
    } catch (...) {
        return false;
    }
}

t_uint32 TidalInputDecoder::get_subsong_count() {
    return 1;
}

t_uint32 TidalInputDecoder::get_subsong(t_uint32 p_index) {
    return 0;
}

void TidalInputDecoder::get_info(t_uint32 p_subsong, file_info& p_info, abort_callback& p_abort) {
    // Try underlying decoder first
    if (m_decoder.is_valid()) {
        try {
            m_decoder->get_info(p_subsong, p_info, p_abort);
        } catch (...) {
            // Fall through to use our metadata
        }
    }

    // Overlay our metadata
    if (m_trackInfo) {
        if (m_trackInfo.title) {
            p_info.meta_set("TITLE", [m_trackInfo.title UTF8String]);
        }
        if (m_trackInfo.artist) {
            p_info.meta_set("ARTIST", [m_trackInfo.artist UTF8String]);
        }
        if (m_trackInfo.album) {
            p_info.meta_set("ALBUM", [m_trackInfo.album UTF8String]);
        }
        if (m_trackInfo.albumArtist) {
            p_info.meta_set("ALBUM ARTIST", [m_trackInfo.albumArtist UTF8String]);
        }
        if (m_trackInfo.duration > 0) {
            p_info.set_length(m_trackInfo.duration);
        }
        if (m_trackInfo.trackNumber > 0) {
            p_info.meta_set("TRACKNUMBER", [[NSString stringWithFormat:@"%ld", (long)m_trackInfo.trackNumber] UTF8String]);
        }
        if (m_trackInfo.discNumber > 0) {
            p_info.meta_set("DISCNUMBER", [[NSString stringWithFormat:@"%ld", (long)m_trackInfo.discNumber] UTF8String]);
        }
        if (m_trackInfo.totalTracks > 0) {
            p_info.meta_set("TOTALTRACKS", [[NSString stringWithFormat:@"%ld", (long)m_trackInfo.totalTracks] UTF8String]);
        }
        if (m_trackInfo.isrc) {
            p_info.meta_set("ISRC", [m_trackInfo.isrc UTF8String]);
        }
        if (m_trackInfo.releaseDate) {
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd";
            fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            p_info.meta_set("DATE", [[fmt stringFromDate:m_trackInfo.releaseDate] UTF8String]);
        }
        if (m_trackInfo.copyright) {
            p_info.meta_set("COPYRIGHT", [m_trackInfo.copyright UTF8String]);
        }
    }

    // Add quality info
    if (m_playbackInfo) {
        p_info.info_set(kTidalMetadataQuality.UTF8String, [m_playbackInfo.qualityDescription UTF8String]);
        p_info.info_set(kTidalMetadataTrackID.UTF8String, m_trackID.c_str());
    }
}

t_filestats TidalInputDecoder::get_file_stats(abort_callback& p_abort) {
    if (m_decoder.is_valid()) {
        return m_decoder->get_file_stats(p_abort);
    }
    t_filestats result;
    result.m_size = filesize_invalid;
    result.m_timestamp = filetimestamp_invalid;
    return result;
}

void TidalInputDecoder::initialize(t_uint32 p_subsong, unsigned p_flags, abort_callback& p_abort) {
    m_subsong = p_subsong;
    m_flags = p_flags;
    m_initialized = true;

    if (m_decoder.is_valid()) {
        m_decoder->initialize(p_subsong, p_flags, p_abort);
    }
}

bool TidalInputDecoder::run(audio_chunk& p_chunk, abort_callback& p_abort) {
    if (!m_decoder.is_valid()) {
        return false;
    }

    try {
        return m_decoder->run(p_chunk, p_abort);
    } catch (const exception_io& e) {
        // Check for 403 error (stream expired)
        const char* msg = e.what();
        if (msg && (strstr(msg, "403") || strstr(msg, "Forbidden"))) {
            if (tryReopen(p_abort)) {
                return m_decoder->run(p_chunk, p_abort);
            }
        }
        throw;
    }
}

void TidalInputDecoder::seek(double p_seconds, abort_callback& p_abort) {
    if (m_decoder.is_valid()) {
        m_decoder->seek(p_seconds, p_abort);
    }
}

bool TidalInputDecoder::can_seek() {
    if (m_decoder.is_valid()) {
        return m_decoder->can_seek();
    }
    return false;
}

bool TidalInputDecoder::get_dynamic_info(file_info& p_out, double& p_timestamp_delta) {
    if (m_decoder.is_valid()) {
        return m_decoder->get_dynamic_info(p_out, p_timestamp_delta);
    }
    return false;
}

bool TidalInputDecoder::get_dynamic_info_track(file_info& p_out, double& p_timestamp_delta) {
    if (m_decoder.is_valid()) {
        return m_decoder->get_dynamic_info_track(p_out, p_timestamp_delta);
    }
    return false;
}

void TidalInputDecoder::on_idle(abort_callback& p_abort) {
    if (m_decoder.is_valid()) {
        m_decoder->on_idle(p_abort);
    }
}

bool TidalInputDecoder::run_raw(audio_chunk& out, mem_block_container& outRaw, abort_callback& abort) {
    throw pfc::exception_not_implemented();
}

void TidalInputDecoder::set_logger(event_logger::ptr ptr) {
    m_logger = ptr;
}

// TidalInfoReader implementation - fetches metadata from API

TidalInfoReader::TidalInfoReader()
    : m_trackInfo(nil) {
}

void TidalInfoReader::open(const char* p_path, abort_callback& p_abort) {
    std::string pathStr(p_path);
    logDebug(("TidalInfoReader::open called with: " + pathStr).c_str());

    auto parsed = parseURL(pathStr);
    if (!parsed.has_value() || parsed->type != TidalContentType::Track) {
        logDebug("TidalInfoReader: URL parsing failed or not a track");
        return;
    }

    m_trackID = parsed->id;
    logDebug(("TidalInfoReader: track ID = " + m_trackID).c_str());

    // Fetch metadata from API
    __block JLTidalTrack* trackResult = nil;
    __block NSError* fetchError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSString* trackIDStr = [NSString stringWithUTF8String:m_trackID.c_str()];

    [[JLTidalStreamResolver shared] getMetadataForTrackID:trackIDStr
                                               completion:^(JLTidalTrack *track, NSError *error) {
        trackResult = track;
        fetchError = error;
        dispatch_semaphore_signal(semaphore);
    }];

    // Wait with timeout (max 5 seconds, check abort periodically)
    int attempts = 0;
    while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (p_abort.is_aborting()) {
            logDebug("TidalInfoReader: aborted while fetching metadata");
            return;
        }
        if (++attempts > 50) {  // 5 second timeout
            logDebug("TidalInfoReader: metadata fetch timed out");
            return;
        }
    }

    if (fetchError) {
        logDebug([[NSString stringWithFormat:@"TidalInfoReader: metadata fetch failed: %@",
                   fetchError.localizedDescription] UTF8String]);
    } else if (trackResult) {
        logDebug([[NSString stringWithFormat:@"TidalInfoReader: got metadata - title=%@, artist=%@",
                   trackResult.title ?: @"(nil)", trackResult.artist ?: @"(nil)"] UTF8String]);
    } else {
        logDebug("TidalInfoReader: no metadata and no error");
    }

    m_trackInfo = trackResult;
}

void TidalInfoReader::get_info(t_uint32 p_subsong, file_info& p_info, abort_callback& p_abort) {
    logDebug(("TidalInfoReader::get_info called, trackID=" + m_trackID +
              ", hasTrackInfo=" + (m_trackInfo ? "yes" : "no")).c_str());

    if (m_trackInfo) {
        if (m_trackInfo.title) {
            p_info.meta_set("TITLE", [m_trackInfo.title UTF8String]);
            logDebug([[NSString stringWithFormat:@"TidalInfoReader: set TITLE=%@", m_trackInfo.title] UTF8String]);
        }
        if (m_trackInfo.artist) {
            p_info.meta_set("ARTIST", [m_trackInfo.artist UTF8String]);
            logDebug([[NSString stringWithFormat:@"TidalInfoReader: set ARTIST=%@", m_trackInfo.artist] UTF8String]);
        }
        if (m_trackInfo.album) {
            p_info.meta_set("ALBUM", [m_trackInfo.album UTF8String]);
        }
        if (m_trackInfo.albumArtist) {
            p_info.meta_set("ALBUM ARTIST", [m_trackInfo.albumArtist UTF8String]);
        }
        if (m_trackInfo.duration > 0) {
            p_info.set_length(m_trackInfo.duration);
        }
        if (m_trackInfo.trackNumber > 0) {
            p_info.meta_set("TRACKNUMBER", [[NSString stringWithFormat:@"%ld", (long)m_trackInfo.trackNumber] UTF8String]);
        }
        if (m_trackInfo.discNumber > 0) {
            p_info.meta_set("DISCNUMBER", [[NSString stringWithFormat:@"%ld", (long)m_trackInfo.discNumber] UTF8String]);
        }
        if (m_trackInfo.totalTracks > 0) {
            p_info.meta_set("TOTALTRACKS", [[NSString stringWithFormat:@"%ld", (long)m_trackInfo.totalTracks] UTF8String]);
        }
        if (m_trackInfo.isrc) {
            p_info.meta_set("ISRC", [m_trackInfo.isrc UTF8String]);
        }
        if (m_trackInfo.releaseDate) {
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd";
            fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            p_info.meta_set("DATE", [[fmt stringFromDate:m_trackInfo.releaseDate] UTF8String]);
        }
        if (m_trackInfo.copyright) {
            p_info.meta_set("COPYRIGHT", [m_trackInfo.copyright UTF8String]);
        }
    } else {
        // Fallback if metadata fetch failed - show track ID so user knows what it is
        logDebug("TidalInfoReader: no track info, using fallback");
        if (!m_trackID.empty()) {
            p_info.meta_set("TITLE", ("Tidal Track " + m_trackID).c_str());
            p_info.meta_set("ARTIST", "Tidal");
        } else {
            p_info.meta_set("TITLE", "Unknown Tidal Track");
            p_info.meta_set("ARTIST", "Tidal");
        }
    }

    if (!m_trackID.empty()) {
        p_info.info_set("TIDAL_TRACK_ID", m_trackID.c_str());
    }
}

t_filestats TidalInfoReader::get_file_stats(abort_callback& p_abort) {
    t_filestats result;
    result.m_size = filesize_invalid;
    result.m_timestamp = filetimestamp_invalid;
    return result;
}

// TidalInputEntry implementation

bool TidalInputEntry::is_our_content_type(const char* p_type) {
    return false;  // We don't handle content types, only URLs
}

bool TidalInputEntry::is_our_path(const char* p_full_path, const char* p_extension) {
    if (!p_full_path || !*p_full_path) return false;

    return isTidalURL(p_full_path);
}

void TidalInputEntry::open_for_decoding(service_ptr_t<input_decoder>& p_instance,
                                         service_ptr_t<file> p_filehint,
                                         const char* p_path,
                                         abort_callback& p_abort) {
    service_ptr_t<TidalInputDecoder> instance = new service_impl_t<TidalInputDecoder>();
    instance->open(p_path, p_abort);
    p_instance = instance;
}

void TidalInputEntry::open_for_info_read(service_ptr_t<input_info_reader>& p_instance,
                                          service_ptr_t<file> p_filehint,
                                          const char* p_path,
                                          abort_callback& p_abort) {
    service_ptr_t<TidalInfoReader> instance = new service_impl_t<TidalInfoReader>();
    instance->open(p_path, p_abort);
    p_instance = instance;
}

void TidalInputEntry::open_for_info_write(service_ptr_t<input_info_writer>& p_instance,
                                           service_ptr_t<file> p_filehint,
                                           const char* p_path,
                                           abort_callback& p_abort) {
    pfc::throw_exception_with_message<exception_io_unsupported_format>("Tidal streams are read-only");
}

void TidalInputEntry::get_extended_data(service_ptr_t<file> p_filehint,
                                         const playable_location& p_location,
                                         const GUID& p_guid,
                                         mem_block_container& p_out,
                                         abort_callback& p_abort) {
    // Not implemented
}

unsigned TidalInputEntry::get_flags() {
    return 0;
}

GUID TidalInputEntry::get_guid() {
    return g_tidalInputGUID;
}

const char* TidalInputEntry::get_name() {
    return "Tidal Integration";
}

GUID TidalInputEntry::get_preferences_guid() {
    return pfc::guid_null;
}

bool TidalInputEntry::is_low_merit() {
    return false;
}

// Service registration
static service_factory_single_t<TidalInputEntry> g_tidalInputFactory;

} // namespace tidal
