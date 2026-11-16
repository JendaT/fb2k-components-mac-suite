//
//  IntakeLiveUpdateTests.mm
//  foo_jl_intake_mac
//
//  B4 end to end without foobar2000: IntakeWatcher (real FSEvents) wired to
//  IntakeLoader over the mock CLI the way IntakeService wires them, on a
//  fresh mock state in a temp directory:
//   - the first load runs version, income, status and hands the watch set
//     to the watcher with the event id taken before `status`; the stream's
//     start costs no second status (none within 3 s);
//   - a sidecar written after that `status` call and before the stream
//     started (a deliberately delayed handover) is replayed: one more status;
//   - a mock state change applied by a CLI call from outside (the
//     `.next` mechanism, like a Terminal run) retints within a few seconds,
//     with exactly one more `status`;
//   - non-sidecar writes and idle time run nothing;
//   - a burst of sidecar touches is one `status`;
//   - re-running --mock-setup (the scenario switch) retints back.
//  Hermetic: the mock only, temp directories only.
//
// TEST_FRAMEWORKS: CoreServices
// TEST_DEPS: src/Core/IntakeWatcher.mm src/Core/IntakeWatchFilter.mm src/Core/IntakeDebounce.mm
// TEST_DEPS: src/Core/IntakeLoader.mm src/Core/IntakeCliRunner.mm src/Core/IntakeCommandArgs.mm
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeProcess.mm src/Core/IntakeLog.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeCapabilities.mm src/Core/IntakeErrorMap.mm src/Core/IntakeVersionGate.mm
// TEST_DEPS: src/Core/IntakeStatusModel.mm src/Core/IntakeSidecarMembers.mm src/Core/IntakeSnapshot.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeMountAliases.mm src/Core/IntakeLoadPolicy.mm src/Core/IntakeView.mm
// TEST_DEPS: src/Core/IntakeIncome.mm src/Core/IntakeWatchSet.mm src/Core/IntakeSettingsParse.mm
// TEST_DEPS: src/Core/IntakeGroupBadge.mm
// TEST_DEPS: src/Core/IntakeLibraryIndex.mm src/Core/IntakeSwapPlanner.mm
//

#import <Foundation/Foundation.h>
#include <CoreServices/CoreServices.h>

#include "../src/Core/IntakeLoader.h"
#include "../src/Core/IntakeLog.h"
#include "../src/Core/IntakeWatcher.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace intake;

namespace {

struct Published {
    std::shared_ptr<const IntakeView> view;
    bool invalidate = false;
};

struct Sink {
    std::mutex m;
    std::vector<Published> published;
    size_t finished = 0;

    size_t publishCount() {
        std::lock_guard<std::mutex> lock(m);
        return published.size();
    }
    size_t finishedCount() {
        std::lock_guard<std::mutex> lock(m);
        return finished;
    }
    Published last() {
        std::lock_guard<std::mutex> lock(m);
        return published.empty() ? Published() : published.back();
    }
};

std::vector<std::string> calls(const std::string &state) {
    std::vector<std::string> out;
    std::string text = mock::callsLog(state);
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(start, end - start);
        if (!line.empty() && line.rfind("--mock-setup", 0) != 0) out.push_back(line);
        start = end + 1;
    }
    return out;
}

size_t statusCalls(const std::string &state) {
    size_t n = 0;
    for (const std::string &c : calls(state)) {
        if (c == "status\t--json") n++;
    }
    return n;
}

const char *const kResolvedTrack = "/income/dump/Fixture Artist - Resolved Album/01 - Test Track One.wav";

WatchEventId currentEventId() {
    return static_cast<WatchEventId>(FSEventsGetCurrentEventId());
}

// IntakeService's handover.
void handOver(IntakeWatcher &w, const WatchHandover &handover) {
    if (handover.restart) {
        w.restart(handover.sinceEventId);
    } else {
        w.setPaths(handover.paths, handover.sinceEventId);
    }
}

} // anonymous namespace

static void testLiveUpdates() {
    g_context = "live-first-load";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto sink = std::make_shared<Sink>();

    // IntakeService's wiring: batches -> reloadForChanges; watch sets -> setPaths.
    IntakeLoader *loaderSlot = nullptr;
    IntakeLoader **slot = &loaderSlot;
    auto watcher = std::make_shared<IntakeWatcher>([slot](WatchBatch batch) {
        if (IntakeLoader *loader = *slot) loader->reloadForChanges(std::move(batch.directories), batch.rescan);
    });
    std::weak_ptr<IntakeWatcher> weakWatcher = watcher;

    LoaderSettings s;
    s.cli.cliPath = mock::mockPath();
    s.cli.bunSearchDirs = {mock::newDir("nobun")};
    s.cli.baseEnvironment = mock::mockEnv(state);
    s.readMounts = [] { return std::vector<MountEntry>{MountEntry{"/", "/dev/disk-fixture", "apfs", true}}; };
    s.publish = [sink](std::shared_ptr<const IntakeView> view, bool invalidate, PublishReason) {
        std::lock_guard<std::mutex> lock(sink->m);
        sink->published.push_back({std::move(view), invalidate});
    };
    s.onLoadFinished = [sink](const LoaderStatus &) {
        std::lock_guard<std::mutex> lock(sink->m);
        sink->finished++;
    };
    s.onWatchSet = [weakWatcher](const WatchHandover &handover) {
        if (std::shared_ptr<IntakeWatcher> w = weakWatcher.lock()) handOver(*w, handover);
    };
    s.currentEventId = [] { return currentEventId(); };
    auto loader = std::make_unique<IntakeLoader>(std::move(s));
    loaderSlot = loader.get();

    loader->reload(true);
    CHECK(mock::waitUntil([&] { return sink->finishedCount() >= 1; }, 20), "the first load finishes");
    CHECK(mock::waitUntil([&] { return watcher->stats().streamRunning; }, 5), "the watch stream runs");
    CHECK(watcher->stats().paths.size() == 3, "watching dump, offline and shop");
    CHECK(watcher->stats().sinceEventId != kWatchSinceNow, "from the event id taken before status");
    CHECK(mock::waitUntil([&] { return watcher->stats().historyDone >= 1; }, 5), "its replay ran");
    std::this_thread::sleep_for(std::chrono::milliseconds(3000));
    CHECK_EQ(sink->finishedCount(), 1, "no second load within 3 s of the stream's start");
    std::vector<std::string> c = calls(state);
    CHECK(c.size() == 3 && c[0] == "version\t--json" && c[1] == "income\t--json" && c[2] == "status\t--json",
          "calls.log: exactly version, income, status");
    ViewScratch scratch;
    const IntakeRowVisual *before = sink->last().view ? sink->last().view->visualFor(root + kResolvedTrack, scratch)
                                                      : nullptr;
    CHECK(before && before->icon == IntakeIcon::CircleOpen, "the resolved album is blue first");

    g_context = "live-terminal-run";
    // A CLI run from outside foobar2000 (Terminal): propose applies the
    // b-proposed state, which rewrites the root's sidecar.
    const size_t published = sink->publishCount();
    mock::writeFile(state + "/propose.next", "b-proposed\n");
    const auto started = mock::Clock::now();
    CHECK(mock::runSync({mock::mockPath(), "propose", "itk_0000000b", "--json"}, mock::mockEnv(state)) == 0,
          "the outside propose run succeeds");
    CHECK(mock::waitUntil(
              [&] { return sink->publishCount() > published && sink->last().invalidate; }, 6),
          "the change is published with invalidate-all");
    const double seconds = mock::secondsSince(started);
    CHECK(seconds < 4.5, "within a few seconds (about 2 s expected: 0.5 s latency, 1 s quiet, one load)");
    printf("  retint after %.2f s\n", seconds);
    const IntakeRowVisual *after = sink->last().view ? sink->last().view->visualFor(root + kResolvedTrack, scratch)
                                                     : nullptr;
    CHECK(after && after->icon == IntakeIcon::CircleLeftHalf, "the row is proposed (teal, half circle) now");
    c = calls(state);
    CHECK(c.size() == 5 && c[3] == "propose\titk_0000000b\t--json" && c[4] == "status\t--json",
          "calls.log: the outside run, then exactly one status");

    g_context = "live-idle";
    mock::writeFile(root + "/income/dump/Fixture Artist - New Album/notes.txt", "x");
    mock::writeFile(root + "/income/dump/Fixture Artist - New Album/.intake-tmp-1", "{}");
    mock::writeFile(root + "/income/shop/Loose Tracks/.intake-hint.json", "{}");
    std::this_thread::sleep_for(std::chrono::milliseconds(2500));
    CHECK_EQ(calls(state).size(), 5, "non-sidecar writes and idle time run nothing");

    g_context = "live-burst";
    const size_t statusBefore = statusCalls(state);
    for (const char *album : {"New Album", "Close Call", "Proposed Album", "Approved Album", "Placed Album"}) {
        const std::string sidecar = root + "/income/dump/Fixture Artist - " + album + "/.intake.json";
        mock::writeFile(sidecar, mock::readFile(sidecar));
    }
    CHECK(mock::waitUntil([&] { return statusCalls(state) > statusBefore; }, 6), "the burst reloads");
    std::this_thread::sleep_for(std::chrono::milliseconds(1800));
    CHECK_EQ(statusCalls(state), statusBefore + 1, "five sidecar writes: one status");

    g_context = "live-scenario-switch";
    const size_t beforeSetup = sink->publishCount();
    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "default"}, mock::mockEnv(state)) == 0,
          "the scenario is set up again");
    CHECK(mock::waitUntil([&] { return sink->publishCount() > beforeSetup && sink->last().invalidate; }, 8),
          "the scenario switch is published with invalidate-all");
    const IntakeRowVisual *back = sink->last().view ? sink->last().view->visualFor(root + kResolvedTrack, scratch)
                                                    : nullptr;
    CHECK(back && back->icon == IntakeIcon::CircleOpen, "the row is blue again");

    watcher->stop();
    loaderSlot = nullptr;
    loader->shutdown();
    loader.reset();
    watcher.reset();
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "no stream left");
}

// The startup gap: the stream starts after the first `status` (the handover
// runs once the load has finished), and a sidecar written in between must
// still reload. The handover is delayed on purpose, with the write inside.
static void testStartupGap() {
    g_context = "startup-gap";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    const std::string sidecar = root + "/income/dump/Fixture Artist - New Album/.intake.json";
    auto sink = std::make_shared<Sink>();

    IntakeLoader *loaderSlot = nullptr;
    IntakeLoader **slot = &loaderSlot;
    auto watcher = std::make_shared<IntakeWatcher>([slot](WatchBatch batch) {
        if (IntakeLoader *loader = *slot) loader->reloadForChanges(std::move(batch.directories), batch.rescan);
    });
    std::weak_ptr<IntakeWatcher> weakWatcher = watcher;

    LoaderSettings s;
    s.cli.cliPath = mock::mockPath();
    s.cli.bunSearchDirs = {mock::newDir("nobun")};
    s.cli.baseEnvironment = mock::mockEnv(state);
    s.readMounts = [] { return std::vector<MountEntry>{MountEntry{"/", "/dev/disk-fixture", "apfs", true}}; };
    s.publish = [sink](std::shared_ptr<const IntakeView> view, bool invalidate, PublishReason) {
        std::lock_guard<std::mutex> lock(sink->m);
        sink->published.push_back({std::move(view), invalidate});
    };
    s.onLoadFinished = [sink](const LoaderStatus &) {
        std::lock_guard<std::mutex> lock(sink->m);
        sink->finished++;
    };
    auto handovers = std::make_shared<std::atomic<int>>(0);
    s.onWatchSet = [weakWatcher, handovers, sidecar](const WatchHandover &handover) {
        if (handovers->fetch_add(1) == 0) {
            // After the first `status` returned, before the stream exists.
            mock::writeFile(sidecar, mock::readFile(sidecar));
            std::this_thread::sleep_for(std::chrono::milliseconds(400));
        }
        if (std::shared_ptr<IntakeWatcher> w = weakWatcher.lock()) handOver(*w, handover);
    };
    s.currentEventId = [] { return currentEventId(); };
    auto loader = std::make_unique<IntakeLoader>(std::move(s));
    loaderSlot = loader.get();

    loader->reload(true);
    CHECK(mock::waitUntil([&] { return sink->finishedCount() >= 1; }, 20), "the first load finishes");
    CHECK(mock::waitUntil([&] { return statusCalls(state) >= 2; }, 6),
          "the write between status and the stream's start reloads (replayed)");
    CHECK(mock::waitUntil([&] { return sink->finishedCount() >= 2; }, 10), "that load finishes");
    std::this_thread::sleep_for(std::chrono::milliseconds(2000));
    std::vector<std::string> c = calls(state);
    CHECK(c.size() == 4 && c[0] == "version\t--json" && c[1] == "income\t--json" && c[2] == "status\t--json" &&
              c[3] == "status\t--json",
          "calls.log: version, income, status, then one status for the replayed write");
    CHECK_EQ(handovers->load(), 1, "one watch set handed over");

    watcher->stop();
    loaderSlot = nullptr;
    loader->shutdown();
    loader.reset();
    watcher.reset();
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "no stream left");
}

int main(void) {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        atexit(mock::removeTempRoot);
        setLogLevel(LogLevel::Error);
        testLiveUpdates();
        testStartupGap();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
