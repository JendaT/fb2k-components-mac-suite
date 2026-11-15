//
//  IntakeLoaderTests.mm
//  foo_jl_intake_mac
//
//  End-to-end tests for IntakeLoader over the mock CLI (Tests/mock-cli):
//  not configured (nothing spawned), the default load (version then status,
//  invalidate-all only on the first load and on a visual change), the inert
//  state per doc 03 v1.2 (garbage, E_NO_RULES, timeout, a failed gate after
//  a successful load), a failed refresh keeping the last data, coalesced
//  reloads, mount aliases (a row on another mount point of the share, then
//  losing that mount point), and shutdown killing the read lane.
//  Hermetic: every state directory is a fresh temp directory; the mount
//  tables are synthetic.
//
// TEST_DEPS: src/Core/IntakeCliRunner.mm src/Core/IntakeCommandArgs.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeProcess.mm src/Core/IntakeLog.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeCapabilities.mm src/Core/IntakeErrorMap.mm src/Core/IntakeVersionGate.mm
// TEST_DEPS: src/Core/IntakeStatusModel.mm src/Core/IntakeSidecarMembers.mm src/Core/IntakeSnapshot.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeMountAliases.mm src/Core/IntakeLoadPolicy.mm src/Core/IntakeView.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLoader.h"
#include "../src/Core/IntakeLog.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <memory>
#include <mutex>
#include <string>
#include <vector>

using namespace intake;

namespace {

std::string g_noBunDir;

// --- log capture ---

std::mutex g_logMutex;
std::vector<std::string> g_logLines;

void captureBackend(LogLevel, const char *message) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    g_logLines.push_back(message);
}

void clearLog() {
    std::lock_guard<std::mutex> lock(g_logMutex);
    g_logLines.clear();
}

size_t logCount(const std::string &needle) {
    std::lock_guard<std::mutex> lock(g_logMutex);
    size_t n = 0;
    for (const std::string &line : g_logLines) {
        if (line.find(needle) != std::string::npos) n++;
    }
    return n;
}

// --- loader harness ---

struct Published {
    std::shared_ptr<const IntakeView> view;
    bool invalidate = false;
    PublishReason reason = PublishReason::Load;
};

struct Harness {
    mutable std::mutex m;
    std::vector<Published> published;
    std::vector<LoaderStatus> finished;
    std::vector<MountEntry> mounts;

    size_t publishCount() const {
        std::lock_guard<std::mutex> lock(m);
        return published.size();
    }
    size_t finishedCount() const {
        std::lock_guard<std::mutex> lock(m);
        return finished.size();
    }
    Published lastPublished() const {
        std::lock_guard<std::mutex> lock(m);
        return published.empty() ? Published() : published.back();
    }
    LoaderStatus lastFinished() const {
        std::lock_guard<std::mutex> lock(m);
        return finished.empty() ? LoaderStatus() : finished.back();
    }
    void setMounts(std::vector<MountEntry> list) {
        std::lock_guard<std::mutex> lock(m);
        mounts = std::move(list);
    }
};

LoaderSettings settingsFor(const std::string &state, const std::shared_ptr<Harness> &h, double budget = 10) {
    LoaderSettings s;
    s.cli.cliPath = mock::mockPath();
    s.cli.bunSearchDirs = {g_noBunDir};
    s.cli.baseEnvironment = mock::mockEnv(state);
    s.limits.budgetSeconds = budget;
    s.limits.killGraceSeconds = 0.3;
    s.limits.drainGraceSeconds = 0.3;
    s.limits.hardCapSeconds = 60;
    s.readMounts = [h] {
        std::lock_guard<std::mutex> lock(h->m);
        return h->mounts;
    };
    s.publish = [h](std::shared_ptr<const IntakeView> view, bool invalidate, PublishReason reason) {
        std::lock_guard<std::mutex> lock(h->m);
        h->published.push_back({std::move(view), invalidate, reason});
    };
    s.onLoadFinished = [h](const LoaderStatus &status) {
        std::lock_guard<std::mutex> lock(h->m);
        h->finished.push_back(status);
    };
    return s;
}

bool waitFinished(const Harness &h, size_t count, double timeout = 20) {
    return mock::waitUntil([&h, count] { return h.finishedCount() >= count; }, timeout);
}

// calls.log without the --mock-setup lines.
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

const std::string kVersion = "version\t--json";
const std::string kStatus = "status\t--json";

bool callsAre(const std::string &state, const std::vector<std::string> &expected) {
    std::vector<std::string> got = calls(state);
    if (got == expected) return true;
    printf("  calls.log:");
    for (const std::string &c : got) printf(" [%s]", c.c_str());
    printf("\n");
    return false;
}

std::string newAlbum(const std::string &root) {
    return root + "/income/dump/Fixture Artist - New Album/01 - Test Track One.wav";
}

void clearMode(const std::string &state, const std::string &command) {
    unlink((state + "/" + command + ".mode").c_str());
}

bool replaceInFile(const std::string &path, const std::string &from, const std::string &to) {
    std::string text = mock::readFile(path);
    const size_t at = text.find(from);
    if (at == std::string::npos) return false;
    text.replace(at, from.size(), to);
    return mock::writeFile(path, text);
}

} // anonymous namespace

static void testNotConfigured() {
    g_context = "not-configured";
    clearLog();
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    LoaderSettings s = settingsFor(state, h);
    s.cli.cliPath.clear();
    IntakeLoader loader(std::move(s));
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "the attempt finishes");
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a second attempt finishes");
    CHECK(h->lastFinished().state == LoaderState::NotConfigured, "state: not configured");
    CHECK(loader.statusLine() == "Not configured: no intake CLI path", "status line");
    CHECK_EQ(h->publishCount(), 0, "nothing is published");
    CHECK(callsAre(state, {}), "nothing is spawned");
    CHECK_EQ(logCount("not configured"), 1, "one console line, not one per attempt");
}

static void testDefaultLoad() {
    g_context = "default-load";
    clearLog();
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    CHECK(loader.status().state == LoaderState::Loading, "before the first load: loading");
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "the first load finishes");
    LoaderStatus st = h->lastFinished();
    CHECK(st.state == LoaderState::Ready && st.roots == 16 && st.cliVersion == "0.3.0",
          "ready, 16 roots, CLI 0.3.0");
    CHECK(loader.statusLine() == "Ready \xC2\xB7 CLI 0.3.0 \xC2\xB7 16 roots", "status line");
    CHECK(callsAre(state, {kVersion, kStatus}), "calls.log: exactly version, then status");
    CHECK_EQ(h->publishCount(), 1, "one publish");
    Published first = h->lastPublished();
    CHECK(first.invalidate && first.reason == PublishReason::Load, "the first load invalidates all");
    CHECK(first.view && !first.view->isInert() && first.view->snapshot().size() == 16, "a normal view of 16 roots");

    ViewScratch scratch;
    const IntakeRowVisual *blue = first.view->visualFor(newAlbum(root), scratch);
    CHECK(blue && blue->icon == IntakeIcon::CircleOpen && blue->bgTint == 0x4A90D938, "new: blue, open circle");
    const IntakeRowVisual *single =
        first.view->visualFor(root + "/income/shop/Loose Tracks/Fixture Artist E - Single Track.wav", scratch);
    CHECK(single && single->bgTint == 0xE5A50A38 && single->tooltip == "needs review \xC2\xB7 slot pending",
          "the single: amber, needs review and slot pending");
    const IntakeRowVisual *member =
        first.view->visualFor(root + "/income/shop/Loose Tracks/Fixture Artist C - Other Two.wav", scratch);
    CHECK(member && member->icon == IntakeIcon::CircleOpen && member->tooltip.empty(),
          "a virtual root's member (resolved, no review)");
    CHECK(first.view->visualFor(root + "/income/dump/Fixture Artist - Collected Album/01 - Test Track One.wav",
                                scratch) == nullptr,
          "gc_done renders nothing");

    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload finishes");
    CHECK(callsAre(state, {kVersion, kStatus, kStatus}), "a reload runs status only");
    CHECK_EQ(h->publishCount(), 2, "the unchanged snapshot is still swapped in");
    CHECK(!h->lastPublished().invalidate, "but without invalidation");

    loader.reload(true);
    CHECK(waitFinished(*h, 3), "a recheck finishes");
    CHECK(callsAre(state, {kVersion, kStatus, kStatus, kVersion, kStatus}), "a recheck runs version again");
    CHECK(!h->lastPublished().invalidate, "unchanged after the recheck: no invalidation");

    // A visual change: the new root becomes resolved with needs_review.
    CHECK(replaceInFile(state + "/responses/status.d/itk_0000000a.json", "\"status\":\"new\",\"needs_review\":false",
                        "\"status\":\"resolved\",\"needs_review\":true"),
          "fixture edited");
    loader.reload(false);
    CHECK(waitFinished(*h, 4), "the reload after the change finishes");
    Published changed = h->lastPublished();
    CHECK(changed.invalidate, "a visual change invalidates all");
    const IntakeRowVisual *amber = changed.view ? changed.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(amber && amber->bgTint == 0xE5A50A38 && amber->tooltip == "needs review", "the row is amber now");

    g_context = "default-logs";
    CHECK(logCount("[intake] loaded 16 roots (CLI 0.3.0)") == 1, "one Info line for the first load");
    CHECK(logCount("decorations changed") == 1, "one Info line for the change");
    CHECK(logCount("version: ok, exit 0") >= 2 && logCount("status: ok, exit 0") >= 4,
          "Debug lines: command, outcome, exit code");
    CHECK(logCount("load: rules from the CLI's own config.toml") >= 1, "Debug line naming the rules source");
    CHECK(logCount("\"ok\"") == 0 && logCount("\"data\"") == 0, "stdout is never logged");
}

static void testFirstLoadFailures() {
    g_context = "garbage-version";
    {
        std::string state = mock::setupState("default");
        auto h = std::make_shared<Harness>();
        IntakeLoader loader(settingsFor(state, h));
        mock::setMode(state, "version", "garbage");
        loader.reload(true);
        CHECK(waitFinished(*h, 1), "finishes");
        LoaderStatus st = h->lastFinished();
        CHECK(st.state == LoaderState::Inert && st.error.find("Intake CLI not available") != std::string::npos,
              "garbage stdout on the first version: inert, E_NO_CLI");
        CHECK(loader.statusLine().rfind("Inactive: version: Intake CLI not available", 0) == 0, "status line");
        CHECK(callsAre(state, {kVersion}), "status is not attempted");
        Published p = h->lastPublished();
        CHECK(h->publishCount() == 1 && p.view && p.view->isInert() && p.view->rendersNothing() && !p.invalidate,
              "an inert view with nothing to render, no invalidation");

        clearMode(state, "version");
        loader.reload(false);
        CHECK(waitFinished(*h, 2), "the retry finishes");
        CHECK(h->lastFinished().state == LoaderState::Ready, "the retry loads");
        CHECK(callsAre(state, {kVersion, kVersion, kStatus}), "the retry runs version again (it never passed)");
        CHECK(h->lastPublished().invalidate && !h->lastPublished().view->isInert(),
              "the first successful load invalidates all");
    }

    g_context = "no-rules";
    {
        std::string state = mock::setupState("default");
        auto h = std::make_shared<Harness>();
        IntakeLoader loader(settingsFor(state, h));
        mock::setMode(state, "status", "exit2 E_NO_RULES");
        loader.reload(true);
        CHECK(waitFinished(*h, 1), "finishes");
        LoaderStatus st = h->lastFinished();
        CHECK(st.state == LoaderState::Inert && st.error.find("Intake rules not configured") != std::string::npos,
              "E_NO_RULES on the first status: inert");
        CHECK(callsAre(state, {kVersion, kStatus}), "version passed, status failed");
    }

    g_context = "internal";
    {
        std::string state = mock::setupState("default");
        auto h = std::make_shared<Harness>();
        IntakeLoader loader(settingsFor(state, h));
        mock::setMode(state, "status", "exit2");
        loader.reload(true);
        CHECK(waitFinished(*h, 1), "finishes");
        CHECK(h->lastFinished().state == LoaderState::Failed, "E_INTERNAL on the first status: failed, not inert");
        CHECK(loader.statusLine().rfind("Load failed: status: Intake CLI internal error", 0) == 0, "status line");
        CHECK_EQ(h->publishCount(), 0, "nothing published");
    }

    g_context = "timeout";
    {
        std::string state = mock::setupState("default");
        auto h = std::make_shared<Harness>();
        IntakeLoader loader(settingsFor(state, h, 1.0));
        mock::setMode(state, "status", "hang");
        loader.reload(true);
        CHECK(waitFinished(*h, 1), "finishes");
        mock::trackHangPids(state);
        LoaderStatus st = h->lastFinished();
        CHECK(st.state == LoaderState::Inert && st.error.find("timed out") != std::string::npos,
              "a status timeout on the first load: inert, E_CLI_TIMEOUT");
        mock::killLeftovers();
    }

    g_context = "partial";
    {
        std::string state = mock::setupState("default");
        auto h = std::make_shared<Harness>();
        IntakeLoader loader(settingsFor(state, h));
        mock::setMode(state, "status", "partial");
        loader.reload(true);
        CHECK(waitFinished(*h, 1), "finishes");
        LoaderStatus st = h->lastFinished();
        CHECK(st.state == LoaderState::Ready && st.partialErrors == 1 && st.roots == 16,
              "a partial status loads its data and counts the error");
        CHECK(loader.statusLine().find("1 error: Unreadable sidecar") != std::string::npos, "status line");
        CHECK(h->lastPublished().invalidate, "published like a full load");
    }
}

static void testRefreshFailures() {
    g_context = "refresh-keeps-last";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");
    std::shared_ptr<const IntakeView> good = h->lastPublished().view;

    mock::setMode(state, "status", "garbage");
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "the failed refresh finishes");
    LoaderStatus st = h->lastFinished();
    CHECK(st.state == LoaderState::Stale && st.roots == 16, "E_NO_CLI after a successful load: stale, not inert");
    CHECK(loader.statusLine().rfind("Refresh failed, showing the last data (CLI 0.3.0 \xC2\xB7 16 roots)", 0) == 0,
          "status line");
    CHECK_EQ(h->publishCount(), 1, "nothing new published: the last data stays");

    clearMode(state, "status");
    loader.reload(false);
    CHECK(waitFinished(*h, 3) && h->lastFinished().state == LoaderState::Ready, "recovers");
    CHECK(h->publishCount() == 2 && !h->lastPublished().invalidate, "recovered, unchanged: no invalidation");

    g_context = "gate-after-load";
    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "schema2"}, mock::mockEnv(state)) == 0, "schema2 set up");
    loader.reload(true);
    CHECK(waitFinished(*h, 4), "the recheck finishes");
    st = h->lastFinished();
    CHECK(st.state == LoaderState::Inert && st.error.find("unsupported intake CLI") != std::string::npos,
          "a failed gate after a successful load: inert");
    Published inert = h->lastPublished();
    CHECK(inert.reason == PublishReason::Inert && inert.invalidate && inert.view && inert.view->isInert(),
          "an inert view, invalidated (rows change)");
    ViewScratch scratch;
    const IntakeRowVisual *tip = inert.view ? inert.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(tip && tip->bgTint == 0 && tip->icon == IntakeIcon::None &&
              tip->tooltip.rfind("intake inactive: unsupported intake CLI", 0) == 0,
          "rows under the last-known roots get a tooltip naming the error");

    const size_t before = h->publishCount();
    loader.reload(false);
    CHECK(waitFinished(*h, 5), "a reload while inert finishes");
    CHECK(h->lastFinished().state == LoaderState::Inert, "still inert (the gate runs again and fails)");
    CHECK(h->publishCount() == before + 1 && !h->lastPublished().invalidate, "same reason: no invalidation");

    mock::setMode(state, "version", "garbage");
    loader.reload(false);
    CHECK(waitFinished(*h, 6), "a version failure while inert finishes");
    CHECK(h->lastFinished().state == LoaderState::Inert && h->lastPublished().view->isInert(),
          "after a gate failure, a later E_NO_CLI keeps the inert view");
    clearMode(state, "version");

    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "default"}, mock::mockEnv(state)) == 0, "default again");
    loader.reload(false);
    CHECK(waitFinished(*h, 7) && h->lastFinished().state == LoaderState::Ready, "the gate passes again");
    Published back = h->lastPublished();
    CHECK(back.invalidate && back.view && !back.view->isInert(), "leaving the inert state invalidates all");
}

static void testCoalescing() {
    g_context = "coalescing";
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    mock::setMode(state, "status", "slow 1");
    loader.reload(true);
    loader.reload(false);
    loader.reload(false);
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "two loads finish");
    std::this_thread::sleep_for(std::chrono::milliseconds(600));
    CHECK_EQ(h->finishedCount(), 2, "requests during a load coalesce into one more load");
    CHECK(callsAre(state, {kVersion, kStatus, kStatus}), "calls.log: version, status, status");
    clearMode(state, "status");
}

static void testMountAliases() {
    g_context = "mount-aliases";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    const std::string alias = state + "/alias";  // never exists: only a mount table entry
    auto h = std::make_shared<Harness>();
    const MountEntry lan{root, "//user@nas-lan.local/fixture-share", "smbfs"};
    const MountEntry vpn{alias, "//user@10.8.0.1/fixture-share", "smbfs"};
    h->setMounts({lan, vpn});
    IntakeLoader loader(settingsFor(state, h));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "loads with two aliases");
    Published p = h->lastPublished();
    ViewScratch scratch;
    CHECK(p.view && p.view->aliases().aliasCount() == 2, "the view carries the alias table");
    const IntakeRowVisual *viaAlias = p.view ? p.view->visualFor(newAlbum(alias), scratch) : nullptr;
    CHECK(viaAlias && viaAlias->icon == IntakeIcon::CircleOpen, "a row on the other mount point matches");
    const IntakeRowVisual *viaRoot = p.view ? p.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(viaRoot && viaRoot->icon == IntakeIcon::CircleOpen, "a row on the CLI's mount point matches");
    const IntakeRowVisual *memberViaAlias =
        p.view ? p.view->visualFor(alias + "/income/shop/Loose Tracks/Fixture Artist B - Loose One.wav", scratch)
               : nullptr;
    CHECK(memberViaAlias && memberViaAlias->tooltip == "needs review",
          "a virtual root's member through the alias (members follow the alias key)");

    g_context = "mount-lost";
    const size_t before = h->publishCount();
    h->setMounts({lan});
    loader.remount();
    CHECK(mock::waitUntil([&] { return h->publishCount() > before; }, 10), "losing a mount publishes");
    Published lost = h->lastPublished();
    CHECK(lost.reason == PublishReason::Remount && lost.invalidate, "rebuilt keys, invalidate all");
    CHECK(lost.view && lost.view->visualFor(newAlbum(alias), scratch) == nullptr,
          "rows under the lost mount point stop matching");
    const IntakeRowVisual *kept = lost.view ? lost.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(kept && kept->icon == IntakeIcon::CircleOpen, "rows under the remaining mount point keep matching");
    CHECK(callsAre(state, {kVersion, kStatus}), "a remount alone runs no CLI");

    g_context = "mount-same";
    loader.remount();  // same table
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload after an unchanged remount finishes");
    CHECK(h->publishCount() == before + 2 && h->lastPublished().reason == PublishReason::Load &&
              !h->lastPublished().invalidate,
          "an unchanged mount table publishes nothing; the reload is unchanged");
}

static void testShutdown() {
    g_context = "shutdown";
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    auto loader = std::make_unique<IntakeLoader>(settingsFor(state, h, 30));
    mock::setMode(state, "status", "hang");
    loader->reload(true);
    CHECK(mock::waitUntil([&] { return mock::fileExists(state + "/hang.pid"); }, 10), "status is hanging");
    mock::trackHangPids(state);
    int shell = 0, child = 0;
    sscanf(mock::readFile(state + "/hang.pid").c_str(), "%d %d", &shell, &child);
    loader->shutdown();
    CHECK(loader->status().state == LoaderState::Stopped && loader->statusLine() == "Stopped", "stopped");
    CHECK(shell > 1 && mock::waitUntil([shell] { return mock::groupGone(shell); }, 5),
          "shutdown kills the read lane's process group");
    loader->reload(true);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK_EQ(h->publishCount(), 0, "nothing is published after shutdown");
    CHECK_EQ(h->finishedCount(), 0, "no load is reported after shutdown");
    CHECK(callsAre(state, {kVersion, kStatus}), "no call after shutdown");
    loader->shutdown();  // idempotent
    loader.reset();
    mock::killLeftovers();
}

int main(void) {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        atexit(mock::removeTempRoot);
        setLogBackend(captureBackend);
        setLogLevel(LogLevel::Debug);
        g_noBunDir = mock::newDir("nobun");

        testNotConfigured();
        testDefaultLoad();
        testFirstLoadFailures();
        testRefreshFailures();
        testCoalescing();
        testMountAliases();
        testShutdown();

        setLogBackend(nullptr);
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
