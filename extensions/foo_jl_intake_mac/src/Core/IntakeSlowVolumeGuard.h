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
//  Policy: a conversion of a mac-volume://<UUID>/... path that takes more
//  than kSlowNativePathMicros (20 ms) is a slow call. When
//  kSlowCallsToMark (3) calls on one UUID in a row are slow, with no fast
//  call on that UUID between them, the UUID is remembered as slow, and
//  later rows of the same UUID get no match without calling the SDK, until
//  reset() (Integration calls it on every NSWorkspace mount or unmount
//  notification and on a user Refresh, then invalidates every row). A
//  single slow sample is not enough: S0 measured 1-15 us per call with no
//  I/O, so one 20 ms sample on a mounted volume is far more likely a
//  scheduling or paging stall than a stale UUID, and marking a share's
//  UUID untints most rows of the playlist. A stale UUID whose every call
//  blocks still costs at most three slow calls before it is marked.
//  noteCall() reports the marking of a UUID once per reset, so the caller
//  logs once per UUID.
//
//  A call that started before a reset and ends after it does not count: the
//  caller passes the generation() it read before the call, and a stale one
//  is ignored (the volume may just have been remounted).
//
//  Cost on the decorate path: while no UUID is slow and no slow call is
//  pending a streak, isSlow() and a fast noteCall() are one atomic load each
//  (acquire) and take no lock. Otherwise they lock one mutex around short
//  vectors (one entry per slow or suspect volume). The caller times the SDK
//  call itself (two steady_clock reads).
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
inline constexpr int kSlowCallsToMark = 3;

// The <UUID> of "mac-volume://<UUID>/<path>" (scheme ignoring ASCII case),
// or "" for another scheme or an empty UUID. Views `path`.
std::string_view macVolumeUuid(std::string_view path);

// The policy: a conversion this long marks its volume slow.
inline bool isSlowNativePathCall(uint64_t micros) {
    return micros > kSlowNativePathMicros;
}

// The main thread's allowance for one pass that maps many rows at once: a
// context menu, or the Delete sheet's census over every playlist (PLAN.md
// 3.2 and risk 6: no I/O-like stall on the main thread). Per UUID: after
// kSlowCallsToMark slow conversions of one UUID in this pass (counted, not
// necessarily in a row), the rest of the pass makes no call for that UUID,
// and its rows get no match (the census counts them unchecked). Other UUIDs
// are not affected: a stale volume met first no longer stops a fast one
// (UAT 2026-11-17: one slow conversion used to refuse every UUID not yet
// converted, 84,139 NAS rows on each Delete). Each stale UUID thus costs at
// most kSlowCallsToMark slow calls per pass, and every call is still
// reported to the guard above, which marks a UUID after kSlowCallsToMark
// slow calls in a row, so later passes skip it from the start. One per
// pass; not thread-safe (the main thread only).
class NativePathMenuBudget {
public:
    // The pass may call the SDK for a row of `uuid` (exact bytes).
    bool allows(std::string_view uuid) const;
    // A conversion for `uuid` took `micros`. True only when this call makes
    // the pass refuse `uuid` from now on (for one Debug line).
    bool note(std::string_view uuid, uint64_t micros);
    // Some UUID is refused in this pass.
    bool spent() const { return refusedCount_ > 0; }
    // Rows refused by allows() (for a log line).
    size_t skipped() const { return skipped_; }
    // Slow calls of `uuid` in this pass, and their total time.
    int slowCalls(std::string_view uuid) const;
    uint64_t slowMicros(std::string_view uuid) const;

private:
    struct Volume {
        std::string uuid;
        int slow = 0;
        uint64_t slowMicros = 0;
    };
    const Volume *find(std::string_view uuid) const;
    std::vector<Volume> volumes_;  // UUIDs with a slow call in this pass
    size_t refusedCount_ = 0;
    mutable size_t skipped_ = 0;
};

class SlowVolumeGuard {
public:
    // `uuid` was marked slow since the last reset (exact bytes).
    bool isSlow(std::string_view uuid) const;
    // Read before the SDK call and pass it to noteCall.
    uint64_t generation() const { return generation_.load(std::memory_order_acquire); }
    // One conversion of a path on `uuid` took `micros`, and started at
    // `generation`; call it for every conversion, fast or slow. True only
    // when this call newly marks the UUID slow.
    bool noteCall(std::string_view uuid, uint64_t micros, uint64_t generation);
    // Forgets every slow UUID and every streak (a mount or unmount
    // notification, a Refresh).
    void reset();
    size_t slowCount() const;

private:
    struct Streak {
        std::string uuid;
        int slowCalls = 0;
    };
    mutable std::mutex mutex_;
    std::vector<std::string> slow_;  // guarded by mutex_
    std::vector<Streak> streaks_;    // guarded by mutex_: suspects not yet marked
    std::atomic<bool> any_{false};
    std::atomic<bool> anyStreak_{false};
    std::atomic<uint64_t> generation_{0};
};

} // namespace intake
