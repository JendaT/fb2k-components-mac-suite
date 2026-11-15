//
//  SpectrogramSource.h
//  foo_jl_spectrogram_mac
//
//  Reads mono analysis windows from the foobar2000 visualisation stream at
//  arbitrary stream times. The SDK boundary for the spectrogram: everything
//  it feeds (src/Core/SpectrogramEngine) is SDK-free.
//

#pragma once

#include "../fb2k_sdk.h"
#include <vector>

class SpectrogramSource {
public:
    // Stream time of the audio being played right now.
    // Returns false when nothing is playing.
    bool now(double& time);

    // Fill `out` with `count` mono samples centred on stream time `time`,
    // downmixed per spectrogram_config::Channel. Audio that does not exist
    // yet at the start of playback reads as silence. Returns false when the
    // window is not available, or when the sample rate just changed (check
    // sampleRate() and retry with a window sized for it).
    bool read(double time, int count, int channel, std::vector<float>& out);

    // Sample rate of the last chunk read (44100 before the first one).
    double sampleRate() const { return _sampleRate; }

    // Drop the visualisation stream (call when the view goes off-screen).
    // The stream is lazily recreated on the next now().
    void suspend();

private:
    bool ensureStream();
    bool fetch(double start, double length);

    service_ptr_t<visualisation_stream_v2> _stream;
    audio_chunk_impl _chunk;
    double _sampleRate = 44100.0;
    // Windows normally reach half their length past the playback position,
    // into audio already buffered for output. Cleared for the stream's
    // lifetime if that audio turns out not to be available.
    bool _lookahead = true;
};
