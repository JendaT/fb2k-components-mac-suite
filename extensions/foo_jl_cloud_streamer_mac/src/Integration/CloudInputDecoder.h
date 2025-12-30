#pragma once

#include "../fb2k_sdk.h"
#include "../Core/TrackInfo.h"
#include <atomic>
#include <optional>

namespace cloud_streamer {

// Input decoder for cloud streaming URLs
// Wraps underlying HTTP decoder after resolving stream URL
class CloudInputDecoder : public input_decoder_v2 {
public:
    CloudInputDecoder();
    ~CloudInputDecoder();

    // input_info_reader interface
    t_uint32 get_subsong_count() override;
    t_uint32 get_subsong(t_uint32 p_index) override;
    void get_info(t_uint32 p_subsong, file_info& p_info, abort_callback& p_abort) override;
    t_filestats get_file_stats(abort_callback& p_abort) override;

    // input_decoder interface
    void initialize(t_uint32 p_subsong, unsigned p_flags, abort_callback& p_abort) override;
    bool run(audio_chunk& p_chunk, abort_callback& p_abort) override;
    void seek(double p_seconds, abort_callback& p_abort) override;
    bool can_seek() override;
    bool get_dynamic_info(file_info& p_out, double& p_timestamp_delta) override;
    bool get_dynamic_info_track(file_info& p_out, double& p_timestamp_delta) override;
    void on_idle(abort_callback& p_abort) override;

    // input_decoder_v2 interface
    bool run_raw(audio_chunk& out, mem_block_container& outRaw, abort_callback& abort) override;
    void set_logger(event_logger::ptr ptr) override;

    // Opening
    void open(const char* p_path, abort_callback& p_abort);

private:
    // Resolve stream and open underlying decoder
    void openStream(abort_callback& p_abort);

    // Try to reopen on 403 error
    bool tryReopen(abort_callback& p_abort);

    std::string m_internalURL;
    std::string m_streamURL;
    std::optional<TrackInfo> m_trackInfo;
    service_ptr_t<input_decoder> m_decoder;
    event_logger::ptr m_logger;
    std::atomic<bool> m_abortFlag;
    bool m_initialized;
    unsigned m_flags;
    t_uint32 m_subsong;
    bool m_403Retry;
};

// Lightweight info reader that doesn't resolve streams (fast add to playlist)
class CloudInfoReader : public input_info_reader {
public:
    CloudInfoReader() = default;

    // Open without resolving stream - just parse URL
    void open(const char* p_path);

    // input_info_reader interface
    t_uint32 get_subsong_count() override { return 1; }
    t_uint32 get_subsong(t_uint32 p_index) override { return 0; }
    void get_info(t_uint32 p_subsong, file_info& p_info, abort_callback& p_abort) override;
    t_filestats get_file_stats(abort_callback& p_abort) override;

private:
    std::string m_internalURL;
    std::optional<TrackInfo> m_cachedInfo;
};

// Input entry for registering the decoder
class CloudInputEntry : public input_entry_v2 {
public:
    bool is_our_content_type(const char* p_type) override;
    bool is_our_path(const char* p_full_path, const char* p_extension) override;

    void open_for_decoding(service_ptr_t<input_decoder>& p_instance,
                           service_ptr_t<file> p_filehint,
                           const char* p_path,
                           abort_callback& p_abort) override;

    void open_for_info_read(service_ptr_t<input_info_reader>& p_instance,
                            service_ptr_t<file> p_filehint,
                            const char* p_path,
                            abort_callback& p_abort) override;

    void open_for_info_write(service_ptr_t<input_info_writer>& p_instance,
                             service_ptr_t<file> p_filehint,
                             const char* p_path,
                             abort_callback& p_abort) override;

    void get_extended_data(service_ptr_t<file> p_filehint,
                           const playable_location& p_location,
                           const GUID& p_guid,
                           mem_block_container& p_out,
                           abort_callback& p_abort) override;

    unsigned get_flags() override;

    // input_entry_v2 interface
    GUID get_guid() override;
    const char* get_name() override;
    GUID get_preferences_guid() override;
    bool is_low_merit() override;
};

} // namespace cloud_streamer
