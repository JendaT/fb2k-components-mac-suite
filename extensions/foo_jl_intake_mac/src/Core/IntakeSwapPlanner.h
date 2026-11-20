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
//  Swap stats them in order and converts one that exists, on the mount whose
//  canonical volume form the playlist's items already use, else the one
//  foobar2000 resolves its own form to (chooseCanonicalCandidate). The
//  income row's volume does not decide: local income and a library on a
//  share are the usual case.
//
//  Share links (B11, docs/shadow-link.md): when items of the playlist lie
//  under a share link (file://<link>/<rel>, MountAliases::LinkEntry), the
//  mount's volume form would be a second spelling of the same file, so a
//  second metadb entry. Swap then notes those links at the click
//  (noteLinkForm) and uses the link form instead (linkFormFor): the first
//  candidate that lies under a noted link's raw target, as "file://" + the
//  link + the candidate's bytes past the target, with no conversion; an
//  item of the playlist that already spells that path in another Unicode
//  form lends its spelling (linkSpellingFor). No noted link leads to any
//  candidate (a mirror, the unmounted placeholder, or items that spell the
//  link only in another letter case): the row is skipped, never swapped
//  to the volume form (decideLinkForm). A playlist with no link-form item
//  keeps the volume-form rule above; in a mixed playlist the link form
//  wins.
//
//  Thread-safety: pure functions, except readPlacedRootFiles, which calls
//  `fs` (any thread; Swap's queue and the loader queue).
//

#pragma once

#include <array>
#include <cstddef>
#include <string>
#include <string_view>
#include <unordered_map>
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
    NoMatchingMount,   // no mount of the share has a volume form the playlist uses or foobar2000 resolves to it
    LinkOffShare,      // B11: the playlist uses a share link, and no link it uses leads to the library copy
    SlowConversion,    // the swap's path conversions on the main thread ran over their budget
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

// --- which mount foobar2000 gets (doc 04 v1.2: "the mount point whose
// canonical form matches the playlist's items") ---

// The mount point in `mounts` that owns `path` (raw, lexically cleaned
// here): the longest mount point containing it, ignoring ASCII case, at
// component boundaries (a later row for the same point wins); "" when none
// does.
std::string owningMountPoint(const std::vector<MountEntry> &mounts, std::string_view path);

// `path` (raw or file://) is `mountPoint` or lies under it, as above; "/"
// holds every absolute path. False when either is not an absolute path.
bool pathUnderMountPoint(std::string_view path, std::string_view mountPoint);

// Adds the volume form of `path` (canonicalVolumePrefix) to `forms` once,
// ASCII case ignored; nothing for a path without one.
void noteVolumeForm(std::vector<std::string> &forms, std::string_view path);

// The volume form of `path` is one of `forms`.
bool hasVolumeForm(const std::vector<std::string> &forms, std::string_view path);

// One library file that exists under one mount of the share, as foobar2000
// sees it (Swap fills these in on the main thread, once per mount).
struct CanonicalCandidate {
    std::string path;         // the raw path that exists
    std::string form;         // the volume form (canonicalVolumePrefix) of its g_get_canonical_path; "" when that failed
    bool roundTrips = false;  // g_get_native_path of that canonical path lies under this path's own mount point
};

// The candidate Swap converts to, or -1 ("no matching mount"): the first
// whose volume form an item of the playlist already uses
// (`playlistForms`, the swapped row's own included): handle_create then
// meets the volume id foobar2000 already uses for that share, so no
// duplicate metadb entry (docs/VOLUME_UUID_ISSUE.md). When no item uses any
// of them (a local income row and a library on a share no playlist item is
// on yet), the first whose canonical form round-trips to its own mount:
// the form foobar2000 itself resolves to that mount. Candidates without a
// volume form never count.
long chooseCanonicalCandidate(const std::vector<CanonicalCandidate> &candidates,
                              const std::vector<std::string> &playlistForms);

// --- share links (B11; see the top of this file) ---

// The share links a playlist's items lie under, noted at the Swap click.
struct PlaylistLinkForms {
    std::vector<std::string> links;  // LinkEntry::linkKey of each link an item lies under, each once, in playlist order
    // LinkEntry::linkKey of each link an item lies under only ignoring ASCII
    // case (share_links says /Users/x/Music, the items /Users/x/music), each
    // once: rewrite() maps no such item, yet on a case-insensitive volume it
    // is the same link, so the playlist is still in the link form. No noted
    // link can spell its rows, so they are skipped, never given a volume form.
    std::vector<std::string> otherCase;
    // Every item under `links`: its IntakePath key -> its path as the
    // playlist spells it (the first item with that key).
    std::unordered_map<std::string, std::string> items;
    bool empty() const { return links.empty() && otherCase.empty(); }
};

// Notes `path` (a playlist item's path) when it is a file:// path under one
// of `links`: by IntakePath key, byte-exact, the longest link winning, as
// MountAliases::rewrite() matches links; under none byte-exact but under
// one ignoring ASCII case: in `otherCase`. Other schemes are never link
// forms. `buffer` is scratch.
void noteLinkForm(PlaylistLinkForms &forms, const std::vector<MountAliases::LinkEntry> &links,
                  std::string_view path, std::string &buffer);

struct LinkForm {
    std::string path;          // "file://" + rawLink + the candidate's bytes past the target; "" with none
    long candidateIndex = -1;  // the candidate it stands for, or -1
};

// The link form of the first of `candidates` (raw library paths Swap
// stat'ed, in order) that lies under the raw target of one of `links`
// whose key is in `linkForms` (the noted links, tried in that order): the
// target compared ignoring ASCII case, as mount points are (a candidate
// spelled through the link itself also counts, byte-exact). onShare is not
// read: a link to a local folder works the same. The link is lexically
// cleaned; the rest keeps the candidate's bytes (its Unicode form as
// stat'ed). None (index -1) when `linkForms` is empty or no noted link
// leads to any candidate.
LinkForm linkFormFor(const std::vector<std::string> &candidates, const std::vector<MountAliases::LinkEntry> &links,
                     const std::vector<std::string> &linkForms);

// `path` (a link form) as an item of the playlist already spells it, the
// same path by IntakePath key (NFC and NFD alike), so handle_create meets
// the metadb entry that item uses; else `path` itself.
std::string linkSpellingFor(const PlaylistLinkForms &forms, const std::string &path);

// What Swap does with one row (planOnQueue), from the paths of its library
// copy (the candidates, in order) and the playlist's link forms (rules 1-4
// at the top of this file):
//   - `forms` empty: neither field set; the volume-form rule applies;
//   - no noted link leads to a candidate (also: only `otherCase` links):
//     `skip` LinkOffShare, never the volume form;
//   - otherwise `path`: the link form (linkFormFor), as an item of the
//     playlist already spells it (linkSpellingFor).
struct LinkDecision {
    SwapSkip skip = SwapSkip::None;
    std::string path;
};
LinkDecision decideLinkForm(const std::vector<std::string> &candidates,
                            const std::vector<MountAliases::LinkEntry> &links, const PlaylistLinkForms &forms);

// --- the Delete census ---

// How the income-row census (IntakeSwap incomeRowCensus) counts one
// playlist entry. Fail closed (doc 04 "Delete local copy"):
enum class CensusEntry {
    Clear,     // no income path of the roots
    Income,    // an income path of one of the roots
    Unchecked, // unknown, never clear: "Swap, then delete" deletes nothing while one is left
};
// `refused`: the entry's mac-volume path was not converted (a slow volume,
// the budget). `offShareLink` (B11): it lies under a share link whose
// target is off the share, or under a link's path spelled in another
// letter case (MountAliases::underOffShareLink); whatever it matches now,
// it could reach an income copy once the link points at the share again
// (or through the same link), and Swap skips it meanwhile. `income`: its path
// maps to one of the roots. Either of the first two makes it unchecked,
// even when it matches.
CensusEntry censusEntry(bool refused, bool offShareLink, bool income);

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
