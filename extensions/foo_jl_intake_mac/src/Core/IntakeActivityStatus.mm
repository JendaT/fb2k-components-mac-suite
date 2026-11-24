//
//  IntakeActivityStatus.mm
//  foo_jl_intake
//
//  See IntakeActivityStatus.h.
//

#include "IntakeActivityStatus.h"

namespace intake {

namespace {

// 0/0 stays "no bar", and the bar never runs past its end.
void progressInto(uint32_t done, uint32_t total, uint32_t &outDone, uint32_t &outTotal) {
    outTotal = total;
    outDone = total == 0 ? 0 : (done > total ? total : done);
}

int64_t epochMsOrNone(int64_t ms) {
    return ms > 0 ? ms : 0;
}

} // anonymous namespace

StatusFieldState statusFieldStateFor(ActivityState state) {
    switch (state) {
        case ActivityState::Running: return StatusFieldState::Running;
        case ActivityState::Succeeded: return StatusFieldState::Succeeded;
        case ActivityState::Failed: return StatusFieldState::Failed;
    }
    return StatusFieldState::Running;
}

IntakeIcon statusFieldIconFor(ActivityIcon icon) {
    switch (icon) {
        case ActivityIcon::None: return IntakeIcon::None;
        case ActivityIcon::Check: return IntakeIcon::Check;
        case ActivityIcon::Cross: return IntakeIcon::Cross;
    }
    return IntakeIcon::None;
}

StatusLineFields statusLineFieldsFor(const ActivityLine &line) {
    StatusLineFields out;
    out.text = line.text;
    progressInto(line.done, line.total, out.done, out.total);
    out.icon = statusFieldIconFor(line.icon);
    out.state = statusFieldStateFor(line.state);
    return out;
}

StatusItemFields statusItemFieldsFor(const ActivityItem &item) {
    StatusItemFields out;
    out.id = item.id;
    out.title = item.title;
    out.detail = item.detail;
    out.state = statusFieldStateFor(item.state);
    progressInto(item.done, item.total, out.done, out.total);
    out.startedMs = epochMsOrNone(item.startedMs);
    out.endedMs = item.state == ActivityState::Running ? 0 : epochMsOrNone(item.endedMs);
    return out;
}

} // namespace intake
