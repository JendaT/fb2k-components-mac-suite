//
//  BpmTagWriter.mm
//  foo_jl_bpm_mac
//

#include "BpmTagWriter.h"

#include "../Core/BpmValue.h"

#include <unordered_map>

namespace bpm {

namespace {

constexpr const char *kField = "BPM";

void runUpdate(metadb_handle_list_cref items, file_info_filter::ptr filter, const char *what) {
    pfc::string8 label = what;
    auto notify = fb2k::makeCompletionNotify([label](unsigned code) {
        if (code != metadb_io::update_info_success) {
            FB2K_console_formatter() << "BPM: " << label << " finished with code " << code;
        }
    });
    metadb_io_v2::get()->update_info_async(items, filter, core_api::get_main_window(),
                                           metadb_io_v2::op_flag_delay_ui, notify);
}

} // namespace

void writeBpmTags(metadb_handle_list_cref items, const std::vector<std::string> &values) {
    if (items.get_count() == 0 || items.get_count() != values.size()) return;

    // The filter runs on the tag updater's thread, so it gets its own copy.
    std::unordered_map<const metadb_handle *, std::string> byItem;
    for (size_t i = 0; i < values.size(); i++) byItem[items[i].get_ptr()] = values[i];

    auto filter = file_info_filter::create([byItem](trackRef location, t_filestats, file_info &info) {
        const auto it = byItem.find(location.get_ptr());
        if (it == byItem.end()) return false;
        const char *old = info.meta_get(kField, 0);
        if (old && it->second == old) return false;
        info.meta_set(kField, it->second.c_str());
        return true;
    });
    runUpdate(items, filter, "writing tags");
}

void scaleBpmTags(metadb_handle_list_cref items, double factor) {
    if (items.get_count() == 0) return;
    auto filter = file_info_filter::create([factor](trackRef, t_filestats, file_info &info) {
        const char *old = info.meta_get(kField, 0);
        if (!old) return false;
        const auto value = parseBpm(old);
        if (!value) return false;
        const double scaled = *value * factor;
        if (!(scaled > 0.0) || !(scaled < 1000.0)) return false;
        info.meta_set(kField, formatBpmExact(scaled).c_str());
        return true;
    });
    runUpdate(items, filter, factor > 1.0 ? "doubling BPM" : "halving BPM");
}

} // namespace bpm
