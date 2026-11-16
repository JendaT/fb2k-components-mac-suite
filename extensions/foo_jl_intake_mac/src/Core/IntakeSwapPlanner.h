//
//  IntakeSwapPlanner.h
//  foo_jl_intake
//
//  Where a placed release's files live in the library (doc 04 v1.2 "Swap to
//  library paths", "Delete local copy"; doc 03 v1.2 "Execute protocol";
//  PLAN.md B9, 3.8). Pure: the sidecar comes in through SidecarFileAccess,
//  the mount table as MountEntry rows; Integration stats the result,
//  converts it with filesystem::g_get_canonical_path and edits the playlist
//  (IntakeSwap.mm), and the loader builds the library index from it
//  (IntakeLibraryIndex).
//
//  The rule (doc 03 v1.2: "Each placed file lands at target_path/<path
//  relative to the root>", commands-p3.ts planFiles):
//   1. The row must be one of the root's sidecar files[] entries. The match
//      is by IntakePath key, as the snapshot matches members: the row's key
//      (IntakeView: normalized, NFC, then the mount aliases) against
//      normalize(rootKey + "/" + files[].path), so an NFD name on the share
//      meets an NFC sidecar path, and a row on /Volumes/<share>-1 meets a
//      root reported under /Volumes/<share>. This holds for whole-folder
//      roots (`.intake.json`) and virtual roots (`.intake.<id>.json`, several
//      in one folder) alike: files[] is the list either way. A file of a
//      whole-folder root that files[] does not list (a cover, a cue, a log:
//      artifacts are copied too, but have no files[] entry to check against)
//      is skipped ("not in the sidecar").
//   2. A `quality_shadow: true` entry is skipped: shadows are not placed
//      (doc 03 v1.2), so the library has no copy of them.
//   3. library path = placed.target_path + "/" + files[].path (the sidecar's
//      spelling), lexically cleaned (no NFC: it is used for I/O).
//   4. Then the prefix pair (swap_prefix_from -> swap_prefix_to): the path is
//      rewritten when it is `from` or lies under it, whole components only
//      (/a/music does not match /a/music2), byte for byte. A pair that is
//      not usable (validatePrefixPair other than Ok: empty, half filled,
//      relative, the root folder) rewrites nothing. A usable pair that the
//      path lies outside leaves it unchanged (OutsidePair): the CLI may
//      already report Mac paths (it runs on this Mac and its tier roots may
//      be /Volumes/... paths), and the stat that follows decides; the
//      caller logs it at Debug.
//
//  Mount aliases for I/O (aliasMountPaths): a library path under an smbfs
//  mount is also tried under every other mount of the same share
//  (IntakeMountAliases' share key: user and host ignored, the share name
//  ignoring ASCII case, a mounted subfolder kept), the given spelling first.
//  Swap stats them in order and converts the one that exists on the mount
//  point whose canonical form matches the row's (canonicalVolumePrefix).
//
//  Thread-safety: pure functions, except readPlacedRootFiles, which calls
//  `fs` (any thread; Swap's queue and the loader queue).
//

#pragma once

#include <array>
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

#include "IntakeMountAliases.h"
#include "IntakeSettingsParse.h"

namespace intake {

class SidecarFileAccess;
struct IntakeRecord;

// One sidecar files[] entry.
struct SidecarFile {
    std::string path;     // files[].path as the sidecar spells it (relative to the root)
    bool shadow = false;  // quality_shadow: true
};

// What Swap, Delete and the library index need of one placed root.
struct PlacedRootFiles {
    std::string id;
    std::string rootPath;    // root_path as the CLI spelled it (for I/O)
    std::string rootKey;     // IntakeRecord::rootKey (match key: normalized, aliased)
    std::string targetPath;  // placed.target_path as the CLI spelled it
    bool wholeFolder = true; // the sidecar's `virtual` is not true (`.intake.json`)
    std::vector<SidecarFile> files;
};

// Parses a sidecar document: `files` must be an array of objects with a
// safe relative `path` (the CLI's isSafeRelPath, IntakeSidecarMembers), as
// for the member lists; `quality_shadow` counts only as the JSON boolean
// true. `docId` (optional) gets the document's id ("" when absent),
// `isVirtual` (optional) whether `virtual` is true. False when the document
// is not acceptable.
bool parseSidecarFiles(std::string_view json, std::vector<SidecarFile> &files, std::string *docId = nullptr,
                       bool *isVirtual = nullptr);

// Reads the sidecar of `record` with `fs`: `.intake.<id>.json` in root_path
// first (virtual roots and singles), then `.intake.json` (whole folder) when
// the first does not exist. A read or parse failure is retried once (the
// CLI writes sidecars in place). The document's id must be the record's.
// On success `out` holds the record's id, rootPath, rootKey and
// placedTargetPath plus the files. False with `error` (one line) otherwise;
// `errnoOut` (optional) gets the errno of the last failed read (0 for a
// parse or id problem), so the caller can stop on isShareUnreachableError.
bool readPlacedRootFiles(const IntakeRecord &record, SidecarFileAccess &fs, PlacedRootFiles &out,
                         std::string &error, int *errnoOut = nullptr);

// --- the prefix pair ---

struct LibraryPrefix {
    std::string from;  // normalizedPrefix(swap_prefix_from)
    std::string to;    // normalizedPrefix(swap_prefix_to)
    PrefixPairCheck check = PrefixPairCheck::BothEmpty;
    bool active() const { return check == PrefixPairCheck::Ok; }
    bool operator==(const LibraryPrefix &other) const {
        return from == other.from && to == other.to && check == other.check;
    }
    bool operator!=(const LibraryPrefix &other) const { return !(*this == other); }
};

// The pair as the settings hold it (normalizedPrefix, validatePrefixPair).
LibraryPrefix makeLibraryPrefix(std::string_view from, std::string_view to);

enum class PrefixRewrite {
    NoMapping,   // no usable pair: `out` is the path unchanged
    Rewritten,   // `out` is `to` + the rest
    OutsidePair, // a usable pair the path lies outside: `out` is the path unchanged
};

// Step 4 above. `path` should be lexically clean (lexicalAbsolutePath).
PrefixRewrite rewriteLibraryPrefix(const LibraryPrefix &prefix, std::string_view path, std::string &out);

// --- planning one row ---

// Why a row was not swapped (the console line counts them in this order).
enum class SwapSkip {
    None,
    NotPlaced,         // the root is no longer placed with placed.verified
    NoTarget,          // the root has no placed.target_path
    SidecarUnreadable, // its sidecar could not be read
    NotInSidecar,      // the row is not one of the root's files[] entries
    Shadow,            // a quality_shadow file: not placed in the library
    LibraryMissing,    // no library file at that path (either Unicode form, any mount of the share)
    ShareUnreachable,  // the library share stopped answering
    NoMatchingMount,   // no mount point of the share has the row's canonical volume form
    PlaylistGone,      // the playlist was closed meanwhile
    PlaylistLocked,    // the playlist does not allow replacing items
    RowGone,           // the row is no longer in the playlist
    ReplaceRefused,    // playlist_replace_item returned false
    Count,
};

// "library file missing", "shadow", ...
const char *swapSkipText(SwapSkip skip);

struct SwapPlan {
    SwapSkip skip = SwapSkip::None;
    std::string relativePath;   // files[].path of the matching entry
    std::string libraryPath;    // after the prefix pair (for I/O)
    PrefixRewrite rewrite = PrefixRewrite::NoMapping;
};

// The files[] index `itemKey` stands for, or -1. `itemKey` is an IntakePath
// match key built like IntakeView's (normalized, then the mount aliases of
// the table root.rootKey was built with).
long matchSidecarFile(const PlacedRootFiles &root, std::string_view itemKey);

// Steps 1-4 for one row.
SwapPlan planSwap(const PlacedRootFiles &root, std::string_view itemKey, const LibraryPrefix &prefix);

// The library path of files[index] (steps 3-4), skipping nothing: used by
// planSwap and the library index. False for a root without a target path.
bool libraryPathFor(const PlacedRootFiles &root, size_t index, const LibraryPrefix &prefix, std::string &out,
                    PrefixRewrite *rewrite = nullptr);

// --- I/O helpers (pure) ---

// `path` (a raw path under some mount) under every mount of the same SMB
// share: `path` first, then the same share-relative path under each other
// smbfs mount whose share key covers it, in mount-table order, each once.
// A path under no smbfs mount (the longest mount point containing it is
// another type) yields just `path`. Mount points match ignoring ASCII case,
// at component boundaries.
std::vector<std::string> aliasMountPaths(const std::vector<MountEntry> &mounts, std::string_view path);

// `path` in the other Unicode normalization form: NFD when it is NFC, else
// NFC; "" when both forms are the same bytes (ASCII) or the bytes are not
// UTF-8. For the stat that tries the sidecar's spelling first.
std::string otherNormalizationForm(std::string_view path);

// The volume part of a foobar2000 path, the form Swap compares: for
// "mac-volume://<UUID>/..." the scheme and UUID ("mac-volume://<UUID>/"),
// for "file://..." just "file://"; "" for anything else.
std::string canonicalVolumePrefix(std::string_view path);

// Both are the same volume form: equal ignoring ASCII case, and not empty.
bool sameVolumePrefix(std::string_view a, std::string_view b);

// --- the console line ---

struct SwapTally {
    size_t swapped = 0;
    std::array<size_t, static_cast<size_t>(SwapSkip::Count)> skipped{};

    void skip(SwapSkip reason) { skipped[static_cast<size_t>(reason)]++; }
    size_t skippedTotal() const;
    size_t skippedFor(SwapSkip reason) const { return skipped[static_cast<size_t>(reason)]; }
};

// "swap: 2 row(s) swapped to library paths, 3 skipped (2 library file
// missing, 1 shadow)"; "..., 0 skipped" with no reasons.
std::string swapResultLine(const SwapTally &tally);

} // namespace intake
