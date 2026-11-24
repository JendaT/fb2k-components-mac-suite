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
//  share that mounted during the load is never resolved. B5 review fixes:
//  reload()'s `served` handler runs after the load serving the request (not
//  the one already running; handed on past a load discarded by reconfigure;
//  never after shutdown), a failed `income` call is named in the status,
//  and no CLI path means an empty watch set. Watch event ids: the id is
//  taken just before each `status` call and handed over with the watch
//  set; restartWatch() uses the reload's id once its `status` started, and
//  "from now" while it has not, and never runs a `status` itself.
//  B9: the library index in every published view (placed, verified roots
//  only; their sidecars read once and reused while root and target stay
//  the same), setLibraryPrefix republishing without invalidation, and the
//  placed-unverified scenario and a gc_done root leaving it empty.
//  B10: setPalette() rebuilding the last load in the new colours (rows,
//  icons and badges; invalidate-all only when something changes and the
//  view is not inert: an inert view and a colour no root renders publish
//  without one; no CLI call) and reaching later loads.
//  B11: share links (setShareLinks publishing and invalidating, an
//  unchanged link publishing nothing, a re-point through relink() and
//  through the next load's start, batches staying incremental, links
//  configured at start matching from the first load, a root spelled
//  through a link moving its key and so listing in full once), and with
//  no links configured the mount table read for the aliases only by the
//  first load and remount(), as before.
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
// TEST_DEPS: src/Core/IntakeGroupBadge.mm src/Core/IntakeRootErrors.mm
// TEST_DEPS: src/Core/IntakeLibraryIndex.mm src/Core/IntakeSwapPlanner.mm
// TEST_DEPS: src/Core/IntakeTargetPath.mm
// TEST_DEPS: src/Core/IntakeFields.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLoader.h"
#include "../src/Core/IntakeLog.h"
#include "../src/Core/IntakeRootErrors.h"
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
    std::vector<WatchHandover> handovers;        // the same calls in full
    std::vector<std::string> resolved;           // every path the link reader examined

    size_t count() {
        std::lock_guard<std::mutex> lock(m);
        return sets.size();
    }
    std::vector<std::string> last() {
        std::lock_guard<std::mutex> lock(m);
        return sets.empty() ? std::vector<std::string>() : sets.back();
    }
    WatchHandover lastHandover() {
        std::lock_guard<std::mutex> lock(m);
        return handovers.empty() ? WatchHandover() : handovers.back();
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
    s.onWatchSet = [w](const WatchHandover &handover) {
        std::lock_guard<std::mutex> lock(w->m);
        w->sets.push_back(handover.paths);
        w->handovers.push_back(handover);
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

// --- B11: share links ---

// A mock state at its physical path: a link's target is resolved
// physically (/var -> /private/var), the CLI's root paths only lexically,
// so the roots must be spelled the way the link resolves.
std::string physicalState(const std::string &scenario = "default") {
    const std::string dir = realOf(mock::newDir("state"));
    if (dir.empty()) return dir;
    return mock::runSync({mock::mockPath(), "--mock-setup", scenario}, mock::mockEnv(dir)) == 0 ? dir : std::string();
}

// `link` (re)created as a symlink to `target` (ln -sfn).
bool pointLink(const std::string &link, const std::string &target) {
    unlink(link.c_str());
    return symlink(target.c_str(), link.c_str()) == 0;
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
    CHECK(single && single->bgTint == 0xE5A50A38 && single->tooltip == "Intake: Resolved \xC2\xB7 needs review\nTarget: Test Collection A \xC2\xB7 slot "
                                                                 "pending\nAssigned by the engine (confidence 0.64)",
          "the single: amber, needs review and slot pending");
    const IntakeRowVisual *member =
        first.view->visualFor(root + "/income/shop/Loose Tracks/Fixture Artist C - Other Two.wav", scratch);
    CHECK(member && member->icon == IntakeIcon::CircleOpen && member->tooltip == "Intake: Resolved\nNo target yet: Propose (or Assign to a collection first)",
          "a virtual root's member (resolved, no review, no proposal)");
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
    CHECK(amber && amber->bgTint == 0xE5A50A38 && amber->tooltip == "Intake: Resolved \xC2\xB7 needs review\nNo target yet: Propose (or Assign to a collection first)",
          "the row is amber now");

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
    CHECK(memberViaAlias && memberViaAlias->tooltip == "Intake: New \xC2\xB7 needs review",
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

    // B11: with no share links configured, neither relink() nor a load's
    // start reads the mount table for the aliases: a mount whose
    // notification has not come yet is mapped by remount() only, as before
    // share links existed.
    g_context = "mount-no-links";
    count = h->publishCount();
    h->setMounts({lan, vpn});
    loader.relink();
    CHECK(!mock::waitUntil([&] { return h->publishCount() > count; }, 0.5), "relink() reads nothing with no links");
    loader.reload(false);
    CHECK(waitFinished(*h, 3), "a reload after the mount table changed");
    CHECK(h->publishCount() == count + 1 && h->lastPublished().reason == PublishReason::Load,
          "its start publishes no remount: only the load");
    CHECK(h->lastPublished().view && h->lastPublished().view->aliases().aliasCount() == 1,
          "the load keeps the table remount() read");
    loader.remount();
    CHECK(mock::waitUntil([&] { return h->publishCount() > count + 1; }, 10), "remount() publishes");
    CHECK(h->lastPublished().reason == PublishReason::Remount && h->lastPublished().view &&
              h->lastPublished().view->aliases().aliasCount() == 2,
          "and maps the new mount");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus}), "one status for the reload, none else");
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
    {
        const LoaderStatus st = loader.status();
        CHECK(st.incomeOffered && st.incomeFolders.size() == 3 && !st.incomeError.empty(),
              "the status keeps the last good folders and names the failure");
    }
    clearMode(state, "income");

    g_context = "income-folder-removed";
    // A configured income folder disappears from income.yaml: the watch set
    // follows on the next income call (reload(true)).
    CHECK(replaceInFile(state + "/responses/income", "offline\tincome/offline\n", ""), "offline removed");
    loader.reload(true);
    CHECK(waitFinished(*h, 4), "a recheck finishes");
    CHECK(w->count() == 2 && w->last().size() == 2, "the changed set is handed over: dump and shop");
    CHECK(loader.status().incomeError.empty(), "a good income call clears the failure");

    g_context = "income-first-call-fails";
    // The very first income call fails: no good list exists, and the status
    // says so instead of looking like an empty answer.
    std::string fresh = mock::setupState("default");
    mock::setMode(fresh, "income", "exit2");
    auto h2 = std::make_shared<Harness>();
    IntakeLoader loader2(settingsFor(fresh, h2));
    loader2.reload(true);
    CHECK(waitFinished(*h2, 1) && h2->lastFinished().state == LoaderState::Ready, "the load is Ready");
    const LoaderStatus st2 = loader2.status();
    CHECK(st2.incomeOffered && st2.incomeFolders.empty() && !st2.incomeError.empty(),
          "offered, no folders, the failure named");
    CHECK(incomeDisplay(st2).note.find("could not list the income folders") != std::string::npos,
          "the page names the failure");
}

// The income-folder root guard: a root at an income folder itself is left
// out of the load while `income` answers, and back when it fails.
static void testIncomeFolderGuard() {
    g_context = "income-folder-guard";
    clearLog();
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    CHECK(mock::writeFile(state + "/responses/status.d/itk_000000ff.json",
                          "{\"id\":\"itk_000000ff\",\"root_path\":\"" + root +
                              "/income/dump\",\"status\":\"resolved\",\"needs_review\":false,\"cluster\":"
                              "{\"albumartist\":null,\"album\":null},\"proposal\":null,\"placed\":null}\n"),
          "a root at the income folder itself");
    auto h = std::make_shared<Harness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(settingsFor(state, h));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");
    Published first = h->lastPublished();
    ViewScratch scratch;
    CHECK(first.view && first.view->snapshot().size() == 16 &&
              first.view->snapshot().recordForId("itk_000000ff") == nullptr,
          "the income-folder root is not in the view");
    CHECK(first.view && first.view->recordFor(root + "/income/dump/Stray Track.wav", scratch) == nullptr,
          "a stray row at the folder's top level maps to nothing");
    CHECK(first.view && first.view->visualFor(newAlbum(root), scratch) != nullptr, "a root inside it still decorates");
    CHECK_EQ(logCount("root itk_000000ff is the income folder dump itself; ignored (loose files at its top level)"), 1,
             "one Info line");
    loader.reload(true);
    CHECK(waitFinished(*h, 2), "a recheck finishes");
    CHECK_EQ(logCount("root itk_000000ff is the income folder dump itself"), 1, "once per session");

    g_context = "income-folder-guard-off";
    mock::setMode(state, "income", "exit2");
    loader.reload(true);
    CHECK(waitFinished(*h, 3), "a recheck with a failing income finishes");
    Published unguarded = h->lastPublished();
    CHECK(unguarded.view && unguarded.view->snapshot().recordForId("itk_000000ff") != nullptr,
          "income failed: no guard, the root is back");
    clearMode(state, "income");
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

    g_context = "set-watch-folders-no-cli";
    // B5 review: clearing the CLI path stops watching the last load's
    // folders (nothing could reload); a watch_folders change made then keeps
    // the set empty, and restoring the path brings the folders back.
    loader.setWatchFolders({extra});
    CHECK(mock::waitUntil([&] { return w->count() == 4; }, 10), "the extra folder is watched");
    CliConfig none = mockCli(state);
    none.cliPath.clear();
    loader.reconfigure(none);
    CHECK(waitFinished(*h, 2) && h->lastFinished().state == LoaderState::NotConfigured, "not configured");
    CHECK(w->count() == 5 && w->last().empty(), "the watch set empties");
    loader.setWatchFolders({real + "/income/dump"});
    mock::waitUntil([] { return false; }, 0.5);
    CHECK(w->count() == 5, "a watch folder change with no CLI path hands over nothing");
    loader.reconfigure(mockCli(state));
    CHECK(waitFinished(*h, 3) && h->lastFinished().state == LoaderState::Ready, "ready again");
    CHECK(w->count() == 6 && w->last().size() == 3, "the income folders are watched again");
}

// B5 review: reload()'s `served` handler runs when the load serving the
// request ends, not when an earlier one does.
struct Served {
    std::mutex m;
    std::vector<LoaderStatus> statuses;
    std::vector<size_t> finishedAt;  // the harness's finished count when it ran

    LoadFinishedHandler handler(const std::shared_ptr<Harness> &h, const std::shared_ptr<Served> &self) {
        return [h, self](const LoaderStatus &status) {
            const size_t finished = h->finishedCount();
            std::lock_guard<std::mutex> lock(self->m);
            self->statuses.push_back(status);
            self->finishedAt.push_back(finished);
        };
    }
    size_t count() {
        std::lock_guard<std::mutex> lock(m);
        return statuses.size();
    }
};

static void testReloadServed() {
    g_context = "reload-served-idle";
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    auto a = std::make_shared<Served>();
    loader.reload(true, a->handler(h, a));
    CHECK(mock::waitUntil([&] { return a->count() == 1; }, 20), "served once");
    {
        std::lock_guard<std::mutex> lock(a->m);
        CHECK(a->statuses[0].state == LoaderState::Ready && a->finishedAt[0] == 1,
              "after the load it started, with its status");
    }

    g_context = "reload-served-running";
    mock::setMode(state, "status", "slow 1");
    loader.reload(false);
    CHECK(mock::waitUntil([&] { return calls(state).size() >= 4; }, 10), "the slow status started");
    auto b = std::make_shared<Served>();
    loader.reload(false, b->handler(h, b));
    CHECK(waitFinished(*h, 3), "the running load and one more finish");
    CHECK(mock::waitUntil([&] { return b->count() == 1; }, 10), "served once");
    {
        std::lock_guard<std::mutex> lock(b->m);
        CHECK(b->finishedAt[0] == 3, "by the load after the running one, not by the running one");
    }

    g_context = "reload-served-reconfigure";
    const size_t before = h->finishedCount();
    auto c = std::make_shared<Served>();
    mock::setMode(state, "status", "slow 3");
    loader.reload(false, c->handler(h, c));
    CHECK(mock::waitUntil([&] { return calls(state).size() >= 6; }, 10), "the slow status started");
    loader.reconfigure(mockCli(state));
    clearMode(state, "status");
    CHECK(waitFinished(*h, before + 1, 20), "the load with the new settings finishes");
    CHECK(mock::waitUntil([&] { return c->count() == 1; }, 10), "served once");
    {
        std::lock_guard<std::mutex> lock(c->m);
        CHECK(c->finishedAt[0] == before + 1 && c->statuses[0].state == LoaderState::Ready,
              "a discarded load hands the request on to the load with the new settings");
    }

    g_context = "reload-served-shutdown";
    auto d = std::make_shared<Served>();
    mock::setMode(state, "status", "slow 3");
    loader.reload(false, d->handler(h, d));
    CHECK(mock::waitUntil([&] { return calls(state).size() >= 10; }, 10), "the slow status started");
    loader.shutdown();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK_EQ(d->count(), 0, "never served after shutdown");
    clearMode(state, "status");
    mock::killLeftovers();

    g_context = "reload-served-not-configured";
    std::string none = mock::setupState("default");
    auto h2 = std::make_shared<Harness>();
    LoaderSettings s2 = settingsFor(none, h2);
    s2.cli.cliPath.clear();
    IntakeLoader loader2(std::move(s2));
    auto e = std::make_shared<Served>();
    loader2.reload(true, e->handler(h2, e));
    CHECK(mock::waitUntil([&] { return e->count() == 1; }, 10), "served once");
    {
        std::lock_guard<std::mutex> lock(e->m);
        CHECK(e->statuses[0].state == LoaderState::NotConfigured, "with the not-configured status");
    }
}

// The watch event ids (IntakeWatcher replays from them): taken just before
// each `status` call, handed over with the watch set; restartWatch() after a
// mount event uses the reload's id once its `status` started, else "now".
struct EventIds {
    std::mutex m;
    WatchEventId next = 1000;
    std::vector<size_t> callsAt;  // calls.log entries when each id was taken
};

static void testWatchEventIds() {
    g_context = "watch-event-ids";
    std::string state = mock::setupState("default");
    const std::string extra = mock::newDir("extra-ids");
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    auto ids = std::make_shared<EventIds>();
    h->setMounts({kLocalRoot});
    LoaderSettings s = watchSettingsFor(state, h, w);
    s.currentEventId = [ids, state] {
        std::lock_guard<std::mutex> lock(ids->m);
        ids->callsAt.push_back(calls(state).size());
        return ids->next++;
    };
    IntakeLoader loader(std::move(s));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "version, income, status");
    {
        std::lock_guard<std::mutex> lock(ids->m);
        CHECK(ids->callsAt.size() == 1 && ids->callsAt[0] == 2,
              "one id, taken after version and income and before status ran");
    }
    WatchHandover first = w->lastHandover();
    CHECK(w->count() == 1 && first.paths.size() == 3 && first.sinceEventId == 1000 && !first.restart,
          "the watch set goes over with that id");

    g_context = "watch-event-ids-reload";
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload");
    CHECK_EQ(w->count(), 1, "an unchanged set is not handed over (its new id 1001 is kept)");
    loader.setWatchFolders({extra});
    CHECK(mock::waitUntil([&] { return w->count() == 2; }, 10), "a new set");
    CHECK(w->lastHandover().sinceEventId == 1001 && w->lastHandover().paths.size() == 4,
          "a set changed between loads goes over with the latest status call's id");

    g_context = "watch-event-ids-restart-idle";
    // IntakeService on a mount event: remount, reload(false), restartWatch.
    loader.remount();
    loader.reload(false);
    loader.restartWatch();
    CHECK(waitFinished(*h, 3), "the reload finishes");
    CHECK(mock::waitUntil([&] { return w->count() == 3; }, 10), "the restart is handed over");
    WatchHandover restart = w->lastHandover();
    CHECK(restart.restart && restart.paths == w->last() && restart.paths.size() == 4 && restart.sinceEventId == 1002,
          "idle loader: the reload's status already started, so its id (1002)");
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus}), "the restart ran no status of its own");
    CHECK(w->count() == 3 && h->finishedCount() == 3, "and nothing else");

    g_context = "watch-event-ids-restart-busy";
    mock::setMode(state, "status", "slow 1");
    loader.reload(false);
    CHECK(mock::waitUntil([&] { return calls(state).size() >= 6; }, 10), "a slow status runs (id 1003)");
    loader.remount();
    loader.reload(false);  // queued behind the running load
    loader.restartWatch();
    CHECK(mock::waitUntil([&] { return w->count() == 4; }, 10), "the restart is handed over at once");
    restart = w->lastHandover();
    CHECK(restart.restart && restart.sinceEventId == kWatchSinceNow,
          "the reload's status has not started yet: from now (that status follows)");
    clearMode(state, "status");
    CHECK(waitFinished(*h, 5), "the running load and the reload finish");
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus, kStatus, kStatus}),
          "one status each; none for the restart");
    CHECK_EQ(w->count(), 4, "nothing more handed over");

    g_context = "watch-event-ids-none";
    // No reader (the default): every stream starts from now.
    std::string plain = mock::setupState("default");
    auto h2 = std::make_shared<Harness>();
    auto w2 = std::make_shared<WatchHarness>();
    h2->setMounts({kLocalRoot});
    IntakeLoader loader2(watchSettingsFor(plain, h2, w2));
    loader2.reload(true);
    CHECK(waitFinished(*h2, 1) && w2->count() == 1 && w2->lastHandover().sinceEventId == kWatchSinceNow,
          "without currentEventId the set goes over \"from now\"");
    loader2.restartWatch();
    CHECK(mock::waitUntil([&] { return w2->count() == 2; }, 10) && w2->lastHandover().restart &&
              w2->lastHandover().sinceEventId == kWatchSinceNow,
          "and so does a restart");

    g_context = "watch-event-ids-restart-before-set";
    std::string early = mock::setupState("default");
    auto h3 = std::make_shared<Harness>();
    auto w3 = std::make_shared<WatchHarness>();
    h3->setMounts({kLocalRoot});
    IntakeLoader loader3(watchSettingsFor(early, h3, w3));
    loader3.restartWatch();
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    CHECK_EQ(w3->count(), 0, "no restart before a watch set was handed over");
    CHECK(callsAre(early, {}), "and no CLI call");
}

// B6: the annotator puts per-root command errors into the records before
// the snapshot is built (tooltip and invalidation), errors leave when the
// status changes, badges are in the published view, and the status carries
// the CLI's features.
static void testAnnotateAndBadges() {
    g_context = "annotate";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    const std::string resolvedRow = root + "/income/dump/Fixture Artist - Resolved Album/01 - Track.wav";
    const std::string proposedRow = root + "/income/dump/Fixture Artist - Proposed Album/01 - Track.wav";
    const std::string closeRow = root + "/income/dump/Fixture Artist - Close Call/01 - Track.wav";
    const std::string userRow = root + "/income/dump/Fixture Artist - Overridden Album/01 - Track.wav";
    auto h = std::make_shared<Harness>();
    auto store = std::make_shared<RootErrorStore>();
    LoaderSettings settings = settingsFor(state, h);
    settings.annotateRecords = [store](std::vector<IntakeRecord> &records,
                                       std::chrono::steady_clock::time_point started) { store->apply(records, started); };
    IntakeLoader loader(std::move(settings));
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "first load");
    LoaderStatus st = h->lastFinished();
    CHECK(st.cliInfo.cli == "0.3.0" && st.cliInfo.hasCommands, "the status carries cli and commands");
    CHECK(cliSupportsCommand(st.cliInfo, CliCommand::Reject), "reject detected from commands[]");

    ViewScratch scratch;
    std::shared_ptr<const IntakeView> view = h->lastPublished().view;
    const IntakeRecord *proposed = view ? view->recordFor(proposedRow, scratch) : nullptr;
    CHECK(proposed && proposed->badge.text == "\xE2\x86\x92 Test Collection A \xC2\xB7 0.91" && !proposed->badge.amber,
          "badge of the engine proposal");
    const IntakeRecord *close = view ? view->recordFor(closeRow, scratch) : nullptr;
    CHECK(close && close->badge.amber &&
              close->badge.text ==
                  "\xE2\x86\x92 Test Collection B \xC2\xB7 0.61 (alt: Test Collection A)",
          "the close call: amber with the alt hint");
    const IntakeRecord *user = view ? view->recordFor(userRow, scratch) : nullptr;
    CHECK(user && user->badge.text ==
                      "\xE2\x86\x92 Test & Ambient \xC2\xB7 yours (alt: Test Collection C)",
          "the user override: yours, amber (needs_review kept)");

    store->set("itk_0000000b", "propose: No target collection");
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "reload after an error");
    Published withError = h->lastPublished();
    CHECK(withError.invalidate, "a new per-root error invalidates");
    const IntakeRowVisual *errorVisual = withError.view ? withError.view->visualFor(resolvedRow, scratch) : nullptr;
    CHECK(errorVisual && errorVisual->tooltip == "Intake: Resolved\nNo target yet: Propose (or Assign to a collection first)\npropose: No target collection",
          "the error is the tooltip's last line");

    loader.reload(false);
    CHECK(waitFinished(*h, 3), "reload, same status");
    CHECK(!h->lastPublished().invalidate, "the error stays, nothing changed");

    CHECK(replaceInFile(state + "/responses/status.d/itk_0000000b.json", "\"status\":\"resolved\"",
                        "\"status\":\"proposed\""),
          "fixture edited");
    loader.reload(false);
    CHECK(waitFinished(*h, 4), "reload after the status change");
    Published moved = h->lastPublished();
    const IntakeRowVisual *movedVisual = moved.view ? moved.view->visualFor(resolvedRow, scratch) : nullptr;
    CHECK(moved.invalidate && movedVisual && movedVisual->tooltip == "Intake: Proposed" && store->size() == 0,
          "the status changed: the error is gone");
}

// B9: counts readFile per path; answers through the POSIX access.
class ReadCountingAccess : public SidecarFileAccess {
public:
    bool listDirectory(const std::string &directory, std::vector<std::string> &names, int &error) override {
        return posixSidecarFileAccess().listDirectory(directory, names, error);
    }
    bool readFile(const std::string &path, std::string &contents, int &error) override {
        {
            std::lock_guard<std::mutex> lock(m);
            reads[path]++;
        }
        return posixSidecarFileAccess().readFile(path, contents, error);
    }
    int readsOf(const std::string &path) {
        std::lock_guard<std::mutex> lock(m);
        return reads[path];
    }

private:
    std::mutex m;
    std::map<std::string, int> reads;
};

static void testLibraryIndex() {
    g_context = "library-index";
    std::string state = mock::setupState("default");
    const std::string root = state + "/root";
    const std::string placedDir = root + "/income/dump/Fixture Artist - Placed Album";
    const std::string library = root + "/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Placed Album";
    const std::string collected =
        root + "/library/music.hq/Test Collection C/Fixture Artist/Fixture Artist - 2026 - Collected Album/01 - Test Track One.wav";
    auto h = std::make_shared<Harness>();
    ReadCountingAccess files;
    LoaderSettings settings = settingsFor(state, h);
    settings.files = &files;
    IntakeLoader loader(std::move(settings));
    loader.reload(true);
    CHECK(waitFinished(*h, 1), "first load");
    std::shared_ptr<const IntakeView> view = h->lastPublished().view;
    CHECK(view && view->library().rootCount() == 1 && view->library().size() == 2,
          "the placed, verified root's two files; gc_done and other roots absent");
    ViewScratch scratch;
    const IntakeRecord *swapped = view ? view->libraryRecordFor(library + "/01 - Test Track One.wav", scratch) : nullptr;
    CHECK(swapped && swapped->id == "itk_00000012", "a row on the library copy maps to itk_00000012");
    CHECK(view && view->libraryRecordFor(collected, scratch) == nullptr, "the gc_done root's library copy maps to nothing");
    CHECK(view && view->visualFor(library + "/01 - Test Track One.wav", scratch) == nullptr,
          "library rows decorate nothing");
    CHECK(files.readsOf(placedDir + "/.intake.itk_00000012.json") == 1 && files.readsOf(placedDir + "/.intake.json") == 1,
          "the placed root's sidecar: the named one tried, then .intake.json, once");

    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload");
    CHECK(files.readsOf(placedDir + "/.intake.json") == 1, "the files of an unchanged placed root are reused");
    CHECK(h->lastPublished().view->library().size() == 2, "still in the new view");

    // A new pair: the index is rebuilt and the same view republished,
    // without invalidation and without I/O.
    const size_t before = h->publishCount();
    loader.setLibraryPrefix(makeLibraryPrefix(root + "/library", "/Volumes/fixture-lib"));
    CHECK(mock::waitUntil([&h, before] { return h->publishCount() > before; }, 10), "the pair change publishes");
    Published repub = h->lastPublished();
    CHECK(repub.reason == PublishReason::Library && !repub.invalidate, "reason Library, no invalidation");
    const IntakeRecord *mapped = repub.view ? repub.view->libraryRecordFor(
                                                  "/Volumes/fixture-lib/music.hq/Test Collection A/Fixture Artist/"
                                                  "Fixture Artist - 2026 - Placed Album/02 - Test Track Two.wav",
                                                  scratch)
                                            : nullptr;
    CHECK(mapped && mapped->id == "itk_00000012", "the library path after the pair maps to the root");
    CHECK(repub.view && repub.view->libraryRecordFor(library + "/01 - Test Track One.wav", scratch) == nullptr,
          "the unmapped spelling no longer does");
    CHECK(files.readsOf(placedDir + "/.intake.json") == 1, "no sidecar read for a pair change");
    loader.setLibraryPrefix(makeLibraryPrefix(root + "/library", "/Volumes/fixture-lib"));
    loader.reload(false);
    CHECK(waitFinished(*h, 3), "a reload after the same pair again");
    CHECK(h->publishCount() == before + 2 && h->lastPublished().reason == PublishReason::Load,
          "the same pair again publishes nothing of its own");

    // The root is gc_done now: out of the index.
    CHECK(replaceInFile(state + "/responses/status.d/itk_00000012.json", "\"status\":\"placed\"", "\"status\":\"gc_done\""),
          "fixture edited");
    loader.reload(false);
    CHECK(waitFinished(*h, 4), "the reload after gc");
    CHECK(h->lastPublished().view->library().isEmpty(), "a gc_done root leaves the index");

    // The placed-unverified scenario: placed, but not verified.
    std::string unverified = mock::setupState("placed-unverified");
    auto h2 = std::make_shared<Harness>();
    IntakeLoader loader2(settingsFor(unverified, h2));
    loader2.reload(true);
    CHECK(waitFinished(*h2, 1), "first load (placed-unverified)");
    std::shared_ptr<const IntakeView> v2 = h2->lastPublished().view;
    const IntakeRecord *r2 = v2 ? v2->snapshot().recordForId("itk_00000012") : nullptr;
    CHECK(r2 && r2->status == IntakeStatus::Placed && r2->hasPlaced && !r2->placedVerified,
          "the scenario: itk_00000012 placed with placed.verified false");
    CHECK(v2 && v2->library().isEmpty() &&
              v2->libraryRecordFor(unverified + "/root/library/music.hq/Test Collection A/Fixture Artist/Fixture "
                                                "Artist - 2026 - Placed Album/01 - Test Track One.wav",
                                   scratch) == nullptr,
          "no library index entry without placed.verified");
}

// B10: setPalette() rebuilds the last load in the new colours: one publish,
// invalidate-all only when a row or badge changes and the view is not
// inert (checked both ways: a colour no root renders publishes without
// one), no CLI call; a palette set earlier reaches the first load.
static void testPalette() {
    g_context = "palette-before-load";
    clearLog();
    std::string state = mock::setupState("default");
    auto h = std::make_shared<Harness>();
    IntakeLoader loader(settingsFor(state, h));
    IntakePalette magenta;
    magenta.tintPlaced = 0xFF00FFFF;
    loader.setPalette(magenta);
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load");
    CHECK(h->publishCount() == 1 && h->lastPublished().reason == PublishReason::Load,
          "nothing loaded yet: no publish of its own");
    const IntakeRecord *placed = h->lastPublished().view->snapshot().recordForId("itk_00000012");
    CHECK(placed && placed->visual.bgTint == 0xFF00FFFF && placed->visual.iconColor == 0,
          "the first load uses the palette set before it (opaque: the icon in the label colour)");

    g_context = "palette-off";
    IntakePalette off = magenta;
    off.tintPlaced = 0;
    size_t before = h->publishCount();
    loader.setPalette(off);
    CHECK(mock::waitUntil([&h, before] { return h->publishCount() > before; }, 10), "a palette change publishes");
    Published p = h->lastPublished();
    CHECK(p.reason == PublishReason::Palette && p.invalidate && p.view && !p.view->isInert(),
          "reason Palette, one invalidate-all");
    placed = p.view ? p.view->snapshot().recordForId("itk_00000012") : nullptr;
    CHECK(placed && placed->visual.bgTint == 0 && placed->visual.iconColor == 0 &&
              placed->visual.icon == IntakeIcon::CircleFilled,
          "tint 0: no background, the host's icon colour, the icon kept");
    const IntakeRecord *fresh = p.view ? p.view->snapshot().recordForId("itk_0000000a") : nullptr;
    CHECK(fresh && fresh->visual.bgTint == 0x4A90D938, "the other statuses keep their colours");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "no CLI call for a colour change");
    CHECK(logCount("row colours changed: rows rebuilt, invalidate-all") == 1, "one Debug line");

    loader.setPalette(off);
    loader.reload(false);
    CHECK(waitFinished(*h, 2), "a reload");
    CHECK(h->publishCount() == before + 2 && h->lastPublished().reason == PublishReason::Load &&
              !h->lastPublished().invalidate,
          "the same palette again publishes nothing; the reload in it changes no row");

    g_context = "palette-review";
    IntakePalette review = off;
    review.tintReview = 0x11223344;
    before = h->publishCount();
    loader.setPalette(review);
    CHECK(mock::waitUntil([&h, before] { return h->publishCount() > before; }, 10), "published");
    p = h->lastPublished();
    const IntakeRecord *overridden = p.view ? p.view->snapshot().recordForId("itk_0000000f") : nullptr;
    CHECK(overridden && overridden->visual.bgTint == 0x11223344 && overridden->visual.iconColor == 0x112233FF &&
              overridden->badge.amber && overridden->badge.color == 0x112233FF,
          "the review tint reaches the amber row, its icon and its group badge");

    g_context = "palette-inert";
    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "schema2"}, mock::mockEnv(state)) == 0, "schema2 set up");
    loader.reload(true);
    CHECK(waitFinished(*h, 3) && h->lastFinished().state == LoaderState::Inert, "the gate fails: inert");
    before = h->publishCount();
    IntakePalette inertColours = review;
    inertColours.tintPlaced = 0x00FF00FF;
    loader.setPalette(inertColours);
    CHECK(mock::waitUntil([&h, before] { return h->publishCount() > before; }, 10), "published while inert");
    p = h->lastPublished();
    CHECK(p.reason == PublishReason::Palette && !p.invalidate && p.view && p.view->isInert(),
          "still inert, rows show no tints: no invalidation");
    CHECK(mock::runSync({mock::mockPath(), "--mock-setup", "default"}, mock::mockEnv(state)) == 0, "default again");
    loader.reload(false);
    CHECK(waitFinished(*h, 4) && h->lastFinished().state == LoaderState::Ready, "the gate passes again");
    placed = h->lastPublished().view->snapshot().recordForId("itk_00000012");
    CHECK(placed && placed->visual.bgTint == 0x00FF00FF && h->lastPublished().invalidate,
          "back from inert in the colours set meanwhile");

    g_context = "palette-unloaded";
    CliConfig none = mockCli(state);
    none.cliPath.clear();
    loader.reconfigure(none);
    CHECK(waitFinished(*h, 5) && h->lastFinished().state == LoaderState::NotConfigured, "not configured");
    before = h->publishCount();
    loader.setPalette(IntakePalette());
    loader.reconfigure(mockCli(state));
    CHECK(waitFinished(*h, 6) && h->lastFinished().state == LoaderState::Ready, "loaded again");
    std::vector<Published> all = h->publishedCopy();
    CHECK(all.size() == before + 2 && all[before].reason == PublishReason::Reconfigured &&
              all[before + 1].reason == PublishReason::Load,
          "with nothing loaded the palette change publishes nothing");
    placed = all.back().view->snapshot().recordForId("itk_00000012");
    CHECK(placed && placed->visual.bgTint == IntakePalette().tintPlaced, "the next load uses it");
    loader.shutdown();

    // A colour no root renders: placed-unverified has no verified placed
    // root (its one placed root is unverified, the gc_done root shows
    // nothing), so tint_placed changes no row and no badge. The view is
    // republished in the new palette without an invalidate-all.
    g_context = "palette-unused";
    clearLog();
    std::string unverified = mock::setupState("placed-unverified");
    auto h2 = std::make_shared<Harness>();
    IntakeLoader loader2(settingsFor(unverified, h2));
    loader2.reload(true);
    CHECK(waitFinished(*h2, 1) && h2->lastFinished().state == LoaderState::Ready, "first load (placed-unverified)");
    const IntakeRecord *unverifiedPlaced = h2->lastPublished().view->snapshot().recordForId("itk_00000012");
    CHECK(unverifiedPlaced && unverifiedPlaced->status == IntakeStatus::Placed && !unverifiedPlaced->placedVerified &&
              unverifiedPlaced->visual.bgTint == 0,
          "the scenario: the placed root is unverified and untinted");
    before = h2->publishCount();
    IntakePalette unused;
    unused.tintPlaced = 0xFF00FFFF;
    loader2.setPalette(unused);
    CHECK(mock::waitUntil([&h2, before] { return h2->publishCount() > before; }, 10), "an unused colour publishes");
    // Let a stray second publish show up before counting.
    CHECK(!mock::waitUntil([&h2, before] { return h2->publishCount() > before + 1; }, 0.5), "exactly one publish");
    p = h2->lastPublished();
    CHECK(h2->publishCount() == before + 1 && p.reason == PublishReason::Palette && !p.invalidate && p.view &&
              !p.view->isInert(),
          "reason Palette, not inert, no invalidate-all: no root uses the colour");
    unverifiedPlaced = p.view ? p.view->snapshot().recordForId("itk_00000012") : nullptr;
    CHECK(unverifiedPlaced && unverifiedPlaced->visual.bgTint == 0 && unverifiedPlaced->visual.iconColor == 0,
          "the unverified placed root stays untinted");
    CHECK(callsAre(unverified, {kVersion, kIncome, kStatus}), "no CLI call for an unused colour");
    CHECK(logCount("row colours changed: no root uses them, no invalidation") == 1, "one Debug line");
    loader2.shutdown();
    mock::killLeftovers();
}

// B11: share links. Link-form rows (file://<link>/<rel>, the link spelled
// through /var, a symlink to the mock's root) match once setShareLinks()
// names the link: one Remount publish with invalidate-all and no CLI call.
// An unchanged link publishes nothing; a re-point (picked up by relink()
// or, with no call at all, by the next load's start) invalidates; neither
// a link change nor a re-point makes the next FSEvents batch list every
// member folder. Links configured at start match from the first load.
static void testShareLinks() {
    g_context = "share-links-set";
    clearLog();
    const std::string state = physicalState();
    CHECK(!state.empty(), "physical mock state set up");
    const std::string root = state + "/root";
    const std::string loose = root + "/income/shop/Loose Tracks";
    const std::string newAlbumDir = root + "/income/dump/Fixture Artist - New Album";
    const std::string linkDir = mock::newDir("links");  // NSTemporaryDirectory: spelled through /var
    const std::string link = linkDir + "/music-link";
    const std::string empty = mock::newDir("empty");
    CHECK(pointLink(link, root), "link -> the mock's root");
    const std::string linkRow = "file://" + newAlbum(link);
    CountingAccess files;
    auto h = std::make_shared<Harness>();
    auto w = std::make_shared<WatchHarness>();
    h->setMounts({kLocalRoot});
    IntakeLoader loader(watchSettingsFor(state, h, w, &files));
    loader.reload(true);
    CHECK(waitFinished(*h, 1) && h->lastFinished().state == LoaderState::Ready, "first load, no links");
    CHECK_EQ(files.listsOf(loose), 1, "the first load lists the shared folder");
    ViewScratch scratch;
    CHECK(h->lastPublished().view && h->lastPublished().view->visualFor(linkRow, scratch) == nullptr,
          "negative control: without the setting a link-form row matches nothing");
    const IntakeRowVisual *direct = h->lastPublished().view->visualFor(newAlbum(root), scratch);
    CHECK(direct && direct->icon == IntakeIcon::CircleOpen, "the root's own spelling matches");

    size_t before = h->publishCount();
    loader.setShareLinks({link});
    CHECK(mock::waitUntil([&] { return h->publishCount() > before; }, 10), "setShareLinks publishes");
    Published p = h->lastPublished();
    CHECK(p.reason == PublishReason::Remount && p.invalidate, "the last load's keys rebuilt, invalidate-all");
    const IntakeRowVisual *linked = p.view ? p.view->visualFor(linkRow, scratch) : nullptr;
    CHECK(linked && linked->icon == IntakeIcon::CircleOpen && linked->bgTint == 0x4A90D938,
          "the link-form row matches the root (new: blue, open circle)");
    CHECK(p.view && p.view->aliases().links().size() == 1 && p.view->aliases().links()[0].rawTarget == root,
          "the view carries the link entry, its target read physically");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus}), "no CLI call for a share link change");
    CHECK(logCount("share link \"" + link + "\" points at \"" + root + "\"") == 1,
          "one Info line: the link points off any mounted share (no smbfs here)");

    g_context = "share-links-incremental";
    loader.reloadForChanges({newAlbumDir}, false);
    CHECK(waitFinished(*h, 2), "a batch after the link change");
    CHECK_EQ(files.listsOf(loose), 1, "still incremental: the shared folder is not listed again");
    CHECK(h->lastPublished().view && h->lastPublished().view->visualFor(linkRow, scratch) != nullptr,
          "the load keeps matching link-form rows");

    g_context = "share-links-unchanged";
    before = h->publishCount();
    loader.relink();
    loader.setShareLinks({link});
    CHECK(!mock::waitUntil([&] { return h->publishCount() > before; }, 0.5), "an unchanged link publishes nothing");
    loader.reload(false);
    CHECK(waitFinished(*h, 3), "a reload");
    CHECK(h->publishCount() == before + 1 && h->lastPublished().reason == PublishReason::Load &&
              !h->lastPublished().invalidate,
          "its start reads the same link: only the unchanged load is published");
    CHECK(logCount("share link \"" + link + "\" points at") == 1, "the same note is not logged again");

    g_context = "share-links-repoint";
    const size_t listed = static_cast<size_t>(files.listsOf(loose));
    CHECK(pointLink(link, empty), "the link re-pointed at an empty folder");
    before = h->publishCount();
    loader.relink();
    CHECK(mock::waitUntil([&] { return h->publishCount() > before; }, 10), "relink() publishes the re-point");
    p = h->lastPublished();
    CHECK(p.reason == PublishReason::Remount && p.invalidate, "invalidate-all: link-form rows change");
    CHECK(p.view && p.view->visualFor(linkRow, scratch) == nullptr, "the link-form row matches nothing now");
    CHECK(p.view && p.view->visualFor(newAlbum(root), scratch) != nullptr, "the root's own spelling still matches");
    CHECK(logCount("points at \"" + realOf(empty) + "\"") == 1, "one Info line for the new target");
    loader.reloadForChanges({newAlbumDir}, false);
    CHECK(waitFinished(*h, 4), "a batch after the re-point");
    CHECK_EQ(static_cast<size_t>(files.listsOf(loose)), listed, "still incremental after a re-point");

    g_context = "share-links-load-start";
    // No relink() call: the next load's start reads the link.
    CHECK(pointLink(link, root), "the link points back at the root");
    before = h->publishCount();
    loader.reload(false);
    CHECK(waitFinished(*h, 5), "a reload");
    std::vector<Published> all = h->publishedCopy();
    CHECK(all.size() == before + 2 && all[before].reason == PublishReason::Remount && all[before].invalidate &&
              all[before + 1].reason == PublishReason::Load && !all[before + 1].invalidate,
          "the load's start publishes the re-point (invalidate-all), then the unchanged load");
    CHECK(all.back().view && all.back().view->visualFor(linkRow, scratch) != nullptr, "the row matches again");
    CHECK(callsAre(state, {kVersion, kIncome, kStatus, kStatus, kStatus, kStatus, kStatus}),
          "no CLI call of its own for any link change: one status per load");

    g_context = "share-links-startup";
    clearLog();
    const std::string state2 = physicalState();
    const std::string link2 = mock::newDir("links") + "/music-link";
    CHECK(!state2.empty() && pointLink(link2, state2 + "/root"), "a second state and link");
    auto h2 = std::make_shared<Harness>();
    h2->setMounts({kLocalRoot});
    LoaderSettings s2 = settingsFor(state2, h2);
    s2.shareLinks = {link2};
    IntakeLoader loader2(std::move(s2));
    loader2.reload(true);
    CHECK(waitFinished(*h2, 1) && h2->lastFinished().state == LoaderState::Ready, "first load with a link configured");
    CHECK_EQ(h2->publishCount(), 1, "one publish: the load");
    const IntakeRowVisual *first =
        h2->lastPublished().view ? h2->lastPublished().view->visualFor("file://" + newAlbum(link2), scratch) : nullptr;
    CHECK(first && first->icon == IntakeIcon::CircleOpen, "link-form rows match from the first load");
    CHECK(logCount("share link \"" + link2 + "\" points at") == 1, "the note is logged on the first read");

    g_context = "share-links-root-key";
    // The CLI spells its roots through a link (the CLI keeps /Volumes roots
    // in practice): configuring that link moves the roots' own keys, so the
    // members kept by root key no longer fit and the next batch lists in
    // full, once.
    // Set up through the link, so the mock's sidecars and replies spell the
    // roots that way.
    const std::string state3 = realOf(mock::newDir("state"));
    const std::string stateLink = mock::newDir("links") + "/state-link";
    CHECK(!state3.empty() && pointLink(stateLink, state3) &&
              mock::runSync({mock::mockPath(), "--mock-setup", "default"}, mock::mockEnv(stateLink)) == 0,
          "a mock state set up through a link");
    const std::string loose3 = stateLink + "/root/income/shop/Loose Tracks";  // as the CLI spells it
    const std::string album3 = state3 + "/root/income/dump/Fixture Artist - New Album";  // as FSEvents does
    CountingAccess files3;
    auto h3 = std::make_shared<Harness>();
    auto w3 = std::make_shared<WatchHarness>();
    h3->setMounts({kLocalRoot});
    IntakeLoader loader3(watchSettingsFor(stateLink, h3, w3, &files3));
    loader3.reload(true);
    CHECK(waitFinished(*h3, 1) && h3->lastFinished().state == LoaderState::Ready, "first load, roots through the link");
    CHECK_EQ(files3.listsOf(loose3), 1, "the first load lists the shared folder");
    p = h3->lastPublished();
    CHECK(p.view && p.view->visualFor(newAlbum(state3 + "/root"), scratch) == nullptr,
          "a row spelled physically does not meet a root spelled through the link");
    loader3.reloadForChanges({album3}, false);
    CHECK(waitFinished(*h3, 2), "a batch before the link is configured");
    CHECK_EQ(files3.listsOf(loose3), 1, "incremental (control)");
    before = h3->publishCount();
    loader3.setShareLinks({stateLink});
    CHECK(mock::waitUntil([&] { return h3->publishCount() > before; }, 10), "setShareLinks publishes");
    p = h3->lastPublished();
    CHECK(p.reason == PublishReason::Remount && p.view && p.view->visualFor(newAlbum(state3 + "/root"), scratch),
          "the roots' keys moved to the link's target: a physically spelled row matches now");
    loader3.reloadForChanges({album3}, false);
    CHECK(waitFinished(*h3, 3), "a batch after the root keys moved");
    CHECK_EQ(files3.listsOf(loose3), 2, "a root's own key moved: the batch lists every member folder");
    loader3.reloadForChanges({album3}, false);
    CHECK(waitFinished(*h3, 4), "the next batch");
    CHECK_EQ(files3.listsOf(loose3), 2, "incremental again");
    loader3.shutdown();
    loader2.shutdown();
    loader.shutdown();
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
        testIncomeAndWatchSet();
        testIncomeFolderGuard();
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
        testReloadServed();
        testWatchEventIds();
        testAnnotateAndBadges();
        testLibraryIndex();
        testPalette();
        testShareLinks();

        setLogBackend(nullptr);
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
