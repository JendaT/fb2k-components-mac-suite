#pragma once

#include "../fb2k_sdk.h"

namespace cloud_streamer {

// Link resolver for Mixcloud and SoundCloud URLs
// Converts web URLs to internal scheme for playlist handling
class CloudLinkResolver : public link_resolver {
public:
    // link_resolver interface
    bool is_our_path(const char* p_path, const char* p_extension) override;
    void resolve(service_ptr_t<file> p_filehint, const char* p_path,
                 pfc::string_base& p_out, abort_callback& p_abort) override;
};

} // namespace cloud_streamer
