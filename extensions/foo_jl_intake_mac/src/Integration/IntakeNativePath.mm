//
//  IntakeNativePath.mm
//  foo_jl_intake
//

#include "IntakeNativePath.h"

#include <cstring>
#include <strings.h>

namespace intake {

namespace {

constexpr const char kFileScheme[] = "file://";
constexpr const char kMacVolumeScheme[] = "mac-volume://";

bool hasPrefixIgnoringCase(const char *path, const char *prefix, size_t length) {
    return strncasecmp(path, prefix, length) == 0;
}

} // anonymous namespace

const char *intakeNativePath(const char *path, pfc::string_base &scratch) {
    if (path == nullptr || path[0] == '\0') return nullptr;
    if (path[0] == '/') return path;
    if (hasPrefixIgnoringCase(path, kFileScheme, sizeof kFileScheme - 1)) return path;
    if (!hasPrefixIgnoringCase(path, kMacVolumeScheme, sizeof kMacVolumeScheme - 1)) return nullptr;
    // g_get_native_path catches the filesystem service's exceptions itself
    // and returns false (leaving the input in `scratch`) when it cannot
    // convert; the guard keeps any other throw off the host's queue.
    try {
        if (!filesystem::g_get_native_path(path, scratch)) return nullptr;
    } catch (...) {
        return nullptr;
    }
    const char *native = scratch.get_ptr();
    return native[0] == '/' ? native : nullptr;
}

} // namespace intake
