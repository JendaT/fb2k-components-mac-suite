//
//  IntakeView.h
//  foo_jl_intake
//
//  What decorate() reads: one immutable bundle of the snapshot, the mount
//  alias table its keys were built with, and the inert state (PLAN.md 3.2,
//  3.4). The loader publishes a new view; the provider swaps a
//  shared_ptr<const IntakeView> under a short lock and never holds the lock
//  while it works.
//
//  The per-row lookup lives here, SDK-free, so the provider only converts
//  foobar2000's path (IntakeNativePath, Integration) and copies the result:
//    1. IntakePath normalisation (file:// stripped, lexical, NFC); another
//       scheme or a relative path matches nothing;
//    2. the mount alias rewrite (IntakeMountAliases), on the normalized key,
//       so NFD and NFC spellings of a mount point both match;
//    3. the snapshot lookup (member map, then the ancestor walk).
//  No filesystem access, no allocation for an already-normal ASCII path that
//  is not under an smbfs mount.
//
//  A path with a non-ASCII byte (names stored decomposed on an SMB share)
//  would go through CoreFoundation for NFC in step 1, whether or not it is
//  near a root. mayHaveRecord() runs first and rules most such rows out by
//  their ASCII folder (IntakePath asciiFolderOf): normalized, aliased, and
//  neither under a root nor an ancestor of one
//  (IntakeSnapshot::mayMatchUnder). Skipped, so the full lookup runs, when a
//  mount point lies below that folder (the alias could then differ). The
//  answer is the same either way; only the cost changes.
//
//  B9: the view also carries the library index (IntakeLibraryIndex) built
//  with the same snapshot and alias table. Only the context menu asks it
//  (libraryRecordFor), so a row already swapped to its library path still
//  maps to its root for "Delete local copy…"; visualFor() and recordFor()
//  never read it, so library rows get no decoration.
//
//  Inert (doc 03 v1.2 "Inert state"): a view with an inert reason gives every
//  row under a known root a tooltip-only visual naming the reason, and
//  nothing else. With no known roots (the first load failed) it renders
//  nothing.
//
//  Thread-safety: immutable once made; visualFor() may run on any number of
//  threads at once, each with its own ViewScratch.
//

#pragma once

#include <memory>
#include <string>
#include <string_view>

#include "IntakeDecorationMap.h"
#include "IntakeLibraryIndex.h"
#include "IntakeMountAliases.h"
#include "IntakeSnapshot.h"

namespace intake {

// Per-thread buffers for visualFor(); reuse one across a batch.
struct ViewScratch {
    std::string normalized;
    std::string aliased;
};

// "intake inactive: "
extern const char *_Nonnull const kInertTooltipPrefix;

// The tooltip-only visual of an inert provider: kInertTooltipPrefix + reason.
IntakeRowVisual inertVisual(const std::string &reason);

class IntakeView {
public:
    // A null snapshot, alias table or library index stands for the empty one.
    static std::shared_ptr<const IntakeView> make(std::shared_ptr<const IntakeSnapshot> snapshot,
                                                  std::shared_ptr<const MountAliases> aliases,
                                                  std::string inertReason = std::string(),
                                                  std::shared_ptr<const LibraryIndex> library = nullptr);

    const IntakeSnapshot &snapshot() const { return *snapshot_; }
    const std::shared_ptr<const IntakeSnapshot> &snapshotPtr() const { return snapshot_; }
    const MountAliases &aliases() const { return *aliases_; }
    const std::shared_ptr<const MountAliases> &aliasesPtr() const { return aliases_; }
    const LibraryIndex &library() const { return *library_; }
    const std::shared_ptr<const LibraryIndex> &libraryPtr() const { return library_; }
    bool isInert() const { return !inertReason_.empty(); }
    const std::string &inertReason() const { return inertReason_; }
    // No row can be decorated: decorate() may skip the batch.
    bool rendersNothing() const { return snapshot_->isEmpty(); }

    // The record owning `path` (a native POSIX path or file://), or nullptr.
    const IntakeRecord *_Nullable recordFor(std::string_view path, ViewScratch &scratch) const;
    // False only when recordFor(path) is nullptr, decided without NFC (see
    // the top of this file); true for every ASCII path. recordFor() asks it
    // first.
    bool mayHaveRecord(std::string_view path, ViewScratch &scratch) const;
    // Its visual, or nullptr when the row gets no decoration. The pointer
    // stays valid while the caller holds this view.
    const IntakeRowVisual *_Nullable visualFor(std::string_view path, ViewScratch &scratch) const;
    // B9, never on the decorate path: the root whose library copy `path` is
    // (the library index), when the snapshot still has it placed with
    // placed.verified; else nullptr.
    const IntakeRecord *_Nullable libraryRecordFor(std::string_view path, ViewScratch &scratch) const;
    // The match key of `path` as recordFor() builds it (normalized, then
    // aliased), or false (another scheme, a relative path).
    bool matchKey(std::string_view path, ViewScratch &scratch, std::string &out) const;

    IntakeView(const IntakeView &) = delete;
    IntakeView &operator=(const IntakeView &) = delete;

private:
    struct Token {};

public:
    IntakeView(Token, std::shared_ptr<const IntakeSnapshot> snapshot, std::shared_ptr<const MountAliases> aliases,
               std::string inertReason, std::shared_ptr<const LibraryIndex> library);

private:
    std::shared_ptr<const IntakeSnapshot> snapshot_;
    std::shared_ptr<const MountAliases> aliases_;
    std::shared_ptr<const LibraryIndex> library_;
    std::string inertReason_;
    IntakeRowVisual inertVisual_;
};

} // namespace intake
