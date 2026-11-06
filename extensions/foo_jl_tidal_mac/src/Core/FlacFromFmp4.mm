//
//  FlacFromFmp4.mm
//  foo_jl_tidal_mac
//

#include "FlacFromFmp4.h"

#include <algorithm>
#include <cstring>

namespace tidal {

namespace {

uint32_t be32(const uint8_t *p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

uint64_t be64(const uint8_t *p) {
    return (uint64_t(be32(p)) << 32) | be32(p + 4);
}

bool isType(const uint8_t *p, const char *fourcc) {
    return std::memcmp(p, fourcc, 4) == 0;
}

constexpr uint8_t kBlockStreamInfo = 0;
constexpr uint8_t kBlockSeekTable = 3;
constexpr uint32_t kStreamInfoLength = 34;
constexpr uint64_t kMaxTotalSamples = (uint64_t(1) << 36) - 1;

}  // namespace

FlacFromFmp4::FlacFromFmp4(uint64_t duration, uint64_t timescale)
    : m_duration(duration), m_timescale(timescale) {}

FlacFromFmp4::Status FlacFromFmp4::fail(const char *why) {
    m_error = why;
    m_state = State::Done;
    return Status::Error;
}

// Finds the dfLa box in the moov payload and turns it into a FLAC stream
// header. dfLa is a FullBox (4 bytes of version and flags) holding the FLAC
// metadata blocks verbatim, STREAMINFO first.
bool FlacFromFmp4::buildHeader(const uint8_t *moov, size_t len) {
    // Searching by fourcc instead of walking trak/mdia/minf/stbl/stsd/fLaC:
    // the path has six levels of version-dependent sample-entry layout, and an
    // init segment holds nothing else that could spell "dfLa" with a box size
    // in front of it that fits.
    const uint8_t *dfla = nullptr;
    size_t dflaLen = 0;
    for (size_t i = 4; i + 4 <= len; i++) {
        if (!isType(moov + i, "dfLa")) continue;
        uint32_t size = be32(moov + i - 4);
        if (size < 8 + 4 + 4 + kStreamInfoLength || i - 4 + size > len) continue;
        dfla = moov + i + 4 + 4;  // past the type and the FullBox header
        dflaLen = size - 8 - 4;
        break;
    }
    if (!dfla) return false;

    // Copy the blocks, dropping any SEEKTABLE: its offsets describe a file
    // that never existed. The last-block flag is recomputed for the same
    // reason a dropped block could have been the one carrying it.
    std::vector<std::pair<size_t, size_t>> blocks;  // offset, total length
    size_t pos = 0;
    while (pos + 4 <= dflaLen) {
        uint8_t type = dfla[pos] & 0x7F;
        bool last = (dfla[pos] & 0x80) != 0;
        uint32_t blockLen = (uint32_t(dfla[pos + 1]) << 16) | (uint32_t(dfla[pos + 2]) << 8) | dfla[pos + 3];
        if (pos + 4 + blockLen > dflaLen) return false;
        if (blocks.empty() && (type != kBlockStreamInfo || blockLen != kStreamInfoLength)) return false;
        if (type != kBlockSeekTable) blocks.emplace_back(pos, 4 + blockLen);
        pos += 4 + blockLen;
        if (last) break;
    }
    if (blocks.empty()) return false;

    m_header.assign({'f', 'L', 'a', 'C'});
    for (size_t b = 0; b < blocks.size(); b++) {
        size_t start = m_header.size();
        m_header.insert(m_header.end(), dfla + blocks[b].first, dfla + blocks[b].first + blocks[b].second);
        m_header[start] = (m_header[start] & 0x7F) | (b + 1 == blocks.size() ? 0x80 : 0x00);
    }

    // STREAMINFO bytes 10..17 (after the 4-byte block header): sample rate
    // (20 bits), channels-1 (3), bits-1 (5), total samples (36).
    uint8_t *si = m_header.data() + 4 + 4;
    uint32_t sampleRate = (uint32_t(si[10]) << 12) | (uint32_t(si[11]) << 4) | (si[12] >> 4);
    uint64_t total = (uint64_t(si[13] & 0x0F) << 32) | be32(si + 14);
    if (total == 0 && m_duration > 0 && m_timescale > 0 && sampleRate > 0) {
        uint64_t samples = (m_timescale == sampleRate)
            ? m_duration
            : (uint64_t)((long double)m_duration * sampleRate / m_timescale);
        if (samples <= kMaxTotalSamples) {
            si[13] = (si[13] & 0xF0) | uint8_t((samples >> 32) & 0x0F);
            si[14] = uint8_t(samples >> 24);
            si[15] = uint8_t(samples >> 16);
            si[16] = uint8_t(samples >> 8);
            si[17] = uint8_t(samples);
        }
    }
    m_haveHeader = true;
    m_headerPos = 0;
    return true;
}

FlacFromFmp4::Status FlacFromFmp4::produce(const uint8_t *src, size_t avail, bool complete,
                                           uint8_t *dst, size_t cap, size_t *written) {
    *written = 0;
    auto settle = [&](Status idle) { return *written > 0 ? Status::Progress : idle; };

    for (;;) {
        if (*written == cap) return Status::Progress;

        if (m_headerPos < m_header.size()) {
            size_t n = std::min(cap - *written, m_header.size() - m_headerPos);
            std::memcpy(dst + *written, m_header.data() + m_headerPos, n);
            m_headerPos += n;
            *written += n;
            continue;
        }

        switch (m_state) {
        case State::Done:
            return settle(m_error.empty() ? Status::End : Status::Error);

        case State::BoxHeader: {
            if (m_src >= avail) {
                if (!complete) return settle(Status::NeedMoreInput);
                if (!m_haveHeader) return fail("stream ended before the FLAC header (no moov/dfLa)");
                m_state = State::Done;
                continue;
            }
            if (avail - m_src < 8) {
                if (complete) return fail("truncated box header");
                return settle(Status::NeedMoreInput);
            }
            const uint8_t *h = src + m_src;
            uint64_t size = be32(h);
            uint64_t headerLen = 8;
            if (size == 1) {
                if (avail - m_src < 16) {
                    if (complete) return fail("truncated large box header");
                    return settle(Status::NeedMoreInput);
                }
                size = be64(h + 8);
                headerLen = 16;
            } else if (size == 0) {
                // "Extends to the end of the file": only knowable once it has ended.
                if (!complete) return settle(Status::NeedMoreInput);
                size = avail - m_src;
            }
            if (size < headerLen) return fail("box smaller than its own header");
            uint64_t end = m_src + size;

            if (isType(h + 4, "moov")) {
                if (end > avail) {
                    if (complete) return fail("truncated moov");
                    return settle(Status::NeedMoreInput);
                }
                if (m_haveHeader) return fail("second moov");
                if (!buildHeader(h + headerLen, size_t(size - headerLen))) {
                    return fail("moov carries no usable FLAC metadata (dfLa)");
                }
                m_src = end;
                continue;
            }
            if (isType(h + 4, "mdat")) {
                if (!m_haveHeader) return fail("media data before the FLAC header");
                m_src += headerLen;
                m_boxEnd = end;
                m_state = State::Payload;
                continue;
            }
            // ftyp, styp, sidx, moof, free...: nothing FLAC needs.
            m_src += headerLen;
            m_boxEnd = end;
            m_state = State::Skip;
            continue;
        }

        case State::Skip:
            if (avail >= m_boxEnd) {
                m_src = m_boxEnd;
                m_state = State::BoxHeader;
                continue;
            }
            m_src = avail;
            if (complete) return fail("truncated box");
            return settle(Status::NeedMoreInput);

        case State::Payload: {
            uint64_t ready = std::min<uint64_t>(avail, m_boxEnd);
            if (m_src < ready) {
                size_t n = (size_t)std::min<uint64_t>(cap - *written, ready - m_src);
                std::memcpy(dst + *written, src + m_src, n);
                m_src += n;
                *written += n;
                continue;
            }
            if (m_src == m_boxEnd) {
                m_state = State::BoxHeader;
                continue;
            }
            if (complete) return fail("truncated mdat");
            return settle(Status::NeedMoreInput);
        }
        }
    }
}

} // namespace tidal
