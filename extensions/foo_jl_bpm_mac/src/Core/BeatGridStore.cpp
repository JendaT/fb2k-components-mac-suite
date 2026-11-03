//
//  BeatGridStore.cpp
//  foo_jl_bpm_mac
//

#include "BeatGridStore.h"

#include <cmath>
#include <cstring>

namespace bpm {

namespace {

const char kMagic[4] = { 'J', 'L', 'B', 'G' };
// Sanity bounds for a damaged blob: a day-long track at 300 BPM has ~108k bars
constexpr uint32_t kMaxBars = 1u << 20;
constexpr uint32_t kMaxRegions = 1u << 20;

class Writer {
public:
    std::vector<uint8_t> bytes;
    template <typename T> void put(T value) {
        uint8_t raw[sizeof(T)];
        std::memcpy(raw, &value, sizeof(T));   // little-endian hosts (arm64, x86_64)
        bytes.insert(bytes.end(), raw, raw + sizeof(T));
    }
};

class Reader {
public:
    Reader(const uint8_t *data, size_t size) : m_data(data), m_size(size) {}
    template <typename T> bool get(T &value) {
        if (m_size - m_offset < sizeof(T)) return false;
        std::memcpy(&value, m_data + m_offset, sizeof(T));
        m_offset += sizeof(T);
        return true;
    }
    size_t remaining() const { return m_size - m_offset; }
private:
    const uint8_t *m_data;
    size_t m_size;
    size_t m_offset = 0;
};

} // namespace

StoredGrid toStored(const BeatGrid &grid) {
    StoredGrid out;
    out.available = grid.valid;
    if (!grid.valid) return out;
    out.summary.bpm = grid.bpm;
    out.summary.anchor_seconds = grid.anchorSeconds;
    out.summary.tempo_strength = grid.tempoStrength;
    out.summary.bar_phase = grid.barPhase;
    out.summary.phrase_phase_bars = grid.phrasePhaseBars;
    out.summary.phrase_confidence = grid.phraseConfidence;
    out.summary.source = static_cast<uint8_t>(grid.source);
    for (const BeatRegion &r : grid.regions) {
        out.regions.push_back({ r.startSeconds, r.beatSeconds, r.beatCount, r.quiet ? jl_region_quiet : 0u });
    }
    out.bars = grid.bars;
    return out;
}

std::vector<uint8_t> encodeStoredGrid(const StoredGrid &grid) {
    Writer w;
    w.bytes.insert(w.bytes.end(), kMagic, kMagic + 4);
    w.put(kStoredGridVersion);
    w.put(static_cast<uint8_t>(grid.available ? 1 : 0));
    if (!grid.available) return w.bytes;
    const jl_beatgrid_summary &s = grid.summary;
    w.put(s.bpm);
    w.put(s.anchor_seconds);
    w.put(s.tempo_strength);
    w.put(s.bar_phase);
    w.put(s.phrase_phase_bars);
    w.put(s.phrase_confidence);
    w.put(s.source);
    w.put(static_cast<uint32_t>(grid.regions.size()));
    w.put(static_cast<uint32_t>(grid.bars.size()));
    for (const jl_beat_region &r : grid.regions) {
        w.put(r.start_seconds);
        w.put(r.beat_seconds);
        w.put(r.beat_count);
        w.put(r.flags);
    }
    for (const jl_bar_stat &b : grid.bars) {
        w.put(b.offset_ms);
        w.put(b.matched);
        w.put(b.pulse);
        w.put(b.flags);
    }
    return w.bytes;
}

std::optional<StoredGrid> decodeStoredGrid(const uint8_t *data, size_t size) {
    if (!data || size < 9 || std::memcmp(data, kMagic, 4) != 0) return std::nullopt;
    Reader r(data + 4, size - 4);
    uint32_t version = 0;
    uint8_t available = 0;
    if (!r.get(version) || version != kStoredGridVersion || !r.get(available) || available > 1) return std::nullopt;
    StoredGrid out;
    out.available = available == 1;
    if (!out.available) return r.remaining() == 0 ? std::optional<StoredGrid>(out) : std::nullopt;

    jl_beatgrid_summary &s = out.summary;
    uint32_t regions = 0, bars = 0;
    if (!r.get(s.bpm) || !r.get(s.anchor_seconds) || !r.get(s.tempo_strength) || !r.get(s.bar_phase) ||
        !r.get(s.phrase_phase_bars) || !r.get(s.phrase_confidence) || !r.get(s.source) || !r.get(regions) ||
        !r.get(bars)) {
        return std::nullopt;
    }
    if (!(s.bpm > 0.0) || !std::isfinite(s.bpm) || !std::isfinite(s.anchor_seconds) || regions > kMaxRegions ||
        bars > kMaxBars || r.remaining() != static_cast<size_t>(regions) * 24 + static_cast<size_t>(bars) * 4) {
        return std::nullopt;
    }
    out.regions.resize(regions);
    for (jl_beat_region &g : out.regions) {
        r.get(g.start_seconds);
        r.get(g.beat_seconds);
        r.get(g.beat_count);
        r.get(g.flags);
    }
    out.bars.resize(bars);
    for (jl_bar_stat &b : out.bars) {
        r.get(b.offset_ms);
        r.get(b.matched);
        r.get(b.pulse);
        r.get(b.flags);
    }
    return out;
}

double lockedShare(const std::vector<jl_bar_stat> &bars) {
    if (bars.empty()) return 0.0;
    size_t locked = 0;
    for (const jl_bar_stat &b : bars) locked += jl_classify_phrase(&b, 1) == jl_phrase_locked;
    return static_cast<double>(locked) / static_cast<double>(bars.size());
}

} // namespace bpm
