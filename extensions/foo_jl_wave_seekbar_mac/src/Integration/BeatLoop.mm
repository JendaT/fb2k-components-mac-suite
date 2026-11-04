//
//  BeatLoop.mm
//  foo_wave_seekbar_mac
//
//  The "Beat loop" DSP and its bridge to the main thread (see BeatLoop.h).
//  The DSP passes audio through untouched until a loop is armed; the
//  seek to the loop's start flushes it, which binds the loop.
//

#import <Foundation/Foundation.h>

#include "../fb2k_sdk.h"
#include "BeatLoop.h"

#include <atomic>
#include <chrono>
#include <mutex>

namespace {

// {795D5E97-EF6B-4587-A637-FC2D2D985942}
constexpr GUID guid_beat_loop_dsp = { 0x795d5e97, 0xef6b, 0x4587, { 0xa6, 0x37, 0xfc, 0x2d, 0x2d, 0x98, 0x59, 0x42 } };

using Engine = waveseek::LoopEngine<audio_sample>;
using Clock = std::chrono::steady_clock;

// Requests from the main thread and status back, under one lock; the DSP
// holds it only to copy them between blocks
struct Bridge {
    std::mutex lock;
    uint64_t nextId = 0;
    // The arm waiting for a seek
    uint64_t armId = 0;
    double armStart = 0.0, armLength = 0.0;
    Clock::time_point armedAt;
    // The latest length and exit asked for, per loop id
    uint64_t lengthId = 0;
    double length = 0.0;
    uint64_t lengthSerial = 0;
    uint64_t exitId = 0;
    beatloop::Status status;

    static Bridge &get() {
        static Bridge bridge;
        return bridge;
    }
};

std::atomic<int> g_instances{ 0 };

class dsp_beat_loop : public dsp_impl_base {
public:
    dsp_beat_loop() { g_instances++; }
    ~dsp_beat_loop() { g_instances--; }

    static GUID g_get_guid() { return guid_beat_loop_dsp; }
    static void g_get_name(pfc::string_base &out) { out = "Beat loop (Waveform Seekbar)"; }

    bool on_chunk(audio_chunk *chunk, abort_callback &) override {
        takeRequests();
        if (m_engine.phase() == Engine::Idle) {   // the usual case: untouched
            publishIfChanged();
            return true;
        }
        Engine::Block in;
        in.channels = chunk->get_channel_count();
        in.rate = chunk->get_sample_rate();
        in.config = chunk->get_channel_config();
        in.samples.assign(chunk->get_data(), chunk->get_data() + chunk->get_used_size());
        std::vector<Engine::Block> out;
        m_engine.process(std::move(in), out);
        insert(out);
        publishIfChanged();
        return false;
    }

    void on_endofplayback(abort_callback &) override {
        std::vector<Engine::Block> out;
        m_engine.endOfStream(out);
        insert(out);
        publishIfChanged();
    }

    void on_endoftrack(abort_callback &) override {}

    void flush() override {
        // A fresh arm is for this seek; a stale one is dropped
        {
            Bridge &b = Bridge::get();
            std::lock_guard<std::mutex> guard(b.lock);
            if (b.armId != 0) {
                const double age = std::chrono::duration<double>(Clock::now() - b.armedAt).count();
                if (age <= beatloop::kArmTimeout) m_engine.arm(b.armId, b.armStart, b.armLength);
                b.armId = 0;
            }
        }
        m_engine.flush();
        m_lengthSerial = 0;
        publishIfChanged(true);
    }

    // May be asked from another thread: the held audio as of the last block
    double get_latency() override { return m_latency.load(std::memory_order_relaxed); }
    bool need_track_change_mark() override { return false; }

private:
    void takeRequests() {
        Bridge &b = Bridge::get();
        std::lock_guard<std::mutex> guard(b.lock);
        const uint64_t id = m_engine.boundId();
        if (id == 0) return;
        if (b.lengthId == id && b.lengthSerial != m_lengthSerial) {
            m_lengthSerial = b.lengthSerial;
            m_engine.setLength(b.length);
        }
        if (b.exitId == id && !m_exitTaken) {
            m_exitTaken = true;
            m_engine.requestExit();
        }
    }

    void insert(std::vector<Engine::Block> &blocks) {
        for (const Engine::Block &block : blocks) {
            if (block.frames() == 0) continue;
            audio_chunk *chunk = insert_chunk(block.samples.size());
            chunk->set_data(block.samples.data(), block.frames(), block.channels, block.rate, block.config);
        }
    }

    // The status for the view, when something it reads changed
    void publishIfChanged(bool force = false) {
        m_latency.store(m_engine.heldSeconds(), std::memory_order_relaxed);
        const bool looping = m_engine.phase() == Engine::Recording || m_engine.phase() == Engine::Repeating;
        const size_t segments = m_engine.timeline().size();
        if (!force && m_engine.boundId() == m_publishedId && looping == m_publishedLooping &&
            segments == m_publishedSegments && m_engine.rate() == m_publishedRate) {
            return;
        }
        if (m_engine.boundId() != m_publishedId) m_exitTaken = false;
        m_publishedId = m_engine.boundId();
        m_publishedLooping = looping;
        m_publishedSegments = segments;
        m_publishedRate = m_engine.rate();
        Bridge &b = Bridge::get();
        std::lock_guard<std::mutex> guard(b.lock);
        b.status.id = m_engine.boundId();
        b.status.flushedAway = m_engine.flushedAway();
        b.status.looping = looping;
        b.status.rate = m_engine.rate();
        b.status.start = m_engine.start();
        b.status.timeline = m_engine.timeline();
    }

    Engine m_engine;
    std::atomic<double> m_latency{ 0.0 };
    uint64_t m_lengthSerial = 0;
    bool m_exitTaken = false;
    uint64_t m_publishedId = 0;
    bool m_publishedLooping = false;
    size_t m_publishedSegments = 0;
    unsigned m_publishedRate = 0;
};

dsp_factory_nopreset_t<dsp_beat_loop> g_beat_loop_factory;

visualisation_stream::ptr g_clock;

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

uint64_t arm(double start, double length) {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    b.armId = ++b.nextId;
    b.armStart = start;
    b.armLength = length;
    b.armedAt = Clock::now();
    return b.armId;
}

void setLength(uint64_t id, double length) {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    if (b.armId == id) b.armLength = length;   // not bound yet
    b.lengthId = id;
    b.length = length;
    b.lengthSerial++;
}

void exit(uint64_t id) {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    if (b.armId == id) b.armId = 0;   // never bound: nothing to leave
    b.exitId = id;
}

Status status() {
    Bridge &b = Bridge::get();
    std::lock_guard<std::mutex> guard(b.lock);
    return b.status;
}

double playedSinceSeek() {
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

} // namespace beatloop
