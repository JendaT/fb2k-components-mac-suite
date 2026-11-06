//
//  ScopeSource.cpp
//  foo_jl_vectorscope_mac
//

#include "ScopeSource.h"
#include <algorithm>

namespace {
    // Window used for the first pull, before there is a previous end time.
    const double kFirstWindow = 1.0 / 60.0;
    // Longest stretch fetched in one pull. After a stall (window hidden, UI
    // blocked) the scope resumes at "now" instead of replaying the gap.
    const double kMaxWindow = 0.05;
    // The window ends at the playback position, so it reaches back in time.
    const double kBacklog = 0.25;
}

bool ScopeSource::pull(std::vector<float>& lr, double& sampleRate) {
    lr.clear();

    try {
        if (_stream.is_empty()) {
            _lastTime = -1.0;
            auto vm = visualisation_manager::get();
            if (vm.is_valid()) {
                vm->create_stream(_stream, 0);
                if (_stream.is_valid()) {
                    _stream->set_channel_mode(visualisation_stream_v2::channel_mode_default);
                    _stream->request_backlog(kBacklog);
                }
            }
        }
        if (!_stream.is_valid()) return false;

        double now = 0;
        if (!_stream->get_absolute_time(now)) {
            _lastTime = -1.0;
            return false;
        }

        double from = _lastTime;
        if (from < 0 || now < from) from = now - kFirstWindow;
        if (now - from > kMaxWindow) from = now - kMaxWindow;
        if (from < 0) from = 0;
        // Paused, or the clock has not moved since the last frame: keep the
        // previous end time so no samples are skipped.
        if (now - from < 1e-4) return false;

        audio_chunk_impl chunk;
        bool ok = _stream->get_chunk_absolute(chunk, from, now - from);
        // No backlog behind the playback position (just started, just
        // seeked): take the same length ahead of it instead, which is
        // already buffered for output.
        if (!ok) ok = _stream->get_chunk_absolute(chunk, now, now - from);
        _lastTime = now;
        if (!ok) return false;

        const unsigned channels = chunk.get_channel_count();
        const t_size frames = chunk.get_sample_count();
        const audio_sample* data = chunk.get_data();
        if (channels == 0 || frames == 0 || data == nullptr) return false;

        lr.resize((size_t)frames * 2);
        if (channels == 1) {
            for (t_size i = 0; i < frames; ++i) {
                lr[2 * i] = lr[2 * i + 1] = (float)data[i];
            }
        } else {
            for (t_size i = 0; i < frames; ++i) {
                lr[2 * i]     = (float)data[(size_t)i * channels];
                lr[2 * i + 1] = (float)data[(size_t)i * channels + 1];
            }
        }
        sampleRate = chunk.get_sample_rate();
        return sampleRate > 0;
    } catch (...) {
        lr.clear();
        return false;
    }
}

void ScopeSource::suspend() {
    try {
        _stream.release();
    } catch (...) {
    }
    _lastTime = -1.0;
}
