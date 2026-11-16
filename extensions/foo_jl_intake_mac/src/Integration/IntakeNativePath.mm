//
//  IntakeNativePath.mm
//  foo_jl_intake
//

#include "IntakeNativePath.h"

#include "../Core/IntakeLog.h"
#include "../Core/IntakeSlowVolumeGuard.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <strings.h>

namespace intake {

namespace {

constexpr const char kFileScheme[] = "file://";
constexpr const char kMacVolumeScheme[] = "mac-volume://";

bool hasPrefixIgnoringCase(const char *path, const char *prefix, size_t length) {
    return strncasecmp(path, prefix, length) == 0;
}

// Leaked on purpose: decorate() may still run while static destructors do.
SlowVolumeGuard &slowVolumes() {
    static SlowVolumeGuard *guard = new SlowVolumeGuard();
    return *guard;
}

} // anonymous namespace

const char *intakeNativePath(const char *path, pfc::string_base &scratch, NativePathMenuBudget *menuBudget,
                             bool *refused) {
    if (refused != nullptr) *refused = false;
    if (path == nullptr || path[0] == '\0') return nullptr;
    if (path[0] == '/') return path;
    if (hasPrefixIgnoringCase(path, kFileScheme, sizeof kFileScheme - 1)) return path;
    if (!hasPrefixIgnoringCase(path, kMacVolumeScheme, sizeof kMacVolumeScheme - 1)) return nullptr;

    SlowVolumeGuard &guard = slowVolumes();
    const std::string_view uuid = macVolumeUuid(path);
    if (guard.isSlow(uuid) || (menuBudget != nullptr && !menuBudget->allows(uuid))) {
        if (refused != nullptr) *refused = true;
        return nullptr;
    }
    const uint64_t generation = guard.generation();
    const auto start = std::chrono::steady_clock::now();
    // g_get_native_path catches the filesystem service's exceptions itself
    // and returns false (leaving the input in `scratch`) when it cannot
    // convert; the guard keeps any other throw off the host's queue.
    bool converted = false;
    try {
        converted = filesystem::g_get_native_path(path, scratch);
    } catch (...) {
        converted = false;
    }
    const uint64_t micros = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
    if (menuBudget != nullptr) menuBudget->note(uuid, micros);
    if (guard.noteCall(uuid, micros, generation)) {
        char line[256];
        snprintf(line, sizeof line,
                 "mac-volume %.*s: %d path conversions in a row took over %llu ms (the last %llu ms); its rows get "
                 "no tint until the next mount, unmount or Refresh",
                 static_cast<int>(uuid.size()), uuid.data(), kSlowCallsToMark,
                 static_cast<unsigned long long>(kSlowNativePathMicros / 1000),
                 static_cast<unsigned long long>(micros / 1000));
        logInfo(line);
    }
    if (!converted) return nullptr;
    const char *native = scratch.get_ptr();
    return native[0] == '/' ? native : nullptr;
}

bool resetSlowVolumes(const char *why) {
    SlowVolumeGuard &guard = slowVolumes();
    const size_t slow = guard.slowCount();
    guard.reset();
    if (slow) logInfo(std::string(why) + ": " + std::to_string(slow) + " slow mac-volume(s) get tints again");
    return slow != 0;
}

} // namespace intake
