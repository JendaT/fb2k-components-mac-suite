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

// `path` equals `base` or lies under it ('/' boundary), byte-exact.
bool coveredBy(const std::string &path, const std::string &base) {
    if (path.size() < base.size() || path.compare(0, base.size(), base) != 0) return false;
    return path.size() == base.size() || path[base.size()] == '/' || base == "/";
}

// Some path of `next` lies under no path of `previous`.
bool addsUncoveredPath(const std::vector<std::string> &next, const std::vector<std::string> &previous) {
    for (const std::string &p : next) {
        bool covered = false;
        for (const std::string &q : previous) {
            if (coveredBy(p, q)) {
                covered = true;
                break;
            }
        }
        if (!covered) return true;
    }
    return false;
}

void streamCallback(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                    const FSEventStreamEventFlags flags[], const FSEventStreamEventId ids[]);
void releaseContext(const void *info);

} // anonymous namespace

struct IntakeWatcher::Impl : std::enable_shared_from_this<IntakeWatcher::Impl> {
    using Clock = DebounceWindow::Clock;

    Impl(Handler h, WatcherOptions o)
        : options(o), window(o.quietSeconds, o.maxWaitSeconds), handler(std::move(h)) {
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
    dispatch_queue_t queue = nil;
    std::atomic<bool> stopped{false};

    // Queue only.
    FSEventStreamRef stream = nullptr;
    std::vector<FSEventStreamRef> retiring;  // replaced, flushed, released after a delay
    std::vector<std::string> paths;
    DebounceWindow window;
    WatchBatchBuilder builder;
    uint64_t timerGeneration = 0;

    // Held while the handler runs, so stop() returns only after a running
    // call finished. Recursive: stop() from inside the handler must not
    // deadlock.
    std::recursive_mutex handlerMutex;
    Handler handler;

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
                                          kFSEventStreamEventIdSinceNow, options.latencySeconds,
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
        }
        logInfo("watching " + std::to_string(paths.size()) + " folder(s) for sidecar changes");
        if (isLogEnabled(LogLevel::Debug)) {
            std::string line = "watch:";
            for (const std::string &p : paths) line += " " + p;
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

    void applyPaths(std::vector<std::string> next, bool force) {
        if (stopped) return;
        std::sort(next.begin(), next.end());
        next.erase(std::unique(next.begin(), next.end()), next.end());
        const bool same = next == paths && (stream != nullptr || paths.empty());
        if (same && !force) return;
        // A folder the old stream did not watch may have changed unseen.
        const bool catchUp = force || stream == nullptr || addsUncoveredPath(next, paths);
        FSEventStreamRef previous = stream;
        stream = nullptr;
        paths = std::move(next);
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
        if (stream && catchUp) {
            builder.addStreamStart();
            if (window.add(Clock::now())) arm();
        }
    }

    // --- events ---

    void onEvents(size_t count, char **eventPaths, const FSEventStreamEventFlags *flags) {
        if (stopped) return;
        bool relevant = false;
        for (size_t i = 0; i < count; i++) {
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
                    const FSEventStreamEventFlags flags[], const FSEventStreamEventId[]) {
    auto *weak = static_cast<std::weak_ptr<IntakeWatcher::Impl> *>(info);
    if (std::shared_ptr<IntakeWatcher::Impl> self = weak->lock()) {
        self->onEvents(count, static_cast<char **>(paths), flags);
    }
}

void releaseContext(const void *info) {
    delete static_cast<const std::weak_ptr<IntakeWatcher::Impl> *>(info);
}

} // anonymous namespace

IntakeWatcher::IntakeWatcher(Handler handler, WatcherOptions options)
    : impl_(std::make_shared<Impl>(std::move(handler), options)) {}

IntakeWatcher::~IntakeWatcher() {
    stop();
}

void IntakeWatcher::setPaths(std::vector<std::string> paths) {
    std::shared_ptr<Impl> impl = impl_;
    if (impl->stopped) return;
    auto next = std::make_shared<std::vector<std::string>>(std::move(paths));
    dispatch_async(impl->queue, ^{
        impl->applyPaths(std::move(*next), false);
    });
}

void IntakeWatcher::restart() {
    std::shared_ptr<Impl> impl = impl_;
    if (impl->stopped) return;
    dispatch_async(impl->queue, ^{
        impl->applyPaths(impl->paths, true);
    });
}

void IntakeWatcher::stop() {
    std::shared_ptr<Impl> impl = impl_;
    if (impl->stopped.exchange(true)) return;
    {
        std::lock_guard<std::recursive_mutex> lock(impl->handlerMutex);
        impl->handler = nullptr;
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
