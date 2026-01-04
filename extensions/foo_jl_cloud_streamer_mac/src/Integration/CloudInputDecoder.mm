#import "CloudInputDecoder.h"
#import "../Core/URLUtils.h"
#import "../Core/CloudConfig.h"
#import "../Core/CloudErrors.h"
#import "../Core/MetadataCache.h"
#import "../Services/StreamResolver.h"

namespace cloud_streamer {

// GUIDs for this input
// {7A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D}
static const GUID g_cloudInputGUID =
    { 0x7a1b2c3d, 0x4e5f, 0x6a7b, { 0x8c, 0x9d, 0x0e, 0x1f, 0x2a, 0x3b, 0x4c, 0x5d } };

// CloudInputDecoder implementation

CloudInputDecoder::CloudInputDecoder()
    : m_abortFlag(false)
    , m_initialized(false)
    , m_flags(0)
    , m_subsong(0)
    , m_403Retry(false) {
}

CloudInputDecoder::~CloudInputDecoder() {
    m_abortFlag = true;
}

void CloudInputDecoder::open(const char* p_path, abort_callback& p_abort) {
    std::string path(p_path);
    m_abortFlag = false;
    m_403Retry = false;

    console::info(("[Cloud Streamer] open() called with: " + path).c_str());

    // Convert web URL to internal scheme if needed
    if (URLUtils::isInternalScheme(path)) {
        m_internalURL = path;
        console::info(("[Cloud Streamer] Using internal URL: " + m_internalURL).c_str());
    } else if (URLUtils::isCloudWebURL(path)) {
        m_internalURL = URLUtils::webURLToInternalScheme(path);
        if (m_internalURL.empty()) {
            console::error("[Cloud Streamer] Failed to convert URL to internal scheme");
            pfc::throw_exception_with_message<exception_io_data>("Failed to convert URL to internal scheme");
        }
        console::info(("[Cloud Streamer] Converted to internal URL: " + m_internalURL).c_str());
    } else {
        console::error(("[Cloud Streamer] Unsupported URL format: " + path).c_str());
        pfc::throw_exception_with_message<exception_io_data>("Unsupported URL format");
    }

    // Resolve stream URL
    console::info("[Cloud Streamer] Resolving stream URL...");
    openStream(p_abort);
    console::info("[Cloud Streamer] Stream opened successfully");
}

void CloudInputDecoder::openStream(abort_callback& p_abort) {
    // Resolve stream URL
    console::info(("[Cloud Streamer] Resolving: " + m_internalURL).c_str());
    auto result = StreamResolver::shared().resolve(m_internalURL, &m_abortFlag);

    if (!result.success) {
        std::string errorMsg = "Failed to resolve stream: " + result.errorMessage;
        console::error(("[Cloud Streamer] " + errorMsg).c_str());
        pfc::throw_exception_with_message<exception_io_data>(errorMsg.c_str());
    }

    m_streamURL = result.streamURL;
    m_trackInfo = result.trackInfo;

    console::info(("[Cloud Streamer] Got stream URL: " + m_streamURL.substr(0, 80) + "...").c_str());

    // Open underlying decoder for the stream URL
    input_entry::ptr entry;
    if (!input_entry::g_find_service_by_path(entry, m_streamURL.c_str())) {
        console::error("[Cloud Streamer] No decoder found for stream URL");
        pfc::throw_exception_with_message<exception_io_data>("No decoder found for stream URL");
    }

    console::info("[Cloud Streamer] Found decoder, opening stream...");
    entry->open_for_decoding(m_decoder, nullptr, m_streamURL.c_str(), p_abort);

    if (!m_decoder.is_valid()) {
        console::error("[Cloud Streamer] Failed to open stream decoder");
        pfc::throw_exception_with_message<exception_io_data>("Failed to open stream decoder");
    }
}

bool CloudInputDecoder::tryReopen(abort_callback& p_abort) {
    if (m_403Retry) {
        // Already tried once
        return false;
    }

    m_403Retry = true;
    logDebug("CloudInputDecoder: trying to re-resolve stream (403 retry)");

    try {
        // Bypass cache to get fresh URL
        auto result = StreamResolver::shared().resolveBypassCache(m_internalURL, &m_abortFlag);

        if (!result.success) {
            return false;
        }

        m_streamURL = result.streamURL;

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

        // Re-initialize at same position would be nice, but just start fresh
        m_decoder = newDecoder;
        m_decoder->initialize(m_subsong, m_flags, p_abort);

        logDebug("CloudInputDecoder: successfully re-resolved stream");
        return true;
    } catch (...) {
        return false;
    }
}

t_uint32 CloudInputDecoder::get_subsong_count() {
    return 1;
}

t_uint32 CloudInputDecoder::get_subsong(t_uint32 p_index) {
    return 0;
}

void CloudInputDecoder::get_info(t_uint32 p_subsong, file_info& p_info, abort_callback& p_abort) {
    // Try underlying decoder first
    if (m_decoder.is_valid()) {
        try {
            m_decoder->get_info(p_subsong, p_info, p_abort);
        } catch (...) {
            // Fall through to use our metadata
        }
    }

    // Overlay our metadata if available
    if (m_trackInfo.has_value()) {
        const TrackInfo& info = m_trackInfo.value();

        if (!info.title.empty()) {
            p_info.meta_set("TITLE", info.title.c_str());
        }
        if (!info.artist.empty()) {
            p_info.meta_set("ARTIST", info.artist.c_str());
        }
        if (!info.album.empty()) {
            p_info.meta_set("ALBUM", info.album.c_str());
        }
        if (!info.uploader.empty()) {
            p_info.meta_set("UPLOADER", info.uploader.c_str());
        }
        if (!info.description.empty()) {
            p_info.meta_set("COMMENT", info.description.c_str());
        }
        if (!info.uploadDate.empty()) {
            p_info.meta_set("DATE", info.uploadDate.c_str());
        }
        if (info.duration > 0) {
            p_info.set_length(info.duration);
        }

        // Add tags
        for (const auto& tag : info.tags) {
            p_info.meta_add("GENRE", tag.c_str());
        }

        // Service info
        const char* serviceName = info.service == CloudService::Mixcloud ? "Mixcloud" : "SoundCloud";
        p_info.info_set("CLOUD_SERVICE", serviceName);
        if (!info.webURL.empty()) {
            p_info.info_set("URL", info.webURL.c_str());
        }

        // Add embedded CUE sheet for chapter navigation
        std::string cueSheet = info.generateCueSheet();
        if (!cueSheet.empty()) {
            p_info.meta_set("CUESHEET", cueSheet.c_str());
            logDebug("CloudInputDecoder: Generated CUE sheet with " +
                     std::to_string(info.chapters.size()) + " chapters");
        }
    }
}

t_filestats CloudInputDecoder::get_file_stats(abort_callback& p_abort) {
    if (m_decoder.is_valid()) {
        return m_decoder->get_file_stats(p_abort);
    }
    t_filestats result;
    result.m_size = filesize_invalid;
    result.m_timestamp = filetimestamp_invalid;
    return result;
}

void CloudInputDecoder::initialize(t_uint32 p_subsong, unsigned p_flags, abort_callback& p_abort) {
    m_subsong = p_subsong;
    m_flags = p_flags;
    m_initialized = true;

    if (m_decoder.is_valid()) {
        m_decoder->initialize(p_subsong, p_flags, p_abort);
    }
}

bool CloudInputDecoder::run(audio_chunk& p_chunk, abort_callback& p_abort) {
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

void CloudInputDecoder::seek(double p_seconds, abort_callback& p_abort) {
    if (m_decoder.is_valid()) {
        m_decoder->seek(p_seconds, p_abort);
    }
}

bool CloudInputDecoder::can_seek() {
    if (m_decoder.is_valid()) {
        return m_decoder->can_seek();
    }
    return false;
}

bool CloudInputDecoder::get_dynamic_info(file_info& p_out, double& p_timestamp_delta) {
    if (m_decoder.is_valid()) {
        return m_decoder->get_dynamic_info(p_out, p_timestamp_delta);
    }
    return false;
}

bool CloudInputDecoder::get_dynamic_info_track(file_info& p_out, double& p_timestamp_delta) {
    if (m_decoder.is_valid()) {
        return m_decoder->get_dynamic_info_track(p_out, p_timestamp_delta);
    }
    return false;
}

void CloudInputDecoder::on_idle(abort_callback& p_abort) {
    if (m_decoder.is_valid()) {
        m_decoder->on_idle(p_abort);
    }
}

bool CloudInputDecoder::run_raw(audio_chunk& out, mem_block_container& outRaw, abort_callback& abort) {
    throw pfc::exception_not_implemented();
}

void CloudInputDecoder::set_logger(event_logger::ptr ptr) {
    m_logger = ptr;
    // Can't forward to m_decoder as it may not exist yet
}

// CloudInfoReader implementation (lightweight, no stream resolution)

void CloudInfoReader::open(const char* p_path) {
    std::string path(p_path);

    // Convert to internal scheme if needed
    if (URLUtils::isInternalScheme(path)) {
        m_internalURL = path;
    } else if (URLUtils::isCloudWebURL(path)) {
        m_internalURL = URLUtils::webURLToInternalScheme(path);
    } else {
        m_internalURL = path;
    }

    // Check metadata cache for existing info
    m_cachedInfo = MetadataCache::shared().get(m_internalURL);
}

void CloudInfoReader::get_info(t_uint32 p_subsong, file_info& p_info, abort_callback& p_abort) {
    // Use cached metadata if available
    if (m_cachedInfo.has_value()) {
        const TrackInfo& info = m_cachedInfo.value();

        if (!info.title.empty()) {
            p_info.meta_set("TITLE", info.title.c_str());
        }
        if (!info.artist.empty()) {
            p_info.meta_set("ARTIST", info.artist.c_str());
        }
        if (!info.album.empty()) {
            p_info.meta_set("ALBUM", info.album.c_str());
        }
        if (!info.uploader.empty()) {
            p_info.meta_set("UPLOADER", info.uploader.c_str());
        }
        if (info.duration > 0) {
            p_info.set_length(info.duration);
        }

        const char* serviceName = info.service == CloudService::Mixcloud ? "Mixcloud" : "SoundCloud";
        p_info.info_set("CLOUD_SERVICE", serviceName);

        // Add embedded CUE sheet for chapter navigation
        std::string cueSheet = info.generateCueSheet();
        if (!cueSheet.empty()) {
            p_info.meta_set("CUESHEET", cueSheet.c_str());
        }
        return;
    }

    // No cached info - generate basic info from URL
    ParsedCloudURL parsed = URLUtils::parseURL(m_internalURL);

    // Generate title from slug (replace dashes with spaces)
    if (!parsed.slug.empty()) {
        std::string title = parsed.slug;
        for (char& c : title) {
            if (c == '-' || c == '_') c = ' ';
        }
        p_info.meta_set("TITLE", title.c_str());
    }

    // Use username as artist
    if (!parsed.username.empty()) {
        p_info.meta_set("ARTIST", parsed.username.c_str());
    }

    // Set service info
    const char* serviceName = parsed.service == CloudService::Mixcloud ? "Mixcloud" : "SoundCloud";
    p_info.info_set("CLOUD_SERVICE", serviceName);

    // Duration unknown without resolving
    p_info.set_length(0);
}

t_filestats CloudInfoReader::get_file_stats(abort_callback& p_abort) {
    t_filestats result;
    result.m_size = filesize_invalid;
    result.m_timestamp = filetimestamp_invalid;
    return result;
}

// CloudInputEntry implementation

bool CloudInputEntry::is_our_content_type(const char* p_type) {
    // We don't handle content types, only URLs
    return false;
}

bool CloudInputEntry::is_our_path(const char* p_full_path, const char* p_extension) {
    if (!p_full_path || !*p_full_path) return false;

    std::string path(p_full_path);

    // Accept internal schemes (mixcloud://, soundcloud://)
    if (URLUtils::isInternalScheme(path)) {
        return true;
    }

    // Also accept web URLs from Mixcloud and SoundCloud
    if (URLUtils::isCloudWebURL(path)) {
        ParsedCloudURL parsed = URLUtils::parseURL(path);
        // Only accept track URLs, not profiles or playlists
        if (parsed.type == JLCloudURLType::Track || parsed.type == JLCloudURLType::DJSet) {
            return true;
        }
    }

    return false;
}

void CloudInputEntry::open_for_decoding(service_ptr_t<input_decoder>& p_instance,
                                         service_ptr_t<file> p_filehint,
                                         const char* p_path,
                                         abort_callback& p_abort) {
    service_ptr_t<CloudInputDecoder> instance = new service_impl_t<CloudInputDecoder>();
    instance->open(p_path, p_abort);
    p_instance = instance;
}

void CloudInputEntry::open_for_info_read(service_ptr_t<input_info_reader>& p_instance,
                                          service_ptr_t<file> p_filehint,
                                          const char* p_path,
                                          abort_callback& p_abort) {
    // Use lightweight info reader that doesn't resolve streams
    service_ptr_t<CloudInfoReader> instance = new service_impl_t<CloudInfoReader>();
    instance->open(p_path);
    p_instance = instance;
}

void CloudInputEntry::open_for_info_write(service_ptr_t<input_info_writer>& p_instance,
                                           service_ptr_t<file> p_filehint,
                                           const char* p_path,
                                           abort_callback& p_abort) {
    pfc::throw_exception_with_message<exception_io_unsupported_format>("Cloud streams are read-only");
}

void CloudInputEntry::get_extended_data(service_ptr_t<file> p_filehint,
                                         const playable_location& p_location,
                                         const GUID& p_guid,
                                         mem_block_container& p_out,
                                         abort_callback& p_abort) {
    // Not implemented
}

unsigned CloudInputEntry::get_flags() {
    // No special flags
    return 0;
}

GUID CloudInputEntry::get_guid() {
    return g_cloudInputGUID;
}

const char* CloudInputEntry::get_name() {
    return "Cloud Streamer (Mixcloud/SoundCloud)";
}

GUID CloudInputEntry::get_preferences_guid() {
    return pfc::guid_null;  // TODO: Add preferences page GUID
}

bool CloudInputEntry::is_low_merit() {
    // We only handle our specific URLs, so merit doesn't matter
    return false;
}

// Service registration
static service_factory_single_t<CloudInputEntry> g_cloudInputFactory;

} // namespace cloud_streamer
