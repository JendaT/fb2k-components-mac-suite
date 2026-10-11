//
//  SpectrogramSource.cpp
//  foo_jl_spectrogram_mac
//

#include "SpectrogramSource.h"
#include "../Core/SpectrogramConfig.h"
#include <algorithm>

namespace {
    // Audio kept behind the playback position: the longest analysis window
    // (65536 samples, ~1.5 s at 44.1 kHz) plus room to catch up after a
    // dropped frame.
    const double kBacklog = 2.0;
}

bool SpectrogramSource::ensureStream() {
    if (_stream.is_valid()) return true;
    auto vm = visualisation_manager::get();
    if (!vm.is_valid()) return false;
    vm->create_stream(_stream, 0);
    if (!_stream.is_valid()) return false;
    _stream->set_channel_mode(visualisation_stream_v2::channel_mode_default);
    _stream->request_backlog(kBacklog);
    _lookahead = true;
    return true;
}

bool SpectrogramSource::now(double& time) {
    try {
        if (!ensureStream()) return false;
        return _stream->get_absolute_time(time);
    } catch (...) {
        return false;
    }
}

bool SpectrogramSource::fetch(double start, double length) {
    // Stream time starts at 0 on playback start and seek; clip the part of
    // the window that reaches before it.
    if (start < 0.0) { length += start; start = 0.0; }
    if (length <= 0.0) return false;
    return _stream->get_chunk_absolute(_chunk, start, length);
}

bool SpectrogramSource::read(double time, int count, int channel, std::vector<float>& out) {
    using namespace spectrogram_config;
    if (count <= 0) return false;

    try {
        if (!ensureStream()) return false;

        const double length = (double)count / _sampleRate;
        bool ok = _lookahead && fetch(time - 0.5 * length, length);
        if (!ok) {
            // Fall back to a window ending at `time` (the display then lags
            // by half a window). Sticky once playback is past its first
            // window, so columns do not alternate between the two alignments.
            ok = fetch(time - length, length);
            if (ok && _lookahead && time > length) _lookahead = false;
        }
        if (!ok) return false;

        const unsigned channels = _chunk.get_channel_count();
        const t_size frames = _chunk.get_sample_count();
        const audio_sample* data = _chunk.get_data();
        const double sr = _chunk.get_sample_rate();
        if (channels == 0 || frames == 0 || data == nullptr || sr <= 0) return false;

        if (sr != _sampleRate) {
            _sampleRate = sr;
            return false;
        }

        // Right-align: the chunk ends where the window ends, and may be short
        // by the part clipped at the start of the stream (or a rounding sample).
        out.assign((size_t)count, 0.0f);
        const size_t n = std::min<size_t>((size_t)frames, (size_t)count);
        const audio_sample* src = data + (size_t)(frames - n) * channels;
        float* dst = out.data() + ((size_t)count - n);
        const bool stereo = channels >= 2;

        switch (stereo ? channel : ChannelLeft) {
            case ChannelLeft:
                for (size_t i = 0; i < n; ++i) dst[i] = (float)src[i * channels];
                break;
            case ChannelRight:
                for (size_t i = 0; i < n; ++i) dst[i] = (float)src[i * channels + 1];
                break;
            case ChannelSide:
                for (size_t i = 0; i < n; ++i) {
                    dst[i] = 0.5f * (float)(src[i * channels] - src[i * channels + 1]);
                }
                break;
            default:
                for (size_t i = 0; i < n; ++i) {
                    dst[i] = 0.5f * (float)(src[i * channels] + src[i * channels + 1]);
                }
                break;
        }
        return true;
    } catch (...) {
        return false;
    }
}

void SpectrogramSource::suspend() {
    _stream.release();
}
