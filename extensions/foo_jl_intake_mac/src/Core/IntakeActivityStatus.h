//
//  IntakeActivityStatus.h
//  foo_jl_intake
//
//  The status bar's fields (PLAN-B14 section 2, "Provider"): the activity
//  model's line and items (IntakeActivity) as the values of the suite's
//  jl_status_line and jl_status_item (shared/jl_status_api.h), which the
//  status provider (Integration/IntakeStatusProvider.mm) copies field by
//  field. Pure, no SDK: that header includes the SDK, so the values here
//  are plain mirrors of its enums, and the provider static_asserts them
//  against it (StatusFieldState against jl_status_state; IntakeIcon mirrors
//  jl_icon_id already, IntakeDecorationMap.h).
//
//  The mapping:
//   - state: Running -> running, Succeeded -> succeeded, Failed -> failed.
//     Queued is never produced yet: queued entries come with B12, and their
//     items will carry started 0 (the header's "not started").
//   - icon: None, Check, Cross -> IntakeIcon None, Check, Cross. The model
//     gives a result line check (succeeded) or cross (failed), a running
//     line none.
//   - progress: done/total as the model has them, except that a total of 0
//     sends done 0 too (0/0 is "no bar") and done is never above total.
//     Execute and Resume carry n/m from the start (0/40: an empty bar);
//     results carry none.
//   - times (items): Unix epoch milliseconds as the model took them at
//     begin() and end(); ended is 0 while the item runs. A time before the
//     epoch (a clock set that far back) is sent as 0, the header's "none".
//   - texts and id: as the model made them (one line of UTF-8, labels and
//     reasons cut on a character boundary; the id stable while the entry
//     exists).
//  Order is the model's (items(): running first, most recently begun
//  first, then the results still shown, newest first), which is the order
//  the header asks for.
//
//  Thread-safety: pure functions, no shared state.
//

#pragma once

#include <cstdint>
#include <string>

#include "IntakeActivity.h"
#include "IntakeDecorationMap.h"  // IntakeIcon

namespace intake {

// jl_status_state's values (append-only ABI); the provider static_asserts
// them.
enum class StatusFieldState : uint32_t {
    Queued = 0,
    Running = 1,
    Succeeded = 2,
    Failed = 3,
};

// jl_status_line's fields.
struct StatusLineFields {
    std::string text;
    uint32_t done = 0;
    uint32_t total = 0;
    IntakeIcon icon = IntakeIcon::None;
    StatusFieldState state = StatusFieldState::Running;
};

// jl_status_item's fields.
struct StatusItemFields {
    uint64_t id = 0;
    std::string title;
    std::string detail;
    StatusFieldState state = StatusFieldState::Running;
    uint32_t done = 0;
    uint32_t total = 0;
    int64_t startedMs = 0;
    int64_t endedMs = 0;
};

StatusFieldState statusFieldStateFor(ActivityState state);
IntakeIcon statusFieldIconFor(ActivityIcon icon);

StatusLineFields statusLineFieldsFor(const ActivityLine &line);
StatusItemFields statusItemFieldsFor(const ActivityItem &item);

} // namespace intake
