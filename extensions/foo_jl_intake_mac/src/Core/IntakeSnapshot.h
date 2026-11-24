//
//  IntakeSnapshot.h
//  foo_jl_intake
//
//  One immutable view of intake state: the records of a `status --json`
//  load (IntakeStatusModel), their membership (IntakeSidecarMembers), their
//  visuals (IntakeDecorationMap), group badges (IntakeGroupBadge) and
//  title-formatting field values (IntakeFields, B13), indexed for the
//  decorate path (PLAN.md 3.2, 3.3).
//
//  Lookup of a row path:
//   1. The member map: an exact match on root_path + "/" + files[].path of
//      a virtual root or single (MemberKind::Members).
//   2. The directory map, by the ancestor walk (IntakePathMap.h, shared with
//      IntakeRootIndex): the path itself, then each parent, over the
//      directories of whole-directory roots. The deepest root wins, so a
//      nested root beats its parent.
//  Roots of kind None are in neither map; they match nothing. A file in a
//  directory of singles that no sidecar lists falls through to an ancestor
//  root, if any.
//  Known gap: so do a None root's own files, because its member list was
//  never read (a virtual root that renders nothing, IntakeSidecarMembers,
//  or one whose sidecar stayed unusable). They take the visual of a
//  whole-directory root in the same folder (a stale `.intake.json` left by
//  `resolve --force`) or of the nearest ancestor root, where doc 04 wants
//  nothing. A whole-directory root that renders nothing is in the directory
//  map and does shadow its ancestors. Accepted: it needs a stale sidecar or
//  singles nested under another root, plus a status that renders nothing,
//  and closing it costs a sidecar read per such root on every load.
//  Ties are broken by the lowest id (two whole-directory roots on one key,
//  two virtual roots listing one file), so the answer never depends on the
//  CLI's row order.
//
//  Keys: both maps are keyed from IntakeRecord::rootKey (IntakePath match
//  key: lexical, NFC), directories as normalize(rootKey) and members as
//  normalize(rootKey + "/" + path), so NFC and NFD spellings match on both
//  sides even when Integration rewrote rootKey (B3 mount aliases) without
//  normalizing it, and the rewritten key carries its members along. Matching is
//  case-sensitive. lookup() normalizes the query (file:// stripped; other
//  schemes and relative paths match nothing); lookupKey() takes a query that
//  is already a match key, e.g. an alias key.
//
//  A record without a MemberTable entry counts as whole-directory.
//
//  Thread-safety: immutable once built. build() returns a
//  shared_ptr<const IntakeSnapshot>; nothing mutates it afterwards and there
//  are no lazy caches, so any number of threads may read one concurrently
//  (decorate queues, one per panel). Pointers returned by the lookups stay
//  valid while the caller holds the shared_ptr. Cost: lookup() allocates
//  only for a query that is not already normal ASCII.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "IntakeDecorationMap.h"
#include "IntakePathMap.h"
#include "IntakeSidecarMembers.h"
#include "IntakeStatusModel.h"

namespace intake {

// Whether `record` is a singles root, for the null-target wording
// (IntakeDecorationMap, IntakeGroupBadge). `members` is its entry, or null.
//  - Members: the named sidecar's `singles` flag (RootMembers::singles).
//  - Whole-directory from a listing (Listed, Reused): no named sidecar, so
//    an `.intake.json` root, never a single.
//  - Kind not verified (Assumed, Previous whole-directory, no entry: a lone
//    root whose sidecar is not read): a singles root always has a null
//    cluster.album (doc 01), so an empty album counts as singles. A
//    non-singles root with no album name keeps "slot pending" then, as
//    before.
//  - None: false (it renders nothing).
bool singlesRootFor(const IntakeRecord &record, const RootMembers *members);

class IntakeSnapshot {
public:
    // Takes the records and the member table, computes every record's visual
    // and badge with `palette` and its field values, and builds both maps.
    // Logs ties at Debug level.
    static std::shared_ptr<const IntakeSnapshot> build(std::vector<IntakeRecord> records,
                                                       MemberTable members,
                                                       const IntakePalette &palette = IntakePalette());

    // A snapshot with no records (before the first load).
    static std::shared_ptr<const IntakeSnapshot> empty();

    // The record owning `path` (a native POSIX path or file://), or nullptr.
    const IntakeRecord *lookup(std::string_view path) const;
    // Same for a query that is already a normalized match key.
    const IntakeRecord *lookupKey(std::string_view key) const;
    // By sidecar id, or nullptr.
    const IntakeRecord *recordForId(std::string_view id) const;

    const std::vector<IntakeRecord> &records() const { return records_; }
    // The membership this snapshot was built from: the next load's `previous`.
    const MemberTable &members() const { return members_; }

    size_t size() const { return records_.size(); }
    bool isEmpty() const { return records_.empty(); }
    size_t memberKeyCount() const { return byMember_.size(); }
    size_t directoryKeyCount() const { return byDirectory_.size(); }

    IntakeSnapshot(const IntakeSnapshot &) = delete;
    IntakeSnapshot &operator=(const IntakeSnapshot &) = delete;

private:
    struct Token {};

public:
    explicit IntakeSnapshot(Token) {}

private:
    std::vector<IntakeRecord> records_;
    MemberTable members_;
    PathMap<uint32_t> byMember_;     // member file key -> record index
    PathMap<uint32_t> byDirectory_;  // whole-directory root key -> record index
    std::unordered_map<std::string, uint32_t, PathKeyHash, std::equal_to<>> byId_;
};

} // namespace intake
