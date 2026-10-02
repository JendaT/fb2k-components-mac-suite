//
//  StopAfterQueue.mm
//  foo_jl_queue_manager
//
//  SDK glue for "Stop After Queue": translates queue and playback
//  callbacks into StopAfterQueuePolicy events and applies its actions to
//  fb2k's one-shot "stop after current" flag. Also registers the
//  Playback > Stop After Queue menu command.
//

#import "StopAfterQueue.h"
#include "../Core/ConfigHelper.h"
#include "../Core/QueueConfig.h"
#include "../Core/QueueOperations.h"
#include "../Core/StopAfterQueuePolicy.h"

namespace stop_after_queue {

namespace {

queue_stop::StopAfterQueuePolicy g_policy;

// Handles kept alive so their pointers stay valid as policy TrackIds
metadb_handle_ptr g_lastQueuedTrack;  // sole queue item as of the last change
metadb_handle_ptr g_armedTrack;       // track the policy armed for

queue_stop::TrackId trackId(const metadb_handle_ptr& handle) {
    return reinterpret_cast<queue_stop::TrackId>(handle.get_ptr());
}

queue_stop::TrackId nowPlayingId() {
    metadb_handle_ptr playing;
    if (!playback_control::get()->get_now_playing(playing)) return 0;
    // Only identity matters; comparing against g_armedTrack (kept alive)
    // is valid because metadb hands out one handle object per location
    return trackId(playing);
}

void apply(const queue_stop::Actions& actions) {
    auto pc = playback_control::get();
    if (actions.setStopAfterCurrent) pc->set_stop_after_current(true);
    if (actions.clearStopAfterCurrent) pc->set_stop_after_current(false);
    if (actions.disableSetting) {
        queue_config::setConfigBool(queue_config::kKeyStopAfterQueue, false);
    }
    if (!g_policy.isArmed()) g_armedTrack.release();
}

queue_stop::StopReason toStopReason(play_control::t_stop_reason reason) {
    switch (reason) {
        case play_control::stop_reason_eof: return queue_stop::StopReason::EndOfFile;
        case play_control::stop_reason_starting_another: return queue_stop::StopReason::StartingAnother;
        case play_control::stop_reason_shutting_down: return queue_stop::StopReason::ShuttingDown;
        case play_control::stop_reason_user:
        default: return queue_stop::StopReason::User;
    }
}

} // namespace

bool isEnabled() {
    return queue_config::getConfigBool(queue_config::kKeyStopAfterQueue,
                                       queue_config::kDefaultStopAfterQueue);
}

void setEnabled(bool enabled) {
    queue_config::setConfigBool(queue_config::kKeyStopAfterQueue, enabled);
    if (!enabled) {
        apply(g_policy.onSettingDisabled(
            nowPlayingId(), playback_control::get()->get_stop_after_current()));
    }
}

bool isOnlyOnce() {
    return queue_config::getConfigBool(queue_config::kKeyStopAfterQueueOnce,
                                       queue_config::kDefaultStopAfterQueueOnce);
}

void setOnlyOnce(bool onlyOnce) {
    queue_config::setConfigBool(queue_config::kKeyStopAfterQueueOnce, onlyOnce);
}

void onQueueChanged(playback_queue_callback::t_change_origin origin) {
    // Remember the sole remaining item so we know which track an advance
    // consumed (an advance removes exactly one item)
    const size_t count = queue_ops::getCount();
    metadb_handle_ptr consumed = g_lastQueuedTrack;
    g_lastQueuedTrack.release();
    if (count == 1) {
        auto contents = queue_ops::getContentsVector();
        if (!contents.empty()) g_lastQueuedTrack = contents[0].m_handle;
    }

    auto pc = playback_control::get();
    if (origin == playback_queue_callback::changed_playback_advance && count == 0) {
        queue_stop::Actions actions = g_policy.onQueueAdvancedToEmpty(isEnabled(), trackId(consumed));
        if (g_policy.isArmed()) g_armedTrack = consumed;
        apply(actions);
    } else if (origin == playback_queue_callback::changed_user_added) {
        apply(g_policy.onQueueItemsAdded(nowPlayingId(), pc->get_stop_after_current()));
    }
}

void shutdown() {
    // Drop handles before static destruction outlives metadb
    g_lastQueuedTrack.release();
    g_armedTrack.release();
}

namespace {

class stop_after_queue_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track | flag_on_playback_stop;
    }

    void on_playback_new_track(metadb_handle_ptr p_track) override {
        apply(g_policy.onNewTrack(trackId(p_track),
                                  playback_control::get()->get_stop_after_current()));
    }

    void on_playback_stop(play_control::t_stop_reason p_reason) override {
        apply(g_policy.onPlaybackStopped(toStopReason(p_reason),
                                         playback_control::get()->get_stop_after_current(),
                                         isOnlyOnce()));
    }

    // Unused callbacks
    void on_playback_starting(play_control::t_track_command p_command, bool p_paused) override {}
    void on_playback_seek(double p_time) override {}
    void on_playback_pause(bool p_state) override {}
    void on_playback_edited(metadb_handle_ptr p_track) override {}
    void on_playback_dynamic_info(const file_info& p_info) override {}
    void on_playback_dynamic_info_track(const file_info& p_info) override {}
    void on_playback_time(double p_time) override {}
    void on_volume_change(float p_new_val) override {}
};

FB2K_SERVICE_FACTORY(stop_after_queue_play_callback);

// Playback > Stop After Queue (next to fb2k's own Stop After Current)
static const GUID guid_cmd_stop_after_queue = {
    0x903eb73a, 0x6263, 0x4f77, { 0xb8, 0xf9, 0xda, 0xdf, 0x8d, 0x57, 0x75, 0xf7 }
};

class stop_after_queue_mainmenu : public mainmenu_commands {
public:
    t_uint32 get_command_count() override { return 1; }

    GUID get_command(t_uint32 p_index) override {
        (void)p_index;
        return guid_cmd_stop_after_queue;
    }

    void get_name(t_uint32 p_index, pfc::string_base& p_out) override {
        (void)p_index;
        p_out = "Stop After Queue";
    }

    bool get_description(t_uint32 p_index, pfc::string_base& p_out) override {
        (void)p_index;
        p_out = "Stops playback when the last track in the playback queue finishes.";
        return true;
    }

    GUID get_parent() override {
        return mainmenu_groups::playback_etc;
    }

    bool get_display(t_uint32 p_index, pfc::string_base& p_text, t_uint32& p_flags) override {
        bool rv = mainmenu_commands::get_display(p_index, p_text, p_flags);
        if (isEnabled()) p_flags |= flag_checked;
        return rv;
    }

    void execute(t_uint32 p_index, service_ptr_t<service_base> p_callback) override {
        (void)p_index;
        (void)p_callback;
        setEnabled(!isEnabled());
    }
};

static mainmenu_commands_factory_t<stop_after_queue_mainmenu> g_stop_after_queue_mainmenu;

} // namespace

} // namespace stop_after_queue
