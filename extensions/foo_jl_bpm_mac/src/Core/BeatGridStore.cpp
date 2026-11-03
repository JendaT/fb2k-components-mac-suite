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
constexpr uint32_t kMaxSections = 1u << 16;
constexpr size_t kRegionBytes = 24, kBarBytes = 4, kSectionBytes = 38;   // 3 doubles, 2 int8, float, 2 uint32

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
        out.regions.push_back({ r.startSeconds, r.beatSeconds, r.beatCount, r.quiet || r.unsure ? jl_region_quiet : 0u });
    }
    out.bars = grid.bars;
    for (const GridSection &g : grid.sections) {
        jl_grid_section s{};
        s.start_seconds = g.startSeconds;
        s.bpm = g.bpm;
        s.anchor_seconds = g.anchorSeconds;
        s.bar_phase = g.barPhase;
        s.phrase_phase_bars = g.phrasePhaseBars;
        s.phrase_confidence = g.phraseConfidence;
        s.first_bar = static_cast<uint32_t>(out.sectionBars.size());
        s.bar_count = static_cast<uint32_t>(g.bars.size());
        out.sections.push_back(s);
        out.sectionBars.insert(out.sectionBars.end(), g.bars.begin(), g.bars.end());
    }
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
    w.put(static_cast<uint32_t>(grid.sections.size()));
    w.put(static_cast<uint32_t>(grid.sectionBars.size()));
    for (const jl_beat_region &r : grid.regions) {
        w.put(r.start_seconds);
        w.put(r.beat_seconds);
        w.put(r.beat_count);
        w.put(r.flags);
    }
    auto putBar = [&](const jl_bar_stat &b) {
        w.put(b.offset_ms);
        w.put(b.matched);
        w.put(b.pulse);
        w.put(b.flags);
    };
    for (const jl_bar_stat &b : grid.bars) putBar(b);
    for (const jl_grid_section &g : grid.sections) {
        w.put(g.start_seconds);
        w.put(g.bpm);
        w.put(g.anchor_seconds);
        w.put(g.bar_phase);
        w.put(g.phrase_phase_bars);
        w.put(g.phrase_confidence);
        w.put(g.first_bar);
        w.put(g.bar_count);
    }
    for (const jl_bar_stat &b : grid.sectionBars) putBar(b);
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
    uint32_t regions = 0, bars = 0, sections = 0, sectionBars = 0;
    if (!r.get(s.bpm) || !r.get(s.anchor_seconds) || !r.get(s.tempo_strength) || !r.get(s.bar_phase) ||
        !r.get(s.phrase_phase_bars) || !r.get(s.phrase_confidence) || !r.get(s.source) || !r.get(regions) ||
        !r.get(bars) || !r.get(sections) || !r.get(sectionBars)) {
        return std::nullopt;
    }
    if (!(s.bpm > 0.0) || !std::isfinite(s.bpm) || !std::isfinite(s.anchor_seconds) || regions > kMaxRegions ||
        bars > kMaxBars || sections > kMaxSections || sectionBars > kMaxBars ||
        r.remaining() != regions * kRegionBytes + bars * kBarBytes + sections * kSectionBytes +
                             sectionBars * kBarBytes) {
        return std::nullopt;
    }
    out.regions.resize(regions);
    for (jl_beat_region &g : out.regions) {
        r.get(g.start_seconds);
        r.get(g.beat_seconds);
        r.get(g.beat_count);
        r.get(g.flags);
    }
    auto getBar = [&](jl_bar_stat &b) {
        r.get(b.offset_ms);
        r.get(b.matched);
        r.get(b.pulse);
        r.get(b.flags);
    };
    out.bars.resize(bars);
    for (jl_bar_stat &b : out.bars) getBar(b);
    out.sections.resize(sections);
    uint32_t nextBar = 0;
    for (jl_grid_section &g : out.sections) {
        g = jl_grid_section{};
        r.get(g.start_seconds);
        r.get(g.bpm);
        r.get(g.anchor_seconds);
        r.get(g.bar_phase);
        r.get(g.phrase_phase_bars);
        r.get(g.phrase_confidence);
        r.get(g.first_bar);
        r.get(g.bar_count);
        // In order, back to back over the sections' bars
        if (!(g.bpm > 0.0) || !std::isfinite(g.bpm) || !std::isfinite(g.anchor_seconds) ||
            !std::isfinite(g.start_seconds) || g.first_bar != nextBar || g.bar_count > sectionBars - nextBar) {
            return std::nullopt;
        }
        nextBar += g.bar_count;
    }
    if (nextBar != sectionBars) return std::nullopt;
    out.sectionBars.resize(sectionBars);
    for (jl_bar_stat &b : out.sectionBars) getBar(b);
    return out;
}

bool sectionsOf(const StoredGrid &grid, std::vector<jl_grid_section> &sections, std::vector<jl_bar_stat> &bars) {
    sections.clear();
    bars.clear();
    if (!grid.available) return false;
    if (grid.sections.empty()) {
        sections.push_back(jl_master_section(grid.summary, grid.bars.size()));
        bars = grid.bars;
    } else {
        sections = grid.sections;
        bars = grid.sectionBars;
    }
    return true;
}

double lockedShare(const std::vector<jl_bar_stat> &bars) {
    if (bars.empty()) return 0.0;
    size_t locked = 0;
    for (const jl_bar_stat &b : bars) locked += jl_classify_phrase(&b, 1) == jl_phrase_locked;
    return static_cast<double>(locked) / static_cast<double>(bars.size());
}

} // namespace bpm
