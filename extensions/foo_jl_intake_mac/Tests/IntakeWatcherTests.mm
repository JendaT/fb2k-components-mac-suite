//
//  IntakeWatcherTests.mm
//  foo_jl_intake_mac
//
//  IntakeWatcher against real FSEvents, in temp directories only (under
//  NSTemporaryDirectory, never a share, a music or an income folder):
//   - a sidecar written in a watched folder reaches the handler within 5 s
//     (production latency and debounce), after the 1 s quiet time, and
//     non-sidecar files (.intake-tmp-*, .intake-hint.json, audio) do not;
//   - a burst of sidecar writes is one batch;
//   - the batch's directory maps back to the folder's original spelling
//     through IntakeWatchSet (/var -> /private/var);
//   - a watched folder that does not exist yet, or is deleted and created
//     again (the mock's --mock-setup), still reports;
//   - the stream restarts only when the set changes, or on restart();
//   - stop() releases the stream and no batch arrives after it; the
//     destructor does the same.
//  Every stream is released before the binary exits (liveStreams() == 0).
//
// TEST_FRAMEWORKS: CoreServices
// TEST_DEPS: src/Core/IntakeWatchFilter.mm src/Core/IntakeDebounce.mm src/Core/IntakeLog.mm
// TEST_DEPS: src/Core/IntakeWatchSet.mm src/Core/IntakePath.mm src/Core/IntakeMountAliases.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeLog.h"
#include "../src/Core/IntakePath.h"
#include "../src/Core/IntakeWatchSet.h"
#include "../src/Core/IntakeWatcher.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

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
    std::string out;
    return realPathResolver(path, out) ? out : path;
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

} // anonymous namespace

static void testSidecarWrite() {
    g_context = "sidecar-write";
    const std::string root = mock::newDir("watch");
    const std::string real = realPath(root);
    mkdir((root + "/A").c_str(), 0755);
    mkdir((root + "/B").c_str(), 0755);

    // The loader's pipeline: the original spelling in, the stream path out.
    WatchSet ws = WatchSet::build({root}, {MountEntry{"/", "/dev/disk-fixture", "apfs", true}}, &realPathResolver);
    CHECK(ws.streamPaths().size() == 1 && ws.streamPaths()[0] == real, "the stream watches realpath's spelling");

    Collector c;
    IntakeWatcher w(c.handler());  // production: 0.5 s latency, 1 s quiet
    w.setPaths(ws.streamPaths());
    CHECK(waitRunning(w, 1), "the stream starts");

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
    CHECK_EQ(IntakeWatcher::liveStreams(), 1, "one live stream after the restart (the old one released)");

    w.stop();
    CHECK_EQ(IntakeWatcher::liveStreams(), 0, "stop() released the stream");
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
    CHECK(mock::waitUntil([&] { return c.count() >= 1; }, 5), "a sidecar in the folder created later is reported");
    CHECK(c.at(0).directories.size() == 1 && c.at(0).directories[0] == real + "/later/Album", "its folder");

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
        CHECK_EQ(IntakeWatcher::liveStreams(), 0, "released by stop()");
        w.stop();  // idempotent
        w.setPaths({real + "/other"});
        w.restart();
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        CHECK_EQ(w.stats().streamStarts, 1, "a stopped watcher starts no stream");
        mock::writeFile(root + "/.intake.json", "{}");
        std::this_thread::sleep_for(std::chrono::milliseconds(1200));
        CHECK_EQ(c.count(), 0, "no batch after stop()");
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

int main(void) {
    @autoreleasepool {
        atexit(mock::removeTempRoot);
        setLogLevel(LogLevel::Error);
        testSidecarWrite();
        testMissingAndRecreated();
        testStop();
        CHECK_EQ(IntakeWatcher::liveStreams(), 0, "no stream left");
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
