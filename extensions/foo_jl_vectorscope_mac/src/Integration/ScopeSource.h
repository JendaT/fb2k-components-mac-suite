//
//  ScopeSource.h
//  foo_jl_vectorscope_mac
//
//  Pulls the raw stereo samples currently being played from the foobar2000
//  visualisation stream. The SDK boundary for the scope: everything it feeds
//  (src/Core/StereoAnalysis, PhosphorBuffer) is SDK-free.
//

#pragma once

#include "../fb2k_sdk.h"
#include <vector>

class ScopeSource {
public:
    // Fetch the audio played since the previous call as interleaved L/R
    // frames. Mono is duplicated to both channels; surround uses the first
    // two channels (front left / front right).
    // Returns false when there is nothing new (stopped, paused, no data yet).
    bool pull(std::vector<float>& lr, double& sampleRate);

    // Drop the visualisation stream (call when the view goes off-screen).
    // The stream is lazily recreated on the next pull().
    void suspend();

private:
    service_ptr_t<visualisation_stream_v2> _stream;
    double _lastTime = -1.0;   // stream time the previous pull ended at
};
