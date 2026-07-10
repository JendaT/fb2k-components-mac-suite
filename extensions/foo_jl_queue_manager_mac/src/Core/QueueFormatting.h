//
//  QueueFormatting.h
//  foo_jl_queue_manager
//
//  Pure string formatting for queue display.
//
//  No foobar2000 SDK dependency (std::string only) so it can be
//  unit-tested standalone. Duration math extracted from
//  queue_ops::formatDuration, status text from QueueManagerController.
//

#pragma once

#include <cstddef>
#include <string>

namespace queue_format {

// Track length in seconds -> "m:ss", "h:mm:ss", or "--:--" for
// non-positive lengths. Fractional seconds are truncated.
std::string formatDurationSeconds(double lengthSeconds);

// Status bar text: "" for empty, "1 item in queue", "N items in queue".
std::string statusTextForCount(size_t count);

}  // namespace queue_format
