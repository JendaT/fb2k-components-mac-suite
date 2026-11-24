//
//  IntakeActivityStatusTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeActivityStatus (the status bar's line and items as
//  jl_status_line / jl_status_item fields, B14): the state and icon values
//  (jl_status_state's and jl_icon_id's numbers), lines and items taken from
//  a real ActivityModel with a fake clock (running with and without n/m,
//  succeeded, failed, " (+N more)", UTF-8 texts byte for byte, the model's
//  order and ids), progress rules (0/0, done above total), and times
//  (ended 0 while running, a time before the epoch sent as 0).
//

// TEST_DEPS: src/Core/IntakeActivity.mm

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeActivityStatus.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using namespace intake;

static const std::string kDots = "\xE2\x80\xA6";  // U+2026
static const std::string kDash = "\xE2\x80\x93";  // U+2013

static ActivityResult failed(const std::string &reason, const std::string &detail = std::string()) {
    ActivityResult r;
    r.succeeded = false;
    r.reason = reason;
    r.detail = detail;
    return r;
}

static void testStateAndIconValues() {
    g_context = "values";
    // jl_status_state: queued 0, running 1, succeeded 2, failed 3.
    CHECK_EQ(static_cast<uint32_t>(StatusFieldState::Queued), 0, "queued");
    CHECK_EQ(static_cast<uint32_t>(statusFieldStateFor(ActivityState::Running)), 1, "running");
    CHECK_EQ(static_cast<uint32_t>(statusFieldStateFor(ActivityState::Succeeded)), 2, "succeeded");
    CHECK_EQ(static_cast<uint32_t>(statusFieldStateFor(ActivityState::Failed)), 3, "failed");
    // jl_icon_id: none 0, cross 6, check 7.
    CHECK_EQ(static_cast<uint32_t>(statusFieldIconFor(ActivityIcon::None)), 0, "icon none");
    CHECK_EQ(static_cast<uint32_t>(statusFieldIconFor(ActivityIcon::Cross)), 6, "icon cross");
    CHECK_EQ(static_cast<uint32_t>(statusFieldIconFor(ActivityIcon::Check)), 7, "icon check");
}

static void testRunningLine() {
    g_context = "running-line";
    ActivityModel m;
    m.begin(activityRunKey("s1"), ActivityKind::Execute, 40, "Artist " + kDash + " Album", 1000);
    StatusLineFields f = statusLineFieldsFor(*m.line(1000));
    CHECK(f.text == "Placing 40 albums" + kDots, "the plain form until progress");
    CHECK(f.done == 0 && f.total == 40, "0/40 from the start: an empty bar");
    CHECK(f.icon == IntakeIcon::None, "no icon while running");
    CHECK(f.state == StatusFieldState::Running, "running");

    m.progress(activityRunKey("s1"), 12, 40, "Artist B " + kDash + " Album B");
    f = statusLineFieldsFor(*m.line(1500));
    CHECK(f.text == "Placing 12/40: Artist B " + kDash + " Album B", "n/m with the album, UTF-8 byte for byte");
    CHECK(f.done == 12 && f.total == 40, "12/40");

    m.begin(activityLaneKey(7), ActivityKind::Propose, 3, "First", 2000);
    f = statusLineFieldsFor(*m.line(2000));
    CHECK(f.text == "Proposing 3 albums" + kDots + " (+1 more)", "the one begun last, plus the count of others");
    CHECK(f.done == 0 && f.total == 0, "a propose has no bar");
    CHECK(f.state == StatusFieldState::Running, "still running");
}

static void testResultLines() {
    g_context = "result-lines";
    ActivityModel m;
    m.begin(activityLaneKey(1), ActivityKind::Propose, 3, "First", 1000);
    m.end(activityLaneKey(1), ActivityResult(), 2000);
    StatusLineFields f = statusLineFieldsFor(*m.line(2000));
    CHECK(f.text == "Proposed 3 albums", "succeeded text");
    CHECK(f.icon == IntakeIcon::Check && f.state == StatusFieldState::Succeeded, "check, succeeded");
    CHECK(f.done == 0 && f.total == 0, "a result has no bar");

    m.begin(activityRunKey("s2"), ActivityKind::Execute, 5, "First", 3000);
    m.progress(activityRunKey("s2"), 4, 5, std::string());
    m.end(activityRunKey("s2"), failed("1 of 5 albums", "execute: E_VERIFY ..."), 4000);
    f = statusLineFieldsFor(*m.line(4000));
    CHECK(f.text == "Execute failed: 1 of 5 albums", "failed text: the newest result");
    CHECK(f.icon == IntakeIcon::Cross && f.state == StatusFieldState::Failed, "cross, failed");
    CHECK(f.done == 0 && f.total == 0, "a failed run's line has no bar");

    CHECK(m.line(13999).has_value(), "shown until 10 s after its end");
    CHECK(!m.line(14000).has_value(), "then idle: the provider answers false");
}

static void testProgressRules() {
    g_context = "progress";
    ActivityLine line;
    line.text = "x";
    line.done = 5;
    line.total = 0;
    StatusLineFields f = statusLineFieldsFor(line);
    CHECK(f.done == 0 && f.total == 0, "total 0: 0/0, no bar");
    line.done = 9;
    line.total = 4;
    f = statusLineFieldsFor(line);
    CHECK(f.done == 4 && f.total == 4, "done never above total");
    line.done = 3;
    f = statusLineFieldsFor(line);
    CHECK(f.done == 3 && f.total == 4, "3/4 kept");

    ActivityItem item;
    item.done = 7;
    item.total = 0;
    StatusItemFields g = statusItemFieldsFor(item);
    CHECK(g.done == 0 && g.total == 0, "item: total 0 is 0/0");
    item.done = 7;
    item.total = 2;
    g = statusItemFieldsFor(item);
    CHECK(g.done == 2 && g.total == 2, "item: done never above total");
}

static void testItems() {
    g_context = "items";
    ActivityModel m;
    const uint64_t execId = m.begin(activityRunKey("s1"), ActivityKind::Execute, 40, "First", 1000);
    m.progress(activityRunKey("s1"), 12, 40, "Artist B " + kDash + " Album B");
    const uint64_t okId = m.begin(activityLaneKey(1), ActivityKind::Approve, 1, "Solo " + kDash + " One", 1100);
    m.end(activityLaneKey(1), ActivityResult(), 1200);
    const uint64_t badId = m.begin(activityLaneKey(2), ActivityKind::Reject, 2, "Duo", 1300);
    m.end(activityLaneKey(2), failed("no such root", "reject: no such root itk_1"), 1400);
    const uint64_t propId = m.begin(activityLaneKey(3), ActivityKind::Propose, 3, "Trio", 1500);

    const std::vector<ActivityItem> items = m.items(1600);
    std::vector<StatusItemFields> f;
    for (const ActivityItem &item : items) f.push_back(statusItemFieldsFor(item));
    CHECK_EQ(f.size(), 4, "two running, two results");
    if (f.size() != 4) return;

    // Running first, begun last first; then results, newest first.
    CHECK(f[0].id == propId && f[1].id == execId && f[2].id == badId && f[3].id == okId, "the model's order and ids");

    CHECK(f[0].title == "Proposing 3 albums" + kDots && f[0].detail == "Trio and 2 more", "propose title, detail");
    CHECK(f[0].state == StatusFieldState::Running, "propose running");
    CHECK(f[0].startedMs == 1500 && f[0].endedMs == 0, "propose: started, not ended");
    CHECK(f[0].done == 0 && f[0].total == 0, "propose: no bar");

    CHECK(f[1].title == "Placing 12/40" && f[1].detail == "Artist B " + kDash + " Album B", "execute n/m, album");
    CHECK(f[1].done == 12 && f[1].total == 40, "execute 12/40");
    CHECK(f[1].startedMs == 1000 && f[1].endedMs == 0, "execute: started, not ended");

    CHECK(f[2].title == "Reject failed: no such root", "failure title");
    CHECK(f[2].detail == "reject: no such root itk_1", "failure detail: the console line");
    CHECK(f[2].state == StatusFieldState::Failed, "failed");
    CHECK(f[2].startedMs == 1300 && f[2].endedMs == 1400, "failed: started and ended");
    CHECK(f[2].done == 0 && f[2].total == 0, "a result has no bar");

    CHECK(f[3].title == "Approved Solo " + kDash + " One" && f[3].detail.empty(), "one album: label in the title");
    CHECK(f[3].state == StatusFieldState::Succeeded, "succeeded");
    CHECK(f[3].startedMs == 1100 && f[3].endedMs == 1200, "succeeded: started and ended");

    // After the results' 10 s only the running ones are left.
    CHECK_EQ(m.items(11400).size(), 2, "results gone after 10 s");
}

static void testTimes() {
    g_context = "times";
    ActivityItem item;
    item.state = ActivityState::Running;
    item.startedMs = 5000;
    item.endedMs = 6000;  // never set by the model while running
    StatusItemFields f = statusItemFieldsFor(item);
    CHECK(f.startedMs == 5000 && f.endedMs == 0, "running: ended 0 whatever the item holds");

    item.state = ActivityState::Succeeded;
    f = statusItemFieldsFor(item);
    CHECK(f.endedMs == 6000, "ended: its time");

    item.startedMs = -20;
    item.endedMs = -10;
    f = statusItemFieldsFor(item);
    CHECK(f.startedMs == 0 && f.endedMs == 0, "before the epoch: 0, the header's none");

    item.startedMs = 1732460000000LL;
    item.endedMs = 1732460010000LL;
    item.state = ActivityState::Failed;
    f = statusItemFieldsFor(item);
    CHECK(f.startedMs == 1732460000000LL && f.endedMs == 1732460010000LL, "Unix epoch ms kept in 64 bits");
}

int main(void) {
    @autoreleasepool {
        testStateAndIconValues();
        testRunningLine();
        testResultLines();
        testProgressRules();
        testItems();
        testTimes();
    }
    TEST_MAIN_END();
}
