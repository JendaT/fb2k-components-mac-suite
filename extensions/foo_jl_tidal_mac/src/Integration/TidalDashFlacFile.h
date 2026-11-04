//
//  TidalDashFlacFile.h
//  foo_jl_tidal_mac
//
//  A foobar2000 `file` that serves a DASH FLAC track as plain FLAC while it
//  is still downloading. Reads block until the bytes they need have arrived,
//  so the FLAC decoder starts on the first segment instead of the last.
//
//  Presented as a remote, non-seekable stream -- the same contract as an
//  HTTP FLAC stream -- so decoders do not seek to the end looking for tags,
//  which would wait for the whole download. Seeking within the track is
//  handled one level up, by TidalInputDecoder.
//

#pragma once

#include "../fb2k_sdk.h"
#include "../Core/FlacFromFmp4.h"
#import "TidalDashCache.h"
#include <memory>

namespace tidal {

class DashFlacFile : public file {
public:
    // `duration`/`timescale` give the remux the track length (see FlacFromFmp4).
    void init(JLTidalDashStream *stream, uint64_t duration, uint64_t timescale);

    t_size read(void *p_buffer, t_size p_bytes, abort_callback &p_abort) override;
    void write(const void *p_buffer, t_size p_bytes, abort_callback &p_abort) override;
    t_filesize get_size(abort_callback &p_abort) override;
    t_filesize get_position(abort_callback &p_abort) override;
    void resize(t_filesize p_size, abort_callback &p_abort) override;
    void seek(t_filesize p_position, abort_callback &p_abort) override;
    bool can_seek() override;
    bool get_content_type(pfc::string_base &p_out) override;
    void reopen(abort_callback &p_abort) override;
    bool is_remote() override;
    t_filetimestamp get_timestamp(abort_callback &p_abort) override;

private:
    void restart();

    __strong JLTidalDashStream *m_stream = nil;
    std::unique_ptr<FlacFromFmp4> m_remux;
    uint64_t m_duration = 0;
    uint64_t m_timescale = 0;
    t_filesize m_position = 0;
};

} // namespace tidal
