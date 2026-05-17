//
//  TidalMemoryFile.h
//  foo_jl_tidal_mac
//
//  In-memory fb2k `file` implementation backed by NSData.
//  Used to present an assembled DASH stream (init + media segments) to
//  fb2k's underlying decoder as if it were a single seekable file.
//

#pragma once

#include "../fb2k_sdk.h"
#import <Foundation/Foundation.h>

namespace tidal {

class MemoryFile : public file {
public:
    MemoryFile();

    // Must be called once before any IO. The data is retained.
    void initWithData(NSData *data, const char *contentType);

    // file interface
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
    __strong NSData *m_data;
    t_filesize m_position;
    std::string m_contentType;
};

} // namespace tidal
