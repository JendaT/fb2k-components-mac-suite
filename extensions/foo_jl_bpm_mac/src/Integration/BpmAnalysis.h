//
//  BpmAnalysis.h
//  foo_jl_bpm_mac
//
//  "Analyze BPM": asks TIDAL first for tracks it can match exactly, decodes
//  and analyses the rest, then opens the review window. Nothing is written
//  until the user confirms there.
//

#pragma once

#include "../fb2k_sdk.h"

namespace bpm {

// Main thread. Shows foobar2000's progress dialog while it runs.
void startAnalysis(metadb_handle_list_cref items);

} // namespace bpm
