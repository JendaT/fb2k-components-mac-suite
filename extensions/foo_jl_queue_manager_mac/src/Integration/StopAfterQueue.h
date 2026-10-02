//
//  StopAfterQueue.h
//  foo_jl_queue_manager
//
//  "Stop After Queue" feature: settings access shared by the Playback
//  menu command, the Queue Manager context menu and the preferences page,
//  plus the SDK glue that feeds StopAfterQueuePolicy.
//  All functions must be called from the main thread.
//

#pragma once

#include <foobar2000/SDK/foobar2000.h>

namespace stop_after_queue {

bool isEnabled();
// Turning the feature off also cancels a stop it already armed
void setEnabled(bool enabled);

// "Only once": the feature turns itself off after stopping playback once
bool isOnlyOnce();
void setOnlyOnce(bool onlyOnce);

// Called for every playback queue change (from playback_queue_callback)
void onQueueChanged(playback_queue_callback::t_change_origin origin);

// Release held track handles; call from initquit::on_quit
void shutdown();

} // namespace stop_after_queue
