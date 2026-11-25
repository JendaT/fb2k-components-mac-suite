//
//  IntakeProposeChain.h
//  foo_jl_intake
//
//  B12: a propose of many roots, run as a chain of small `propose` calls
//  (chunks) instead of one. Each root takes the CLI 18 to 114 s (beets,
//  MusicBrainz), so one call for 49 roots ran into the 15-minute hard cap,
//  was terminated, and held the mutation lane the whole time. With chunks of
//  kProposeChunkSize roots, each its own lane run, the lane is free between
//  chunks and a kill loses at most one chunk. Integration (IntakeActions)
//  runs the chain for a propose of more than kProposeChunkSize roots: the
//  user's Propose, the propose after an assign and the one after an
//  auto-scan; 5 or fewer keep their single call. Pure: no I/O.
//
//  The roots (add). In the order added; a root is known by its id, and one
//  already pending, in the chunk in flight or handled by this chain (done,
//  failed or skipped) is not added again, so roots asked for while the chain
//  runs join it without repeats. total() counts every root added.
//
//  A chunk (nextChunk). Up to kProposeChunkSize pending roots whose CURRENT
//  status (statusOf: the current view, read just before the chunk) is
//  resolved, in order; they are in flight until record(). A pending root met
//  on the way that is no longer resolved, or missing from the view, is
//  handled as skipped (`propose` would refuse it: doc 03, propose only from
//  resolved) and listed in the chunk's skipped line (one Debug line). The
//  chunk's roots carry status Resolved, the baseline of their errors
//  (RootErrorStore). Empty while a chunk is in flight, or when nothing
//  resolved is pending (finished() then says whether the chain is done).
//
//  After a chunk (record): each root of the chunk in flight is done when its
//  id is in MutationOutcome::succeeded, else failed; a root in flight that
//  the chunk does not name goes back to the front of the pending roots.
//  Root errors are kept for the end's result.
//
//  Stop or go on (proposeChainStopFor, from the chunk's envelope):
//   - stop when the call was killed at the 15-minute hard cap: a mutating
//     call is killed only there (IntakeProcess ReportAtBudget), and
//     IntakeEnvelope reports it as the host-synthesized outcome Timeout
//     (E_CLI_TIMEOUT "still running at the hard cap; terminated"); the next
//     chunk would most likely meet the same;
//   - stop on E_NO_CLI (outcome NoCli: nothing usable ran);
//   - stop on Cancelled (never for a mutating call: only read-only calls are
//     cancelled; kept so a runner shutting down never starts another chunk);
//   - go on after per-root errors and any other envelope error (Partial,
//     Failed): they are the roots' own, shown as tooltips.
//
//  The end (result): activityResultFor over all chunks together, so a
//  partial failure reads "Propose failed: 3 of 49 albums" (a cross, B14
//  decision a) and a total one the first root's error; skipped roots count
//  neither way (named() = done + failed). Its detail is summaryLine():
//   "propose: done for 49 roots in 10 chunks"
//   "propose: done for 46 of 49 roots in 10 chunks; failed: itk_a itk_b itk_c"
//  plus "; skipped (no longer resolved): itk_x" when roots were skipped, and
//  "; <reason>" when chunks reported an error but failed no root. Where
//  activityResultFor would fall back to that line (no root error to show:
//  every failed root failed without one, or a chunk's error failed none),
//  the reason is the first failing chunk's own (activityResultFor of that
//  chunk: "cancelled", the envelope's error).
//
//  Progress (progress): done of total for the status bar's n/m, and the
//  root the chunk in flight starts with (its album is the one worked on
//  now). Before anything is handled the current root is left empty, so the
//  line keeps its plain form ("Proposing 49 albums…") until the first chunk
//  ends ("Proposing 10/49: Artist – Album" afterwards).
//
//  Chunk numbers: chunksStarted() counts the chunks handed out (the one in
//  flight included), chunksRecorded() the ones recorded, chunkCount() the
//  estimate of all: started plus the pending roots in chunks of
//  kProposeChunkSize (it grows when roots join, shrinks when some are
//  skipped).
//
//  Thread-safety: none (Integration uses it on the main thread only).
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

#include "IntakeActivity.h"
#include "IntakeEnvelope.h"
#include "IntakeMutationResult.h"
#include "IntakeStatusModel.h"

namespace intake {

// The most roots one `propose` call of a chain names. A propose of more
// roots than this goes through the chain; one of this many or fewer stays a
// single call.
inline constexpr size_t kProposeChunkSize = 5;

// A root's current status by id; nullopt when the current view has no such
// root.
using ProposeStatusOf = std::function<std::optional<IntakeStatus>(const std::string &id)>;

struct ProposeChunk {
    size_t number = 0;                // 1 for the first chunk handed out; 0 when empty
    std::vector<MutationRoot> roots;  // up to kProposeChunkSize, status Resolved
    // Handled as skipped on the way: "itk_a (proposed)", "itk_b (not in the
    // view)", in order.
    std::vector<std::string> skipped;
    // "propose: skipped 2 roots no longer resolved: itk_a (proposed), itk_b
    // (not in the view)"; empty when none was skipped.
    std::string skippedLine;

    std::vector<std::string> ids() const;
};

struct ProposeChainStop {
    bool stop = false;
    std::string reason;  // for the stop line and the status bar ("the chunk was terminated at the 15-minute cap")
};

// Stop or go on after a chunk with this envelope (see the top of this file).
ProposeChainStop proposeChainStopFor(const EnvelopeResult &envelope);

struct ProposeChainProgress {
    uint32_t done = 0;
    uint32_t total = 0;
    // The first root of the chunk in flight once something was handled;
    // empty id otherwise.
    MutationRoot current;
};

class ProposeChain {
public:
    // Adds the roots not known to this chain yet (see the top of this
    // file); returns how many were added.
    size_t add(const std::vector<MutationRoot> &roots);

    // The next chunk (see the top of this file).
    ProposeChunk nextChunk(const ProposeStatusOf &statusOf);

    // The chunk in flight has ended with `outcome`; `chunk`: the roots its
    // call named.
    void record(const std::vector<MutationRoot> &chunk, const MutationOutcome &outcome);

    size_t total() const { return order_.size(); }
    size_t done() const { return succeeded_.size() + failed_.size() + skipped_.size(); }
    size_t named() const { return succeeded_.size() + failed_.size(); }
    size_t pendingCount() const { return pending_.size(); }
    bool inFlight() const { return !inFlight_.empty(); }
    // Nothing pending and nothing in flight.
    bool finished() const { return pending_.empty() && inFlight_.empty(); }

    // Pending roots, in order (not yet handed out).
    std::vector<std::string> pendingIds() const;
    // Neither proposed nor tried: the chunk in flight (not recorded: a
    // refused chunk), then the pending roots.
    std::vector<std::string> notProposed() const;

    const std::vector<std::string> &succeeded() const { return succeeded_; }
    const std::vector<std::string> &failed() const { return failed_; }
    const std::vector<std::string> &skipped() const { return skipped_; }

    // The first root ever added (the status bar's label); null when none.
    const MutationRoot *firstRoot() const { return first_ ? &*first_ : nullptr; }

    size_t chunksStarted() const { return chunksStarted_; }
    size_t chunksRecorded() const { return chunksRecorded_; }
    size_t chunkCount() const;

    ProposeChainProgress progress() const;

    std::string summaryLine() const;
    ActivityResult result() const;

private:
    bool known(const std::string &id) const { return known_.count(id) != 0; }

    std::vector<std::string> order_;          // every id added, in order
    std::unordered_set<std::string> known_;   // the same, for lookups
    std::optional<MutationRoot> first_;
    std::vector<MutationRoot> pending_;       // in order
    std::vector<MutationRoot> inFlight_;      // the chunk handed out, not recorded yet
    std::vector<std::string> succeeded_;
    std::vector<std::string> failed_;
    std::vector<std::string> skipped_;
    std::vector<std::pair<std::string, std::string>> rootErrors_;  // naming order, all chunks
    std::vector<std::string> failedWithoutError_;
    std::string firstReason_;  // the reason of the first chunk whose own result failed
    size_t chunksStarted_ = 0;
    size_t chunksRecorded_ = 0;
};

} // namespace intake
