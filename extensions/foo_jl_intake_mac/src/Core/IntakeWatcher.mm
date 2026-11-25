//
//  IntakeWatcher.mm
//  foo_jl_intake
//

#include "IntakeWatcher.h"

#include "IntakeLog.h"

#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>

namespace intake {

namespace {

std::atomic<size_t> g_liveStreams{0};

// Set on the watcher's queue so stop() can tell it is running there.
const void *const kWatcherQueueKey = &kWatcherQueueKey;

static_assert(kWatchSinceNow == kFSEventStreamEventIdSinceNow, "kWatchSinceNow is FSEvents' \"since now\"");

// RootChanged is not listed: it arrives only with
// kFSEventStreamCreateFlagWatchRoot, which this stream does not use (see
// the header). A watched folder that moves is a directory event instead.
constexpr FSEventStreamEventFlags kRescanFlags =
    kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
    kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount;

// A directory renamed, moved or removed. FSEvents keeps item flags sticky
// for a while, so a later event on the same folder may repeat them: at
// worst one more coalesced load.
constexpr FSEventStreamEventFlags kDirectoryMoveFlags =
    kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved;

void streamCallback(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                    const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]);
void releaseContext(const void *info);

} // anonymous namespace

struct IntakeWatcher::Impl : std::enable_shared_from_this<IntakeWatcher::Impl> {
    using Clock = DebounceWindow::Clock;

    Impl(Handler h, WatcherOptions o, EventSink s)
        : options(o), hasSink(static_cast<bool>(s)), window(o.quietSeconds, o.maxWaitSeconds),
          handler(std::move(h)), sink(std::move(s)) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.foobar2000.intake.watch", attr);
        dispatch_queue_set_specific(queue, kWatcherQueueKey, (void *)kWatcherQueueKey, nullptr);
    }

    ~Impl() {
        // Every block that touches the stream holds a reference, and stop()
        // releases it on the queue; this is the last resort.
        releaseStream();
    }

    WatcherOptions options;
    const bool hasSink;  // a sink was given: only then are events collected for it
    dispatch_queue_t queue = nil;
    std::atomic<bool> stopped{false};

    // Queue only.
    FSEventStreamRef stream = nullptr;
    std::vector<FSEventStreamRef> retiring;  // replaced, flushed, released after a delay
    std::vector<std::string> paths;
    WatchEventId since = kWatchSinceNow;     // where the next stream starts
    DebounceWindow window;
    WatchBatchBuilder builder;
    uint64_t timerGeneration = 0;

    // Held while the handler or the sink runs, so stop() returns only after
    // a running call finished. Recursive: stop() from inside the handler
    // must not deadlock.
    std::recursive_mutex handlerMutex;
    Handler handler;
    EventSink sink;

    mutable std::mutex statsMutex;
    WatcherStats stats;

    // --- stream ---

    void startStream() {
        CFMutableArrayRef cfPaths = CFArrayCreateMutable(kCFAllocatorDefault, (CFIndex)paths.size(),
                                                         &kCFTypeArrayCallBacks);
        for (const std::string &p : paths) {
            CFStringRef s = CFStringCreateWithFileSystemRepresentation(kCFAllocatorDefault, p.c_str());
            if (s) {
                CFArrayAppendValue(cfPaths, s);
                CFRelease(s);
            }
        }
        // The stream holds a weak reference, freed when the stream is: a
        // callback that arrives after the last owner let go does nothing.
        FSEventStreamContext context = {0, new std::weak_ptr<Impl>(shared_from_this()), nullptr,
                                        &releaseContext, nullptr};
        FSEventStreamRef created = nullptr;
        if (CFArrayGetCount(cfPaths) > 0) {
            created = FSEventStreamCreate(kCFAllocatorDefault, &streamCallback, &context, cfPaths,
                                          static_cast<FSEventStreamEventId>(since), options.latencySeconds,
                                          kFSEventStreamCreateFlagFileEvents);
        }
        CFRelease(cfPaths);
        if (!created) {
            releaseContext(context.info);
            noteStartFailure("could not create the FSEvents stream");
            return;
        }
        g_liveStreams.fetch_add(1);
        FSEventStreamSetDispatchQueue(created, queue);
        if (!FSEventStreamStart(created)) {
            FSEventStreamInvalidate(created);
            FSEventStreamRelease(created);
            g_liveStreams.fetch_sub(1);
            noteStartFailure("could not start the FSEvents stream");
            return;
        }
        stream = created;
        {
            std::lock_guard<std::mutex> lock(statsMutex);
            stats.streamStarts++;
            stats.streamRunning = true;
            stats.sinceEventId = since;
        }
        logInfo("watching " + std::to_string(paths.size()) + " folder(s) for sidecar changes");
        if (isLogEnabled(LogLevel::Debug)) {
            std::string line = "watch:";
            for (const std::string &p : paths) line += " " + p;
            line += since == kWatchSinceNow ? std::string(" (from now)")
                                            : " (replaying since event " + std::to_string(since) + ")";
            logDebug(line);
        }
    }

    void noteStartFailure(const char *what) {
        {
            std::lock_guard<std::mutex> lock(statsMutex);
            stats.streamStartFailures++;
            stats.streamRunning = false;
        }
        logError(std::string(what) + " for " + std::to_string(paths.size()) +
                 " folder(s); sidecar changes need Refresh until the next watch change");
    }

    static void destroyStream(FSEventStreamRef s) {
        FSEventStreamStop(s);
        FSEventStreamInvalidate(s);
        FSEventStreamRelease(s);
        g_liveStreams.fetch_sub(1);
    }

    // Every stream, the current one and the retiring ones (stop(), the
    // destructor).
    void releaseStream() {
        for (FSEventStreamRef s : retiring) destroyStream(s);
        retiring.clear();
        if (!stream) return;
        destroyStream(stream);
        stream = nullptr;
        std::lock_guard<std::mutex> lock(statsMutex);
        stats.streamRunning = false;
    }

    // A replaced stream: flushed now, so what sits in its latency buffer is
    // delivered, and released once that had time to arrive.
    void retireStream(FSEventStreamRef old) {
        FSEventStreamFlushAsync(old);
        retiring.push_back(old);
        const double delay = options.latencySeconds + 0.5;
        std::weak_ptr<Impl> weak = shared_from_this();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay * NSEC_PER_SEC)), queue, ^{
            std::shared_ptr<Impl> self = weak.lock();
            if (!self) return;
            auto it = std::find(self->retiring.begin(), self->retiring.end(), old);
            if (it == self->retiring.end()) return;  // stop() released it already
            self->retiring.erase(it);
            destroyStream(old);
        });
    }

    // `sinceEventId` applies only when a stream is created here: an
    // unchanged set keeps its running stream (see the header). No batch of
    // its own: what changed before the start comes as replayed events.
    void applyPaths(std::vector<std::string> next, WatchEventId sinceEventId, bool force) {
        if (stopped) return;
        std::sort(next.begin(), next.end());
        next.erase(std::unique(next.begin(), next.end()), next.end());
        const bool same = next == paths && (stream != nullptr || paths.empty());
        if (same && !force) return;
        FSEventStreamRef previous = stream;
        stream = nullptr;
        paths = std::move(next);
        since = sinceEventId;
        {
            std::lock_guard<std::mutex> lock(statsMutex);
            stats.paths = paths;
            stats.streamRunning = false;
        }
        if (paths.empty()) {
            logDebug("watch: no folders, no stream");
        } else {
            startStream();
        }
        // After the new stream started: no gap between the two.
        if (previous) retireStream(previous);
    }

    // --- events ---

    void onEvents(size_t count, char **eventPaths, const FSEventStreamEventFlags *flags,
                  const FSEventStreamEventId *ids) {
        if (stopped) return;
        if (hasSink) passToSink(count, eventPaths, flags, ids);
        bool relevant = false;
        for (size_t i = 0; i < count; i++) {
            // The end of a replay (the stream was created with an event id):
            // a marker on the watched path, not a change.
            if (flags[i] & kFSEventStreamEventFlagHistoryDone) {
                {
                    std::lock_guard<std::mutex> lock(statsMutex);
                    stats.historyDone++;
                }
                logDebug("watch: replay done");
                continue;
            }
            if (flags[i] & kRescanFlags) {
                builder.addRescan();
                relevant = true;
                continue;
            }
            if (eventPaths[i] == nullptr) continue;
            if ((flags[i] & kFSEventStreamEventFlagItemIsDir) && (flags[i] & kDirectoryMoveFlags)) {
                if (builder.addDirectory(eventPaths[i])) relevant = true;
                continue;
            }
            if (builder.addPath(eventPaths[i])) relevant = true;
        }
        if (!relevant) return;
        if (window.add(Clock::now())) arm();
    }

    // B12: the whole callback, unfiltered (see the header).
    void passToSink(size_t count, char **eventPaths, const FSEventStreamEventFlags *flags,
                    const FSEventStreamEventId *ids) {
        std::lock_guard<std::recursive_mutex> lock(handlerMutex);
        if (stopped || !sink) return;
        std::vector<AutoScanEvent> events;
        events.reserve(count);
        for (size_t i = 0; i < count; i++) {
            AutoScanEvent e;
            if (eventPaths[i] != nullptr) e.path = eventPaths[i];
            e.flags = static_cast<uint32_t>(flags[i]);
            e.id = ids != nullptr ? static_cast<WatchEventId>(ids[i]) : 0;
            events.push_back(e);
        }
        sink(events);
    }

    void arm() {
        const uint64_t generation = ++timerGeneration;
        const auto delay = window.due() - Clock::now();
        int64_t nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(delay).count();
        if (nanos < 0) nanos = 0;
        std::weak_ptr<Impl> weak = shared_from_this();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nanos), queue, ^{
            if (std::shared_ptr<Impl> self = weak.lock()) self->onTimer(generation);
        });
    }

    void onTimer(uint64_t generation) {
        if (stopped || generation != timerGeneration) return;
        if (window.fire(Clock::now())) {
            deliver();
        } else if (window.pending()) {
            arm();
        }
    }

    void deliver() {
        WatchBatch batch = builder.take();
        if (batch.empty()) return;
        std::lock_guard<std::recursive_mutex> lock(handlerMutex);
        if (stopped || !handler) return;
        {
            std::lock_guard<std::mutex> statsLock(statsMutex);
            stats.batchesDelivered++;
        }
        handler(std::move(batch));
    }
};

namespace {

void streamCallback(ConstFSEventStreamRef, void *info, size_t count, void *paths,
                    const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]) {
    auto *weak = static_cast<std::weak_ptr<IntakeWatcher::Impl> *>(info);
    if (std::shared_ptr<IntakeWatcher::Impl> self = weak->lock()) {
        self->onEvents(count, static_cast<char **>(paths), flags, ids);
    }
}

void releaseContext(const void *info) {
    delete static_cast<const std::weak_ptr<IntakeWatcher::Impl> *>(info);
}

} // anonymous namespace

IntakeWatcher::IntakeWatcher(Handler handler, WatcherOptions options, EventSink sink)
    : impl_(std::make_shared<Impl>(std::move(handler), options, std::move(sink))) {}

IntakeWatcher::~IntakeWatcher() {
    stop();
}

void IntakeWatcher::setPaths(std::vector<std::string> paths, WatchEventId sinceEventId) {
    std::shared_ptr<Impl> impl = impl_;
    if (impl->stopped) return;
    auto next = std::make_shared<std::vector<std::string>>(std::move(paths));
    dispatch_async(impl->queue, ^{
        impl->applyPaths(std::move(*next), sinceEventId, false);
    });
}

void IntakeWatcher::restart(WatchEventId sinceEventId) {
    std::shared_ptr<Impl> impl = impl_;
    if (impl->stopped) return;
    dispatch_async(impl->queue, ^{
        impl->applyPaths(impl->paths, sinceEventId, true);
    });
}

void IntakeWatcher::stop() {
    std::shared_ptr<Impl> impl = impl_;
    if (impl->stopped.exchange(true)) return;
    {
        std::lock_guard<std::recursive_mutex> lock(impl->handlerMutex);
        impl->handler = nullptr;
        impl->sink = nullptr;
    }
    dispatch_semaphore_t released = dispatch_semaphore_create(0);
    dispatch_async(impl->queue, ^{
        impl->releaseStream();
        impl->window.reset();
        impl->builder.take();
        dispatch_semaphore_signal(released);
    });
    if (dispatch_get_specific(kWatcherQueueKey) == kWatcherQueueKey) return;
    if (dispatch_semaphore_wait(released, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) != 0) {
        logInfo("watch: the stream is still being set up; it is released as soon as that ends");
    }
}

WatcherStats IntakeWatcher::stats() const {
    std::lock_guard<std::mutex> lock(impl_->statsMutex);
    return impl_->stats;
}

size_t IntakeWatcher::liveStreams() {
    return g_liveStreams.load();
}

} // namespace intake
