//
//  IntakeLoaderTests.mm
//  foo_jl_intake_mac
//
//  End-to-end tests for IntakeLoader over the mock CLI (Tests/mock-cli):
//  not configured (nothing spawned), the default load (version then status,
//  invalidate-all only on the first load and on a visual change), the inert
//  state per doc 03 v1.2 (garbage, E_NO_RULES, timeout, a failed gate after
//  a successful load and the gate passing again before a failed status), a
//  failed refresh keeping the last data, coalesced reloads, mount aliases (a
//  row on another mount point of the share, then losing that mount point,
//  and a share holding no root coming and going without invalidation), and
//  shutdown killing the read lane. B4: the `income` call (CLI 0.3.0 only,
//  a failure is per-command), the watch set handed over only on change
//  (realpath only for local paths), reloadForChanges coalescing into one
//  more `status` (the reload-again flag), and incremental member lists
//  (unchanged folders not listed again; a full listing on reload(true),
//  remount, rescan or an unmapped folder; changes of a failed load carried
//  over). B4 review fixes: a partial `status` whose E_PARSE names a
//  sidecar keeps that root's last record (no untint, no invalidation) and
//  retries once 1 s later; the watch set reads the mount table again, so a
//  share that mounted during the load is never resolved.
//  Hermetic: every state directory is a fresh temp directory; the mount
//  tables are synthetic.
//
// TEST_DEPS: src/Core/IntakeCliRunner.mm src/Core/IntakeCommandArgs.mm src/Core/IntakeEnvelope.mm
// TEST_DEPS: src/Core/IntakeProcess.mm src/Core/IntakeLog.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeCapabilities.mm src/Core/IntakeErrorMap.mm src/Core/IntakeVersionGate.mm
// TEST_DEPS: src/Core/IntakeStatusModel.mm src/Core/IntakeSidecarMembers.mm src/Core/IntakeSnapshot.mm
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm src/Core/IntakePath.mm
// TEST_DEPS: src/Core/IntakeMountAliases.mm src/Core/IntakeLoadPolicy.mm src/Core/IntakeView.mm
// TEST_DEPS: src/Core/IntakeIncome.mm src/Core/IntakeWatchSet.mm src/Core/IntakeWatchFilter.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLoader.h"
#include "../src/Core/IntakeLog.h"
#include "../src/Core/IntakeWatchSet.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
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
    std::vector<LoaderStatus> statusChanges;
    std::vector<MountEntry> mounts;

    size_t statusChangeCount() const {
        std::lock_guard<std::mutex> lock(m);
        return statusChanges.size();
    }
    std::vector<Published> publishedCopy() const {
        std::lock_guard<std::mutex> lock(m);
        return published;
    }

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
    s.onStatusChanged = [h](const LoaderStatus &status) {
        std::lock_guard<std::mutex> lock(h->m);
        h->statusChanges.push_back(status);
    };
    return s;
}

// The mock's CLI settings, for reconfigure().
CliConfig mockCli(const std::string &state) {
    CliConfig c;
    c.cliPath = mock::mockPath();
    c.bunSearchDirs = {g_noBunDir};
    c.baseEnvironment = mock::mockEnv(state);
    return c;
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
const std::string kIncome = "income\t--json";
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

// --- B4: watch set and member I/O ---

// Counts listDirectory per directory; answers through the POSIX access.
class CountingAccess : public SidecarFileAccess {
public:
    bool listDirectory(const std::string &directory, std::vector<std::string> &names, int &error) override {
        {
            std::lock_guard<std::mutex> lock(m);
            lists[directory]++;
        }
        return posixSidecarFileAccess().listDirectory(directory, names, error);
    }
    bool readFile(const std::string &path, std::string &contents, int &error) override {
        return posixSidecarFileAccess().readFile(path, contents, error);
    }
    int listsOf(const std::string &directory) {
        std::lock_guard<std::mutex> lock(m);
        return lists[directory];
    }

private:
    std::mutex m;
    std::map<std::string, int> lists;
};

struct WatchHarness {
    std::mutex m;
    std::vector<std::vector<std::string>> sets;  // every onWatchSet call
    std::vector<std::string> resolved;           // every path the link reader examined

    size_t count() {
        std::lock_guard<std::mutex> lock(m);
        return sets.size();
    }
    std::vector<std::string> last() {
        std::lock_guard<std::mutex> lock(m);
        return sets.empty() ? std::vector<std::string>() : sets.back();
    }
    bool resolvedUnder(const std::string &prefix) {
        std::lock_guard<std::mutex> lock(m);
        for (const std::string &p : resolved) {
            if (p.rfind(prefix, 0) == 0) return true;
        }
        return false;
    }
};

const MountEntry kLocalRoot{"/", "/dev/disk-fixture", "apfs", true};

// settingsFor plus the B4 hooks: a recording link reader (lstat/readlink
// underneath) and the watch-set handler.
LoaderSettings watchSettingsFor(const std::string &state, const std::shared_ptr<Harness> &h,
                                const std::shared_ptr<WatchHarness> &w, CountingAccess *files = nullptr) {
    LoaderSettings s = settingsFor(state, h);
    s.files = files;
    s.readLink = [w](const std::string &path, std::string &target) {
        {
            std::lock_guard<std::mutex> lock(w->m);
            w->resolved.push_back(path);
        }
        return posixLinkReader(path, target);
    };
    s.onWatchSet = [w](const std::vector<std::string> &paths) {
        std::lock_guard<std::mutex> lock(w->m);
        w->sets.push_back(paths);
    };
    return s;
}

std::string realOf(const std::string &path) {
    char buffer[PATH_MAX];
    return ::realpath(path.c_str(), buffer) ? std::string(buffer) : path;
}

// A canned exit-1 `status` (responses/status.envelope): every row but
// `omitId`'s, and one E_PARSE naming `sidecar`, as the CLI answers when it
// reads a sidecar half written.
bool writeParsePartial(const std::string &state, const std::string &omitId, const std::string &sidecar) {
    const std::string dir = state + "/responses/status.d";
    std::string rows;
    for (const std::string &name : mock::listDir(dir)) {
        if (name == omitId + ".json") continue;
        std::string row = mock::readFile(dir + "/" + name);
        while (!row.empty() && (row.back() == '\n' || row.back() == '\r')) row.pop_back();
        if (row.empty()) continue;
        if (!rows.empty()) rows += ",";
        rows += row;
    }
    const std::string envelope = "{\"ok\":false,\"data\":[" + rows +
                                 "],\"errors\":[{\"code\":\"E_PARSE\",\"msg\":\"unreadable sidecar\",\"path\":\"" +
                                 sidecar + "\"}]}\n";
    return mock::writeFile(state + "/responses/status.envelope", envelope) &&
           mock::writeFile(state + "/responses/status.exit", "1\n");
}

void clearParsePartial(const std::string &state) {
    unlink((state + "/responses/status.envelope").c_str());
    unlink((state + "/responses/status.exit").c_str());
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
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "calls.log: exactly version, income, then status");
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
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus}), "a reload runs status only");
    CHECK_EQ(h->publishCount(), 2, "the unchanged snapshot is still swapped in");
    CHECK(!h->lastPublished().invalidate, "but without invalidation");

    loader.reload(true);
    CHECK(waitFinished(*h, 3), "a recheck finishes");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kVersion, kIncome, kStatus}),
          "a recheck runs version and income again");
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
        CHECK(callsAre(state, {kVersion, kVersion, kIncome, kStatus}), "the retry runs version again (it never passed)");
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
        CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "version passed, status failed");
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

    // Doc 03 v1.2: inert only while the gate fails. A gate that passes again
    // followed by a failed `status` is a failed refresh: the last data, stale.
    g_context = "gate-passes-status-fails";
    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "schema2"}, mock::mockEnv(state)) == 0, "schema2 again");
    loader.reload(true);
    CHECK(waitFinished(*h, 8) && h->lastFinished().state == LoaderState::Inert, "the gate fails again: inert");
    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "default"}, mock::mockEnv(state)) == 0, "default again");
    mock::setMode(state, "status", "garbage");
    loader.reload(false);
    CHECK(waitFinished(*h, 9), "the gate passes, then status fails");
    st = h->lastFinished();
    CHECK(st.state == LoaderState::Stale && st.roots == 16 && st.error.rfind("status: ", 0) == 0,
          "stale with the status error, not inert");
    CHECK(loader.statusLine().rfind(
              "Refresh failed, showing the last data (CLI 0.3.0 \xC2\xB7 16 roots): status: ", 0) == 0,
          "status line: not 'Inactive'");
    Published stale = h->lastPublished();
    CHECK(stale.reason == PublishReason::GatePassed && stale.invalidate && stale.view && !stale.view->isInert(),
          "the last load is published again without the inert reason, invalidated");
    const IntakeRowVisual *again = stale.view ? stale.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(again && again->icon == IntakeIcon::CircleOpen && again->bgTint == 0x4A90D938 &&
              again->tooltip.find("intake inactive") == std::string::npos,
          "rows render the last loaded visual again");
    clearMode(state, "status");
    loader.reload(false);
    CHECK(waitFinished(*h, 10) && h->lastFinished().state == LoaderState::Ready, "recovers");
    CHECK(!h->lastPublished().invalidate, "recovered, unchanged: no invalidation");
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
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus}), "calls.log: version, income, status, status");
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
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "a remount alone runs no CLI");

    g_context = "mount-same";
    loader.remount();  // same table
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload after an unchanged remount finishes");
    CHECK(h->publishCount() == before + 2 && h->lastPublished().reason == PublishReason::Load &&
              !h->lastPublished().invalidate,
          "an unchanged mount table publishes nothing; the reload is unchanged");

    // A share that holds no intake root mounts and unmounts: the new table
    // is published (rows and roots keyed alike) without invalidation.
    g_context = "mount-unrelated";
    clearLog();
    const MountEntry backup{state + "/backup", "//user@host-a/fixture-backup", "smbfs"};
    size_t count = h->publishCount();
    h->setMounts({lan, backup});
    loader.remount();
    CHECK(mock::waitUntil([&] { return h->publishCount() > count; }, 10), "the new table is published");
    Published unrelated = h->lastPublished();
    CHECK(unrelated.reason == PublishReason::Remount && !unrelated.invalidate &&
              unrelated.view && unrelated.view->aliases().aliasCount() == 2,
          "carrying the new alias, without invalidation");
    const IntakeRowVisual *still = unrelated.view ? unrelated.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(still && still->icon == IntakeIcon::CircleOpen, "rows on the roots' share keep matching");
    count = h->publishCount();
    h->setMounts({lan});
    loader.remount();
    CHECK(mock::waitUntil([&] { return h->publishCount() > count; }, 10), "the unmount is published");
    CHECK(h->lastPublished().reason == PublishReason::Remount && !h->lastPublished().invalidate,
          "and does not invalidate either");
    CHECK(logCount("mount aliases changed under no intake root") == 2, "one Debug line each");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus}), "no CLI call for either");
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
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "no call after shutdown");
    loader->shutdown();  // idempotent
    loader.reset();
    mock::killLeftovers();
}

static void testIncomeAndWatchSet() {
    g_context = "income-watch-set";
    clearLog();
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    const std::string real = realOf(root);
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "CLI 0.3.0: version, income, status");
    CHECK_EQ(w->count(), 1, "one watch set handed over");
    std::vector<std::string> set = w->last();
    CHECK(set.size() == 3 && set[0] == real + "/income/dump" && set[1] == real + "/income/offline" &&
              set[2] == real + "/income/shop",
          "the income folders (offline missing, still watched), realpath'd, roots' parents folded in");
    CHECK(logCount("income: 3 folder(s)") == 1, "a Debug line for the income call");

    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload finishes");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus}), "a plain reload runs no income call");
    CHECK_EQ(w->count(), 1, "an unchanged watch set is not handed over again");

    g_context = "income-failure";
    mock::setMode(state, "income", "exit2");
    loader.reload(true);
    CHECK(waitFinished(*h, 3), "a recheck with a failing income finishes");
    CHECK(h->lastFinished().state == LoaderState::Ready, "a failed income call is not inert: the load is Ready");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kVersion, kIncome, kStatus}),
          "status still runs after the failed income call");
    CHECK(logCount("income failed; watching the last known income folders") == 1, "one log line");
    CHECK_EQ(w->count(), 1, "the last good income folders stay watched");
    clearMode(state, "income");

    g_context = "income-folder-removed";
    // A configured income folder disappears from income.yaml: the watch set
    // follows on the next income call (reload(true)).
    CHECK(replaceInFile(state + "/responses/income", "offline\tincome/offline\n", ""), "offline removed");
    loader.reload(true);
    CHECK(waitFinished(*h, 4), "a recheck finishes");
    CHECK(w->count() == 2 && w->last().size() == 2, "the changed set is handed over: dump and shop");
}

static void testIncomeNotOffered() {
    g_context = "income-not-offered";
    std::string state = mock::setupState("cli-0.2.1");
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "loads");
    CHECK(callsAre(state, {kVersion, kStatus}), "CLI 0.2.1 lists no income command: version, status");
    std::vector<std::string> set = w->last();
    CHECK(set.size() == 2 && set[0] == realOf(state + "/root") + "/income/dump",
          "the watch set is the roots' parent folders");
}

static void testNetworkWatchSet() {
    g_context = "network-watch-set";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    // The mock's root stands in for a share mounted over SMB.
    h->setMounts({kLocalRoot, MountEntry{root, "//user@host-lan/fixture-share", "smbfs", false}});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "loads");
    CHECK(!w->resolvedUnder(root) && !w->resolvedUnder(realOf(root)),
          "nothing under the network mount is examined (either spelling)");
    std::vector<std::string> set = w->last();
    CHECK(set.size() == 3 && set[0] == root + "/income/dump", "the stream gets the folders as the CLI spelled them");

    g_context = "network-watch-set-remount";
    const size_t before = w->count();
    h->setMounts({kLocalRoot});  // the share is gone: the same folders are now local paths
    loader.remount();
    CHECK(mock::waitUntil([&] { return w->count() > before; }, 10), "a remount recomputes the watch set");
    CHECK(w->resolvedUnder(realOf(root)) && w->last().size() == 3 && w->last()[0] == realOf(root) + "/income/dump",
          "now local: resolved");
}

static void testChangeCoalescing() {
    g_context = "change-coalescing";
    std::string state = mock::setupState("default");
    const std::string real = realOf(state + "/root");
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "first load");
    mock::setMode(state, "status", "slow 1");
    loader.reload(false);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));  // status is now running
    loader.reloadForChanges({real + "/income/dump/Fixture Artist - New Album"}, false);
    loader.reloadForChanges({real + "/income/shop/Loose Tracks"}, false);
    loader.reloadForChanges({}, true);
    CHECK(waitFinished(*h, 3), "the running load and one more finish");
    std::this_thread::sleep_for(std::chrono::milliseconds(600));
    CHECK_EQ(h->finishedCount(), 3, "three batches during a load set the reload-again flag once");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus}), "one more status, no version");
    clearMode(state, "status");

    loader.reloadForChanges({real + "/income/dump/Fixture Artist - New Album"}, false);
    CHECK(waitFinished(*h, 4), "an idle batch starts a load at once");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus, kStatus}), "one status per batch");
    CHECK(!h->lastPublished().invalidate, "nothing changed: no invalidation");
}

static void testIncrementalMembers() {
    g_context = "incremental-members";
    clearLog();
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    const std::string real = realOf(root);
    const std::string loose = root + "/income/shop/Loose Tracks";  // three virtual roots: the one shared folder
    const std::string newAlbumDir = real + "/income/dump/Fixture Artist - New Album";
    CountingAccess files;
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w, &files));
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "first load");
    CHECK_EQ(files.listsOf(loose), 1, "the first load lists the shared folder");

    loader.reloadForChanges({newAlbumDir}, false);
    CHECK(waitFinished(*h, 2), "a change elsewhere reloads");
    CHECK_EQ(files.listsOf(loose), 1, "an unchanged folder is not listed again");
    CHECK(logCount("member lists (incremental)") == 1 && logCount("1 reused") >= 1, "logged as incremental");

    loader.reloadForChanges({real + "/income/shop/Loose Tracks"}, false);
    CHECK(waitFinished(*h, 3), "a change in the shared folder reloads");
    CHECK_EQ(files.listsOf(loose), 2, "the changed folder is listed (event spelled /private/..., root /var/...)");

    loader.reloadForChanges({"/fixture-elsewhere/Album"}, false);
    CHECK(waitFinished(*h, 4), "an unmapped folder reloads");
    CHECK_EQ(files.listsOf(loose), 3, "a folder outside the watch set means a full listing");

    loader.reloadForChanges({}, true);
    CHECK(waitFinished(*h, 5), "a rescan reloads");
    CHECK_EQ(files.listsOf(loose), 4, "a rescan means a full listing");

    loader.reload(false);
    CHECK(waitFinished(*h, 6), "a plain reload");
    CHECK_EQ(files.listsOf(loose), 5, "reload() lists in full");

    loader.reload(true);
    CHECK(waitFinished(*h, 7), "a recheck");
    CHECK_EQ(files.listsOf(loose), 6, "reload(true) lists in full");

    loader.remount();
    loader.reloadForChanges({newAlbumDir}, false);
    CHECK(waitFinished(*h, 8), "a batch after a remount");
    CHECK_EQ(files.listsOf(loose), 7, "the first load after a remount lists in full");

    g_context = "incremental-carry-over";
    loader.reloadForChanges({newAlbumDir}, false);
    CHECK(waitFinished(*h, 9), "back to incremental");
    CHECK_EQ(files.listsOf(loose), 7, "incremental again");
    mock::setMode(state, "status", "garbage");
    loader.reloadForChanges({real + "/income/shop/Loose Tracks"}, false);
    CHECK(waitFinished(*h, 10) && h->lastFinished().state == LoaderState::Stale, "the load fails before its members");
    CHECK_EQ(files.listsOf(loose), 7, "nothing listed by the failed load");
    clearMode(state, "status");
    loader.reloadForChanges({newAlbumDir}, false);
    CHECK(waitFinished(*h, 11) && h->lastFinished().state == LoaderState::Ready, "recovers");
    CHECK_EQ(files.listsOf(loose), 8, "the failed load's changed folder is listed by the next load");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus, kStatus, kStatus, kStatus, kVersion, kIncome,
                           kStatus, kStatus, kStatus, kStatus, kStatus}),
          "every trigger is one full status (never --filter); version and income only on reload(true)");
}

static void testUnreadableSidecar() {
    g_context = "unreadable-sidecar";
    clearLog();
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "first load");
    const size_t watchSets = w->count();

    // New Album (a whole-directory root) caught half written by a CLI run.
    CHECK(writeParsePartial(state, "itk_0000000a", root + "/income/dump/Fixture Artist - New Album/.intake.json"),
          "canned partial status");
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "the partial load finishes");
    LoaderStatus st = h->lastFinished();
    CHECK(st.state == LoaderState::Ready && st.partialErrors == 1 && st.roots == 16,
          "ready with the error counted, 16 roots: the unreadable root is kept");
    Published p = h->lastPublished();
    ViewScratch scratch;
    const IntakeRowVisual *kept = p.view ? p.view->visualFor(newAlbum(root), scratch) : nullptr;
    CHECK(kept && kept->icon == IntakeIcon::CircleOpen && kept->bgTint == 0x4A90D938, "its rows keep their tint");
    CHECK(!p.invalidate, "nothing renders differently: no invalidation");
    CHECK(logCount("kept the last record of 1 root(s); retrying in 1 s") == 1, "one Info line");

    CHECK(waitFinished(*h, 3, 5), "one retry about 1 s later");
    CHECK(h->lastFinished().roots == 16 && !h->lastPublished().invalidate, "still kept, still no invalidation");
    CHECK(logCount("already a retry, waiting for the next change") == 1, "the retry meets the error again");
    std::this_thread::sleep_for(std::chrono::milliseconds(1600));
    CHECK_EQ(h->finishedCount(), 3, "and does not retry again");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus}), "calls.log: the load, then one retry");
    CHECK_EQ(w->count(), watchSets, "the watch set did not change");

    g_context = "unreadable-sidecar-recovers";
    // A virtual root's named sidecar: kept by the id in its name.
    CHECK(writeParsePartial(state, "itk_00000016",
                            root + "/income/shop/Loose Tracks/.intake.itk_00000016.json"),
          "canned partial status");
    loader.reload(false);
    CHECK(waitFinished(*h, 4), "another partial load");
    CHECK(h->lastFinished().roots == 16 && !h->lastPublished().invalidate, "the named sidecar's root is kept");
    clearParsePartial(state);  // the write completes before the retry
    CHECK(waitFinished(*h, 5, 5), "the retry");
    st = h->lastFinished();
    CHECK(st.state == LoaderState::Ready && st.partialErrors == 0 && st.roots == 16, "the retry loads it in full");
    CHECK(!h->lastPublished().invalidate, "no invalidation at any step");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus, kStatus, kStatus}),
          "calls.log: one status and one retry each time");
}

static void testShareMountsDuringLoad() {
    g_context = "share-mounts-during-load";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    mock::setMode(state, "status", "slow 1");
    loader.reload(true);
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    // The share mounts while `status` runs; its notification's remount()
    // would queue behind the load.
    h->setMounts({kLocalRoot, MountEntry{root, "//user@host-lan/fixture-share", "smbfs", false}});
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "the load finishes");
    clearMode(state, "status");
    CHECK(!w->resolvedUnder(root) && !w->resolvedUnder(realOf(root)),
          "the folders on the share that just mounted are never examined");
    CHECK(w->count() == 1 && w->last().size() == 3 && w->last()[0] == root + "/income/dump",
          "the stream gets them as the CLI spelled them");
}

static void testWatchSetAfterShutdown() {
    g_context = "watch-set-shutdown";
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    mock::setMode(state, "status", "slow 1");
    loader.reload(true);
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    loader.shutdown();
    loader.reloadForChanges({"/fixture/x"}, true);
    loader.remount();
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    CHECK_EQ(w->count(), 0, "no watch set is handed over after shutdown");
    CHECK_EQ(h->publishCount(), 0, "and nothing is published");
    mock::killLeftovers();
}

// B5: the status carries what the preferences page shows, and every change
// of it reaches onStatusChanged.
static void testStatusForPreferences() {
    g_context = "status-income";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");
    LoaderStatus st = loader.status();
    CHECK(st.incomeOffered && st.incomeFolders.size() == 3, "CLI 0.3.0: income offered, three folders");
    size_t missing = 0;
    for (const IncomeFolder &f : st.incomeFolders) {
        if (!f.exists) {
            missing++;
            CHECK(f.name == "offline" && f.path == root + "/income/offline", "the missing one is offline");
        }
    }
    CHECK_EQ(missing, 1, "one income folder does not exist");
    CHECK(st.rootFolders.size() == 2 && st.rootFolders[0] == root + "/income/dump" &&
              st.rootFolders[1] == root + "/income/shop",
          "the roots' parent folders, sorted, each once");
    {
        std::lock_guard<std::mutex> lock(h->m);
        CHECK(h->statusChanges.size() >= 2 && h->statusChanges.front().state == LoaderState::Loading &&
                  h->statusChanges.back().state == LoaderState::Ready,
              "status changes: loading, then ready");
    }
    const size_t before = h->statusChangeCount();
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload finishes");
    CHECK(h->statusChangeCount() > before, "every load end is reported, even an unchanged one");

    g_context = "status-income-0.2.1";
    std::string old = mock::setupState("cli-0.2.1");
    auto h2 = std::make_shared<Harness>();
    IntakeLoader loader2(settingsFor(old, h2));
    loader2.reload(true);
    CHECK(waitFinished(*h2, 1) && h2->lastFinished().state == LoaderState::Ready, "loads");
    st = loader2.status();
    CHECK(!st.incomeOffered && st.incomeFolders.empty() && st.rootFolders.size() == 2,
          "no income command: no income folders, the roots' folders instead");
}

// B5: reconfigure() starts over with the new CLI settings.
static void testReconfigure() {
    g_context = "reconfigure-empty";
    clearLog();
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");

    CliConfig none = mockCli(state);
    none.cliPath.clear();
    loader.reconfigure(none);
    CHECK(waitFinished(*h, 2), "the reconfigured attempt finishes");
    CHECK(h->lastFinished().state == LoaderState::NotConfigured && loader.status().roots == 0 &&
              loader.status().cliVersion.empty(),
          "no CLI path: not configured, nothing kept");
    Published cleared = h->lastPublished();
    CHECK(cleared.reason == PublishReason::Reconfigured && cleared.invalidate && cleared.view &&
              cleared.view->rendersNothing() && !cleared.view->isInert(),
          "an empty view replaces the tinted one, with invalidate-all");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "nothing is spawned without a CLI path");
    CHECK(logCount("not configured") == 1, "the not-configured line");

    g_context = "reconfigure-back";
    loader.reconfigure(mockCli(state));
    CHECK(waitFinished(*h, 3), "the load with the restored path finishes");
    CHECK(h->lastFinished().state == LoaderState::Ready && loader.status().roots == 16 &&
              loader.status().cliVersion == "0.3.0",
          "ready again");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kVersion, kIncome, kStatus}),
          "a fresh start: version and income again before status");
    Published back = h->lastPublished();
    CHECK(back.reason == PublishReason::Load && back.invalidate, "a first load again: invalidate-all");

    g_context = "reconfigure-rules";
    const size_t publishes = h->publishCount();
    CliConfig rules = mockCli(state);
    rules.rulesDir = state + "/rules-fixture";
    loader.reconfigure(rules);
    CHECK(waitFinished(*h, 4) && h->lastFinished().state == LoaderState::Ready, "a rules folder change reloads");
    std::vector<Published> all = h->publishedCopy();
    CHECK(all.size() == publishes + 2 && all[publishes].reason == PublishReason::Reconfigured &&
              all[publishes].invalidate && all[publishes + 1].reason == PublishReason::Load,
          "forgotten, then loaded: two publishes");

    g_context = "reconfigure-in-flight";
    clearLog();
    mock::setMode(state, "status", "slow 3");
    const size_t finishedBefore = h->finishedCount();
    const size_t publishesBefore = h->publishCount();
    loader.reload(false);
    // Let the slow status start, then change the settings under it.
    CHECK(mock::waitUntil([&] { return calls(state).size() >= 10; }, 10), "the slow status started");
    loader.reconfigure(mockCli(state));
    clearMode(state, "status");
    CHECK(waitFinished(*h, finishedBefore + 1, 20), "the load with the new settings finishes");
    CHECK(h->lastFinished().state == LoaderState::Ready, "ready");
    CHECK_EQ(h->finishedCount(), finishedBefore + 1, "the discarded load reported no finish of its own");
    all = h->publishedCopy();
    CHECK(all.size() == publishesBefore + 2 && all[publishesBefore].reason == PublishReason::Reconfigured &&
              all[publishesBefore + 1].reason == PublishReason::Load,
          "nothing from the old settings was published");
    CHECK(logCount("status: discarded, the CLI settings changed") == 1, "the old status result was discarded");
    std::vector<std::string> got = calls(state);
    CHECK(got.size() >= 3 && got[got.size() - 3] == kVersion && got[got.size() - 2] == kIncome &&
              got.back() == kStatus,
          "then version, income and status with the new settings");
    loader.shutdown();
    mock::killLeftovers();
}

// B5: setWatchFolders() replaces the watch_folders setting: a new watch set,
// no reload.
static void testSetWatchFolders() {
    g_context = "set-watch-folders";
    std::string state = mock::setupState("default");
    const std::string real = realOf(state + "/root");
    const std::string extra = mock::newDir("extra-watch");
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && w->count() == 1 && w->last().size() == 3, "first load: three folders");

    loader.setWatchFolders({extra});
    CHECK(mock::waitUntil([&] { return w->count() == 2; }, 10), "a new watch set is handed over");
    std::vector<std::string> set = w->last();
    CHECK(set.size() == 4 && std::find(set.begin(), set.end(), realOf(extra)) != set.end(),
          "the configured folder joins the income folders (resolved)");

    // The extra folder leaves; an income folder that is watched anyway takes
    // its place: back to the three income folders, handed over once.
    loader.setWatchFolders({real + "/income/dump"});
    CHECK(mock::waitUntil([&] { return w->count() == 3; }, 10), "removing it hands over a set again");
    CHECK(w->last().size() == 3, "back to the three income folders");
    // Same stream paths: nothing is handed over.
    loader.setWatchFolders({});
    mock::waitUntil([] { return false; }, 0.5);
    CHECK_EQ(w->count(), 3, "an unchanged set is not handed over");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "no CLI call for a watch folder change");
    CHECK_EQ(h->finishedCount(), 1, "and no load");
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
        testIncomeAndWatchSet();
        testIncomeNotOffered();
        testNetworkWatchSet();
        testChangeCoalescing();
        testIncrementalMembers();
        testUnreadableSidecar();
        testShareMountsDuringLoad();
        testWatchSetAfterShutdown();
        testStatusForPreferences();
        testReconfigure();
        testSetWatchFolders();

        setLogBackend(nullptr);
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
