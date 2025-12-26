//
//  pfc_debug.cpp
//  foo_wave_seekbar_mac
//
//  Provides debug assertion support for Debug builds.
//  The pfc library is built without PFC_DEBUG, so we need to provide myassert.
//

#include "../fb2k_sdk.h"

#ifdef DEBUG

namespace pfc {

void myassert(const char* _Message, const char* _File, unsigned _Line) {
    // Log the assertion failure to foobar2000 console
    console::error("ASSERT FAILURE");

    pfc::string_formatter msg;
    msg << "Assertion: " << _Message;
    console::error(msg.c_str());

    pfc::string_formatter loc;
    loc << "Location: " << _File << ":" << _Line;
    console::error(loc.c_str());

    // Break into debugger if attached
#if defined(__arm64__) || defined(__aarch64__)
    __builtin_debugtrap();
#else
    __asm__("int $3");
#endif
}

} // namespace pfc

#endif // DEBUG
