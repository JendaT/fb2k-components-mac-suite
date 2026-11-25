//
//  IntakeWatcherTests.mm
//  foo_jl_intake_mac
//
//  IntakeWatcher against real FSEvents, in temp directories only (under
//  NSTemporaryDirectory, never a share, a music or an income folder):
//   - a stream's start is never a batch by itself: not the first stream, a
//     restart, a replacement that adds a folder or one that drops folders;
//   - a stream started from an event id replays a sidecar written after
//     that id and before the stream started (without the id it is lost);
//     the HistoryDone marker that ends the replay is not a batch;
//   - a sidecar written in a watched folder reaches the handler within 5 s
//     (production latency and debounce), after the 1 s quiet time, and
//     non-sidecar files (.intake-tmp-*, .intake-hint.json, audio) do not;
//   - a burst of sidecar writes is one batch;
//   - the batch's directory maps back to the folder's original spelling
//     through IntakeWatchSet (/var -> /private/var);
//   - a folder renamed, moved out (the Trash), moved in, and the watched
//     folder itself renamed are reported as folders; a renamed file is not;
//   - a sidecar written just before the stream is replaced is still
//     reported (the old stream is flushed and released later);
//   - a watched folder that does not exist yet, or is deleted and created
//     again (the mock's --mock-setup), still reports;
//   - the stream restarts only when the set changes, or on restart();
//   - stop() releases the stream and no batch arrives after it; the
//     destructor does the same.
//   - B12, the event sink: every event reaches it with its flags and event
//     id, spelled physically as FSEvents reports it (/private/var/...), and
//     an income folder given as /var/... (the CLI's spelling) matches it
//     through its WatchSet entry (autoScanIncomes, autoScanHits); the
//     handler still gets its sidecar batches, never one for a file that is
//     no sidecar; nothing reaches the sink after stop().
//  Every stream is released before the binary exits (liveStreams() == 0).
//
// TEST_FRAMEWORKS: CoreServices
// TEST_DEPS: src/Core/IntakeWatchFilter.mm src/Core/IntakeDebounce.mm src/Core/IntakeLog.mm
// TEST_DEPS: src/Core/IntakeWatchSet.mm src/Core/IntakePath.mm src/Core/IntakeMountAliases.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm src/Core/IntakeAutoScan.mm
//

#import <Foundation/Foundation.h>
#include <CoreServices/CoreServices.h>

#include "../src/Core/IntakeAutoScan.h"
#include "../src/Core/IntakeLog.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeWatchSet.h"
#include "../src/Core/IntakeWatcher.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <vector>

using namespace intake;

namespace {

struct Collector {
    std::mutex m;
    std::vector<WatchBatch> batches;
    std::vector<mock::Clock::time_point> times;

    IntakeWatcher::Handler handler() {
        return [this](WatchBatch batch) {
            std::lock_guard<std::mutex> lock(m);
            batches.push_back(std::move(batch));
            times.push_back(mock::Clock::now());
        };
    }
    size_t count() {
        std::lock_guard<std::mutex> lock(m);
        return batches.size();
    }
    WatchBatch at(size_t i) {
        std::lock_guard<std::mutex> lock(m);
        return i < batches.size() ? batches[i] : WatchBatch();
    }
    mock::Clock::time_point timeAt(size_t i) {
        std::lock_guard<std::mutex> lock(m);
        return i < times.size() ? times[i] : mock::Clock::time_point();
    }
};

WatcherOptions fastOptions() {
    WatcherOptions o;
    o.latencySeconds = 0.1;
    o.quietSeconds = 0.2;
    o.maxWaitSeconds = 0.6;
    return o;
}

std::string realPath(const std::string &path) {
    char buffer[PATH_MAX];
    return ::realpath(path.c_str(), buffer) ? std::string(buffer) : path;
}

bool waitRunning(IntakeWatcher &w, size_t starts) {
    bool ok = mock::waitUntil([&] { return w.stats().streamStarts >= starts && w.stats().streamRunning; }, 5);
    // The stream is registered when FSEventStreamStart returns; a short
    // pause keeps the first write clear of it.
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    return ok;
}

bool contains(const std::vector<std::string> &v, const std::string &s) {
    return std::find(v.begin(), v.end(), s) != v.end();
}

// A batch from index `from` on reports `dir`.
bool reportedSince(Collector &c, size_t from, const std::string &dir) {
    for (size_t i = from; i < c.count(); i++) {
        if (contains(c.at(i).directories, dir)) return true;
    }
    return false;
}

WatchEventId currentEventId() {
    return static_cast<WatchEventId>(FSEventsGetCurrentEventId());
}

// No batch arrives within `seconds` (from `from` on).
bool quietFor(Collector &c, size_t from, double seconds) {
    return !mock::waitUntil([&] { return c.count() > from; }, seconds);
}

} // anonymous namespace

static void testSidecarWrite() {
    g_context = "sidecar-write";
    const std::string root = mock::newDir("watch");
    const std::string real = realPath(root);
    mkdir((root + "/A").c_str(), 0755);
    mkdir((root + "/B").c_str(), 0755);

    // The loader's pipeline: the original spelling in, the stream path out.
    WatchSet ws = WatchSet::build({root}, {MountEntry{"/", "/dev/disk-fixture", "apfs", true}}, &posixLinkReader);
    CHECK(ws.streamPaths().size() == 1 && ws.streamPaths()[0] == real, "the stream watches realpath's spelling");

    Collector c;
    IntakeWatcher w(c.handler());  // production: 0.5 s latency, 1 s quiet
    w.setPaths(ws.streamPaths());
    CHECK(waitRunning(w, 1), "the stream starts");

    g_context = "first-start";
    CHECK(quietFor(c, 0, 1.6), "the first stream's start is no batch (1 s quiet time waited out)");

    g_context = "sidecar-write";
    mock::writeFile(root + "/A/notes.txt", "x");
    mock::writeFile(root + "/A/.intake-tmp-1", "{}");
    mock::writeFile(root + "/A/.intake-hint.json", "{}");
    mock::writeFile(root + "/A/01 - Test Track One.wav", "RIFF");
    const auto written = mock::Clock::now();
    mock::writeFile(root + "/B/.intake.json", "{\"schema\":1}");
    CHECK(mock::waitUntil([&] { return c.count() >= 1; }, 5), "the sidecar write is reported within 5 s");
    const double after = std::chrono::duration<double>(c.timeAt(0) - written).count();
    CHECK(after >= 0.9, "not before the 1 s quiet time");
    WatchBatch b = c.at(0);
    CHECK(b.directories.size() == 1 && b.directories[0] == real + "/B" && !b.rescan,
          "only the sidecar's folder; the temp, hint, audio and other files are ignored");
    if (b.directories.size() != 1) {
        for (const std::string &d : b.directories) printf("  reported: %s\n", d.c_str());
    }

    g_context = "sidecar-write-mapping";
    std::vector<std::string> keys;
    std::string expected;
    normalizePath(root + "/B", expected);
    CHECK(!b.directories.empty() && ws.mapEventDirectory(b.directories[0], *MountAliases::none(), keys) &&
              keys.size() == 1 && keys[0] == expected,
          "the reported folder maps back to the key of the folder as the CLI spells it");

    g_context = "burst";
    for (int i = 0; i < 5; i++) {
        const std::string dir = root + "/burst" + std::to_string(i);
        mkdir(dir.c_str(), 0755);
        mock::writeFile(dir + "/.intake.itk_0000000" + std::to_string(i) + ".json", "{}");
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
    }
    CHECK(mock::waitUntil([&] { return c.count() >= 2; }, 5), "the burst is reported");
    std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    CHECK_EQ(c.count(), 2, "a burst of five writes is one batch");
    WatchBatch burst = c.at(1);
    CHECK(burst.directories.size() == 5 && contains(burst.directories, real + "/burst0") &&
              contains(burst.directories, real + "/burst4"),
          "with all five folders");

    g_context = "same-set";
    const size_t starts = w.stats().streamStarts;
    w.setPaths(ws.streamPaths());
    w.setPaths({ws.streamPaths()[0], ws.streamPaths()[0]});  // duplicates collapse
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
    CHECK_EQ(w.stats().streamStarts, starts, "an unchanged set does not restart the stream");
    w.restart();
    CHECK(waitRunning(w, starts + 1), "restart() replaces the stream");
    CHECK(w.stats().sinceEventId == kWatchSinceNow, "from now by default");
    CHECK(mock::waitUntil([] { return IntakeWatcher::liveStreams() == 1; }, 3),
          "one live stream shortly after the restart (the old one released after its flush)");
    CHECK(quietFor(c, 2, 1.6), "a restart is no batch by itself");

    const WatchEventId id = currentEventId();
    w.restart(id);
    CHECK(waitRunning(w, starts + 2), "restarted again");
    CHECK(w.stats().sinceEventId == id, "from the event id it was given");
    w.stop();
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "stop() released the stream and the one still retiring");
}

static void testDirectoryMoves() {
    g_context = "directory-moves";
    const std::string root = mock::newDir("watch-moves");
    const std::string real = realPath(root);
    const std::string income = root + "/income";
    mkdir(income.c_str(), 0755);
    mkdir((income + "/Artist").c_str(), 0755);
    mkdir((income + "/Artist/Album").c_str(), 0755);
    mock::writeFile(income + "/Artist/Album/.intake.json", "{}");
    mock::writeFile(income + "/Artist/Album/01 - Test Track One.wav", "RIFF");
    std::this_thread::sleep_for(std::chrono::milliseconds(300));

    Collector c;
    IntakeWatcher w(c.handler(), fastOptions());
    w.setPaths({real + "/income"});
    CHECK(waitRunning(w, 1), "running");

    rename((income + "/Artist/Album/01 - Test Track One.wav").c_str(),
           (income + "/Artist/Album/02 - Test Track One.wav").c_str());
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    CHECK_EQ(c.count(), 0, "neither the start nor a renamed file is a batch");

    size_t before = c.count();
    rename((income + "/Artist/Album").c_str(), (income + "/Artist/Album Two").c_str());
    CHECK(mock::waitUntil([&] { return reportedSince(c, before, real + "/income/Artist/Album Two"); }, 5),
          "a renamed folder holding a sidecar is reported (no event names the sidecar)");
    CHECK(reportedSince(c, before, real + "/income/Artist/Album"), "with its old path");

    before = c.count();
    rename((income + "/Artist").c_str(), (root + "/Trashed").c_str());
    CHECK(mock::waitUntil([&] { return reportedSince(c, before, real + "/income/Artist"); }, 5),
          "a folder moved out of the watched folder (the Trash) is reported");

    before = c.count();
    rename((root + "/Trashed").c_str(), (income + "/Sorted").c_str());
    CHECK(mock::waitUntil([&] { return reportedSince(c, before, real + "/income/Sorted"); }, 5),
          "a folder moved in is reported");

    before = c.count();
    rename(income.c_str(), (root + "/income-renamed").c_str());
    CHECK(mock::waitUntil([&] { return reportedSince(c, before, real + "/income"); }, 5),
          "the watched folder itself renamed is reported");
    w.stop();
}

static void testReplacement() {
    g_context = "replacement-flush";
    const std::string root = mock::newDir("watch-replace");
    const std::string real = realPath(root);
    mkdir((root + "/A").c_str(), 0755);
    mkdir((root + "/B").c_str(), 0755);
    mkdir((root + "/C").c_str(), 0755);
    WatcherOptions o = fastOptions();
    o.latencySeconds = 0.5;  // production latency: the event waits in the old stream's buffer
    Collector c;
    IntakeWatcher w(c.handler(), o);
    w.setPaths({real + "/A"});
    CHECK(waitRunning(w, 1), "running");

    size_t before = c.count();
    mock::writeFile(root + "/A/.intake.json", "{}");
    w.setPaths({real + "/A", real + "/B"});  // at once: well inside the 0.5 s latency
    CHECK(mock::waitUntil([&] { return reportedSince(c, before, real + "/A"); }, 5),
          "a sidecar written just before the stream is replaced is still reported");
    CHECK(mock::waitUntil([] { return IntakeWatcher::liveStreams() == 1; }, 3), "the old stream is released");
    std::this_thread::sleep_for(std::chrono::milliseconds(1200));
    bool onlyA = c.count() > before;
    for (size_t i = before; i < c.count(); i++) {
        const WatchBatch batch = c.at(i);
        if (batch.rescan || batch.directories.size() != 1 || batch.directories[0] != real + "/A") onlyA = false;
    }
    CHECK(onlyA, "only that folder is reported: the replacement adds no batch of its own");

    g_context = "replacement-adds-folder";
    // As the loader hands it over: a new folder, the id of a `status` call
    // made after the last change.
    before = c.count();
    size_t starts = w.stats().streamStarts;
    const size_t replays = w.stats().historyDone;
    w.setPaths({real + "/A", real + "/B", real + "/C"}, currentEventId());
    CHECK(waitRunning(w, starts + 1), "replaced");
    CHECK(mock::waitUntil([&] { return w.stats().historyDone > replays; }, 5), "its replay ran (and found nothing)");
    CHECK(quietFor(c, before, 1.2), "a replacement that adds a folder triggers no reload by itself");

    g_context = "replacement-subset";
    before = c.count();
    starts = w.stats().streamStarts;
    w.setPaths({real + "/A"});  // B and C dropped only
    CHECK(waitRunning(w, starts + 1), "replaced");
    CHECK(quietFor(c, before, 1.2), "a replacement that only drops folders triggers no reload");
    w.stop();
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "released");
}

// The startup gap: a sidecar written after the loader's `status` call (the
// id taken before it) and before the stream started.
static void testHistoryReplay() {
    g_context = "history-replay";
    const std::string root = mock::newDir("watch-replay");
    const std::string real = realPath(root);
    mkdir((root + "/A").c_str(), 0755);
    mkdir((root + "/B").c_str(), 0755);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));  // the mkdirs are history before the id

    Collector c;
    IntakeWatcher w(c.handler(), fastOptions());
    const WatchEventId statusId = currentEventId();
    mock::writeFile(root + "/A/.intake.json", "{}");
    std::this_thread::sleep_for(std::chrono::milliseconds(400));  // the stream starts late
    w.setPaths({real}, statusId);
    CHECK(waitRunning(w, 1), "running");
    CHECK(mock::waitUntil([&] { return reportedSince(c, 0, real + "/A"); }, 5),
          "the sidecar written before the stream started is replayed and reported");
    CHECK(mock::waitUntil([&] { return w.stats().historyDone == 1; }, 5), "the replay ends with HistoryDone");
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    CHECK(c.count() == 1 && c.at(0).directories.size() == 1 && !c.at(0).rescan,
          "one batch with that folder only (the mkdirs before the id are not replayed)");
    w.stop();

    g_context = "history-replay-control";
    // Without the id (from now): the same write is lost, which is why the
    // loader passes one.
    Collector c2;
    IntakeWatcher w2(c2.handler(), fastOptions());
    mock::writeFile(root + "/B/.intake.json", "{}");
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    w2.setPaths({real + "/B"});
    CHECK(waitRunning(w2, 1), "running");
    CHECK(quietFor(c2, 0, 1.5), "from now: the earlier write is not reported");
    CHECK_EQ(w2.stats().historyDone, 0, "and no replay ran");
    w2.stop();
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "released");
}

static void testHistoryDoneIgnored() {
    g_context = "history-done";
    const std::string root = mock::newDir("watch-history-done");
    const std::string real = realPath(root);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    Collector c;
    IntakeWatcher w(c.handler(), fastOptions());
    w.setPaths({real}, currentEventId());
    CHECK(waitRunning(w, 1), "running");
    CHECK(mock::waitUntil([&] { return w.stats().historyDone == 1; }, 5),
          "FSEvents sends the HistoryDone marker (on the watched folder itself)");
    CHECK(quietFor(c, 0, 1.0), "the marker is not a change: no batch");
    w.stop();
}

static void testMissingAndRecreated() {
    g_context = "missing-folder";
    const std::string root = mock::newDir("watch-missing");
    const std::string real = realPath(root);
    Collector c;
    IntakeWatcher w(c.handler(), fastOptions());
    // An income folder that does not exist yet ("exists": false).
    w.setPaths({real + "/later"});
    CHECK(waitRunning(w, 1), "a stream on a missing folder starts");
    mkdir((root + "/later").c_str(), 0755);
    mkdir((root + "/later/Album").c_str(), 0755);
    mock::writeFile(root + "/later/Album/.intake.json", "{}");
    CHECK(mock::waitUntil([&] { return reportedSince(c, 0, real + "/later/Album"); }, 5),
          "a sidecar in the folder created later is reported");

    g_context = "recreated-folder";
    // The mock's --mock-setup deletes root/ and copies it in again.
    [[NSFileManager defaultManager] removeItemAtPath:@((root + "/later").c_str()) error:nil];
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    const size_t before = c.count();
    mkdir((root + "/later").c_str(), 0755);
    mkdir((root + "/later/Album2").c_str(), 0755);
    mock::writeFile(root + "/later/Album2/.intake.itk_0000000a.json", "{}");
    CHECK(mock::waitUntil(
              [&] {
                  for (size_t i = before; i < c.count(); i++) {
                      if (contains(c.at(i).directories, real + "/later/Album2")) return true;
                  }
                  return false;
              },
              5),
          "a sidecar in the deleted and recreated folder is reported");
    w.stop();
}

static void testStop() {
    g_context = "stop";
    const std::string root = mock::newDir("watch-stop");
    const std::string real = realPath(root);
    Collector c;
    {
        IntakeWatcher w(c.handler(), fastOptions());
        w.setPaths({real});
        CHECK(waitRunning(w, 1), "running");
        w.stop();
        const size_t atStop = c.count();
        CHECK_EQ(IntakeWatcher::liveStreams(), 0, "released by stop()");
        w.stop();  // idempotent
        w.setPaths({real + "/other"});
        w.restart();
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        CHECK_EQ(w.stats().streamStarts, 1, "a stopped watcher starts no stream");
        mock::writeFile(root + "/.intake.json", "{}");
        std::this_thread::sleep_for(std::chrono::milliseconds(1200));
        CHECK_EQ(c.count(), atStop, "no batch after stop()");
    }

    g_context = "destructor";
    {
        IntakeWatcher w(c.handler(), fastOptions());
        w.setPaths({real});
        CHECK(waitRunning(w, 1), "running");
        CHECK_EQ(IntakeWatcher::liveStreams(), 1, "one live stream");
    }
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "the destructor released it");

    g_context = "empty-set";
    {
        IntakeWatcher w(c.handler(), fastOptions());
        w.setPaths({});
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
        CHECK(w.stats().streamStarts == 0 && IntakeWatcher::liveStreams() == 0, "an empty set: no stream");
    }
}

// B12: one sink call, copied out (its paths are valid for the call only),
// with the income indices autoScanHits found in it during the call.
struct SinkCall {
    struct Event {
        std::string path;
        uint32_t flags = 0;
        WatchEventId id = 0;
    };
    std::vector<Event> events;
    std::vector<size_t> hitIncomes;
};

struct SinkCollector {
    std::mutex m;
    std::vector<SinkCall> calls;
    std::vector<AutoScanIncome> incomes;  // set before the watcher starts

    IntakeWatcher::EventSink sink() {
        return [this](const std::vector<AutoScanEvent> &events) {
            SinkCall call;
            for (const AutoScanEvent &e : events) call.events.push_back({std::string(e.path), e.flags, e.id});
            call.hitIncomes = autoScanHits(events, incomes, {}).incomes;
            std::lock_guard<std::mutex> lock(m);
            calls.push_back(std::move(call));
        };
    }
    size_t count() {
        std::lock_guard<std::mutex> lock(m);
        return calls.size();
    }
    // The first event for `path`, and the call it came in.
    bool find(const std::string &path, SinkCall::Event &event, SinkCall &call) {
        std::lock_guard<std::mutex> lock(m);
        for (const SinkCall &c : calls) {
            for (const SinkCall::Event &e : c.events) {
                if (e.path == path) {
                    event = e;
                    call = c;
                    return true;
                }
            }
        }
        return false;
    }
};

static void testAutoScanSink() {
    g_context = "auto-scan-sink";
    const std::string root = mock::newDir("sink");
    const std::string real = realPath(root);
    // The CLI's spelling of a temp folder: /var/..., while FSEvents reports
    // /private/var/... (the /var symlink resolved).
    const std::string configured = real.rfind("/private/var/", 0) == 0 ? real.substr(8) : root;
    CHECK(configured.rfind("/var/", 0) == 0 && real.rfind("/private/var/", 0) == 0,
          "the temp folder is /var/..., physically /private/var/...");
    const std::string income = configured + "/income";
    mkdir((real + "/income").c_str(), 0755);

    // The loader's pipeline: the income folder as a watch candidate, then
    // its auto-scan entry from that set.
    const std::vector<MountEntry> mounts = {MountEntry{"/", "/dev/disk-fixture", "apfs", true}};
    WatchSet ws = WatchSet::build(watchCandidates({}, {income}, {}), mounts, &posixLinkReader);
    SinkCollector sc;
    sc.incomes = autoScanIncomes({IncomeFolder{"local", income, true}}, ws);
    CHECK(sc.incomes.size() == 1 && sc.incomes[0].path == income && sc.incomes[0].fsPath == real + "/income",
          "the income entry: the CLI's /var path, the stream's /private/var spelling");
    CHECK(ws.streamPaths().size() == 1 && ws.streamPaths()[0] == real + "/income", "the stream watches it");

    Collector c;
    IntakeWatcher w(c.handler(), fastOptions(), sc.sink());
    w.setPaths(ws.streamPaths());
    CHECK(waitRunning(w, 1), "the stream starts");

    const std::string track = "/income/01 - Test Track One.wav";
    const WatchEventId before = currentEventId();
    mock::writeFile(root + track, "RIFF");
    SinkCall::Event event;
    SinkCall call;
    CHECK(mock::waitUntil([&] { return sc.find(real + track, event, call); }, 5),
          "the sink gets the audio file's event within 5 s, spelled /private/var/...");
    SinkCall::Event unused;
    SinkCall unusedCall;
    CHECK(!sc.find(configured + track, unused, unusedCall), "never in the /var spelling");
    CHECK((event.flags & fsevent::kItemCreated) && (event.flags & fsevent::kItemIsFile),
          "with its flags (created, a file)");
    CHECK(event.id > before && event.id != kWatchSinceNow, "and its event id, after the id taken before the write");
    CHECK(call.hitIncomes.size() == 1 && call.hitIncomes[0] == 0,
          "autoScanHits in the sink matches the income given as /var/...");
    CHECK(quietFor(c, 0, 1.0), "the handler gets no batch for a file that is no sidecar");

    g_context = "auto-scan-sink-sidecar";
    mock::writeFile(root + "/income/.intake.json", "{\"schema\":1}");
    CHECK(mock::waitUntil([&] { return c.count() >= 1; }, 5), "the handler still gets the sidecar's batch");
    CHECK(c.count() >= 1 && c.at(0).directories.size() == 1 && c.at(0).directories[0] == real + "/income",
          "for the income folder");
    CHECK(sc.find(real + "/income/.intake.json", event, call), "the sink saw the sidecar event too");

    g_context = "auto-scan-sink-stop";
    w.stop();
    const size_t atStop = sc.count();
    mock::writeFile(root + "/income/02 - Test Track Two.wav", "RIFF");
    std::this_thread::sleep_for(std::chrono::milliseconds(800));
    CHECK_EQ(sc.count(), atStop, "nothing reaches the sink after stop()");
}

int main(void) {
    @autoreleasepool {
        atexit(mock::removeTempRoot);
        setLogLevel(LogLevel::Error);
        testSidecarWrite();
        testDirectoryMoves();
        testReplacement();
        testHistoryReplay();
        testHistoryDoneIgnored();
        testMissingAndRecreated();
        testStop();
        testAutoScanSink();
        CHECK_EQ(IntakeWatcher::liveStreams(), 0, "no stream left");
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
