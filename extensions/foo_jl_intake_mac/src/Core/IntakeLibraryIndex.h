//
//  IntakeLibraryIndex.h
//  foo_jl_intake
//
//  Library path -> root, for rows already swapped to their library copies
//  (doc 04 v1.2 "Delete local copy": "A library index (library path ->
//  root) covers swapped rows"; PLAN.md B9, verify gap 2).
//
//  Entries: for every root that is placed with placed.verified and whose
//  sidecar files[] the loader could read (PlacedRootFiles), each non-shadow
//  file's library path, by the same rule as Swap (IntakeSwapPlanner
//  libraryPathFor: target_path + "/" + files[].path, then the prefix pair),
//  keyed like a row: IntakePath-normalized (NFC), then the mount aliases the
//  view was built with, so a row on another mount of the share, or in the
//  other Unicode form, finds it. Ties (two roots claiming one library path)
//  go to the lowest id.
//
//  Use: only the context menu asks it, so a row swapped
//  to its library path still maps to its root for "Delete local copy…".
//  decorate() never reads it: library rows are not intake rows and get no
//  tint, no icon and no badge (doc 04 v1.2 "Row decorations").
//
//  Thread-safety: immutable once built; any number of threads may read it.
//

#pragma once

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "IntakeMountAliases.h"
#include "IntakePathMap.h"
#include "IntakeSwapPlanner.h"

namespace intake {

class LibraryIndex {
public:
    // `roots`: the placed, verified roots with their sidecar files (the
    // caller filters by status).
    static std::shared_ptr<const LibraryIndex> build(const std::vector<PlacedRootFiles> &roots,
                                                     const LibraryPrefix &prefix, const MountAliases &aliases);
    static std::shared_ptr<const LibraryIndex> empty();

    // The root id for a row's match key (normalized, then aliased, as
    // IntakeView builds it), or nullptr.
    const std::string *rootForKey(std::string_view key) const;

    size_t size() const { return byPath_.size(); }  // library paths
    size_t rootCount() const { return rootCount_; } // roots with at least one path
    bool isEmpty() const { return byPath_.empty(); }

    LibraryIndex(const LibraryIndex &) = delete;
    LibraryIndex &operator=(const LibraryIndex &) = delete;

private:
    struct Token {};

public:
    explicit LibraryIndex(Token) {}

private:
    PathMap<std::string> byPath_;
    size_t rootCount_ = 0;
};

} // namespace intake
