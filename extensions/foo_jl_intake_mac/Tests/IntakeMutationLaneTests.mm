//
//  IntakeMutationLaneTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeMutationLane (doc 04 v1.2 "Mutation lane"): the
//  holder kind per request, single flight, a real mutating call keeping the
//  lane through its 10 s report, the dry-run release at the report with its
//  late result discarded, stale tokens, and the busy lane disabling the
//  mutating menu items (IntakeActionTable) until it is free again. B12: the
//  background scan's own holder, kept through its 10 s report, named
//  "(scan running)" in the menu; the count of acquires the chunked propose
//  reads.
//
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm
// TEST_DEPS: src/Core/IntakeActionTable.mm src/Core/IntakeCapabilities.mm src/Core/IntakeReviewRule.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeActionTable.h"
#include "../src/Core/IntakeMutationLane.h"
#include "TestHarness.h"

using namespace intake;

static CliRequest req(CliCommand command, bool dryRun = false) {
    CliRequest r;
    r.command = command;
    r.ids = {"itk_0000000b"};
    r.dryRun = dryRun;
    return r;
}

static void testHolderKinds() {
    g_context = "holder";
    CHECK(laneHolderFor(req(CliCommand::Version)) == LaneHolder::None, "version takes no lane");
    CHECK(laneHolderFor(req(CliCommand::Status)) == LaneHolder::None, "status takes no lane");
    CHECK(laneHolderFor(req(CliCommand::Propose)) == LaneHolder::Mutating, "propose: mutating");
    CHECK(laneHolderFor(req(CliCommand::Approve)) == LaneHolder::Mutating, "approve: mutating");
    CHECK(laneHolderFor(req(CliCommand::Reject)) == LaneHolder::Mutating, "reject: mutating");
    CHECK(laneHolderFor(req(CliCommand::Gc)) == LaneHolder::Mutating, "gc: mutating");
    CHECK(laneHolderFor(req(CliCommand::Propose, true)) == LaneHolder::DryRun, "propose --dry-run: dry run");
    CHECK(laneHolderFor(req(CliCommand::Gc, true)) == LaneHolder::DryRun, "gc --dry-run: dry run");
    CHECK(laneHolderFor(req(CliCommand::Execute, true)) == LaneHolder::DryRun, "execute --dry-run: dry run");
    CHECK(laneHolderFor(req(CliCommand::Execute)) == LaneHolder::Execute, "execute: execute");
    CHECK(laneHolderFor(req(CliCommand::Resume)) == LaneHolder::Execute, "resume: execute");
    CliRequest scan;
    scan.command = CliCommand::Scan;
    scan.income = "local";
    CHECK(laneHolderFor(scan) == LaneHolder::Scan, "scan: its own holder");
}

static void testScan() {
    g_context = "scan";
    MutationLane lane;
    const uint64_t s = lane.acquire(LaneHolder::Scan);
    CHECK(s != 0 && lane.busy() && lane.scanRunning() && !lane.executeRunning(), "a background scan holds the lane");
    CHECK(lane.acquire(LaneHolder::Mutating) == 0 && lane.acquire(LaneHolder::Execute) == 0 &&
              lane.acquire(LaneHolder::Scan) == 0,
          "nothing else starts while it runs, another scan neither");
    CHECK(!lane.reportBudget(s) && lane.scanRunning(), "it keeps the lane at its 10 s report (a real mutating call)");
    CHECK(lane.finish(s) && !lane.busy() && !lane.scanRunning(), "free after its exit");
    const uint64_t m = lane.acquire(LaneHolder::Mutating);
    CHECK(m != 0 && !lane.scanRunning(), "another holder is not a scan");
    lane.finish(m);
}

static void testSingleFlight() {
    g_context = "single-flight";
    MutationLane lane;
    CHECK(!lane.busy() && lane.holder() == LaneHolder::None, "starts free");
    CHECK(lane.acquire(LaneHolder::None) == 0, "a read-only call never takes it");
    const uint64_t a = lane.acquire(LaneHolder::Mutating);
    CHECK(a != 0 && lane.busy() && !lane.executeRunning(), "a mutating call holds it");
    CHECK(lane.acquire(LaneHolder::Mutating) == 0, "a second mutating call is refused");
    CHECK(lane.acquire(LaneHolder::DryRun) == 0, "so is a dry run");
    CHECK(!lane.reportBudget(a), "a real mutating call keeps the lane at its 10 s report");
    CHECK(lane.busy(), "still busy after the report");
    CHECK(lane.finish(a), "its exit applies its result");
    CHECK(!lane.busy(), "and frees the lane");
    CHECK(!lane.finish(a), "a second finish is ignored");
    const uint64_t b = lane.acquire(LaneHolder::Mutating);
    CHECK(b != 0 && b != a, "a new call gets a new token");
    CHECK(!lane.finish(a) && lane.busy(), "an old token never frees a newer holder");
    CHECK(!lane.finish(0) && !lane.finish(9999) && lane.busy(), "unknown tokens are ignored");
    CHECK(lane.finish(b), "the holder's exit");
}

static void testDryRun() {
    g_context = "dry-run";
    MutationLane lane;
    const uint64_t dry = lane.acquire(LaneHolder::DryRun);
    CHECK(dry != 0 && lane.holder() == LaneHolder::DryRun, "a dry run holds the lane");
    CHECK(lane.reportBudget(dry), "its 10 s report releases it");
    CHECK(!lane.busy() && lane.releasedRunning() == 1, "free, the process still running");
    CHECK(!lane.reportBudget(dry), "a second report changes nothing");
    const uint64_t real = lane.acquire(LaneHolder::Mutating);
    CHECK(real != 0, "the next call can start");
    CHECK(!lane.finish(dry), "the late dry-run result is discarded");
    CHECK(lane.busy() && lane.holder() == LaneHolder::Mutating, "and does not free the newer holder");
    CHECK(lane.releasedRunning() == 0, "the released run is forgotten once it exits");
    CHECK(lane.finish(real), "the real call finishes normally");

    const uint64_t quick = lane.acquire(LaneHolder::DryRun);
    CHECK(lane.finish(quick) && !lane.busy(), "a dry run that ends before its report applies");
}

static void testExecute() {
    g_context = "execute";
    MutationLane lane;
    const uint64_t e = lane.acquire(LaneHolder::Execute);
    CHECK(e != 0 && lane.executeRunning(), "execute holds the lane as execute");
    CHECK(!lane.reportBudget(e) && lane.busy(), "execute is not released at a budget");
    CHECK(lane.acquire(LaneHolder::Mutating) == 0, "nothing else starts while it runs");
    CHECK(lane.finish(e) && !lane.executeRunning(), "free after its exit");
}

static void testAcquisitions() {
    g_context = "acquisitions";
    MutationLane lane;
    CHECK_EQ(lane.acquisitions(), 0, "none before the first acquire");
    const uint64_t a = lane.acquire(LaneHolder::Mutating);
    CHECK_EQ(lane.acquisitions(), 1, "an acquire counts");
    CHECK(lane.acquire(LaneHolder::Mutating) == 0 && lane.acquire(LaneHolder::None) == 0 &&
              lane.acquisitions() == 1,
          "a refused acquire does not");
    lane.finish(a);
    CHECK_EQ(lane.acquisitions(), 1, "a finish does not");
    const uint64_t dry = lane.acquire(LaneHolder::DryRun);
    lane.reportBudget(dry);
    const uint64_t b = lane.acquire(LaneHolder::Scan);
    CHECK_EQ(lane.acquisitions(), 3, "every holder kind counts, also after a dry run's release at its report");
    lane.finish(dry);
    lane.finish(b);
    CHECK_EQ(lane.acquisitions(), 3, "unchanged once free: a later read tells whether the lane was taken since");
}

static void testMenuWhileBusy() {
    g_context = "menu-busy";
    IntakeRecord r;
    r.id = "itk_0000000b";
    r.rootPath = r.rootKey = "/income/dump/Fixture Artist - Resolved Album";
    r.status = IntakeStatus::Resolved;
    ActionContext c;
    c.cliConfigured = true;
    c.cli.cli = "0.2.1";
    MutationLane lane;

    auto table = [&]() {
        c.laneBusy = lane.busy();
        c.executeRunning = lane.executeRunning();
        return buildActionTable({&r}, c);
    };
    CHECK(findEntry(table(), IntakeAction::Propose)->enabled, "free lane: Propose enabled");
    const uint64_t t = lane.acquire(LaneHolder::Mutating);
    ActionTable busy = table();
    CHECK(!findEntry(busy, IntakeAction::Propose)->enabled, "busy: Propose disabled");
    CHECK(!findEntry(busy, IntakeAction::Reject)->enabled, "busy: Reject disabled");
    CHECK(findEntry(busy, IntakeAction::Refresh)->enabled, "busy: Refresh enabled");
    lane.finish(t);
    CHECK(findEntry(table(), IntakeAction::Propose)->enabled, "free again: enabled");
    const uint64_t e = lane.acquire(LaneHolder::Execute);
    CHECK(findEntry(table(), IntakeAction::Propose)->title == "Propose (execute running)",
          "execute running is named");
    lane.finish(e);
    const uint64_t s = lane.acquire(LaneHolder::Scan);
    c.scanRunning = lane.scanRunning();
    ActionTable scanning = table();
    CHECK(!findEntry(scanning, IntakeAction::Propose)->enabled &&
              findEntry(scanning, IntakeAction::Propose)->title == "Propose (scan running)",
          "a background scan is named");
    lane.finish(s);
    c.scanRunning = lane.scanRunning();
    CHECK(findEntry(table(), IntakeAction::Propose)->enabled &&
              findEntry(table(), IntakeAction::Propose)->title == "Propose",
          "enabled and unlabelled again after it");
}

int main() {
    @autoreleasepool {
        testHolderKinds();
        testSingleFlight();
        testDryRun();
        testExecute();
        testScan();
        testAcquisitions();
        testMenuWhileBusy();
    }
    TEST_MAIN_END();
}
