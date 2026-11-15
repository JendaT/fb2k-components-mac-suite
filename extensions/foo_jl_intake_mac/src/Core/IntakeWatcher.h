//
//  IntakeWatcher.h
//  foo_jl_intake
//
//  A thin FSEventStream wrapper (PLAN.md B4, 3.2, 3.5). SDK-free and in Core
//  so the unit tests link it (Scripts/run_tests.sh, with
//  "// TEST_FRAMEWORKS: CoreServices"); Integration (IntakeService) only owns
//  its lifetime.
//
//  The stream: file-level events (kFSEventStreamCreateFlagFileEvents), 0.5 s
//  latency, from "now" (no history: fseventsd keeps none for SMB volumes),
//  delivered on the watcher's own serial queue. Each event path goes through
//  IntakeWatchFilter: only sidecar names count, and their directories are
//  collected (WatchBatchBuilder). A directory renamed, moved (Finder, the
//  Trash) or removed counts too, as itself: its sidecars move with it
//  without an event of their own. That includes a watched folder itself,
//  which FSEvents reports as a directory event on its own path. Events
//  FSEvents could not deliver one by one (MustScanSubDirs, UserDropped,
//  KernelDropped, Mount, Unmount) mark the batch "rescan". The stream is
//  not created with kFSEventStreamCreateFlagWatchRoot: that flag keeps the
//  watched folder and each of its ancestors open, which on a share would
//  keep the volume busy. Relevant events open or extend a debounce window
//  (IntakeDebounce: 1 s quiet, at most 3 s), and when it fires the handler
//  gets one WatchBatch. Nothing polls: with no events, nothing runs.
//
//  setPaths() hands over the watch set (IntakeWatchSet::streamPaths()); the
//  stream is replaced only when the set differs from the current one, and
//  an empty set means no stream. restart() replaces it with the same paths
//  (a volume mounted or unmounted). Stream creation runs on the watcher's
//  queue, never on the caller's thread: FSEvents may resolve the paths it is
//  given, which is I/O on a share for a network path.
//
//  No change goes unseen across a replacement: the new stream starts
//  before the old one stops, and the old one is flushed
//  (FSEventStreamFlushAsync) and released about latency + 0.5 s later, so
//  events still in its latency buffer are delivered (an event both streams
//  report lands in one batch once, or costs one more coalesced load). A
//  folder no stream watched before (the first stream, a replacement that
//  adds a folder outside the old set, every restart()) can still have
//  changed between the loader's last `status` and the new stream's start:
//  such a start marks the batch streamStarted, and the handler reloads
//  once to catch up.
//
//  stop() (on_quit, before the loader goes): from its return on, the
//  handler is never called again and is released; a handler call already
//  running finishes first. The stream (and any old one not yet released) is
//  stopped, invalidated and released on the watcher's queue; stop() waits for that up to 250 ms and then
//  returns anyway, so a queue stuck in a stream creation on a stalled share
//  cannot hold up quitting (the release then follows when the queue frees).
//  Idempotent; the destructor calls it. Called from inside the handler (on
//  the watcher's queue) it does not deadlock, but cannot wait for the
//  release, which then runs right after the handler returns.
//
//  Thread-safety: every public member may be called from any thread. The
//  handler runs on the watcher's queue.
//

#pragma once

#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "IntakeDebounce.h"
#include "IntakeWatchFilter.h"

namespace intake {

struct WatcherOptions {
    double latencySeconds = 0.5;  // an old stream is released latency + 0.5 s after its replacement started
    double quietSeconds = DebounceWindow::kQuietSeconds;
    double maxWaitSeconds = DebounceWindow::kMaxWaitSeconds;
};

struct WatcherStats {
    size_t streamStarts = 0;         // streams created and started
    size_t streamStartFailures = 0;  // FSEventStreamCreate or Start failed
    size_t batchesDelivered = 0;     // handler calls
    std::vector<std::string> paths;  // the current watch set
    bool streamRunning = false;
};

class IntakeWatcher {
public:
    using Handler = std::function<void(WatchBatch batch)>;

    explicit IntakeWatcher(Handler handler, WatcherOptions options = WatcherOptions());
    ~IntakeWatcher();
    IntakeWatcher(const IntakeWatcher &) = delete;
    IntakeWatcher &operator=(const IntakeWatcher &) = delete;

    // See the top of this file. Paths are sorted and deduplicated here.
    void setPaths(std::vector<std::string> paths);
    void restart();
    void stop();

    WatcherStats stats() const;

    // Streams created and not yet released, process-wide (for tests). A
    // replaced stream counts until its delayed release.
    static size_t liveStreams();

    struct Impl;

private:
    std::shared_ptr<Impl> impl_;
};

} // namespace intake
