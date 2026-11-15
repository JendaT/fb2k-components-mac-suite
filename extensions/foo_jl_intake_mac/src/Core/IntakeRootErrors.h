//
//  IntakeRootErrors.h
//  foo_jl_intake
//
//  Per-root command errors (doc 04 v1.2 "Failure behavior": a console line
//  plus a per-root tooltip, never modal, never inert; PLAN.md B6). A
//  mutating command that fails for a root sets that root's error here
//  (IntakeMutationResult decides which root an error belongs to); the
//  loader copies it into IntakeRecord::lastError before each snapshot is
//  built (LoaderSettings::annotateRecords), so it shows in the row tooltip
//  (IntakeDecorationMap) and its arrival or removal invalidates like any
//  visual change (rendersAlike).
//
//  Lifecycle: "until that root's status changes". The first load that
//  shows an error records the root's status then as the error's baseline;
//  a later load that finds another status drops the error. So an
//  E_BAD_STATUS that came from a stale menu (the root had already moved on)
//  is still shown once, on the status the CLI refused. A newer error for
//  the root replaces the old one and starts over; a command that succeeds
//  for the root clears it. A root missing from a successful load is
//  dropped too (the store stays bounded by the roots that exist).
//
//  Thread-safety: every method may be called from any thread (set/clear on
//  the main thread, apply on the loader queue); one mutex, held only while
//  copying strings.
//

#pragma once

#include <cstddef>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "IntakeStatusModel.h"

namespace intake {

class RootErrorStore {
public:
    // A new error for `id` (an empty text clears instead).
    void set(const std::string &id, std::string text);
    void clear(const std::string &id);
    void clearAll();

    // The loader's annotator: every record gets its root's error in
    // lastError (or an empty one), and errors whose root changed status
    // since they were first shown, or is missing, are dropped (see above).
    void apply(std::vector<IntakeRecord> &records);

    // For tests and logs.
    size_t size() const;
    std::string errorFor(const std::string &id) const;

private:
    struct Entry {
        std::string text;
        bool hasBaseline = false;
        IntakeStatus baseline = IntakeStatus::Unknown;
    };
    mutable std::mutex mutex_;
    std::unordered_map<std::string, Entry> entries_;
};

} // namespace intake
