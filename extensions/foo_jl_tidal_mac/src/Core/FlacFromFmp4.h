//
//  FlacFromFmp4.h
//  foo_jl_tidal_mac
//
//  Incremental remux of Tidal's DASH FLAC into a plain FLAC stream.
//
//  Tidal serves LOSSLESS and HI_RES_LOSSLESS as fragmented MP4: an init
//  segment whose moov carries the FLAC metadata in a dfLa box, then moof+mdat
//  pairs whose mdat payloads are whole FLAC frames (ISO/IEC 14496-12 with the
//  FLAC-in-ISOBMFF mapping). foobar2000's MP4 demuxer only opens such a file
//  once all of it is present, so a 245 MB 24/96 track could not start until
//  the last segment arrived. FLAC is a streaming format: "fLaC", the metadata
//  blocks, then the frames, and its decoder starts on the first frame.
//
//  Pure: no I/O, no foobar2000 SDK. The caller passes the source bytes
//  received so far -- a buffer that only ever grows -- and drains output.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace tidal {

class FlacFromFmp4 {
public:
    enum class Status {
        Progress,       // wrote at least one byte; call again for more
        NeedMoreInput,  // nothing more until the source grows
        End,            // the whole stream has been produced
        Error,          // malformed input; see error()
    };

    // The init segment of a stream that is still being written cannot know its
    // length, so STREAMINFO's total-samples field is 0 there. When it is, the
    // length is filled in from the manifest: `duration` in `timescale` units,
    // rescaled to the stream's sample rate. Pass 0 for either to leave it.
    FlacFromFmp4(uint64_t duration = 0, uint64_t timescale = 0);

    // Writes up to `cap` bytes of FLAC into `dst`. `src[0..avail)` is the whole
    // source so far; `complete` means no more will arrive. Offsets are
    // absolute, so `src` may move between calls (a reallocated buffer) as long
    // as its contents do not change.
    Status produce(const uint8_t *src, size_t avail, bool complete,
                   uint8_t *dst, size_t cap, size_t *written);

    const std::string &error() const { return m_error; }

private:
    enum class State { BoxHeader, Skip, Payload, Done };

    bool buildHeader(const uint8_t *moov, size_t len);
    Status fail(const char *why);

    uint64_t m_duration;
    uint64_t m_timescale;
    uint64_t m_src = 0;     // next unconsumed source byte
    uint64_t m_boxEnd = 0;  // end of the box being skipped or copied
    State m_state = State::BoxHeader;
    bool m_haveHeader = false;
    std::vector<uint8_t> m_header;  // "fLaC" + metadata, emitted once
    size_t m_headerPos = 0;
    std::string m_error;
};

} // namespace tidal
