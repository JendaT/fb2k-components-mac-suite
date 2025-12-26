//
//  PlaybackCallback.mm
//  foo_wave_seekbar_mac
//
//  Playback event handling for waveform updates
//

#import "PlaybackCallback.h"
#import "../UI/WaveformSeekbarController.h"
#import "../Core/WaveformService.h"
#include <vector>
#include <mutex>

// Registered controllers
static std::vector<__weak WaveformSeekbarController*> g_controllers;
static std::mutex g_controllersMutex;

PlaybackCallbackManager& PlaybackCallbackManager::instance() {
    static PlaybackCallbackManager manager;
    return manager;
}

void PlaybackCallbackManager::registerController(WaveformSeekbarController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);

    // Check if already registered
    for (const auto& weak : g_controllers) {
        if (weak == controller) return;
    }

    g_controllers.push_back(controller);
}

void PlaybackCallbackManager::unregisterController(WaveformSeekbarController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);

    g_controllers.erase(
        std::remove_if(g_controllers.begin(), g_controllers.end(),
            [controller](const __weak WaveformSeekbarController* weak) {
                return weak == nil || weak == controller;
            }),
        g_controllers.end()
    );
}

void PlaybackCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    // Note: waveform request is done by the controller in handleNewTrack
    // to avoid duplicate requests

    // Get track duration and BPM
    double duration = 0;
    double bpm = 0;
    if (track.is_valid()) {
        file_info_impl info;
        if (track->get_info_async(info)) {
            duration = info.get_length();
            // Try to read BPM from metadata (check common field names)
            const char* bpmStr = info.meta_get("BPM", 0);
            if (!bpmStr) bpmStr = info.meta_get("bpm", 0);
            if (!bpmStr) bpmStr = info.meta_get("TBPM", 0);
            if (!bpmStr) bpmStr = info.meta_get("TEMPO", 0);
            if (bpmStr) {
                bpm = atof(bpmStr);
            }
        }
    }

    // Notify controllers on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak WaveformSeekbarController* weak : g_controllers) {
            WaveformSeekbarController* controller = weak;
            if (controller) {
                [controller handleNewTrack:track duration:duration bpm:bpm];
            }
        }
    });
}

void PlaybackCallbackManager::onPlaybackStop(play_control::t_stop_reason reason) {
    // Cancel any pending scan
    getWaveformService().cancelAllRequests();

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak WaveformSeekbarController* weak : g_controllers) {
            WaveformSeekbarController* controller = weak;
            if (controller) {
                [controller handlePlaybackStop];
            }
        }
    });
}

void PlaybackCallbackManager::onPlaybackSeek(double time) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak WaveformSeekbarController* weak : g_controllers) {
            WaveformSeekbarController* controller = weak;
            if (controller) {
                [controller handleSeekToTime:time];
            }
        }
    });
}

void PlaybackCallbackManager::onPlaybackTime(double time) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak WaveformSeekbarController* weak : g_controllers) {
            WaveformSeekbarController* controller = weak;
            if (controller) {
                [controller handlePlaybackTime:time];
            }
        }
    });
}

void PlaybackCallbackManager::onPlaybackPause(bool paused) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak WaveformSeekbarController* weak : g_controllers) {
            WaveformSeekbarController* controller = weak;
            if (controller) {
                [controller handlePlaybackPause:paused];
            }
        }
    });
}

// play_callback_static implementation
class waveform_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_seek |
               flag_on_playback_time |
               flag_on_playback_pause;
    }

    void on_playback_new_track(metadb_handle_ptr p_track) override {
        PlaybackCallbackManager::instance().onPlaybackNewTrack(p_track);
    }

    void on_playback_stop(play_control::t_stop_reason p_reason) override {
        PlaybackCallbackManager::instance().onPlaybackStop(p_reason);
    }

    void on_playback_seek(double p_time) override {
        PlaybackCallbackManager::instance().onPlaybackSeek(p_time);
    }

    void on_playback_time(double p_time) override {
        PlaybackCallbackManager::instance().onPlaybackTime(p_time);
    }

    void on_playback_pause(bool p_state) override {
        PlaybackCallbackManager::instance().onPlaybackPause(p_state);
    }

    // Unused callbacks
    void on_playback_starting(play_control::t_track_command p_command, bool p_paused) override {}
    void on_playback_edited(metadb_handle_ptr p_track) override {}
    void on_playback_dynamic_info(const file_info& p_info) override {}
    void on_playback_dynamic_info_track(const file_info& p_info) override {}
    void on_volume_change(float p_new_val) override {}
};

FB2K_SERVICE_FACTORY(waveform_play_callback);

// Initialize waveform service on component init
class waveform_init : public initquit {
public:
    void on_init() override {
        getWaveformService().initialize();
        console::info("[WaveSeek] Waveform Seekbar initialized");
    }

    void on_quit() override {
        getWaveformService().shutdown();
    }
};

FB2K_SERVICE_FACTORY(waveform_init);
