//
//  IntakeSlowVolumeGuard.h
//  foo_jl_intake
//
//  The per-volume slow guard for mac-volume:// rows (PLAN.md B4; the open
//  B3 finding in IntakeNativePath.h). S0 measured g_get_native_path at about
//  1 us on mounted volumes, but never on a stale UUID or an unmounted share
//  (docs/VOLUME_UUID_ISSUE.md records timeouts for unresolvable UUIDs), and
//  decorate() must return promptly: SimPlaylist v2's shutdown waits for
//  in-flight batches.
//
//  Policy: when one conversion of a mac-volume://<UUID>/... path takes more
//  than kSlowNativePathMicros (20 ms), that UUID is remembered as slow, and
//  later rows of the same UUID get no match without calling the SDK, until
//  reset() (Integration calls it on every NSWorkspace mount or unmount
//  notification). noteCall() reports the first marking of a UUID per reset,
//  so the caller logs once per UUID.
//
//  A call that started before a reset and ends after it does not mark: the
//  caller passes the generation() it read before the call, and a stale one
//  is ignored (the volume may just have been remounted).
//
//  Cost on the decorate path: while no UUID is slow, isSlow() is one atomic
//  load (acquire) and takes no lock. Otherwise it locks one mutex around a
//  short vector (one entry per slow volume). The caller times the SDK call
//  itself (two steady_clock reads).
//
//  Thread-safety: every member may be called from any thread.
//

#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace intake {

inline constexpr uint64_t kSlowNativePathMicros = 20000;

// The <UUID> of "mac-volume://<UUID>/<path>" (scheme ignoring ASCII case),
// or "" for another scheme or an empty UUID. Views `path`.
std::string_view macVolumeUuid(std::string_view path);

// The policy: a conversion this long marks its volume slow.
inline bool isSlowNativePathCall(uint64_t micros) {
    return micros > kSlowNativePathMicros;
}

class SlowVolumeGuard {
public:
    // `uuid` was marked slow since the last reset (exact bytes).
    bool isSlow(std::string_view uuid) const;
    // Read before the SDK call and pass it to noteCall.
    uint64_t generation() const { return generation_.load(std::memory_order_acquire); }
    // One conversion of a path on `uuid` took `micros`, and started at
    // `generation`. True only when this call newly marks the UUID slow.
    bool noteCall(std::string_view uuid, uint64_t micros, uint64_t generation);
    // Forgets every slow UUID (a mount or unmount notification).
    void reset();
    size_t slowCount() const;

private:
    mutable std::mutex mutex_;
    std::vector<std::string> slow_;  // guarded by mutex_
    std::atomic<bool> any_{false};
    std::atomic<uint64_t> generation_{0};
};

} // namespace intake
