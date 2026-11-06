//
//  TidalMemoryFile.mm
//  foo_jl_tidal_mac
//

#import "TidalMemoryFile.h"
#import "../Core/TidalConfig.h"

namespace tidal {

MemoryFile::MemoryFile()
    : m_data(nil)
    , m_position(0) {
}

void MemoryFile::initWithData(NSData *data, const char *contentType) {
    m_data = data;
    m_position = 0;
    m_contentType = contentType ? contentType : "application/octet-stream";
}

t_size MemoryFile::read(void *p_buffer, t_size p_bytes, abort_callback &p_abort) {
    p_abort.check();
    if (!m_data || p_bytes == 0) return 0;
    NSUInteger total = m_data.length;
    if (m_position >= total) return 0;
    NSUInteger available = (NSUInteger)(total - m_position);
    NSUInteger toRead = (available < (NSUInteger)p_bytes) ? available : (NSUInteger)p_bytes;
    memcpy(p_buffer, (const uint8_t *)m_data.bytes + (NSUInteger)m_position, toRead);
    m_position += toRead;
    return (t_size)toRead;
}

void MemoryFile::write(const void *, t_size, abort_callback &) {
    throw exception_io_denied();
}

t_filesize MemoryFile::get_size(abort_callback &) {
    return m_data ? (t_filesize)m_data.length : 0;
}

t_filesize MemoryFile::get_position(abort_callback &) {
    return m_position;
}

void MemoryFile::resize(t_filesize, abort_callback &) {
    throw exception_io_denied();
}

void MemoryFile::seek(t_filesize p_position, abort_callback &) {
    if (!m_data) throw exception_io_seek_out_of_range();
    if (p_position > (t_filesize)m_data.length) throw exception_io_seek_out_of_range();
    m_position = p_position;
}

bool MemoryFile::can_seek() { return true; }

bool MemoryFile::get_content_type(pfc::string_base &p_out) {
    p_out = m_contentType.c_str();
    return !m_contentType.empty();
}

void MemoryFile::reopen(abort_callback &) {
    m_position = 0;
}

bool MemoryFile::is_remote() { return false; }

t_filetimestamp MemoryFile::get_timestamp(abort_callback &) {
    return filetimestamp_invalid;
}

} // namespace tidal
