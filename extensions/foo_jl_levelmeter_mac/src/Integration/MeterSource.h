//
//  MeterSource.h
//  foo_jl_levelmeter_mac
//
//  Pulls the samples currently being played from the foobar2000
//  visualisation stream. The SDK boundary for the meter: everything it feeds
//  (src/Core) is SDK-free.
//

#pragma once

#include "../fb2k_sdk.h"
#include <vector>

class MeterSource {
public:
    // Fetch the audio played since the previous call as interleaved L/R
    // frames. Mono is duplicated to both channels (channels = 1); surround
    // uses the first two channels (front left / front right).
    // Returns false when there is nothing new (stopped, paused, no data yet).
    bool pull(std::vector<float>& lr, double& sampleRate, int& channels);

    // Drop the visualisation stream (view closed, or the app is quitting).
    // The stream is lazily recreated on the next pull().
    void suspend();

private:
    service_ptr_t<visualisation_stream_v2> _stream;
    double _lastTime = -1.0;   // stream time the previous pull ended at
};
