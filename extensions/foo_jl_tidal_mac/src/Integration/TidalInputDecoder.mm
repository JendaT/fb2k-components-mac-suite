//
//  TidalInputDecoder.mm
//  foo_jl_tidal_mac
//
//  Input decoder implementation for tidal:// URLs
//

#import "TidalInputDecoder.h"
#import "TidalMemoryFile.h"
#import "TidalDashFlacFile.h"
#import "TidalDashCache.h"
#import "../Core/URLUtils.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalErrors.h"
#import "../Core/StreamCache.h"
#import "../Services/TidalStreamResolver.h"
#import "../API/TidalConstants.h"
#import <dispatch/dispatch.h>
#include <algorithm>

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
        // Must match the UTC zone the date was parsed in (TidalModels.mm),
        // or the DATE tag renders a day earlier east of Greenwich.
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return fmt;
}

// Tidal's signed CDN URLs end in "....mp4?token=...". foobar2000 derives a
// file's extension from everything after the last dot, so the query string must
// be stripped before the URL touches any SDK path API:
//   - g_find_service_by_path() sees extension "mp4?token=..." and matches no
//     extension-based input, falling through to whatever claims URL schemes;
//   - the selected decoder re-runs its own is_our_path()/g_is_our_path() check
//     inside open_for_decoding(), and the same bogus extension makes it reject
//     the stream with "Unsupported file format".
// Lookup therefore uses a synthetic local filename carrying the real extension
// (so only genuine extension/content-type matching applies) and the decoder is
// handed the query-free URL. Shared by openStream and tryReopen.
static std::string pathWithoutQuery(const std::string &url) {
    size_t cut = url.find_first_of("?#");
    return (cut == std::string::npos) ? url : url.substr(0, cut);
}

// Collect every input that could handle this stream, best guess first:
// extension match on a synthetic local filename, then codec-derived content
// type, then the containers Tidal actually serves.
static std::vector<input_entry::ptr> decoderCandidates(const std::string &url, NSString *codec) {
    std::vector<input_entry::ptr> out;
    auto append = [&out](input_entry::ptr e) {
        if (e.is_empty()) return;
        for (const auto &have : out) {
            if (have == e) return;
        }
        out.push_back(e);
    };
    auto appendByPath = [&](const std::string &syntheticName) {
        pfc::list_t<input_entry::ptr> found;
        input_entry::g_find_inputs_by_path(found, syntheticName.c_str(), false);
        for (t_size i = 0; i < found.get_count(); i++) append(found[i]);
    };

    std::string path = pathWithoutQuery(url);
    size_t slash = path.find_last_of('/');
    std::string name = (slash == std::string::npos) ? path : path.substr(slash + 1);
    size_t dot = name.find_last_of('.');
    if (dot != std::string::npos && dot + 1 < name.size()) {
        appendByPath("track." + name.substr(dot + 1));
    }

    const char *mimeType = nullptr;
    if ([codec isEqualToString:@"FLAC"] || [codec isEqualToString:@"MQA"]) {
        mimeType = "audio/flac";  // MQA is encoded in a FLAC container
    } else if ([codec isEqualToString:@"AAC"] || [codec isEqualToString:@"MP4A"]) {
        mimeType = "audio/mp4";
    } else if ([codec isEqualToString:@"EAC3"]) {
        mimeType = "audio/eac3";
    }
    if (mimeType) {
        pfc::list_t<input_entry::ptr> found;
        input_entry::g_find_inputs_by_content_type(found, mimeType, false);
        for (t_size i = 0; i < found.get_count(); i++) append(found[i]);
    }

    appendByPath("track.m4a");
    appendByPath("track.mp4");
    appendByPath("track.flac");
    return out;
}

static std::string decoderName(const input_entry::ptr &entry) {
    input_entry_v2::ptr v2;
    if (entry->service_query_t(v2)) return std::string(v2->get_name());
    return std::string("unnamed input");
}

// Open the stream with the first candidate that actually accepts it.
//
// Several inputs claim the same extension — foobar2000 registers both an "MP4
// Demuxer" and an "MP4 Stream Demuxer" — and only one of them may accept a
// given Tidal stream. Which one comes first depends on input enumeration
// order, which varies between launches, so picking the first claimer made
// playback work or fail seemingly at random across restarts. fb2k's own
// g_open_from_list tries every candidate and falls through on failure; this
// mirrors that, and logs which input accepted or rejected the stream.
static void openDecoderForStream(service_ptr_t<input_decoder> &outDecoder,
                                 const std::string &url, NSString *codec,
                                 const service_ptr_t<file> &streamFile,
                                 abort_callback &p_abort) {
    std::vector<input_entry::ptr> candidates = decoderCandidates(url, codec);
    if (candidates.empty()) {
        pfc::throw_exception_with_message<exception_io_data>("No decoder found for stream URL");
    }

    const std::string cleanPath = pathWithoutQuery(url);
    std::exception_ptr firstFailure;
    for (const auto &entry : candidates) {
        try {
            entry->open_for_decoding(outDecoder, streamFile, cleanPath.c_str(), p_abort);
            logInfo(("Decoder opened the stream: " + decoderName(entry)).c_str());
            return;
        } catch (const exception_aborted &) {
            throw;
        } catch (const std::exception &e) {
            if (p_abort.is_aborting()) throw exception_aborted();
            logInfo(("Decoder " + decoderName(entry) + " rejected the stream: " +
                     std::string(e.what()) + " — trying next").c_str());
            if (!firstFailure) firstFailure = std::current_exception();
        }
    }

    if (firstFailure) std::rethrow_exception(firstFailure);
    pfc::throw_exception_with_message<exception_io_data>("No decoder accepted the stream");
}

// Overlay Tidal track metadata onto a file_info. Shared by TidalInputDecoder
// and TidalInfoReader. When logFields is true, TITLE/ARTIST sets are logged
// at debug level (info-reader diagnostics).
static void applyTrackMeta(file_info& p_info, JLTidalTrack* track, bool logFields) {
    if (track.title) {
        NSString *title = track.displayTitle;
        p_info.meta_set("TITLE", [title UTF8String]);
        if (logFields) {
            logDebug([[NSString stringWithFormat:@"TidalInfoReader: set TITLE=%@", title] UTF8String]);
        }
    }
    // Every credited artist, not just the first: a collaboration otherwise
    // loses its featured names. meta_add appends additional values to the
    // same field, which is how fb2k models multi-value tags.
    if (track.allArtists.count > 0) {
        BOOL first = YES;
        for (NSString *name in track.allArtists) {
            if (first) {
                p_info.meta_set("ARTIST", [name UTF8String]);
                first = NO;
            } else {
                p_info.meta_add("ARTIST", [name UTF8String]);
            }
        }
        if (logFields) {
            logDebug([[NSString stringWithFormat:@"TidalInfoReader: set ARTIST=%@",
                       [track.allArtists componentsJoinedByString:@"; "]] UTF8String]);
        }
    } else if (track.artist) {
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
    // The catalogue duration is whole seconds; the inner decoder knows the
    // exact length. Only fill in when it has not already been established, or
    // a 4:12.37 track reports 4:12 and the seekbar disagrees with the audio.
    if (track.duration > 0 && p_info.get_length() <= 0) {
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
    if (track.bpm > 0) {
        p_info.meta_set("BPM", [[NSString stringWithFormat:@"%lld", llround(track.bpm)] UTF8String]);
    }
    if (track.releaseDate) {
        p_info.meta_set("DATE", [[sharedDateFormatter() stringFromDate:track.releaseDate] UTF8String]);
    }
    if (track.copyright) {
        p_info.meta_set("COPYRIGHT", [track.copyright UTF8String]);
    }
    if (track.isExplicit) {
        p_info.meta_set("EXPLICIT", "1");
    }
    // Catalogue ReplayGain, so a TIDAL track sits at the same level as the
    // local files around it when fb2k's ReplayGain processing is on.
    if (track.hasReplayGain && TidalConfig::isReplayGainEnabled()) {
        replaygain_info rg = p_info.get_replaygain();
        rg.m_track_gain = (float)track.replayGain;
        if (track.peakAmplitude > 0) rg.m_track_peak = (float)track.peakAmplitude;
        p_info.set_replaygain(rg);
    }
}

size_t stripStoredTidalReplayGain() {
    auto pm = playlist_manager::get();
    metadb_handle_list handles;
    for (t_size p = 0; p < pm->get_playlist_count(); p++) {
        metadb_handle_list items;
        pm->playlist_get_all_items(p, items);
        for (t_size i = 0; i < items.get_count(); i++) {
            if (isPlayableTidalTrackURL(items[i]->get_path())) handles.add_item(items[i]);
        }
    }
    handles.sort_by_pointer_remove_duplicates();

    auto hints = metadb_io_v2::get()->create_hint_list();
    size_t changed = 0;
    for (t_size i = 0; i < handles.get_count(); i++) {
        metadb_info_container::ptr stored;
        if (!handles[i]->get_info_ref(stored)) continue;
        replaygain_info rg = stored->info().get_replaygain();
        if (!rg.is_track_gain_present() && !rg.is_album_gain_present() &&
            !rg.is_track_peak_present() && !rg.is_album_peak_present()) continue;
        file_info_impl copy(stored->info());
        copy.reset_replaygain();
        // Fresh, or the hint ranks below the info already stored and is dropped.
        hints->add_hint(handles[i], copy, stored->stats(), true);
        changed++;
    }
    // on_done() refreshes every playlist and viewer, so only when it matters.
    if (changed > 0) hints->on_done();
    return changed;
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
    [m_dashStream close];
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
    m_pinnedQuality = parsed->quality;
    logDebug(("Track ID: " + m_trackID +
              (m_pinnedQuality ? " (pinned " + std::string(JLTidalQualityToString(*m_pinnedQuality).UTF8String) + ")"
                               : "")).c_str());

    // Resolve stream URL
    openStream(p_abort);
}

// One place decides which tier a play asks for: the entry's pin when it has
// one, otherwise whatever the preferences say right now.
void TidalInputDecoder::resolveStream(NSString* trackIDStr, JLTidalStreamResolverCompletion completion) {
    if (m_pinnedQuality) {
        [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackIDStr
                                                        quality:*m_pinnedQuality
                                                     completion:completion];
    } else {
        [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackIDStr
                                                     completion:completion];
    }
}

// Milliseconds between two CFAbsoluteTime stamps, for the open-timing line.
static long elapsedMs(CFAbsoluteTime from, CFAbsoluteTime to) {
    return (long)((to - from) * 1000.0);
}

void TidalInputDecoder::openStream(abort_callback& p_abort) {
    logDebug(("Resolving stream for track: " + m_trackID).c_str());

    // Every step below can block the playback thread, and fb2k opens the next
    // track only when the current one runs out, so whatever this takes is
    // heard as a gap between tracks. Time each step so the console says which.
    const CFAbsoluteTime tStart = CFAbsoluteTimeGetCurrent();

    // Use dispatch semaphore for synchronous resolution
    __block JLTidalPlaybackInfo* resultInfo = nil;
    __block NSError* resultError = nil;

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSString* trackIDStr = [NSString stringWithUTF8String:m_trackID.c_str()];

    resolveStream(trackIDStr, ^(JLTidalPlaybackInfo *info, NSError *error) {
        resultInfo = info;
        resultError = error;
        dispatch_semaphore_signal(semaphore);
    });

    // Wait for resolution, polling for abort. Bounded: the resolver now retries
    // internally, and a completion that never arrives at all (a wedged
    // connection, a handler dropped on the floor) would otherwise hang this
    // decoder thread forever with fb2k showing "Opening..." and no way out but
    // a force quit. Every sibling wait in this file already has a ceiling.
    static const int kResolveTimeoutTicks = 450;  // 45s at 100ms per tick
    int resolveTicks = 0;
    while (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (p_abort.is_aborting() || m_abortFlag) {
            pfc::throw_exception_with_message<exception_aborted>("Operation aborted");
        }
        if (++resolveTicks > kResolveTimeoutTicks) {
            logError(("Stream resolution timed out for track " + m_trackID).c_str());
            pfc::throw_exception_with_message<exception_io_data>("Stream resolution timed out");
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
    const CFAbsoluteTime tResolved = CFAbsoluteTimeGetCurrent();

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
    const CFAbsoluteTime tMeta = CFAbsoluteTimeGetCurrent();

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
    const char *streamSource = "http";
    if (hasDASH) {
        // DASH path: assemble init + N media segments into one fMP4 file in
        // memory. Served from JLTidalDashCache — instant when a prefetch (or a
        // prior play) already assembled it, otherwise downloaded now. The blob
        // stays cached for replays and for the prefetcher's coalescing.
        NSString *tid = [NSString stringWithUTF8String:m_trackID.c_str()];
        abort_callback *pa = &p_abort;
        std::atomic<bool> *af = &m_abortFlag;
        // A miss here means the prefetch did not cover this track (first
        // track, shuffle, a failed prefetch) or is still downloading it.
        BOOL cached = [[JLTidalDashCache shared] cachedBlobForTrackID:tid quality:resultInfo.quality] != nil;
        streamSource = cached ? "prefetched" : "downloaded now";
        if (!cached) {
            [[JLTidalDashCache shared] abandonPrefetchesExceptTrackID:tid quality:resultInfo.quality];
            if (openProgressive(tid, resultInfo, p_abort)) {
                const CFAbsoluteTime tDone = CFAbsoluteTimeGetCurrent();
                logDebug([[NSString stringWithFormat:
                          @"Open timing for track %s: %ld ms total (resolve %ld, metadata %ld, first audio %ld [progressive])",
                          m_trackID.c_str(), elapsedMs(tStart, tDone),
                          elapsedMs(tStart, tResolved), elapsedMs(tResolved, tMeta),
                          elapsedMs(tMeta, tDone)] UTF8String]);
                return;
            }
        }
        NSData *assembled = [[JLTidalDashCache shared] blobForTrackID:tid
                                                              quality:resultInfo.quality
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

    const CFAbsoluteTime tStream = CFAbsoluteTimeGetCurrent();

    try {
        tidal::openDecoderForStream(m_decoder, m_streamURL, resultInfo.codec, streamFile, p_abort);
    } catch (const exception_aborted &) {
        throw;
    } catch (const std::exception &e) {
        // Every candidate rejected the stream — surface why before fb2k skips
        // the track, otherwise the console goes silent here.
        logError(("No decoder accepted the stream: " + std::string(e.what())).c_str());
        throw;
    }

    if (!m_decoder.is_valid()) {
        logError("Failed to open stream decoder");
        pfc::throw_exception_with_message<exception_io_data>("Failed to open stream decoder");
    }

    const CFAbsoluteTime tDone = CFAbsoluteTimeGetCurrent();
    logDebug([[NSString stringWithFormat:
              @"Open timing for track %s: %ld ms total (resolve %ld, metadata %ld, stream %ld [%s], decoder %ld)",
              m_trackID.c_str(), elapsedMs(tStart, tDone),
              elapsedMs(tStart, tResolved), elapsedMs(tResolved, tMeta),
              elapsedMs(tMeta, tStream), streamSource, elapsedMs(tStream, tDone)] UTF8String]);

    logDebug("Stream opened successfully");
}

bool TidalInputDecoder::openProgressive(NSString* trackID, JLTidalPlaybackInfo* info,
                                        abort_callback& p_abort) {
    // FLAC only: the remux unwraps FLAC frames, and FLAC is what Tidal serves
    // through DASH. Anything else waits for the whole blob as before.
    if (![info.codec isEqualToString:@"FLAC"]) return false;

    JLTidalDashStream *stream = [[JLTidalDashCache shared] openStreamForTrackID:trackID
                                                                        quality:info.quality
                                                                  mediaTemplate:info.dashMediaTemplate
                                                                   segmentCount:info.dashSegmentCount];
    if (!stream) return false;  // finished meanwhile: the cached blob is faster still

    // FLAC inputs only. A container demuxer probing raw FLAC can read a box
    // "size" out of the stream header and seek to it, and on this file a far
    // seek waits for the download -- the very stall this path removes.
    std::vector<input_entry::ptr> candidates;
    auto collect = [&candidates](const pfc::list_t<input_entry::ptr> &found) {
        for (t_size i = 0; i < found.get_count(); i++) {
            if (std::find(candidates.begin(), candidates.end(), found[i]) == candidates.end()) {
                candidates.push_back(found[i]);
            }
        }
    };
    {
        // Separate lists: the SDK lookups may reset the list they fill.
        pfc::list_t<input_entry::ptr> byPath, byType;
        input_entry::g_find_inputs_by_path(byPath, "track.flac", false);
        collect(byPath);
        input_entry::g_find_inputs_by_content_type(byType, "audio/flac", false);
        collect(byType);
    }

    for (const auto &entry : candidates) {
        // A fresh file per candidate: a rejected probe leaves its read
        // position wherever it stopped.
        service_ptr_t<DashFlacFile> flac = fb2k::service_new<DashFlacFile>();
        flac->init(stream, (uint64_t)MAX(info.dashTotalDuration, 0), (uint64_t)MAX(info.dashTimescale, 0));
        try {
            entry->open_for_decoding(m_decoder, flac, "track.flac", p_abort);
            logInfo(("Decoder opened the progressive stream: " + decoderName(entry)).c_str());
            m_dashStream = stream;
            return true;
        } catch (const exception_aborted &) {
            [stream close];
            throw;
        } catch (const std::exception &e) {
            if (p_abort.is_aborting() || m_abortFlag) {
                [stream close];
                throw exception_aborted();
            }
            logInfo(("Decoder " + decoderName(entry) + " rejected the progressive stream: " +
                     std::string(e.what())).c_str());
        }
    }

    m_decoder.release();
    [stream close];
    logInfo("Progressive start unavailable; waiting for the whole track instead");
    return false;
}

void TidalInputDecoder::seekProgressive(double p_seconds, abort_callback& p_abort) {
    logInfo([[NSString stringWithFormat:@"Seek to %.1fs before the download finished: waiting for the rest of track %s",
              p_seconds, m_trackID.c_str()] UTF8String]);
    abort_callback *pa = &p_abort;
    std::atomic<bool> *af = &m_abortFlag;
    NSData *blob = [m_dashStream waitForBlobWithCancel:^BOOL{
        return pa->is_aborting() || af->load();
    }];
    if (p_abort.is_aborting() || m_abortFlag) throw exception_aborted();
    if (blob.length == 0) {
        pfc::throw_exception_with_message<exception_io_data>("DASH segment download failed");
    }

    service_ptr_t<tidal::MemoryFile> memFile = fb2k::service_new<tidal::MemoryFile>();
    memFile->initWithData(blob, "audio/x-flac");
    service_ptr_t<input_decoder> full;
    tidal::openDecoderForStream(full, m_streamURL, m_playbackInfo.codec, memFile, p_abort);
    full->initialize(m_subsong, m_flags, p_abort);
    full->seek(p_seconds, p_abort);

    m_decoder = full;
    [m_dashStream close];
    m_dashStream = nil;
    m_decodedSeconds = p_seconds;
    m_samplesDelivered = 0;
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

        resolveStream(trackIDStr, ^(JLTidalPlaybackInfo *info, NSError *error) {
            resultInfo = info;
            resultError = error;
            dispatch_semaphore_signal(semaphore);
        });

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

        service_ptr_t<input_decoder> newDecoder;
        tidal::openDecoderForStream(newDecoder, m_streamURL, resultInfo.codec, streamFile, p_abort);

        if (!newDecoder.is_valid()) {
            return false;
        }

        m_decoder = newDecoder;
        m_decoder->initialize(m_subsong, m_flags, p_abort);

        // initialize() rewinds to the start (SDK/input.h), so without this the
        // track restarts at 0:00 while fb2k's position clock keeps counting
        // from where it was -- audio and seekbar silently disagree.
        double resumeAt = decodedSeconds();
        if (resumeAt > 0.0) {
            if (!m_decoder->can_seek()) {
                logError("Re-resolved stream is not seekable; cannot resume mid-track");
                return false;
            }
            m_decoder->seek(resumeAt, p_abort);
            logInfo([[NSString stringWithFormat:@"Resumed re-resolved stream at %.1fs", resumeAt] UTF8String]);
        }

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

    // Overlay our metadata. When the metadata fetch failed, m_trackInfo is nil
    // and there is nothing to add -- publishing an empty overlay would have
    // fb2k commit blank TITLE/ARTIST/ALBUM over the inner decoder's own tags.
    if (m_trackInfo) {
        applyTrackMeta(p_info, m_trackInfo, false);
    }

    // Off means Tidal tracks carry no ReplayGain at all, whatever the inner
    // decoder or the catalogue says, so fb2k treats them like untagged files.
    const bool useReplayGain = TidalConfig::isReplayGainEnabled();
    if (!useReplayGain) {
        p_info.reset_replaygain();
    }

    // Add quality info
    if (m_playbackInfo) {
        p_info.info_set(kTidalMetadataQuality.UTF8String, [m_playbackInfo.qualityDescription UTF8String]);
        p_info.info_set(kTidalMetadataTrackID.UTF8String, m_trackID.c_str());

        // Stream-level ReplayGain beats the catalogue value when both exist:
        // it describes the asset actually being decoded.
        if (useReplayGain && (m_playbackInfo.hasReplayGain || m_playbackInfo.hasAlbumReplayGain)) {
            replaygain_info rg = p_info.get_replaygain();
            if (m_playbackInfo.hasReplayGain) {
                rg.m_track_gain = (float)m_playbackInfo.trackReplayGain;
                if (m_playbackInfo.trackPeakAmplitude > 0) {
                    rg.m_track_peak = (float)m_playbackInfo.trackPeakAmplitude;
                }
            }
            if (m_playbackInfo.hasAlbumReplayGain) {
                rg.m_album_gain = (float)m_playbackInfo.albumReplayGain;
                if (m_playbackInfo.albumPeakAmplitude > 0) {
                    rg.m_album_peak = (float)m_playbackInfo.albumPeakAmplitude;
                }
            }
            p_info.set_replaygain(rg);
        }
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
        // The inner demuxer may index the whole stream here rather than in
        // open, which would put it outside the open-timing line above.
        const CFAbsoluteTime tStart = CFAbsoluteTimeGetCurrent();
        m_decoder->initialize(p_subsong, p_flags, p_abort);
        logDebug([[NSString stringWithFormat:@"Decoder initialize for track %s: %ld ms",
                  m_trackID.c_str(), elapsedMs(tStart, CFAbsoluteTimeGetCurrent())] UTF8String]);
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
            // Seconds, not just samples: the sample rate is only known once a
            // chunk has arrived, and the 403 resume needs a time to seek to.
            if (p_chunk.get_sample_rate() > 0) {
                m_decodedSeconds += (double)p_chunk.get_sample_count() / (double)p_chunk.get_sample_rate();
            }
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
    } catch (const exception_aborted&) {
        // Stop/Next during a network read is routine, not a fault. Logging it
        // at error level printed "Decoder run() std::exception ... User abort"
        // on every skip. Same ordering as openStream.
        throw;
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
    if (!m_decoder.is_valid()) return;
    if (m_dashStream) {
        seekProgressive(p_seconds, p_abort);
        return;
    }

    // Seeking issues a fresh ranged request, so it is the likeliest moment for
    // an expired signed URL to surface. Previously this went uncaught and the
    // track died outright.
    try {
        m_decoder->seek(p_seconds, p_abort);
        m_decodedSeconds = p_seconds;
        m_samplesDelivered = 0;
        return;
    } catch (const exception_aborted&) {
        throw;
    } catch (const exception_io& e) {
        const char* msg = e.what() ? e.what() : "(no message)";
        logError([[NSString stringWithFormat:@"Seek failed for track %s: %s",
                  m_trackID.c_str(), msg] UTF8String]);
        if (!(strstr(msg, "403") || strstr(msg, "Forbidden"))) throw;
    }

    m_decodedSeconds = p_seconds;   // resume target for the re-open
    m_samplesDelivered = 0;
    if (!tryReopen(p_abort)) {
        logError("Seek re-resolve failed");
        pfc::throw_exception_with_message<exception_io_data>("Stream expired and could not be re-resolved");
    }
    logInfo("Seek succeeded after re-resolving the stream");
}

bool TidalInputDecoder::can_seek() {
    // The progressive stream itself cannot seek, but seekProgressive can.
    if (m_dashStream) return true;
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

    // Failure handling here matters more than it looks: fb2k treats a reader
    // that returns normally as a successful read and COMMITS whatever get_info
    // writes. Returning on abort/timeout/error meant "Reload info" while
    // offline or rate-limited replaced good tags with "Tidal Track <id>".
    // Only a genuinely unparsable URL keeps the placeholder path.
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
            pfc::throw_exception_with_message<exception_aborted>("Operation aborted");
        }
        if (++attempts > 50) {  // 5 second timeout
            logError(("TidalInfoReader: metadata fetch timed out for track " + m_trackID).c_str());
            pfc::throw_exception_with_message<exception_io_data>("Tidal metadata fetch timed out");
        }
    }

    if (fetchError) {
        logError([[NSString stringWithFormat:@"TidalInfoReader: metadata fetch failed: %@",
                   fetchError.localizedDescription] UTF8String]);
        pfc::throw_exception_with_message<exception_io_data>(
            [[NSString stringWithFormat:@"Tidal metadata unavailable: %@",
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

    // Tracks only. Claiming tidal://album/... or tidal://playlist/... admitted
    // entries fb2k could never decode: they sat in the playlist looking normal
    // and failed the moment they were played. Those forms are expanded by the
    // browser instead.
    return isPlayableTidalTrackURL(p_full_path);
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

// Normalises pasted tidal.com web links to the internal tidal://track/<id>
// form, so dragging or pasting a browser URL yields an entry with add-time
// metadata instead of one the input has to re-parse on every open.
//
// Per SDK/link_resolver.h a link may only point at a playable object, never at
// a playlist or another link, which is why only track URLs are accepted.
namespace {

class TidalLinkResolver : public link_resolver {
public:
    bool is_our_path(const char* p_path, const char* p_extension) override {
        if (!p_path || !*p_path) return false;
        // Only the web forms need rewriting; tidal:// is already canonical.
        if (strncmp(p_path, "tidal://", 8) == 0) return false;
        return tidal::isPlayableTidalTrackURL(p_path);
    }

    void resolve(service_ptr_t<file> p_filehint, const char* p_path,
                 pfc::string_base& p_out, abort_callback& p_abort) override {
        auto parsed = tidal::parseURL(std::string(p_path ? p_path : ""));
        if (!parsed.has_value() || parsed->type != tidal::TidalContentType::Track) {
            pfc::throw_exception_with_message<exception_io_data>("Not a Tidal track link");
        }
        p_out = tidal::makeTrackURL(parsed->id).c_str();
    }
};

static service_factory_single_t<TidalLinkResolver> g_tidalLinkResolver;

}  // namespace
