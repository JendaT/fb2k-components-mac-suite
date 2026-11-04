//
//  TidalDashFlacFile.mm
//  foo_jl_tidal_mac
//

#import "TidalDashFlacFile.h"
#include <unistd.h>

namespace tidal {

// How often a read waiting on the download re-checks it. A segment is ~4s of
// audio, so this is far below anything audible and cheap on the lock.
static const useconds_t kWaitSliceUs = 20 * 1000;

void DashFlacFile::init(JLTidalDashStream *stream, uint64_t duration, uint64_t timescale) {
    m_stream = stream;
    m_duration = duration;
    m_timescale = timescale;
    restart();
}

void DashFlacFile::restart() {
    m_remux = std::make_unique<FlacFromFmp4>(m_duration, m_timescale);
    m_position = 0;
}

// file::read may only come back short at end of stream, so this waits for
// the download rather than returning what it has.
t_size DashFlacFile::read(void *p_buffer, t_size p_bytes, abort_callback &p_abort) {
    uint8_t *dst = (uint8_t *)p_buffer;
    t_size done = 0;
    while (done < p_bytes) {
        p_abort.check();
        __block FlacFromFmp4::Status status = FlacFromFmp4::Status::NeedMoreInput;
        __block size_t written = 0;
        __block BOOL failed = NO;
        FlacFromFmp4 *remux = m_remux.get();
        uint8_t *out = dst + done;
        size_t want = p_bytes - done;
        [m_stream withBytes:^(const uint8_t *bytes, NSUInteger length, BOOL complete, BOOL streamFailed) {
            failed = streamFailed;
            status = remux->produce(bytes, length, complete, out, want, &written);
        }];
        done += written;
        m_position += written;

        switch (status) {
        case FlacFromFmp4::Status::Progress:
            continue;
        case FlacFromFmp4::Status::End:
            return done;
        case FlacFromFmp4::Status::Error:
            pfc::throw_exception_with_message<exception_io_data>(
                ("Tidal DASH stream is not valid FLAC: " + m_remux->error()).c_str());
        case FlacFromFmp4::Status::NeedMoreInput:
            if (failed) {
                pfc::throw_exception_with_message<exception_io_data>("Tidal DASH download failed mid-track");
            }
            usleep(kWaitSliceUs);
            continue;
        }
    }
    return done;
}

void DashFlacFile::write(const void *, t_size, abort_callback &) {
    throw exception_io_denied();
}

t_filesize DashFlacFile::get_size(abort_callback &) {
    return filesize_invalid;  // unknown until the last segment lands
}

t_filesize DashFlacFile::get_position(abort_callback &) {
    return m_position;
}

void DashFlacFile::resize(t_filesize, abort_callback &) {
    throw exception_io_denied();
}

// Not advertised (can_seek is false), but a decoder probing the header may
// still rewind. The remux is deterministic, so any position is reachable by
// replaying from the start -- cheap, it is a memcpy over bytes already here.
void DashFlacFile::seek(t_filesize p_position, abort_callback &p_abort) {
    if (p_position < m_position) restart();
    uint8_t scratch[64 * 1024];
    while (m_position < p_position) {
        t_size step = (t_size)std::min<t_filesize>(sizeof(scratch), p_position - m_position);
        if (read(scratch, step, p_abort) < step) throw exception_io_seek_out_of_range();
    }
}

bool DashFlacFile::can_seek() { return false; }

bool DashFlacFile::get_content_type(pfc::string_base &p_out) {
    p_out = "audio/flac";
    return true;
}

void DashFlacFile::reopen(abort_callback &) {
    restart();
}

bool DashFlacFile::is_remote() { return true; }

t_filetimestamp DashFlacFile::get_timestamp(abort_callback &) {
    return filetimestamp_invalid;
}

} // namespace tidal
