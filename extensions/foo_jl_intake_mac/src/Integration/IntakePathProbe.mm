//
//  IntakePathProbe.mm
//  foo_jl_intake
//
//  TEMPORARY (PLAN.md S0). See IntakePathProbe.h. Read-only: it reads
//  playlist and library item paths, converts them, stats the results and
//  creates (never stores) metadb handles. It runs no intake tooling and
//  modifies no playlist, file or metadb record.
//
//  Order of work, chosen so a slow conversion can never stall the UI:
//    1. main thread, 3 s after init: collect samples (paths only, no I/O);
//    2. probe serial queue: convert and stat every sample, time a 1000-call
//       loop, then convert concurrently from a global queue;
//    3. main thread: repeat the conversions there only if phase 2 never took
//       more than 50 ms per call; then the canonical-path / handle_create
//       checks, which do no I/O.
//

#import <Foundation/Foundation.h>
#include "IntakePathProbe.h"

#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/time.h>

namespace intake_probe {
namespace {

const char* const kDoneKey = "foo_jl_intake.s0_path_probe_done";

constexpr int kMaxMacVolumeSamples = 30;
constexpr int kMaxMacVolumePerPlaylist = 4;
constexpr int kMaxFileSamples = 5;
constexpr int kMaxOtherSamples = 5;
constexpr int kDecorateRowLimit = 40;
constexpr int kDecorateRowsPerBatch = 8;
constexpr double kSlowCallMicros = 500000.0;     // stop phase 2 after one such call
constexpr double kMainThreadMaxMicros = 50000.0;  // phase 3 repeats on main only below this

std::atomic<bool> g_active{false};
std::atomic<int> g_decorateRowsLogged{0};
std::atomic<int> g_decorateBatches{0};
std::mutex g_logMutex;

#pragma mark - Logging

std::string timestampNow() {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    time_t secs = tv.tv_sec;
    struct tm local;
    localtime_r(&secs, &local);
    char date[32];
    strftime(date, sizeof(date), "%Y-%m-%d %H:%M:%S", &local);
    char out[48];
    snprintf(out, sizeof(out), "%s.%03d", date, static_cast<int>(tv.tv_usec / 1000));
    return out;
}

const std::string& logFilePath() {
    static const std::string path = [] {
        NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/foobar2000"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString* file = [dir stringByAppendingPathComponent:@"jl_intake_path_probe.log"];
        return std::string(file.fileSystemRepresentation);
    }();
    return path;
}

std::string vformat(const char* fmt, va_list args) {
    va_list copy;
    va_copy(copy, args);
    const int needed = vsnprintf(nullptr, 0, fmt, copy);
    va_end(copy);
    if (needed < 0) return fmt;
    std::vector<char> buf(static_cast<size_t>(needed) + 1);
    vsnprintf(buf.data(), buf.size(), fmt, args);
    return std::string(buf.data(), static_cast<size_t>(needed));
}

__attribute__((format(printf, 1, 2))) void plog(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    const std::string text = vformat(fmt, args);
    va_end(args);

    std::lock_guard<std::mutex> lock(g_logMutex);
    FB2K_console_formatter() << "[intake] [S0 probe] " << text.c_str();
    if (FILE* f = fopen(logFilePath().c_str(), "a")) {
        fprintf(f, "%s [intake] [S0 probe] %s\n", timestampNow().c_str(), text.c_str());
        fclose(f);
    }
}

#pragma mark - Helpers

double nowMicros() {
    static mach_timebase_info_data_t timebase = [] {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        return tb;
    }();
    const uint64_t t = mach_absolute_time();
    return static_cast<double>(t) * timebase.numer / timebase.denom / 1000.0;
}

std::string threadDesc() {
    uint64_t tid = 0;
    pthread_threadid_np(nullptr, &tid);
    const char* label = dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);
    char buf[256];
    snprintf(buf, sizeof(buf), "main=%s tid=%llu queue=%s", pthread_main_np() ? "yes" : "no",
             static_cast<unsigned long long>(tid), (label && *label) ? label : "(none)");
    return buf;
}

std::string schemeOf(const char* path) {
    const char* delim = strstr(path, "://");
    return delim ? std::string(path, static_cast<size_t>(delim - path)) : std::string("(none)");
}

const char* yn(bool v) { return v ? "yes" : "no"; }

struct Conversion {
    bool returned = false;
    bool threw = false;
    std::string out;
    std::string error;
    double micros = 0;
};

Conversion convert(const char* path) {
    Conversion c;
    pfc::string8 out;
    const double t0 = nowMicros();
    try {
        c.returned = filesystem::g_get_native_path(path, out, fb2k::noAbort);
    } catch (const std::exception& e) {
        c.threw = true;
        c.error = e.what();
    } catch (...) {
        c.threw = true;
        c.error = "(non-std exception)";
    }
    c.micros = nowMicros() - t0;
    c.out = out.c_str();
    return c;
}

struct StatResult {
    bool attempted = false;
    bool exists = false;
    int err = 0;
    double micros = 0;
};

StatResult statPosix(const std::string& path) {
    StatResult s;
    if (path.empty() || path[0] != '/') return s;
    s.attempted = true;
    struct stat st;
    const double t0 = nowMicros();
    s.exists = stat(path.c_str(), &st) == 0;
    s.err = s.exists ? 0 : errno;
    s.micros = nowMicros() - t0;
    return s;
}

struct Sample {
    metadb_handle_ptr handle;
    std::string path;
    uint32_t subsong = 0;
    std::string scheme;
    std::string source;  // "playlist N" or "library"
    Conversion background;
};

using Samples = std::vector<Sample>;

#pragma mark - Phase 1: collect (main thread)

void logVolumes() {
    NSArray<NSURLResourceKey>* keys =
        @[ NSURLVolumeIsLocalKey, NSURLVolumeUUIDStringKey, NSURLVolumeIsRemovableKey ];
    NSArray<NSURL*>* vols =
        [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys:keys
                                                                                options:0];
    plog("mounted volumes: %lu", static_cast<unsigned long>(vols.count));
    for (NSURL* url in vols) {
        NSNumber* isLocal = nil;
        NSString* uuid = nil;
        [url getResourceValue:&isLocal forKey:NSURLVolumeIsLocalKey error:nil];
        [url getResourceValue:&uuid forKey:NSURLVolumeUUIDStringKey error:nil];
        plog("  volume %s local=%s uuid=%s", url.path.fileSystemRepresentation,
             isLocal ? yn(isLocal.boolValue) : "?", uuid ? uuid.UTF8String : "(none)");
    }
}

void addSample(Samples& samples, const metadb_handle_ptr& h, const std::string& scheme,
               const std::string& source) {
    Sample s;
    s.handle = h;
    s.path = h->get_path();
    s.subsong = h->get_subsong_index();
    s.scheme = scheme;
    s.source = source;
    samples.push_back(std::move(s));
}

Samples collectSamples() {
    Samples samples;
    int macCount = 0, fileCount = 0, otherCount = 0;
    std::map<std::string, size_t> playlistSchemes;

    auto pm = playlist_manager::get();
    const t_size playlists = pm->get_playlist_count();
    plog("playlists: %zu", static_cast<size_t>(playlists));
    const double t0 = nowMicros();
    for (t_size p = 0; p < playlists; ++p) {
        metadb_handle_list items;
        pm->playlist_get_all_items(p, items);
        std::map<std::string, size_t> schemes;
        int macHere = 0;
        for (t_size i = 0; i < items.get_count(); ++i) {
            const metadb_handle_ptr& h = items[i];
            const std::string scheme = schemeOf(h->get_path());
            ++schemes[scheme];
            ++playlistSchemes[scheme];
            char source[32];
            snprintf(source, sizeof(source), "playlist %zu", static_cast<size_t>(p));
            if (scheme == "mac-volume") {
                if (macCount < kMaxMacVolumeSamples && macHere < kMaxMacVolumePerPlaylist) {
                    addSample(samples, h, scheme, source);
                    ++macCount;
                    ++macHere;
                }
            } else if (scheme == "file") {
                if (fileCount < kMaxFileSamples) {
                    addSample(samples, h, scheme, source);
                    ++fileCount;
                }
            } else if (otherCount < kMaxOtherSamples) {
                addSample(samples, h, scheme, source);
                ++otherCount;
            }
        }
        std::string summary;
        for (const auto& kv : schemes) {
            summary += " " + kv.first + "=" + std::to_string(kv.second);
        }
        plog("  playlist %zu: %zu items%s", static_cast<size_t>(p),
             static_cast<size_t>(items.get_count()), summary.c_str());
    }
    plog("playlist scan took %.0f us", nowMicros() - t0);

    auto lm = library_manager::get();
    const bool libEnabled = lm->is_library_enabled();
    metadb_handle_list lib;
    const double t1 = nowMicros();
    if (libEnabled) lm->get_all_items(lib);
    std::map<std::string, size_t> libSchemes;
    for (t_size i = 0; i < lib.get_count(); ++i) {
        const std::string scheme = schemeOf(lib[i]->get_path());
        ++libSchemes[scheme];
        if (scheme == "mac-volume" && macCount < 10) {
            addSample(samples, lib[i], scheme, "library");
            ++macCount;
        }
    }
    std::string libSummary;
    for (const auto& kv : libSchemes) {
        libSummary += " " + kv.first + "=" + std::to_string(kv.second);
    }
    plog("library enabled=%s items=%zu%s (scan %.0f us)", yn(libEnabled),
         static_cast<size_t>(lib.get_count()), libSummary.c_str(), nowMicros() - t1);
    plog("samples: mac-volume=%d file=%d other=%d", macCount, fileCount, otherCount);
    return samples;
}

#pragma mark - Phase 3: main thread

void finish() {
    fb2k::configStore::get()->setConfigInt(kDoneKey, 1);
    plog("recorded %s = 1; the probe will not run again", kDoneKey);
    plog("=== S0 path probe done ===");
}

void runMainPhase(std::shared_ptr<Samples> samples, double maxBackgroundMicros) {
    plog("--- phase 3: main thread (%s) ---", threadDesc().c_str());

    if (maxBackgroundMicros < kMainThreadMaxMicros) {
        double total = 0, worst = 0;
        int n = 0;
        for (const Sample& s : *samples) {
            const Conversion c = convert(s.path.c_str());
            total += c.micros;
            if (c.micros > worst) worst = c.micros;
            ++n;
            if (c.out != s.background.out) {
                plog("  MAIN/BACKGROUND DIFFER for %s: main=%s background=%s", s.path.c_str(),
                     c.out.c_str(), s.background.out.c_str());
            }
        }
        plog("main-thread g_get_native_path: %d calls, mean %.1f us, max %.1f us", n,
             n ? total / n : 0.0, worst);
    } else {
        plog("main-thread conversion skipped: background max was %.0f us", maxBackgroundMicros);
    }

    // B9 question: what does foobar2000 produce for a plain /Volumes/... path,
    // and is that the same metadb handle as the playlist's mac-volume:// item?
    auto db = metadb::get();
    int checked = 0;
    for (const Sample& s : *samples) {
        if (checked >= 10) break;
        const std::string& native = s.background.out;
        if (native.empty() || native[0] != '/') continue;
        ++checked;

        pfc::string8 canonPlain, canonFile;
        filesystem::g_get_canonical_path(native.c_str(), canonPlain);
        const std::string fileUrl = "file://" + native;
        filesystem::g_get_canonical_path(fileUrl.c_str(), canonFile);

        metadb_handle_ptr fromPlain = db->handle_create(canonPlain.c_str(), s.subsong);
        metadb_handle_ptr fromFile = db->handle_create(canonFile.c_str(), s.subsong);
        metadb_handle_ptr fromOriginal = db->handle_create(s.path.c_str(), s.subsong);

        plog("  canonical [%s, %s]", s.scheme.c_str(), s.source.c_str());
        plog("    item path        %s (subsong %u)", s.path.c_str(), s.subsong);
        plog("    native           %s", native.c_str());
        plog("    canon(native)    %s", canonPlain.c_str());
        plog("    canon(file://)   %s", canonFile.c_str());
        plog("    handle(canon native) path=%s same-as-item=%s", fromPlain->get_path(),
             yn(fromPlain.get_ptr() == s.handle.get_ptr()));
        plog("    handle(canon file)   path=%s same-as-item=%s", fromFile->get_path(),
             yn(fromFile.get_ptr() == s.handle.get_ptr()));
        plog("    handle(item path)    same-as-item=%s (interning sanity check)",
             yn(fromOriginal.get_ptr() == s.handle.get_ptr()));
    }
    if (checked == 0) plog("  no sample had a POSIX native path; canonical checks skipped");

    finish();
}

#pragma mark - Phase 2: background

void runBackgroundPhase(std::shared_ptr<Samples> samples) {
    plog("--- phase 2: probe queue (%s) ---", threadDesc().c_str());
    double worst = 0;
    bool stopped = false;
    for (Sample& s : *samples) {
        if (!g_active.load()) return;  // foobar2000 is quitting
        const Conversion first = convert(s.path.c_str());
        const Conversion second = convert(s.path.c_str());
        s.background = first;
        if (first.micros > worst) worst = first.micros;
        if (second.micros > worst) worst = second.micros;
        const StatResult st = statPosix(first.out);
        plog("  [%s, %s] %s", s.scheme.c_str(), s.source.c_str(), s.path.c_str());
        plog("    -> returned=%s threw=%s%s%s out=%s", yn(first.returned), yn(first.threw),
             first.threw ? " error=" : "", first.error.c_str(), first.out.c_str());
        plog("    time first=%.1f us second=%.1f us; stat attempted=%s exists=%s errno=%d (%.1f us)",
             first.micros, second.micros, yn(st.attempted), yn(st.exists), st.err, st.micros);
        if (first.out != second.out) plog("    FIRST/SECOND RESULTS DIFFER: %s", second.out.c_str());
        if (first.micros > kSlowCallMicros || second.micros > kSlowCallMicros) {
            plog("    call slower than %.0f us: stopping phase 2 here", kSlowCallMicros);
            stopped = true;
            break;
        }
    }

    if (!stopped) {
        const Sample* loopSample = nullptr;
        for (const Sample& s : *samples) {
            if (s.scheme == "mac-volume") { loopSample = &s; break; }
        }
        if (loopSample) {
            double total = 0, max = 0;
            const int kLoops = 1000;
            for (int i = 0; i < kLoops; ++i) {
                const Conversion c = convert(loopSample->path.c_str());
                total += c.micros;
                if (c.micros > max) max = c.micros;
            }
            plog("loop: %d conversions of one mac-volume path, mean %.2f us, max %.1f us", kLoops,
                 total / kLoops, max);
            if (max > worst) worst = max;
        } else {
            plog("loop skipped: no mac-volume sample");
        }

        // Concurrent calls from global-queue threads, like two host panels
        // decorating at once.
        // Blocks copy captured C++ objects, so the shared counters are reached
        // through pointers; dispatch_apply returns only after every iteration.
        std::atomic<int> mismatches{0}, throws{0};
        std::mutex threadsMutex;
        std::map<uint64_t, int> threads;
        std::atomic<int>* mismatchesPtr = &mismatches;
        std::atomic<int>* throwsPtr = &throws;
        std::mutex* threadsMutexPtr = &threadsMutex;
        std::map<uint64_t, int>* threadsPtr = &threads;
        const size_t count = samples->size();
        const double t0 = nowMicros();
        dispatch_apply(count * 4, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(size_t i) {
            const Sample& s = (*samples)[i % count];
            const Conversion c = convert(s.path.c_str());
            if (c.threw) ++*throwsPtr;
            if (c.out != s.background.out) ++*mismatchesPtr;
            uint64_t tid = 0;
            pthread_threadid_np(nullptr, &tid);
            std::lock_guard<std::mutex> lock(*threadsMutexPtr);
            ++(*threadsPtr)[tid];
        });
        plog("concurrent: %zu calls on %zu threads in %.0f us, mismatches=%d throws=%d",
             count * 4, threads.size(), nowMicros() - t0, mismatches.load(), throws.load());
    }

    plog("phase 2 worst single call: %.1f us", worst);
    // on_quit clears g_active; don't queue main-thread work into a shutdown.
    if (!g_active.load()) return;
    fb2k::inMainThread([samples, worst] {
        if (!g_active.load() || core_api::is_shutting_down()) return;
        runMainPhase(samples, worst);
    });
}

void runStartup() {
    plog("=== S0 path probe start ===");
    plog("log file: %s", logFilePath().c_str());
    plog("startup thread: %s", threadDesc().c_str());
    logVolumes();

    auto samples = std::make_shared<Samples>(collectSamples());
    if (samples->empty()) {
        plog("no playlist or library items; nothing to probe");
        finish();
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("foo_jl_intake.s0probe", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{ runBackgroundPhase(samples); });
}

class intake_probe_initquit : public initquit {
public:
    void on_init() override {
        if (fb2k::configStore::get()->getConfigInt(kDoneKey, 0) != 0) return;
        g_active = true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (core_api::is_shutting_down()) return;
                           runStartup();
                       });
    }
    void on_quit() override { g_active = false; }
};

FB2K_SERVICE_FACTORY(intake_probe_initquit);

}  // namespace

void onDecorateBatch(metadb_handle_list_cref items) {
    if (!g_active.load(std::memory_order_relaxed)) return;
    if (g_decorateRowsLogged.load() >= kDecorateRowLimit) return;

    const int batch = ++g_decorateBatches;
    const t_size n = items.get_count();
    plog("decorate batch %d: %zu rows, %s", batch, static_cast<size_t>(n), threadDesc().c_str());
    int here = 0;
    for (t_size i = 0; i < n && here < kDecorateRowsPerBatch; ++i, ++here) {
        if (++g_decorateRowsLogged > kDecorateRowLimit) return;
        const char* path = items[i]->get_path();
        const Conversion c = convert(path);
        plog("  row %zu %s -> %s (%.1f us, returned=%s)", static_cast<size_t>(i), path,
             c.out.c_str(), c.micros, yn(c.returned));
    }
}

}  // namespace intake_probe
