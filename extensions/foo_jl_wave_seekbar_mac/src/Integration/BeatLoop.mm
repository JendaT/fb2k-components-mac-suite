//
//  BeatLoop.mm
//  foo_wave_seekbar_mac
//
//  The "Beat loop" DSP and its bridge to the main thread (see BeatLoop.h).
//  Between blocks the DSP takes the view's requests; after each block it
//  publishes its status. A seek flushes it: an arm made just before is the
//  view's own seek and gives it the track time.
//

#import <Foundation/Foundation.h>

#include "../fb2k_sdk.h"
#include "../Core/ConfigHelper.h"
#include "BeatLoop.h"

#include <atomic>
#include <cmath>
#include <chrono>
#include <deque>
#include <mutex>

namespace {

// {795D5E97-EF6B-4587-A637-FC2D2D985942}
constexpr GUID guid_beat_loop_dsp = { 0x795d5e97, 0xef6b, 0x4587, { 0xa6, 0x37, 0xfc, 0x2d, 0x2d, 0x98, 0x59, 0x42 } };

using Engine = waveseek::LoopEngine<audio_sample>;
using Clock = std::chrono::steady_clock;

// Requests from the main thread and the status back, under one lock; the
// DSP holds it only to copy them between blocks
struct Bridge {
    std::mutex lock;
    uint64_t nextId = 0;
    // The seek coming
    uint64_t armId = 0;
    waveseek::LoopArm arm;
    Clock::time_point armedAt;
    std::deque<waveseek::LoopAction> actions;
    std::deque<Clock::time_point> queuedAt;
    uint64_t syncSerial = 0;
    uint64_t syncEpoch = 0;
    double syncT0 = 0.0;
    beatloop::Status status;

    static Bridge &get() {
        static Bridge bridge;
        return bridge;
    }
};

std::atomic<int> g_instances{ 0 };
std::atomic<bool> g_responsive{ false };
std::atomic<double> g_reserve{ 0.0 };

class dsp_beat_loop : public dsp_impl_base {
public:
    dsp_beat_loop() { g_instances++; }
    ~dsp_beat_loop() { g_instances--; }

    static GUID g_get_guid() { return guid_beat_loop_dsp; }
    static void g_get_name(pfc::string_base &out) { out = "Beat loop (Waveform Seekbar)"; }

    bool on_chunk(audio_chunk *chunk, abort_callback &) override {
        takeRequests();
        m_engine.setResponsive(g_responsive.load(std::memory_order_relaxed));
        m_engine.setReserveSeconds(g_reserve.load(std::memory_order_relaxed));
        // A gapless change to another track: its frame 0 is here
        dsp_track_t file;
        get_cur_file(file);
        const bool newTrack = m_sawFile && file.is_valid() && file != m_file;
        if (file.is_valid()) {
            m_file = file;
            m_sawFile = true;
        }
        const double block = chunk->get_sample_rate() ? static_cast<double>(chunk->get_sample_count()) / chunk->get_sample_rate() : 0.0;
        m_blockSeconds = m_blockSeconds > 0.0 ? 0.9 * m_blockSeconds + 0.1 * block : block;
        std::vector<Engine::Block> out;
        const bool through = m_engine.process(chunk->get_data(), chunk->get_sample_count(), chunk->get_channel_count(),
                                              chunk->get_sample_rate(), chunk->get_channel_config(), newTrack, out);
        if (!through) insert(out);
        publish();
        return through;
    }

    void on_endofplayback(abort_callback &) override {
        std::vector<Engine::Block> out;
        m_engine.endOfStream(out);
        insert(out);
        publish();
    }

    void on_endoftrack(abort_callback &) override {}

    void flush() override {
        // A fresh arm is this seek; a stale one is dropped
        waveseek::LoopArm arm;
        bool own = false;
        {
            Bridge &b = Bridge::get();
            std::lock_guard<std::mutex> guard(b.lock);
            if (b.armId != 0) {
                const double age = std::chrono::duration<double>(Clock::now() - b.armedAt).count();
                if (age <= beatloop::kArmTimeout) {
                    arm = b.arm;
                    own = true;
                }
                b.armId = 0;
            }
            b.actions.clear();   // they were for the audio before the seek
            b.queuedAt.clear();
        }
        m_engine.flush(own ? &arm : nullptr);
        m_sawFile = false;
        m_file.release();
        publish();
    }

    // May be asked from another thread: the decoded audio waiting, as of the last block
    double get_latency() override { return m_latency.load(std::memory_order_relaxed); }
    bool need_track_change_mark() override { return false; }

private:
    void takeRequests() {
        std::deque<waveseek::LoopAction> actions;
        std::deque<Clock::time_point> queuedAt;
        bool haveSync = false;
        uint64_t epoch = 0;
        double t0 = 0.0;
        {
            Bridge &b = Bridge::get();
            std::lock_guard<std::mutex> guard(b.lock);
            actions.swap(b.actions);
            queuedAt.swap(b.queuedAt);
            if (b.syncSerial != m_syncSerial) {
                m_syncSerial = b.syncSerial;
                haveSync = true;
                epoch = b.syncEpoch;
                t0 = b.syncT0;
            }
        }
        if (haveSync) m_engine.sync(epoch, t0);
        for (const waveseek::LoopAction &a : actions) m_engine.act(a);
        if (!queuedAt.empty()) {
            m_lastTakenMs = std::chrono::duration<double, std::milli>(Clock::now() - queuedAt.back()).count();
            m_lastTakenId = actions.back().id;
        }
    }

    void insert(std::vector<Engine::Block> &blocks) {
        for (const Engine::Block &block : blocks) {
            if (block.frames() == 0) continue;
            audio_chunk *chunk = insert_chunk(block.samples.size());
            chunk->set_data(block.samples.data(), block.frames(), block.channels, block.rate, block.config);
        }
    }

    void publish() {
        m_latency.store(m_engine.aheadSeconds(), std::memory_order_relaxed);
        Bridge &b = Bridge::get();
        std::lock_guard<std::mutex> guard(b.lock);
        beatloop::Status &s = b.status;
        s.epoch = m_engine.epoch();
        s.synced = m_engine.synced();
        s.startTime = m_engine.startTime();
        s.pristine = m_engine.pristine();
        s.live = m_engine.live();
        s.looping = m_engine.looping();
        s.rate = m_engine.rate();
        s.loopStart = m_engine.loopStart();
        s.loopEnd = m_engine.loopEnd();
        s.bufferedFrom = m_engine.bufferedFrom();
        s.bufferedTo = m_engine.bufferedTo();
        s.outSeconds = m_engine.outSeconds();
        s.ahead = m_engine.aheadSeconds();
        s.blockSeconds = m_blockSeconds;
        s.lastTakenMs = m_lastTakenMs;
        s.lastTakenId = m_lastTakenId;
        s.boundArmId = m_engine.boundArmId();
        s.lastActionId = m_engine.lastActionId();
        s.rejectedId = m_engine.rejectedId();
        if (m_engine.version() != m_publishedVersion) {
            m_publishedVersion = m_engine.version();
            s.timeline = m_engine.timeline();
        }
    }

    Engine m_engine;
    double m_blockSeconds = 0.0;
    double m_lastTakenMs = 0.0;
    uint64_t m_lastTakenId = 0;
    std::atomic<double> m_latency{ 0.0 };
    uint64_t m_syncSerial = 0;
    uint64_t m_publishedVersion = UINT64_MAX;
    dsp_track_t m_file;
    bool m_sawFile = false;
};

dsp_factory_nopreset_t<dsp_beat_loop> g_beat_loop_factory;

visualisation_stream::ptr g_clock;
service_ptr g_liveEdit;
bool g_liveEditMissing = false;
bool g_quitting = false;

} // namespace

namespace beatloop {

void setInChain(bool on) {
    try {
        auto manager = dsp_config_manager::get();
        dsp_preset_impl present;
        const bool inChain = manager->core_query_dsp(guid_beat_loop_dsp, present);
        if (on == inChain) return;
        if (on) {
            dsp_preset_impl preset;
            preset.set_owner(guid_beat_loop_dsp);
            preset.set_data(nullptr, 0);
            manager->core_enable_dsp(preset, dsp_config_manager::default_insert_first);
            FB2K_console_formatter() << "[WaveSeek] Beat loop DSP added to the playback chain (mixer controls)";
        } else {
            manager->core_disable_dsp(guid_beat_loop_dsp);
            FB2K_console_formatter() << "[WaveSeek] Beat loop DSP removed from the playback chain";
        }
    } catch (const std::exception &e) {
        FB2K_console_formatter() << "[WaveSeek] Beat loop DSP: " << e.what();
    }
}

bool running() {
    return g_instances.load() > 0;
}

uint64_t armSeek(double target, const waveseek::LoopAction *then) {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    b.armId = ++b.nextId;
    b.arm = waveseek::LoopArm();
    b.arm.id = b.armId;
    b.arm.target = target;
    if (then) {
        b.arm.then = *then;
        b.arm.then->id = ++b.nextId;
    }
    b.armedAt = Clock::now();
    return b.armId;
}

uint64_t act(waveseek::LoopAction action) {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    action.id = ++b.nextId;
    b.actions.push_back(action);
    b.queuedAt.push_back(Clock::now());
    return action.id;
}

void sync(uint64_t epoch, double t0) {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    b.syncSerial++;
    b.syncEpoch = epoch;
    b.syncT0 = t0;
}

Status status() {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    return b.status;
}

double playedSinceSeek() {
    if (g_quitting) return NAN;
    try {
        if (!g_clock.is_valid()) visualisation_manager::get()->create_stream(g_clock, 0);
        double seconds = 0.0;
        if (g_clock.is_valid() && g_clock->get_absolute_time(seconds)) return seconds;
    } catch (...) {
    }
    return NAN;
}

void releaseClock() {
    g_clock.release();
}

void setLowLatency(bool on) {
    g_responsive.store(on, std::memory_order_relaxed);
    if (!on) {
        g_liveEdit.release();
        return;
    }
    if (g_liveEdit.is_valid() || g_liveEditMissing || g_quitting) return;
    try {
        dsp_config_manager_v3::ptr manager;
        if (dsp_config_manager_v3::tryGet(manager)) g_liveEdit = manager->acquire_live_edit_scope();
        else {
            g_liveEditMissing = true;
            FB2K_console_formatter() << "[WaveSeek] Beat loop: this foobar2000 has no low-latency hint; changes to a "
                                        "loop are heard after the output buffer (Preferences > Playback > Output)";
        }
    } catch (...) {
        g_liveEditMissing = true;
    }
}

void setReserve(double seconds) {
    g_reserve.store(seconds, std::memory_order_relaxed);   // the engine bounds it
}

void applyMixerBuffer(bool mixerOn, int mixerMs) {
    using namespace waveform_config;
    try {
        output_manager_v2::ptr manager;
        if (!output_manager_v2::tryGet(manager)) return;
        outputCoreConfig_t config = manager->getCoreConfig();
        const int64_t saved = getConfigInt(kKeyMixerSavedBufferMs, 0);
        if (mixerOn && mixerMs > 0) {
            const double want = mixerMs / 1000.0;
            if (std::fabs(config.m_buffer_length - want) < 0.0005) return;
            const int64_t own = saved > 0 ? saved : std::llround(config.m_buffer_length * 1000.0);
            if (saved <= 0) setConfigInt(kKeyMixerSavedBufferMs, own);
            config.m_buffer_length = want;
            manager->setCoreConfig(config);
            FB2K_console_formatter() << "[WaveSeek] Mixer: output buffer " << mixerMs << " ms while the mixer is on (yours, "
                                     << own << " ms, comes back when it goes off)";
        } else if (saved > 0) {
            setConfigInt(kKeyMixerSavedBufferMs, 0);
            if (std::fabs(config.m_buffer_length - saved / 1000.0) < 0.0005) return;
            config.m_buffer_length = saved / 1000.0;
            manager->setCoreConfig(config);
            FB2K_console_formatter() << "[WaveSeek] Mixer off: output buffer back to " << saved << " ms";
        }
    } catch (const std::exception &e) {
        FB2K_console_formatter() << "[WaveSeek] Mixer output buffer: " << e.what();
    }
}

int outputBufferMs() {
    try {
        output_manager::ptr manager;
        if (!fb2k::std_api_try_get(manager)) return 0;
        return static_cast<int>(std::lround(manager->getCoreConfig().m_buffer_length * 1000.0));
    } catch (...) {
        return 0;
    }
}

void shutdown() {
    g_quitting = true;
    g_clock.release();
    g_liveEdit.release();
}

} // namespace beatloop
