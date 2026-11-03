//
//  BpmAnalysis.mm
//  foo_jl_bpm_mac
//
//  Two phases inside one threaded_process run:
//    1. TIDAL (when foo_jl_tidal is installed): tracks with an ISRC tag and
//       tidal:// entries. Only exact matches (track ID or ISRC) are used; the
//       artist + title search is never asked for, so a cover or remaster can
//       not lend its tempo to the wrong file.
//    2. Local analysis of every local file still without a result, several
//       tracks at a time on background-priority threads. The same decode
//       also gives each track its beat grid, stored for the seekbar.
//

#include "BpmAnalysis.h"

#include "BeatGridService.h"
#include "BpmJob.h"
#include "TrackDecode.h"
#include "../Core/BpmValue.h"
#include "../Core/TempoEstimator.h"
#include "../../../../shared/jl_tidal_api.h"
#import "../UI/BpmResultsWindowController.h"

#include <helpers/input_helpers.h>

#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

namespace bpm {

namespace {

constexpr unsigned kMaxWorkers = 8;
constexpr auto kPollInterval = std::chrono::milliseconds(100);

TrackRow makeRow(const metadb_handle_ptr &handle) {
    TrackRow row;
    row.handle = handle;
    const char *path = handle->get_path();
    row.isTidalStream = strncmp(path, "tidal://", 8) == 0;
    row.isLocalFile = !row.isTidalStream && !filesystem::g_is_remote_or_unrecognized(path);

    metadb_info_container::ptr info;
    if (handle->get_info_ref(info)) {
        const file_info &fi = info->info();
        if (const char *value = fi.meta_get("BPM", 0)) {
            row.currentTag = value;
            row.currentBpm = parseBpm(value);
        }
        if (const char *isrc = fi.meta_get("ISRC", 0)) row.hasIsrc = *isrc != 0;
    }
    return row;
}

// ---------------------------------------------------------------------------
// Phase 1: TIDAL
// ---------------------------------------------------------------------------

// on_item/on_done arrive on the main thread while the worker thread waits in
// waitDone(); the mutex hands the rows over between the two.
class TidalNotify : public jl_tidal_lookup_notify {
public:
    TidalNotify(std::shared_ptr<AnalysisJob> job, std::unordered_map<const metadb_handle *, size_t> index)
        : m_job(std::move(job)), m_index(std::move(index)) {}

    void on_item(const metadb_handle_ptr &item, const jl_tidal_track_facts &facts) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        const auto it = m_index.find(item.get_ptr());
        if (it != m_index.end()) {
            TrackRow &row = m_job->rows[it->second];
            const bool exact = facts.match == jl_tidal_match_track_id || facts.match == jl_tidal_match_isrc;
            if (facts.status == jl_tidal_status_found && exact && facts.bpm > 0.0f) {
                row.source = ResultSource::Tidal;
                row.bpm = facts.bpm;
            } else if (row.isTidalStream) {
                row.problem = facts.status == jl_tidal_status_unavailable
                                  ? "TIDAL unavailable (signed out, offline or rate limited)"
                                  : "TIDAL has no BPM for this track";
            }
        }
        m_answered++;
    }

    void on_done() override {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_done = true;
        }
        m_cv.notify_all();
    }

    bool is_cancelled() override { return m_cancelled.load(); }

    bool waitDone() {
        std::unique_lock<std::mutex> lock(m_mutex);
        return m_cv.wait_for(lock, kPollInterval, [this] { return m_done; });
    }

    void cancel() { m_cancelled = true; }
    size_t answered() const { return m_answered.load(); }

private:
    std::shared_ptr<AnalysisJob> m_job;
    std::unordered_map<const metadb_handle *, size_t> m_index;
    std::mutex m_mutex;
    std::condition_variable m_cv;
    bool m_done = false;
    std::atomic<bool> m_cancelled{false};
    std::atomic<size_t> m_answered{0};
};

// Returns false when the user aborted.
bool askTidal(const std::shared_ptr<AnalysisJob> &job, const jl_tidal_lookup::ptr &tidal,
              threaded_process_status &status, abort_callback &abort) {
    metadb_handle_list items;
    std::unordered_map<const metadb_handle *, size_t> index;
    for (size_t i = 0; i < job->rows.size(); i++) {
        const TrackRow &row = job->rows[i];
        if (!row.hasIsrc && !row.isTidalStream) continue;
        items.add_item(row.handle);
        index[row.handle.get_ptr()] = i;
    }
    if (items.get_count() == 0) return true;

    auto notify = fb2k::service_new<TidalNotify>(job, std::move(index));
    const size_t total = items.get_count();
    status.set_item("Looking up tempo on TIDAL...");
    status.set_progress(0, total);
    fb2k::inMainThread([tidal, items, notify] { tidal->lookup(items, notify); });

    while (!notify->waitDone()) {
        if (abort.is_aborting()) {
            notify->cancel();
            return false;
        }
        status.set_progress(notify->answered(), total);
    }
    return true;
}

// ---------------------------------------------------------------------------
// Phase 2: local analysis
// ---------------------------------------------------------------------------

// `progress` receives the decoded share of the track (0..1) for the dialog.
void analyzeRow(TrackRow &row, abort_callback &abort, std::atomic<double> &progress) {
    const auto started = std::chrono::steady_clock::now();
    const DecodedTrack track = decodeTrack(row.handle, abort, &progress);
    if (!track.problem.empty()) {
        row.problem = track.problem;
        return;
    }

    // The beat grid from the same decode, for the seekbar's phrase markers
    const BeatGrid grid = analyseDecodedTrack(track, hintsFor(row.handle));
    storeAnalysedGrid(row.handle, grid,
                      std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count());

    // The network grid's tempo; no grid means no steady beat anywhere, where
    // the classic estimate would only guess (181, 187 BPM on ambient). The
    // classic estimate only where the model could not run.
    const TempoResult result =
        track.networkRan ? networkTempo(grid) : estimateTempo(track.envelope, track.framesPerSecond);
    if (!result.valid) {
        row.problem = track.seconds < kMinimumSeconds ? "Too short to analyze" : "No beat found";
        return;
    }
    row.source = ResultSource::Analysis;
    row.bpm = result.bpm;
    row.strength = result.strength;
}

// Returns false when the user aborted.
bool analyzeLocally(const std::shared_ptr<AnalysisJob> &job, threaded_process_status &status,
                    abort_callback &abort) {
    std::vector<size_t> todo;
    for (size_t i = 0; i < job->rows.size(); i++) {
        TrackRow &row = job->rows[i];
        if (row.source != ResultSource::None) continue;
        if (row.isLocalFile) {
            todo.push_back(i);
        } else if (row.problem.empty()) {
            row.problem = row.isTidalStream ? "TIDAL has no BPM for this track" : "Not a local file";
        }
    }
    if (todo.empty()) return true;

    const unsigned hardware = std::max(1u, std::thread::hardware_concurrency());
    const unsigned workers = std::min<unsigned>({hardware > 1 ? hardware - 1 : 1, kMaxWorkers,
                                                 static_cast<unsigned>(todo.size())});

    std::atomic<size_t> next{0};
    std::atomic<size_t> finished{0};
    std::atomic<size_t> current{todo.front()};
    std::atomic<unsigned> running{workers};
    std::vector<std::atomic<double>> inFlight(workers);  // decoded share of each worker's track

    // Each worker takes the next track; rows are never shared between workers.
    auto work = [&](unsigned slot) {
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        for (;;) {
            if (abort.is_aborting()) break;
            const size_t k = next.fetch_add(1);
            if (k >= todo.size()) break;
            current = todo[k];
            bool aborted = false;
            @autoreleasepool {  // decoders may autorelease; std::thread has no pool
                try {
                    analyzeRow(job->rows[todo[k]], abort, inFlight[slot]);
                } catch (...) {
                    aborted = true;
                }
            }
            if (aborted) break;
            inFlight[slot] = 0.0;
            finished++;
        }
        running--;
    };

    std::vector<std::thread> threads;
    threads.reserve(workers);
    for (unsigned i = 0; i < workers; i++) threads.emplace_back(work, i);

    // Finished tracks plus the decoded share of the ones in flight, so the bar
    // moves within long tracks instead of only between them.
    status.set_progress(0, todo.size());
    while (running.load() > 0) {
        std::this_thread::sleep_for(kPollInterval);
        double done = static_cast<double>(finished.load());
        for (const auto &share : inFlight) done += share.load();
        status.set_progress_float(std::min(1.0, done / static_cast<double>(todo.size())));
        status.set_item_path(job->rows[current.load()].handle->get_path());
    }
    for (auto &t : threads) t.join();
    return !abort.is_aborting();
}

void run(const std::shared_ptr<AnalysisJob> &job, const jl_tidal_lookup::ptr &tidal,
         threaded_process_status &status, abort_callback &abort) {
    try {
        if (tidal.is_valid() && !askTidal(job, tidal, status, abort)) return;
        status.set_title("Analyzing BPM");
        analyzeLocally(job, status, abort);
    } catch (exception_aborted const &) {
    } catch (std::exception const &e) {
        FB2K_console_formatter() << "BPM: analysis failed: " << e.what();
    }
}

} // namespace

void startAnalysis(metadb_handle_list_cref items) {
    if (items.get_count() == 0) return;

    auto job = std::make_shared<AnalysisJob>();
    std::unordered_set<const metadb_handle *> seen;
    for (size_t i = 0; i < items.get_count(); i++) {
        const metadb_handle_ptr &item = items[i];
        if (item.is_empty() || !seen.insert(item.get_ptr()).second) continue;
        job->rows.push_back(makeRow(item));
    }

    // Absent when foo_jl_tidal is not installed; everything is analysed locally.
    jl_tidal_lookup::ptr tidal;
    fb2k::std_api_try_get(tidal);

    auto callback = threaded_process_callback_lambda::create(
        [](threaded_process_callback::ctx_t) {},
        [job, tidal](threaded_process_status &status, abort_callback &abort) { run(job, tidal, status, abort); },
        [job](threaded_process_callback::ctx_t, bool aborted) {
            if (!aborted) [BpmResultsWindowController showResultsForJob:job];
        });

    threaded_process::get()->run_modeless(
        callback,
        threaded_process::flag_show_progress | threaded_process::flag_show_item | threaded_process::flag_show_abort,
        core_api::get_main_window(), "Analyzing BPM");
}

} // namespace bpm
