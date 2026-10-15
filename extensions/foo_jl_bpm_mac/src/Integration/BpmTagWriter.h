//
//  BpmTagWriter.h
//  foo_jl_bpm_mac
//
//  Writes the BPM tag through foobar2000's tag updater, which shows its own
//  progress and error reporting.
//

#pragma once

#include "../fb2k_sdk.h"

#include <string>
#include <vector>

namespace bpm {

// Sets BPM to values[i] on items[i]. Main thread.
void writeBpmTags(metadb_handle_list_cref items, const std::vector<std::string> &values);

// Multiplies each item's existing BPM tag by `factor` (2 or 0.5). Items
// without a readable BPM tag are left alone. Main thread.
void scaleBpmTags(metadb_handle_list_cref items, double factor);

} // namespace bpm
