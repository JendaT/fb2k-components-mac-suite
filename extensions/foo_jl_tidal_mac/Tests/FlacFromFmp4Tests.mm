//
//  FlacFromFmp4Tests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for the incremental fMP4 -> FLAC remux: header extraction from
//  dfLa, STREAMINFO length patching, payload copying across arbitrary input
//  growth, and rejection of malformed streams.
//

#include "../src/Core/FlacFromFmp4.h"
#include "TestHarness.h"

#include <string>
#include <vector>

using tidal::FlacFromFmp4;
typedef std::vector<uint8_t> Bytes;

static void putBE32(Bytes &b, uint32_t v) {
    b.push_back(uint8_t(v >> 24)); b.push_back(uint8_t(v >> 16));
    b.push_back(uint8_t(v >> 8)); b.push_back(uint8_t(v));
}

static Bytes box(const char *type, const Bytes &payload) {
    Bytes b;
    putBE32(b, uint32_t(8 + payload.size()));
    b.insert(b.end(), type, type + 4);
    b.insert(b.end(), payload.begin(), payload.end());
    return b;
}

static Bytes largeBox(const char *type, const Bytes &payload) {
    Bytes b;
    putBE32(b, 1);
    b.insert(b.end(), type, type + 4);
    uint64_t size = 16 + payload.size();
    putBE32(b, uint32_t(size >> 32));
    putBE32(b, uint32_t(size));
    b.insert(b.end(), payload.begin(), payload.end());
    return b;
}

static void append(Bytes &to, const Bytes &from) { to.insert(to.end(), from.begin(), from.end()); }

// A 34-byte STREAMINFO for the given rate and total-samples value.
static Bytes streamInfo(uint32_t sampleRate, uint64_t totalSamples) {
    Bytes si(34, 0);
    si[0] = 0x10; si[2] = 0x10;                  // block sizes 4096
    si[10] = uint8_t(sampleRate >> 12);
    si[11] = uint8_t(sampleRate >> 4);
    si[12] = uint8_t((sampleRate & 0x0F) << 4) | (1 << 1);  // 2 channels (chan-1 = 1)
    si[13] = uint8_t((23 & 0x0F) << 4) | uint8_t((totalSamples >> 32) & 0x0F);  // 24-bit
    si[14] = uint8_t(totalSamples >> 24); si[15] = uint8_t(totalSamples >> 16);
    si[16] = uint8_t(totalSamples >> 8);  si[17] = uint8_t(totalSamples);
    return si;
}

static Bytes metadataBlock(uint8_t type, bool last, const Bytes &data) {
    Bytes b;
    b.push_back(uint8_t(type | (last ? 0x80 : 0)));
    b.push_back(uint8_t(data.size() >> 16)); b.push_back(uint8_t(data.size() >> 8)); b.push_back(uint8_t(data.size()));
    append(b, data);
    return b;
}

// An init segment: ftyp, then a moov with the dfLa buried a few levels down
// behind sample-entry fields, as a real one is.
static Bytes initSegment(const Bytes &blocks) {
    Bytes dflaPayload = {0, 0, 0, 0};  // FullBox version + flags
    append(dflaPayload, blocks);
    Bytes sampleEntry(28, 0);          // AudioSampleEntry fields
    append(sampleEntry, box("dfLa", dflaPayload));
    Bytes stsd = {0, 0, 0, 0, 0, 0, 0, 1};
    append(stsd, box("fLaC", sampleEntry));
    Bytes moov = box("mvhd", Bytes(100, 0));
    append(moov, box("trak", box("mdia", box("minf", box("stbl", box("stsd", stsd))))));

    Bytes out = box("ftyp", {'i', 's', 'o', '6', 0, 0, 0, 0});
    append(out, box("moov", moov));
    return out;
}

static Bytes mediaSegment(const Bytes &frames) {
    Bytes out = box("styp", {'m', 's', 'd', 'h'});
    append(out, box("moof", Bytes(40, 7)));
    append(out, box("mdat", frames));
    return out;
}

static Bytes drain(FlacFromFmp4 &r, const Bytes &src, bool complete, size_t cap, FlacFromFmp4::Status *last) {
    Bytes out;
    std::vector<uint8_t> buf(cap);
    for (;;) {
        size_t w = 0;
        *last = r.produce(src.data(), src.size(), complete, buf.data(), cap, &w);
        out.insert(out.end(), buf.begin(), buf.begin() + w);
        if (*last != FlacFromFmp4::Status::Progress) return out;
    }
}

static Bytes expectedHeader(const Bytes &si) {
    Bytes h = {'f', 'L', 'a', 'C'};
    append(h, metadataBlock(0, true, si));
    return h;
}

static void testWholeStream(void) {
    Bytes frames1(500, 0xA1), frames2(300, 0xB2);
    Bytes src = initSegment(metadataBlock(0, true, streamInfo(96000, 0)));
    append(src, mediaSegment(frames1));
    append(src, mediaSegment(frames2));

    FlacFromFmp4 r(1234567, 96000);
    FlacFromFmp4::Status st;
    Bytes out = drain(r, src, true, 4096, &st);

    Bytes want = expectedHeader(streamInfo(96000, 1234567));
    append(want, frames1);
    append(want, frames2);
    CHECK(st == FlacFromFmp4::Status::End, "complete input ends cleanly (%s)", r.error().c_str());
    CHECK(out == want, "fLaC + STREAMINFO with the manifest length + both payloads, in order");
}

static void testGrowingInput(void) {
    Bytes frames1(700, 0x11), frames2(900, 0x22);
    Bytes full = initSegment(metadataBlock(0, true, streamInfo(44100, 0)));
    append(full, mediaSegment(frames1));
    append(full, largeBox("mdat", frames2));  // 64-bit size form

    // The source arrives a few bytes at a time and is drained through a small
    // buffer, so every state boundary is hit mid-box at least once.
    FlacFromFmp4 r(5000, 44100);
    Bytes out;
    bool sawNeedMore = false;
    std::vector<uint8_t> buf(13);
    for (size_t avail = 0; avail <= full.size(); avail += 5) {
        size_t have = std::min(avail, full.size());
        Bytes prefix(full.begin(), full.begin() + have);
        bool complete = (have == full.size());
        for (;;) {
            size_t w = 0;
            auto st = r.produce(prefix.data(), prefix.size(), complete, buf.data(), buf.size(), &w);
            out.insert(out.end(), buf.begin(), buf.begin() + w);
            if (st == FlacFromFmp4::Status::NeedMoreInput) { sawNeedMore = true; break; }
            if (st != FlacFromFmp4::Status::Progress) {
                CHECK(st == FlacFromFmp4::Status::End, "growing input ends cleanly (%s)", r.error().c_str());
                break;
            }
        }
        if (complete) break;
    }
    if (full.size() % 5 != 0) {
        // The loop above stops short of the exact end on a non-multiple; finish.
        FlacFromFmp4::Status st;
        Bytes rest = drain(r, full, true, 13, &st);
        out.insert(out.end(), rest.begin(), rest.end());
    }

    Bytes want = expectedHeader(streamInfo(44100, 5000));
    append(want, frames1);
    append(want, frames2);
    CHECK(sawNeedMore, "waits for input rather than failing while the source grows");
    CHECK(out == want, "byte-at-a-time growth produces the same stream as all-at-once");
}

static void testLengthPatching(void) {
    // A length already present is kept.
    Bytes src = initSegment(metadataBlock(0, true, streamInfo(48000, 777)));
    append(src, mediaSegment(Bytes(10, 1)));
    FlacFromFmp4 keep(999999, 48000);
    FlacFromFmp4::Status st;
    Bytes out = drain(keep, src, true, 4096, &st);
    Bytes want = expectedHeader(streamInfo(48000, 777));
    CHECK(Bytes(out.begin(), out.begin() + want.size()) == want, "non-zero total samples left alone");

    // A manifest in another timescale is rescaled to the stream's rate.
    src = initSegment(metadataBlock(0, true, streamInfo(96000, 0)));
    append(src, mediaSegment(Bytes(10, 1)));
    FlacFromFmp4 rescale(1000, 1000);  // one second
    out = drain(rescale, src, true, 4096, &st);
    want = expectedHeader(streamInfo(96000, 96000));
    CHECK(Bytes(out.begin(), out.begin() + want.size()) == want, "1000 ticks at 1 kHz = 96000 samples at 96 kHz");

    // No manifest length: stays 0 (unknown) instead of a guess.
    src = initSegment(metadataBlock(0, true, streamInfo(44100, 0)));
    append(src, mediaSegment(Bytes(10, 1)));
    FlacFromFmp4 unknown;
    out = drain(unknown, src, true, 4096, &st);
    want = expectedHeader(streamInfo(44100, 0));
    CHECK(Bytes(out.begin(), out.begin() + want.size()) == want, "no manifest length -> left at 0");
}

static void testMetadataBlocks(void) {
    // STREAMINFO, a VORBIS_COMMENT kept, and a trailing SEEKTABLE dropped:
    // the last-block flag must move to the comment block.
    Bytes comment = {1, 2, 3, 4, 5};
    Bytes blocks = metadataBlock(0, false, streamInfo(44100, 10));
    append(blocks, metadataBlock(4, false, comment));
    append(blocks, metadataBlock(3, true, Bytes(18, 0)));
    Bytes src = initSegment(blocks);
    append(src, mediaSegment(Bytes(4, 9)));

    FlacFromFmp4 r(10, 44100);
    FlacFromFmp4::Status st;
    Bytes out = drain(r, src, true, 4096, &st);

    Bytes want = {'f', 'L', 'a', 'C'};
    append(want, metadataBlock(0, false, streamInfo(44100, 10)));
    append(want, metadataBlock(4, true, comment));
    append(want, Bytes(4, 9));
    CHECK(st == FlacFromFmp4::Status::End, "multi-block header ends cleanly");
    CHECK(out == want, "SEEKTABLE dropped, last-block flag moved to the new last block");
}

static void testMalformed(void) {
    FlacFromFmp4::Status st;

    Bytes noInit = mediaSegment(Bytes(10, 1));
    FlacFromFmp4 a;
    drain(a, noInit, true, 4096, &st);
    CHECK(st == FlacFromFmp4::Status::Error, "media before any moov is rejected");

    Bytes noDfla = box("moov", box("mvhd", Bytes(100, 0)));
    append(noDfla, mediaSegment(Bytes(10, 1)));
    FlacFromFmp4 b;
    drain(b, noDfla, true, 4096, &st);
    CHECK(st == FlacFromFmp4::Status::Error, "moov without dfLa is rejected (not FLAC)");

    Bytes truncated = initSegment(metadataBlock(0, true, streamInfo(44100, 0)));
    append(truncated, mediaSegment(Bytes(100, 1)));
    truncated.resize(truncated.size() - 10);
    FlacFromFmp4 c;
    drain(c, truncated, true, 4096, &st);
    CHECK(st == FlacFromFmp4::Status::Error, "an mdat cut short at end of input is an error");
    drain(c, truncated, true, 4096, &st);
    CHECK(st == FlacFromFmp4::Status::Error, "and stays an error on later calls");

    Bytes empty;
    FlacFromFmp4 d;
    drain(d, empty, false, 4096, &st);
    CHECK(st == FlacFromFmp4::Status::NeedMoreInput, "no input yet -> wait, not fail");
}

int main(void) {
    testWholeStream();
    testGrowingInput();
    testLengthPatching();
    testMetadataBlocks();
    testMalformed();
    return testHarnessFinish("FlacFromFmp4");
}
