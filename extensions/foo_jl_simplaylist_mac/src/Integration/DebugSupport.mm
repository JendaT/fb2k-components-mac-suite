//
//  DebugSupport.mm
//  foo_simplaylist_mac
//
//  Debug-build link support. The suite's SDK static libraries are built
//  Release-only (PFC_DEBUG=0), so they do not contain pfc::myassert, which
//  every PFC_ASSERT in a DEBUG=1 translation unit references. Without this
//  shim the Debug configuration cannot link. The definition is weak: if the
//  SDK libraries are ever built in a debug flavor, their strong definition
//  wins and this file becomes a no-op.
//

#if DEBUG

#import "../fb2k_sdk.h"

#include <cstdlib>

namespace pfc {

__attribute__((weak)) void myassert(const char *message, const char *file, unsigned line) {
    FB2K_console_formatter() << "[SimPlaylist] PFC_ASSERT failed: " << message
                             << " (" << file << ":" << line << ")";
    std::abort();
}

}  // namespace pfc

#endif  // DEBUG
