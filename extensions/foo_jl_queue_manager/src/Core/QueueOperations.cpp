//
//  QueueOperations.cpp
//  foo_jl_queue_manager
//
//  Wrapper for SDK queue operations
//

#include "QueueOperations.h"

namespace queue_ops {

size_t getCount() {
    auto pm = playlist_manager::get();
    return pm->queue_get_count();
}

void getContents(pfc::list_base_t<t_playback_queue_item>& out) {
    auto pm = playlist_manager::get();
    pm->queue_get_contents(out);
}

std::vector<t_playback_queue_item> getContentsVector() {
    pfc::list_t<t_playback_queue_item> list;
    getContents(list);

    std::vector<t_playback_queue_item> result;
    result.reserve(list.get_count());
    for (size_t i = 0; i < list.get_count(); i++) {
        result.push_back(list[i]);
    }
    return result;
}

void removeItems(const std::vector<size_t>& indices) {
    if (indices.empty()) return;

    auto pm = playlist_manager::get();
    size_t count = pm->queue_get_count();

    // Create bit_array mask
    pfc::bit_array_bittable mask(count);
    for (size_t idx : indices) {
        if (idx < count) {
            mask.set(idx, true);
        }
    }

    pm->queue_remove_mask(mask);
}

void removeItem(size_t index) {
    removeItems({index});
}

void clear() {
    auto pm = playlist_manager::get();
    pm->queue_flush();
}

void addItemFromPlaylist(size_t playlist, size_t item) {
    auto pm = playlist_manager::get();
    pm->queue_add_item_playlist(playlist, item);
}

void addOrphanItem(metadb_handle_ptr handle) {
    auto pm = playlist_manager::get();
    pm->queue_add_item(handle);
}

bool isItemValid(const t_playback_queue_item& item) {
    // Orphan items are always "valid" (no playlist reference to check)
    if (isOrphanItem(item)) {
        return true;
    }

    auto pm = playlist_manager::get();

    // Check playlist exists
    if (item.m_playlist >= pm->get_playlist_count()) {
        return false;
    }

    // Check item index valid
    if (item.m_item >= pm->playlist_get_item_count(item.m_playlist)) {
        return false;
    }

    // Check handle matches
    metadb_handle_ptr check;
    pm->playlist_get_item_handle(check, item.m_playlist, item.m_item);
    return check == item.m_handle;
}

bool isOrphanItem(const t_playback_queue_item& item) {
    // Orphan items have m_playlist set to ~0 (SIZE_MAX)
    return item.m_playlist == ~(size_t)0;
}

bool playItem(const t_playback_queue_item& item) {
    auto pm = playlist_manager::get();
    auto pc = playback_control::get();

    if (!isOrphanItem(item) && isItemValid(item)) {
        // Play from source playlist position
        pm->set_active_playlist(item.m_playlist);
        pm->playlist_set_focus_item(item.m_playlist, item.m_item);
        pc->play_start(playback_control::track_command_settrack);
        return true;
    } else {
        // Just start playback - queue will be consumed
        pc->play_start();
        return true;
    }
}

pfc::string8 formatItem(const t_playback_queue_item& item, const char* formatString) {
    pfc::string8 result;

    if (!item.m_handle.is_valid()) {
        result = "[Invalid]";
        return result;
    }

    try {
        titleformat_object::ptr script;
        titleformat_compiler::get()->compile_safe(script, formatString);
        item.m_handle->format_title(nullptr, result, script, nullptr);
    } catch (...) {
        result = "[Error]";
    }

    return result;
}

pfc::string8 formatDuration(const t_playback_queue_item& item) {
    pfc::string8 result;

    if (!item.m_handle.is_valid()) {
        result = "--:--";
        return result;
    }

    double length = item.m_handle->get_length();
    if (length <= 0) {
        result = "--:--";
        return result;
    }

    int seconds = static_cast<int>(length);
    int minutes = seconds / 60;
    seconds = seconds % 60;

    if (minutes >= 60) {
        int hours = minutes / 60;
        minutes = minutes % 60;
        result << hours << ":"
               << pfc::format_int(minutes, 2) << ":"
               << pfc::format_int(seconds, 2);
    } else {
        result << minutes << ":" << pfc::format_int(seconds, 2);
    }

    return result;
}

} // namespace queue_ops
