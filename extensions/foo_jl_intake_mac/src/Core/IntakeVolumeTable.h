//
//  IntakeVolumeTable.h
//  foo_jl_intake
//
//  foobar2000's volume ids for the title-formatting fields (B13 item 4):
//  "mac-volume://<UUID>/<rest>" -> the native path the view matches,
//  without calling the SDK. process_field may make no foobar2000 call other
//  than reading its handle (metadb_display_field_provider.h), so it cannot
//  convert with filesystem::g_get_native_path as decorate() does
//  (IntakeNativePath); this table stands in for that call.
//
//  <UUID> is foobar2000's own volume id, not the macOS volume UUID
//  (docs/VOLUME_UUID_ISSUE.md: it matches no identifier macOS exposes), so
//  the table is filled from foobar2000 itself (Integration,
//  IntakeFieldProvider):
//   - Seeded per mount under /Volumes, on a background queue:
//     g_get_canonical_path("<mount>/") gives "mac-volume://<UUID>/"
//     (volumeIdOfRoot), and g_get_native_path of that gives the volume root
//     as foobar2000 resolves it (volumeRootFromNative). That is the prefix
//     decorate() gets for the volume's rows; one share mounted twice may
//     resolve to the other mount point (docs/intake-mac-paths.md), and the
//     mount aliases make both match anyway.
//   - Learned on the decorate path: a row whose g_get_native_path result
//     ends with "/" + <rest> gives the root as that result without the
//     suffix (learnedVolumeRoot). Rows of a stale volume id, an earlier
//     mount of the share that foobar2000 still resolves, are known only
//     this way.
//   - A re-seed (mount, unmount, Refresh) keeps the learned entries whose
//     root is still a mount point (mergeSeededVolumes).
//
//  <rest> is taken raw, with no percent decoding. S0 recorded the form as
//  "mac-volume://<UUID>/<path relative to the mount point>", converted to
//  "/Volumes/<mount point>/<path>" (docs/intake-mac-paths.md); plorg joins
//  the raw remainder onto mount roots for its existence probes
//  (PlorgVolumeSyncLogic parseFpliteLine) and the shadow-link migration
//  swaps the prefix alone (docs/shadow-link.md). The learn check is also a
//  runtime test of this: a volume whose remainder were encoded fails it, is
//  never learned (one Debug line), and its rows get no field rather than a
//  wrong one.
//
//  Volume ids compare ignoring ASCII case (they are hex UUIDs; plorg
//  uppercases them, foobar2000 writes them uppercase).
//
//  Thread-safety: immutable once built; withVolume() and
//  mergeSeededVolumes() return new tables. Any number of threads may read
//  one concurrently.
//

#pragma once

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace intake {

// "mac-volume://<UUID>/<rest>" (scheme ignoring ASCII case): true, with
// `uuid` and `rest` viewing `path` (`rest` may be empty; so may the slash
// before it). False for any other scheme or an empty UUID.
bool splitMacVolumePath(std::string_view path, std::string_view &uuid, std::string_view &rest);

// The volume id of a canonical volume root, "mac-volume://<UUID>/" or
// "mac-volume://<UUID>"; "" for anything else (another scheme, a path
// below the root).
std::string_view volumeIdOfRoot(std::string_view canonical);

// A native volume root as the table keeps it: absolute, trailing '/'
// removed ("/" stays "/"). "" when `native` is not absolute.
std::string volumeRootFromNative(std::string_view native);

// The root of the volume of `itemPath` ("mac-volume://<UUID>/<rest>"),
// learned from its converted `native` path: `native` without "/" + <rest>,
// when it ends so and an absolute root is left; else "" (another scheme, an
// empty rest, a remainder spelled differently in `native`).
std::string learnedVolumeRoot(std::string_view itemPath, std::string_view native);

struct VolumeEntry {
    std::string uuid;
    std::string root;  // volumeRootFromNative form
};

class VolumeTable {
public:
    // Entries with an empty id or root are skipped; for an id given twice
    // the first wins.
    static std::shared_ptr<const VolumeTable> make(std::vector<VolumeEntry> entries);
    // The table with no volumes.
    static std::shared_ptr<const VolumeTable> empty();

    // The root of volume `uuid`, or nullptr. The pointer stays valid while
    // the caller holds the table.
    const std::string *rootFor(std::string_view uuid) const;
    // root + "/" + rest of a mac-volume path into `out` (reusing its
    // capacity): true. False (with `out` unspecified) for another scheme or
    // an unknown volume.
    bool nativePath(std::string_view itemPath, std::string &out) const;
    // The same with the parts already split.
    bool nativePath(std::string_view uuid, std::string_view rest, std::string &out) const;

    // This table plus `uuid` at `root` (a copy; `uuid` replaces an entry of
    // the same id).
    std::shared_ptr<const VolumeTable> withVolume(std::string uuid, std::string root) const;

    const std::vector<VolumeEntry> &entries() const { return entries_; }
    size_t size() const { return entries_.size(); }
    bool isEmpty() const { return entries_.empty(); }
    // The same ids at the same roots, whatever the order.
    bool sameAs(const VolumeTable &other) const;
    // "<UUID> -> <root>; ..." for the log; "none" when empty.
    std::string describe() const;

    VolumeTable(const VolumeTable &) = delete;
    VolumeTable &operator=(const VolumeTable &) = delete;

private:
    struct Token {};

public:
    explicit VolumeTable(Token) {}

private:
    std::vector<VolumeEntry> entries_;
};

// A re-seed: the `seeded` entries, plus each entry of `previous` whose id
// the seed did not find and whose root is still one of `mountPoints`
// (compared ignoring ASCII case after volumeRootFromNative): a learned
// stale id of a share that is still mounted.
std::shared_ptr<const VolumeTable> mergeSeededVolumes(std::vector<VolumeEntry> seeded, const VolumeTable &previous,
                                                      const std::vector<std::string> &mountPoints);

// One volume id whose root differs between two tables; "" stands for
// "not in that table".
struct VolumeChange {
    std::string uuid;
    std::string before;
    std::string after;
};

// Every id that came, went or moved from `before` to `after`.
std::vector<VolumeChange> volumeChanges(const VolumeTable &before, const VolumeTable &after);

} // namespace intake
