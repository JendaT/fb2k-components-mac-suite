//
//  TidalInputDecoder.mm
//  foo_jl_tidal_mac
//
//  Input decoder implementation for tidal:// URLs
//

#import "TidalInputDecoder.h"
#import "TidalMemoryFile.h"
#import "TidalDashCache.h"
#import "../Core/URLUtils.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalErrors.h"
#import "../Core/StreamCache.h"
#import "../Services/TidalStreamResolver.h"
#import "../API/TidalConstants.h"
#import <dispatch/dispatch.h>

namespace tidal {

// Shared date formatter for metadata (NSDateFormatter is thread-safe on macOS 10.9+,
// so concurrent use from decoder and info-reader threads is fine)
static NSDateFormatter* sharedDateFormatter() {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd";
        fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return fmt;
}

// Overlay Tidal track metadata onto a file_info. Shared by TidalInputDecoder
// and TidalInfoReader. When logFields is true, TITLE/ARTIST sets are logged
// at debug level (info-reader diagnostics).
static void applyTrackMeta(file_info& p_info, JLTidalTrack* track, bool logFields) {
    if (track.title) {
        p_info.meta_set("TITLE", [track.title UTF8String]);
        if (logFields) {
            logDebug([[NSString stringWithFormat:@"TidalInfoReader: set TITLE=%@", track.title] UTF8String]);
        }
    }
    if (track.artist) {
        p_info.meta_set("ARTIST", [track.artist UTF8String]);
        if (logFields) {
            logDebug([[NSString stringWithFormat:@"TidalInfoReader: set ARTIST=%@", track.artist] UTF8String]);
        }
    }
    if (track.album) {
        p_info.meta_set("ALBUM", [track.album UTF8String]);
    }
    if (track.albumArtist) {
        p_info.meta_set("ALBUM ARTIST", [track.albumArtist UTF8String]);
    }
    if (track.duration > 0) {
        p_info.set_length(track.duration);
    }
    if (track.trackNumber > 0) {
        p_info.meta_set("TRACKNUMBER", [[NSString stringWithFormat:@"%ld", (long)track.trackNumber] UTF8String]);
    }
    if (track.discNumber > 0) {
        p_info.meta_set("DISCNUMBER", [[NSString stringWithFormat:@"%ld", (long)track.discNumber] UTF8String]);
    }
    if (track.totalTracks > 0) {
        p_info.meta_set("TOTALTRACKS", [[NSString stringWithFormat:@"%ld", (long)track.totalTracks] UTF8String]);
    }
    if (track.isrc) {
        p_info.meta_set("ISRC", [track.isrc UTF8String]);
    }
    if (track.releaseDate) {
        p_info.meta_set("DATE", [[sharedDateFormatter() stringFromDate:track.releaseDate] UTF8String]);
    }
    if (track.copyright) {
        p_info.meta_set("COPYRIGHT", [track.copyright UTF8String]);
    }
}

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
    , m_403Retry(false)
    , m_samplesDelivered(0) {
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

    // Two delivery modes: direct URL (HIGH/LOW/legacy) or DASH segments (LOSSLESS/HiRes).
    BOOL hasDASH = (tidal::TidalConfig::isDASHEnabled()
                    && resultInfo.dashSegmentCount > 0
                    && resultInfo.dashMediaTemplate.length);
    if (!resultInfo.streamURL && !hasDASH) {
        logError("Stream resolution returned neither URL nor DASH segments");
        pfc::throw_exception_with_message<exception_io_data>("No stream URL available");
    }
    if (resultInfo.streamURL) {
        m_streamURL = std::string([[resultInfo.streamURL absoluteString] UTF8String]);
    } else {
        // For DASH the "logical URL" is the first media segment — used for decoder
        // lookup by extension. Substitute $Number$=0 into the template.
        NSString *seg0 = [resultInfo.dashMediaTemplate
                          stringByReplacingOccurrencesOfString:@"$Number$"
                                                    withString:@"0"];
        m_streamURL = std::string([seg0 UTF8String]);
    }

    logDebug(("Got stream URL, quality: " + std::string([resultInfo.qualityDescription UTF8String])).c_str());

    // Also fetch metadata
    dispatch_semaphore_t metaSemaphore = dispatch_semaphore_create(0);
    __block JLTidalTrack* trackResult = nil;

    [[JLTidalStreamResolver shared] getMetadataForTrackID:trackIDStr
                                               completion:^(JLTidalTrack *track, NSError *error) {
        trackResult = track;
        dispatch_semaphore_signal(metaSemaphore);
    }];

    // Wait for metadata with abort checking (max 8 seconds)
    {
        int metaAttempts = 0;
        while (dispatch_semaphore_wait(metaSemaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
            if (p_abort.is_aborting() || m_abortFlag) {
                logDebug("Metadata fetch aborted");
                break;
            }
            if (++metaAttempts > 80) {  // 8 second timeout
                logDebug("Metadata fetch timed out");
                break;
            }
        }
    }
    m_trackInfo = trackResult;

    // Open underlying decoder for the stream URL
    // Log a short identifier for the stream URL (host + path basename) — full URL has secrets.
    NSString *urlStr = [resultInfo.streamURL absoluteString];
    NSString *urlHost = resultInfo.streamURL.host ?: @"?";
    NSString *urlPath = resultInfo.streamURL.path ?: @"";
    NSString *urlBase = [urlPath lastPathComponent] ?: @"?";
    logInfo([[NSString stringWithFormat:@"Stream open: track=%s codec=%@ quality=%@ host=%@ file=%@ urlLen=%lu",
              m_trackID.c_str(),
              resultInfo.codec ?: @"(nil)",
              resultInfo.qualityDescription ?: @"(nil)",
              urlHost, urlBase, (unsigned long)urlStr.length] UTF8String]);

    // Either open the direct HTTP stream, or download & concatenate DASH segments.
    service_ptr_t<file> streamFile;
    if (hasDASH) {
        // DASH path: assemble init + N media segments into one fMP4 file in
        // memory. Served from JLTidalDashCache — instant when a prefetch (or a
        // prior play) already assembled it, otherwise downloaded now. The blob
        // stays cached for replays and for the prefetcher's coalescing.
        NSString *tid = [NSString stringWithUTF8String:m_trackID.c_str()];
        abort_callback *pa = &p_abort;
        std::atomic<bool> *af = &m_abortFlag;
        NSData *assembled = [[JLTidalDashCache shared] blobForTrackID:tid
                                                        mediaTemplate:resultInfo.dashMediaTemplate
                                                         segmentCount:resultInfo.dashSegmentCount
                                                          isCancelled:^BOOL{
            return pa->is_aborting() || af->load();
        }];
        if (p_abort.is_aborting() || m_abortFlag) {
            // Cancellation — propagate as abort, NOT as a stream failure (or fb2k
            // will think the track is broken and advance to the next, cascading skips).
            throw exception_aborted();
        }
        if (!assembled || assembled.length == 0) {
            pfc::throw_exception_with_message<exception_io_data>("DASH segment download failed");
        }
        logInfo([[NSString stringWithFormat:@"DASH ready: %lu segments → %lu bytes (~%.1f MB)",
                  (unsigned long)resultInfo.dashSegmentCount,
                  (unsigned long)assembled.length,
                  assembled.length / (1024.0 * 1024.0)] UTF8String]);

        // Pick the right MIME so fb2k routes to the FLAC decoder for LOSSLESS instead
        // of a generic MP4 demuxer (mirrors python-tidal MimeType.from_audio_codec map,
        // tidalapi/media.py:138-157).
        const char *contentType = "audio/mp4";
        if ([resultInfo.codec isEqualToString:@"FLAC"]) {
            contentType = "audio/x-flac";
        } else if ([resultInfo.codec isEqualToString:@"EAC3"]) {
            contentType = "audio/eac3";
        }

        service_ptr_t<tidal::MemoryFile> memFile = fb2k::service_new<tidal::MemoryFile>();
        memFile->initWithData(assembled, contentType);
        streamFile = memFile;
    } else {
        try {
            filesystem::g_open(streamFile, m_streamURL.c_str(), filesystem::open_mode_read, p_abort);
        } catch (const exception_aborted &) {
            // fb2k cancelled the open (user skipped, next-track preload superseded,
            // shutdown, etc.). Re-throw as abort — DO NOT convert to exception_io_data,
            // otherwise the playback engine treats it as "track failed" and advances,
            // which causes a cascade of skip-fail-skip-fail across the playlist.
            throw;
        } catch (const std::exception& e) {
            // Genuine failure (network, 4xx/5xx, parse) — but double-check abort state
            // since some HTTP layers stringify abort instead of raising exception_aborted.
            if (p_abort.is_aborting() || m_abortFlag) throw exception_aborted();
            logError(("Failed to open stream file: " + std::string(e.what())).c_str());
            pfc::throw_exception_with_message<exception_io_data>(
                ("Failed to open stream: " + std::string(e.what())).c_str());
        }

        // Inspect the actual HTTP file size we got — premature EOF is a frequent
        // cause of "stalling/skipping" with Tidal preview clips or truncated CDN responses.
        try {
            t_filesize streamSize = streamFile->get_size(p_abort);
            if (streamSize == filesize_invalid) {
                logInfo("Stream file: size unknown (no Content-Length)");
            } else {
                logInfo([[NSString stringWithFormat:@"Stream file size: %llu bytes (~%.1f kB)",
                          (unsigned long long)streamSize, streamSize / 1024.0] UTF8String]);
                // For LOSSLESS FLAC a 5-min track is ~50MB; for HIGH AAC ~12MB.
                // Anything under ~500KB is almost certainly a preview clip.
                if (streamSize > 0 && streamSize < 500 * 1024) {
                    logError([[NSString stringWithFormat:@"Stream too small (%llu bytes) — likely a preview clip, account/track may be restricted",
                              (unsigned long long)streamSize] UTF8String]);
                }
            }
        } catch (const std::exception& e) {
            logError(("get_size failed: " + std::string(e.what())).c_str());
        }
    }

    // Try to find decoder by path (extension-based matching)
    input_entry::ptr entry;
    bool foundDecoder = input_entry::g_find_service_by_path(entry, m_streamURL.c_str());
    if (foundDecoder) {
        logInfo([[NSString stringWithFormat:@"Decoder found by path (ext of %@)",
                  [[NSString stringWithUTF8String:m_streamURL.c_str()] lastPathComponent]] UTF8String]);
    }

    if (!foundDecoder) {
        logDebug("No decoder found by path, trying content type fallback");

        // Map Tidal codec to MIME type for content-type based lookup
        NSString *codec = resultInfo.codec;
        const char* mimeType = nullptr;
        if ([codec isEqualToString:@"FLAC"]) {
            mimeType = "audio/flac";
        } else if ([codec isEqualToString:@"AAC"] || [codec isEqualToString:@"MP4A"]) {
            mimeType = "audio/mp4";
        } else if ([codec isEqualToString:@"MQA"]) {
            mimeType = "audio/flac";  // MQA is encoded in FLAC container
        } else if ([codec isEqualToString:@"EAC3"]) {
            mimeType = "audio/eac3";
        }

        if (mimeType) {
            logDebug(("Trying content type: " + std::string(mimeType)).c_str());
            foundDecoder = input_entry::g_find_service_by_content_type(entry, mimeType);
        }

        if (!foundDecoder) {
            // Last resort: try common extensions
            logDebug("Content type lookup failed, trying known extensions");
            foundDecoder = input_entry::g_find_service_by_path(entry, "dummy.flac");
            if (!foundDecoder) {
                foundDecoder = input_entry::g_find_service_by_path(entry, "dummy.m4a");
            }
        }
    }

    if (!foundDecoder) {
        logError("No decoder found for stream URL by any method");
        pfc::throw_exception_with_message<exception_io_data>("No decoder found for stream URL");
    }

    logDebug("Found decoder, opening for decoding...");
    try {
        entry->open_for_decoding(m_decoder, streamFile, m_streamURL.c_str(), p_abort);
    } catch (const exception_aborted &) {
        throw;
    } catch (const std::exception &e) {
        // Surface WHICH decoder failed and WHY before rethrowing — without this
        // the console shows "Found decoder, opening..." and then silence while
        // fb2k skips to the next track.
        logError(("open_for_decoding failed: " + std::string(e.what())).c_str());
        throw;
    }

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

        // Wait with abort checking (max 10 seconds)
        {
            int reopenAttempts = 0;
            while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
                if (p_abort.is_aborting() || m_abortFlag) return false;
                if (++reopenAttempts > 100) return false;
            }
        }

        if (resultError || !resultInfo) {
            return false;
        }

        if (!resultInfo.streamURL) {
            // DASH resolution has no direct stream URL; this retry path only
            // handles direct-URL streams.
            logDebug("tryReopen: no direct stream URL (DASH resolution), giving up");
            return false;
        }

        m_playbackInfo = resultInfo;
        m_streamURL = std::string([[resultInfo.streamURL absoluteString] UTF8String]);

        // Open new decoder
        service_ptr_t<file> streamFile;
        try {
            filesystem::g_open(streamFile, m_streamURL.c_str(), filesystem::open_mode_read, p_abort);
        } catch (...) {
            logError("tryReopen: failed to open new stream file");
            return false;
        }

        input_entry::ptr entry;
        if (!input_entry::g_find_service_by_path(entry, m_streamURL.c_str())) {
            // Fallback: try FLAC (most common Tidal format)
            if (!input_entry::g_find_service_by_content_type(entry, "audio/flac")) {
                return false;
            }
        }

        service_ptr_t<input_decoder> newDecoder;
        entry->open_for_decoding(newDecoder, streamFile, m_streamURL.c_str(), p_abort);

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
        applyTrackMeta(p_info, m_trackInfo, false);
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
        bool more = m_decoder->run(p_chunk, p_abort);
        if (more) {
            m_samplesDelivered += p_chunk.get_sample_count();
        } else {
            // EOF — detect premature EOF (track API says it's long but stream ended early).
            double declaredSec = m_trackInfo ? (double)m_trackInfo.duration : 0.0;
            double playedSec = (p_chunk.get_sample_rate() > 0)
                ? (double)m_samplesDelivered / (double)p_chunk.get_sample_rate() : 0.0;
            if (declaredSec > 30.0 && playedSec < declaredSec - 5.0) {
                logError([[NSString stringWithFormat:@"Premature EOF: played %.1fs of %.0fs declared — track was truncated (preview clip or stream cut off)",
                          playedSec, declaredSec] UTF8String]);
            }
        }
        return more;
    } catch (const exception_io& e) {
        const char* msg = e.what() ? e.what() : "(no message)";
        logError([[NSString stringWithFormat:@"Decoder run() exception_io for track %s: %s",
                  m_trackID.c_str(), msg] UTF8String]);
        // Check for 403 error (stream expired) — try one re-resolve
        if (strstr(msg, "403") || strstr(msg, "Forbidden")) {
            if (tryReopen(p_abort)) {
                logInfo("403 retry succeeded, resuming playback");
                return m_decoder->run(p_chunk, p_abort);
            }
            logError("403 retry failed");
        }
        throw;
    } catch (const std::exception& e) {
        logError([[NSString stringWithFormat:@"Decoder run() std::exception for track %s: %s",
                  m_trackID.c_str(), e.what()] UTF8String]);
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
        applyTrackMeta(p_info, m_trackInfo, true);
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
        p_info.info_set(kTidalMetadataTrackID.UTF8String, m_trackID.c_str());
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
