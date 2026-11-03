//
//  BeatGridService.mm
//  foo_jl_bpm_mac
//

#include "BeatGridService.h"

#include "TrackDecode.h"
#include "../Core/BeatGridStore.h"
#include "../../../../shared/jl_beatgrid_api.h"

#include <pthread.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace bpm {

namespace {

// ---------------------------------------------------------------------------
// Storage: a metadb index keyed on path + subsong. Change the GUID whenever
// the hashing changes, or old data would pin to the wrong tracks.
// ---------------------------------------------------------------------------

// {4C2B7E91-0A36-4F58-B1D4-8E5A27C91F03}
const GUID guid_grid_index = { 0x4c2b7e91, 0x0a36, 0x4f58, { 0xb1, 0xd4, 0x8e, 0x5a, 0x27, 0xc9, 0x1f, 0x03 } };

// Grids of tracks no longer in the library stay this long
const t_filetimestamp kRetention = system_time_periods::week * 26;

std::atomic<bool> g_indexReady{false};

metadb_index_hash hashLocation(const playable_location &location) {
    pfc::string8 key;
    key << location.get_path() << "|" << location.get_subsong();
    return hasher_md5::get()->process_single_string(key).xorHalve();
}

class GridIndexClient : public metadb_index_client {
public:
    metadb_index_hash transform(const file_info &, const playable_location &location) override {
        return hashLocation(location);
    }
};

metadb_index_manager::ptr indexManager() {
    static metadb_index_manager *cached = metadb_index_manager::get().detach();
    return cached;
}

class GridIndexInit : public init_stage_callback {
public:
    void on_init_stage(t_uint32 stage) override {
        if (stage != init_stages::before_config_read) return;
        auto api = indexManager();
        try {
            api->add(new service_impl_single_t<GridIndexClient>(), guid_grid_index, kRetention);
            g_indexReady = true;
        } catch (std::exception const &e) {
            api->remove(guid_grid_index);
            FB2K_console_formatter() << "[BPM] Beat grid store unavailable: " << e;
        }
    }
};
FB2K_SERVICE_FACTORY(GridIndexInit);

std::optional<StoredGrid> loadGrid(const metadb_handle_ptr &item) {
    if (!g_indexReady || !item.is_valid()) return std::nullopt;
    mem_block_container_impl blob;
    indexManager()->get_user_data(guid_grid_index, hashLocation(item->get_location()), blob);
    if (blob.get_size() == 0) return std::nullopt;
    return decodeStoredGrid(static_cast<const uint8_t *>(blob.get_ptr()), blob.get_size());
}

std::string keyOf(const metadb_handle_ptr &item) {
    return std::string(item->get_path()) + "|" + std::to_string(item->get_subsong_index());
}

void logGrid(const metadb_handle_ptr &item, const StoredGrid &stored, double seconds) {
    if (stored.available) {
        pfc::string_formatter phases;
        if (stored.summary.bar_phase < 0) {
            phases << "bar phase unknown";
        } else {
            phases << "bars on beat " << stored.summary.bar_phase << ", phrases on bar "
                   << stored.summary.phrase_phase_bars << " (confidence "
                   << pfc::format_float(stored.summary.phrase_confidence, 0, 2) << ")";
        }
        const char *source = stored.summary.source == jl_beatgrid_source_beat_this ? "Beat This!" : "classic";
        FB2K_console_formatter() << "[BPM] Beat grid (" << source << "): " << pfc::format_float(stored.summary.bpm, 0, 2) << " BPM, "
            << stored.regions.size() << (stored.regions.size() == 1 ? " region, " : " regions, ")
            << (stored.sections.empty() ? 1 : stored.sections.size())
            << (stored.sections.size() > 1 ? " grids, " : " grid, ")
            << pfc::format_int(static_cast<int64_t>(std::lround(lockedShare(stored.bars) * 100.0)))
            << "% of bars locked, " << phases << " (" << pfc::format_float(seconds, 0, 2) << " s): "
            << item->get_path();
    } else {
        FB2K_console_formatter() << "[BPM] Beat grid: none, no steady pulse (" << pfc::format_float(seconds, 0, 2)
            << " s): " << item->get_path();
    }
}

// ---------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------

class BeatGridServiceImpl : public jl_beatgrid {
public:
    status_t get_status(const metadb_handle_ptr &item) override {
        if (!item.is_valid() || !g_indexReady) return unavailable;
        const std::string key = keyOf(item);
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            if (m_current == key) return analysing;
            for (const auto &queued : m_queue) {
                if (keyOf(queued) == key) return jl_beatgrid::queued;
            }
            if (m_failed.count(key)) return unavailable;
        }
        const std::optional<StoredGrid> stored = loadGrid(item);
        if (!stored) return not_analysed;
        return stored->available ? ready : unavailable;
    }

    bool get(const metadb_handle_ptr &item, jl_beatgrid_summary &out, pfc::array_t<jl_beat_region> &regions,
             pfc::array_t<jl_bar_stat> &bars) override {
        const std::optional<StoredGrid> stored = loadGrid(item);
        if (!stored || !stored->available) return false;
        out = stored->summary;
        regions.set_size(stored->regions.size());
        for (size_t i = 0; i < stored->regions.size(); i++) regions[i] = stored->regions[i];
        bars.set_size(stored->bars.size());
        for (size_t i = 0; i < stored->bars.size(); i++) bars[i] = stored->bars[i];
        return true;
    }

    bool get_sections(const metadb_handle_ptr &item, pfc::array_t<jl_grid_section> &sections,
                      pfc::array_t<jl_bar_stat> &bars) override {
        const std::optional<StoredGrid> stored = loadGrid(item);
        std::vector<jl_grid_section> s;
        std::vector<jl_bar_stat> b;
        if (!stored || !sectionsOf(*stored, s, b)) return false;
        sections.set_size(s.size());
        for (size_t i = 0; i < s.size(); i++) sections[i] = s[i];
        bars.set_size(b.size());
        for (size_t i = 0; i < b.size(); i++) bars[i] = b[i];
        return true;
    }

    void request(const metadb_handle_ptr &item, bool urgent) override {
        if (!item.is_valid() || !g_indexReady || loadGrid(item)) return;
        const std::string key = keyOf(item);
        std::lock_guard<std::mutex> lock(m_mutex);
        if (m_stopping || m_current == key || m_failed.count(key)) return;
        for (auto it = m_queue.begin(); it != m_queue.end(); ++it) {
            if (keyOf(*it) != key) continue;
            if (urgent && it != m_queue.begin()) {   // duplicates collapse; urgent moves to the front
                m_queue.erase(it);
                m_queue.push_front(item);
            }
            return;
        }
        if (urgent) m_queue.push_front(item);
        else m_queue.push_back(item);
        if (!m_worker.joinable()) {
            m_abort = std::make_unique<abort_callback_impl>();
            m_worker = std::thread([this] { work(); });
        }
        m_wake.notify_one();
    }

    void add_notify(jl_beatgrid_notify::ptr notify) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_notifies.push_back(notify);
    }

    void remove_notify(jl_beatgrid_notify::ptr notify) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        for (auto it = m_notifies.begin(); it != m_notifies.end(); ++it) {
            if (*it == notify) {
                m_notifies.erase(it);
                break;
            }
        }
    }

    // Stores on the main thread (as the SDK's sample writes its index), then
    // tells the consumers
    void store(const metadb_handle_ptr &item, StoredGrid stored, double seconds) {
        logGrid(item, stored, seconds);
        auto blob = std::make_shared<std::vector<uint8_t>>(encodeStoredGrid(stored));
        metadb_handle_ptr handle = item;
        fb2k::inMainThread([this, handle, blob] {
            if (g_indexReady) {
                indexManager()->set_user_data(guid_grid_index, hashLocation(handle->get_location()), blob->data(),
                                              blob->size());
            }
            notifyReady(handle);
        });
    }

    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_stopping = true;
            m_queue.clear();
        }
        if (m_abort) m_abort->abort();
        m_wake.notify_all();
        if (m_worker.joinable()) m_worker.join();
    }

private:
    void notifyReady(const metadb_handle_ptr &item) {
        std::vector<jl_beatgrid_notify::ptr> snapshot;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            snapshot = m_notifies;
        }
        for (auto &notify : snapshot) notify->on_ready(item);
    }

    // One track at a time, at background priority, so playback and the
    // consumers' own analysis come first
    void work() {
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
        for (;;) {
            metadb_handle_ptr item;
            {
                std::unique_lock<std::mutex> lock(m_mutex);
                m_wake.wait(lock, [this] { return m_stopping || !m_queue.empty(); });
                if (m_stopping) return;
                item = m_queue.front();
                m_queue.pop_front();
                m_current = keyOf(item);
            }
            @autoreleasepool {
                analyse(item);
            }
            std::lock_guard<std::mutex> lock(m_mutex);
            m_current.clear();
        }
    }

    void analyse(const metadb_handle_ptr &item) {
        const auto started = std::chrono::steady_clock::now();
        try {
            const DecodedTrack track = decodeTrack(item, *m_abort);
            const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
            if (!track.problem.empty()) {
                fail(item, track.problem);
                return;
            }
            const BeatGrid grid = analyseDecodedTrack(track, hintsFor(item));
            store(item, toStored(grid), seconds);
        } catch (exception_aborted const &) {
            // shutting down
        } catch (std::exception const &e) {
            fail(item, e.what());
        }
    }

    // Decode failures are not stored (the file may come back), but not
    // retried in this session either
    void fail(const metadb_handle_ptr &item, const std::string &problem) {
        FB2K_console_formatter() << "[BPM] Beat grid failed (" << problem.c_str() << "): " << item->get_path();
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_failed.insert(keyOf(item));
        }
        metadb_handle_ptr handle = item;
        fb2k::inMainThread([this, handle] { notifyReady(handle); });
    }

    std::mutex m_mutex;
    std::condition_variable m_wake;
    std::deque<metadb_handle_ptr> m_queue;
    std::string m_current;
    std::set<std::string> m_failed;
    std::vector<jl_beatgrid_notify::ptr> m_notifies;
    std::thread m_worker;
    bool m_stopping = false;
    // Made with the worker: this object is built while the component loads,
    // before foobar2000's services exist, and abort_callback_impl's
    // constructor already looks one up (a crash at launch)
    std::unique_ptr<abort_callback_impl> m_abort;
};

service_factory_single_t<BeatGridServiceImpl> g_gridService;

class GridServiceQuit : public initquit {
public:
    void on_quit() override { g_gridService.get_static_instance().shutdown(); }
};
FB2K_SERVICE_FACTORY(GridServiceQuit);

} // namespace

void storeAnalysedGrid(const metadb_handle_ptr &item, const BeatGrid &grid, double seconds) {
    g_gridService.get_static_instance().store(item, toStored(grid), seconds);
}

} // namespace bpm
