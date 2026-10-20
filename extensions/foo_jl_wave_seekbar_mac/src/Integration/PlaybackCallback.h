//
//  PlaybackCallback.h
//  foo_wave_seekbar_mac
//
//  Playback event handling for waveform updates
//

#pragma once

#include "../fb2k_sdk.h"
#include <cstdlib>

// Extract BPM from track metadata (checks common field names)
inline double extractBpmFromInfo(const file_info& info) {
    const char* bpmStr = info.meta_get("BPM", 0);
    if (!bpmStr) bpmStr = info.meta_get("bpm", 0);
    if (!bpmStr) bpmStr = info.meta_get("TBPM", 0);
    if (!bpmStr) bpmStr = info.meta_get("TEMPO", 0);
    return bpmStr ? atof(bpmStr) : 0.0;
}

// Forward declaration
#ifdef __OBJC__
@class WaveformSeekbarController;
#else
typedef void* WaveformSeekbarController;
#endif

// Manages playback callbacks and notifies registered views
class PlaybackCallbackManager {
public:
    static PlaybackCallbackManager& instance();

    // Register/unregister controllers for updates
    void registerController(WaveformSeekbarController* controller);
    void unregisterController(WaveformSeekbarController* controller);

    // Called by play_callback
    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStop(play_control::t_stop_reason reason);
    void onPlaybackSeek(double time);
    void onPlaybackTime(double time);
    void onPlaybackPause(bool paused);

private:
    PlaybackCallbackManager() = default;
    ~PlaybackCallbackManager() = default;

    PlaybackCallbackManager(const PlaybackCallbackManager&) = delete;
    PlaybackCallbackManager& operator=(const PlaybackCallbackManager&) = delete;
};
