//
//  cfg_var_legacy_stubs.cpp
//  foo_wave_seekbar_mac
//
//  Provides static member definitions for cfg_var_legacy types
//  when the SDK was built without FOOBAR2000_HAVE_CFG_VAR_LEGACY
//

#include "../fb2k_sdk.h"

// Note: These stubs are needed regardless of FOOBAR2000_HAVE_CFG_VAR_LEGACY
// because the SDK headers declare cfg_var_legacy but may not provide static definitions

namespace cfg_var_legacy {
    // Static member definitions
    cfg_var_reader* cfg_var_reader::g_list = nullptr;
    cfg_var_writer* cfg_var_writer::g_list = nullptr;

    // Required method implementations
    void cfg_var_reader::config_read_file(stream_reader* p_stream, abort_callback& p_abort) {
        pfc::map_t<GUID, cfg_var_reader*> vars;
        for (cfg_var_reader* walk = g_list; walk != nullptr; walk = walk->m_next) {
            vars.set(walk->m_guid, walk);
        }
        for (;;) {
            GUID guid;
            t_uint32 size;

            if (p_stream->read(&guid, sizeof(guid), p_abort) != sizeof(guid)) break;
            guid = pfc::byteswap_if_be_t(guid);
            p_stream->read_lendian_t(size, p_abort);

            auto iter = vars.find(guid);
            if (iter.is_valid()) {
                stream_reader_limited_ref wrapper(p_stream, size);
                try {
                    iter->m_value->set_data_raw(&wrapper, size, p_abort);
                } catch (exception_io_data const&) {}
                wrapper.flush_remaining(p_abort);
            } else {
                p_stream->skip_object(size, p_abort);
            }
        }
    }

    void cfg_var_writer::config_write_file(stream_writer* p_stream, abort_callback& p_abort) {
        cfg_var_writer* ptr;
        pfc::array_t<t_uint8, pfc::alloc_fast_aggressive> temp;
        for (ptr = g_list; ptr; ptr = ptr->m_next) {
            temp.set_size(0);
            {
                stream_writer_buffer_append_ref_t<pfc::array_t<t_uint8, pfc::alloc_fast_aggressive>> stream(temp);
                ptr->get_data_raw(&stream, p_abort);
            }
            p_stream->write_lendian_t(ptr->m_guid, p_abort);
            p_stream->write_lendian_t(pfc::downcast_guarded<t_uint32>(temp.get_size()), p_abort);
            if (temp.get_size() > 0) {
                p_stream->write_object(temp.get_ptr(), temp.get_size(), p_abort);
            }
        }
    }

    void cfg_string::get_data_raw(stream_writer* p_stream, abort_callback& p_abort) {
        p_stream->write_object(get_ptr(), length(), p_abort);
    }

    void cfg_string::set_data_raw(stream_reader* p_stream, t_size p_sizehint, abort_callback& p_abort) {
        (void)p_sizehint;
        pfc::string8_fastalloc temp;
        p_stream->read_string_raw(temp, p_abort);
        set_string(temp);
    }
}
