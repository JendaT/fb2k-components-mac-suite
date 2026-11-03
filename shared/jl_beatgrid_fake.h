#pragma once

//
// jl_beatgrid_fake.h — debug-only stand-in for BPM Analyzer's jl_beatgrid
//
// Lets a consumer (Waveform Seekbar's phrase markers) be built and tried
// before, or without, the real provider. NOT SHIPPED: include it from one
// file that compiles only in Debug builds, and register it only when an
// environment variable asks for it, so debug builds behave like release
// unless explicitly testing (as SimPlaylist's DebugDummyDecorator.mm does):
//
//     #if DEBUG
//     #include "../../../../shared/jl_beatgrid_fake.h"
//     namespace {
//     struct FakeBeatgridRegistrar {
//         FakeBeatgridRegistrar() {
//             const char *on = std::getenv("WAVESEEK_BEATGRID_FAKE");
//             if (on && on[0] == '1' && on[1] == '\0') jl_beatgrid_fake_register();
//         }
//     } g_fakeBeatgridRegistrar;
//     }
//     #endif
//
//     WAVESEEK_BEATGRID_FAKE=1 open -a foobar2000
//
// Never register it next to the real BPM Analyzer: both would answer the
// same GUID.
//
// Behaviour: every track starts not_analysed; request() makes it ready about
// a second later and calls on_ready(), exercising the request and notify
// path. The grid is 128 BPM from 0.1 s, its bars cycling through every
// marker state across the track: 24 bars locked, 8 drifting (+15 ms, 3 of 4
// matched), 8 locked, 8 broken (+40 ms, none matched), 8 without pulse, then
// a new region (re-anchor) and the cycle again. Tracks without a known
// length are unavailable.
//

#include "jl_beatgrid_api.h"

#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

class jl_beatgrid_fake : public jl_beatgrid {
public:
    status_t get_status(const metadb_handle_ptr &item) override {
        if (!item.is_valid()) return unavailable;
        std::lock_guard<std::mutex> lock(m_mutex);
        const auto it = m_status.find(key(item));
        return it == m_status.end() ? not_analysed : it->second;
    }

    bool get(const metadb_handle_ptr &item, jl_beatgrid_summary &out, pfc::array_t<jl_beat_region> &regions,
             pfc::array_t<jl_bar_stat> &bars) override {
        if (get_status(item) != ready) return false;
        const double length = item->get_length();
        if (!(length > 0.0)) return false;

        out = jl_beatgrid_summary{};
        out.bpm = 128.0;
        out.anchor_seconds = 0.1;
        out.tempo_strength = 0.8f;
        out.bar_phase = 0;
        out.phrase_phase_bars = 0;
        out.phrase_confidence = 0.5f;
        out.source = jl_beatgrid_source_classic;

        const double bar_seconds = 4 * 60.0 / out.bpm;
        const size_t count = static_cast<size_t>(std::ceil((length - out.anchor_seconds) / bar_seconds));
        bars.set_size(count);
        std::vector<jl_beat_region> found;
        for (size_t i = 0; i < count; i++) {
            const size_t phase = i % kCycleBars;
            jl_bar_stat bar = { 0, 4, static_cast<uint8_t>(jl_pulse_unit), 0 };
            if (phase >= 24 && phase < 32) bar = { 15, 3, static_cast<uint8_t>(jl_pulse_unit), 0 };   // drifting
            if (phase >= 40 && phase < 48) bar = { 40, 0, static_cast<uint8_t>(jl_pulse_unit), 0 };   // broken
            if (phase >= 48 && phase < 56) bar = { 0, 1, 8, 0 };                                      // no pulse
            if (phase == 56) {
                bar.flags = jl_bar_region_start;
                found.push_back({ jl_beat_time(out, static_cast<long>(i * 4)), 60.0 / out.bpm, 0, 0 });
            }
            bars[i] = bar;
        }
        // Regions: one per cycle, from its start or the previous re-anchor
        regions.set_size(0);
        double start = out.anchor_seconds;
        for (const jl_beat_region &r : found) {
            regions.append_single(jl_beat_region{ start, 60.0 / out.bpm,
                                    static_cast<uint32_t>(std::lround((r.start_seconds - start) * out.bpm / 60.0)), 0 });
            start = r.start_seconds;
        }
        regions.append_single(jl_beat_region{ start, 60.0 / out.bpm,
                                static_cast<uint32_t>(std::max(0.0, std::floor((length - start) * out.bpm / 60.0))), 0 });
        return true;
    }

    void request(const metadb_handle_ptr &item, bool urgent) override {
        (void)urgent;
        if (!item.is_valid()) return;
        const std::string k = key(item);
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            const auto it = m_status.find(k);
            if (it != m_status.end()) return;   // queued, analysing or done
            m_status[k] = queued;
        }
        // "Analyse" off the main thread for about a second, then report
        service_ptr_t<jl_beatgrid_fake> self(this);
        metadb_handle_ptr handle = item;
        std::thread([self, handle, k] {
            std::this_thread::sleep_for(std::chrono::milliseconds(1000));
            {
                std::lock_guard<std::mutex> lock(self->m_mutex);
                self->m_status[k] = handle->get_length() > 0.0 ? ready : unavailable;
            }
            fb2k::inMainThread([self, handle] { self->notify(handle); });
        }).detach();
    }

    void add_notify(jl_beatgrid_notify::ptr notify) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_notifies.push_back(notify);
    }

    void remove_notify(jl_beatgrid_notify::ptr notify) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        for (size_t i = 0; i < m_notifies.size(); i++) {
            if (m_notifies[i] == notify) {
                m_notifies.erase(m_notifies.begin() + static_cast<std::ptrdiff_t>(i));
                break;
            }
        }
    }

private:
    static constexpr size_t kCycleBars = 64;

    static std::string key(const metadb_handle_ptr &item) {
        return std::string(item->get_path()) + "|" + std::to_string(item->get_subsong_index());
    }

    void notify(const metadb_handle_ptr &item) {
        std::vector<jl_beatgrid_notify::ptr> snapshot;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            snapshot = m_notifies;
        }
        for (auto &n : snapshot) n->on_ready(item);
    }

    std::mutex m_mutex;
    std::unordered_map<std::string, status_t> m_status;
    std::vector<jl_beatgrid_notify::ptr> m_notifies;
};

// Registers the fake for the rest of the process; call at most once, from
// static initialisation in a Debug-only file (see above)
inline void jl_beatgrid_fake_register() {
    static service_factory_single_t<jl_beatgrid_fake> g_factory;
}
