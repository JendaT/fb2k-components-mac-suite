//
//  IntakeSnapshot.h
//  foo_jl_intake
//
//  One immutable view of intake state: the records of a `status --json`
//  load (IntakeStatusModel), their membership (IntakeSidecarMembers) and
//  their visuals (IntakeDecorationMap), indexed for the decorate path
//  (PLAN.md 3.2, 3.3).
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
//  Ties are broken by the lowest id (two whole-directory roots on one key,
//  two virtual roots listing one file), so the answer never depends on the
//  CLI's row order.
//
//  Keys: both maps are keyed from IntakeRecord::rootKey (IntakePath match
//  key: lexical, NFC), with members as normalize(rootKey + "/" + path), so
//  NFC and NFD spellings match on both sides, and a rootKey rewritten by
//  Integration (B3 mount aliases) carries its members along. Matching is
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

class IntakeSnapshot {
public:
    // Takes the records and the member table, computes every record's visual
    // with `palette` and builds both maps. Logs ties at Debug level.
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
