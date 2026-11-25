//
//  IntakeProposeChain.mm
//  foo_jl_intake
//
//  See IntakeProposeChain.h.
//

#include "IntakeProposeChain.h"

#include "IntakeErrorMap.h"

#include <climits>
#include <unordered_set>

namespace intake {

namespace {

std::string plural(size_t n, const char *one, const char *many) {
    return std::to_string(n) + " " + (n == 1 ? one : many);
}

std::string joined(const std::vector<std::string> &items, const char *separator) {
    std::string out;
    for (const std::string &item : items) {
        if (!out.empty()) out += separator;
        out += item;
    }
    return out;
}

uint32_t clamp32(size_t n) {
    return n > UINT32_MAX ? UINT32_MAX : static_cast<uint32_t>(n);
}

} // anonymous namespace

std::vector<std::string> ProposeChunk::ids() const {
    std::vector<std::string> out;
    out.reserve(roots.size());
    for (const MutationRoot &r : roots) out.push_back(r.id);
    return out;
}

ProposeChainStop proposeChainStopFor(const EnvelopeResult &envelope) {
    ProposeChainStop out;
    switch (envelope.outcome) {
        case CliOutcome::Ok:
        case CliOutcome::Partial:
        case CliOutcome::Failed:
            break;
        case CliOutcome::Timeout:
            // A mutating call is killed only at the hard cap (ReportAtBudget).
            out.stop = true;
            out.reason = "the chunk was terminated at the 15-minute cap";
            break;
        case CliOutcome::NoCli:
            out.stop = true;
            out.reason = envelope.errors.empty() ? std::string(kErrorNoCli) : renderError(envelope.errors.front());
            break;
        case CliOutcome::Cancelled:
            out.stop = true;
            out.reason = "the chunk was cancelled";
            break;
    }
    return out;
}

size_t ProposeChain::add(const std::vector<MutationRoot> &roots) {
    size_t added = 0;
    for (const MutationRoot &r : roots) {
        if (r.id.empty() || known(r.id)) continue;
        known_.insert(r.id);
        added_.push_back(r);
        pending_.push_back(r);
        added++;
    }
    return added;
}

std::vector<std::string> ProposeChain::failedAmong(const std::vector<MutationRoot> &roots) const {
    const std::unordered_set<std::string> failed(failed_.begin(), failed_.end());
    std::unordered_set<std::string> seen;
    std::vector<std::string> out;
    for (const MutationRoot &r : roots) {
        if (failed.count(r.id) != 0 && seen.insert(r.id).second) out.push_back(r.id);
    }
    return out;
}

ProposeChunk ProposeChain::nextChunk(const ProposeStatusOf &statusOf) {
    ProposeChunk out;
    if (!inFlight_.empty()) return out;
    size_t taken = 0;
    while (taken < pending_.size() && out.roots.size() < kProposeChunkSize) {
        const MutationRoot &r = pending_[taken++];
        const std::optional<IntakeStatus> status = statusOf ? statusOf(r.id) : std::nullopt;
        if (status && *status == IntakeStatus::Resolved) {
            MutationRoot chunkRoot = r;
            chunkRoot.status = IntakeStatus::Resolved;
            out.roots.push_back(std::move(chunkRoot));
            continue;
        }
        skipped_.push_back(r.id);
        out.skipped.push_back(r.id + (status ? std::string(" (") + intakeStatusName(*status) + ")"
                                             : std::string(" (not in the view)")));
        skippedNotes_.push_back(out.skipped.back());
    }
    pending_.erase(pending_.begin(), pending_.begin() + static_cast<std::ptrdiff_t>(taken));
    if (!out.skipped.empty()) {
        out.skippedLine = "propose: skipped " + plural(out.skipped.size(), "root", "roots") +
                          " not resolved now: " + joined(out.skipped, ", ");
    }
    if (!out.roots.empty()) {
        inFlight_ = out.roots;
        out.number = ++chunksStarted_;
    }
    return out;
}

void ProposeChain::record(const std::vector<MutationRoot> &chunk, const MutationOutcome &outcome) {
    if (inFlight_.empty()) return;
    std::unordered_set<std::string> named;
    for (const MutationRoot &r : chunk) named.insert(r.id);
    const std::unordered_set<std::string> ok(outcome.succeeded.begin(), outcome.succeeded.end());
    std::unordered_set<std::string> failedNow;
    std::vector<MutationRoot> back;
    for (const MutationRoot &r : inFlight_) {
        if (named.count(r.id) == 0) {
            back.push_back(r);
            continue;
        }
        if (ok.count(r.id) != 0) {
            succeeded_.push_back(r.id);
        } else {
            failed_.push_back(r.id);
            failedNow.insert(r.id);
        }
    }
    for (const auto &entry : outcome.rootErrors) {
        if (failedNow.count(entry.first) != 0) rootErrors_.push_back(entry);
    }
    for (const std::string &id : outcome.failedWithoutError) {
        if (failedNow.count(id) != 0) failedWithoutError_.push_back(id);
    }
    if (firstReason_.empty()) {
        const ActivityResult own = activityResultFor(outcome, named.size(), "propose");
        if (!own.succeeded) firstReason_ = own.reason.empty() ? std::string("failed") : own.reason;
    }
    pending_.insert(pending_.begin(), back.begin(), back.end());
    inFlight_.clear();
    chunksRecorded_++;
}

std::vector<std::string> ProposeChain::pendingIds() const {
    std::vector<std::string> out;
    out.reserve(pending_.size());
    for (const MutationRoot &r : pending_) out.push_back(r.id);
    return out;
}

std::vector<std::string> ProposeChain::notProposed() const {
    std::vector<std::string> out;
    out.reserve(inFlight_.size() + pending_.size());
    for (const MutationRoot &r : inFlight_) out.push_back(r.id);
    for (const MutationRoot &r : pending_) out.push_back(r.id);
    return out;
}

size_t ProposeChain::chunkCount() const {
    return chunksStarted_ + (pending_.size() + kProposeChunkSize - 1) / kProposeChunkSize;
}

ProposeChainProgress ProposeChain::progress() const {
    ProposeChainProgress out;
    out.done = clamp32(done());
    out.total = clamp32(total());
    if (done() > 0 && !inFlight_.empty()) out.current = inFlight_.front();
    return out;
}

const MutationRoot *ProposeChain::firstNamed() const {
    if (named() == 0) return nullptr;
    std::unordered_set<std::string> namedIds(succeeded_.begin(), succeeded_.end());
    namedIds.insert(failed_.begin(), failed_.end());
    for (const MutationRoot &r : added_) {
        if (namedIds.count(r.id) != 0) return &r;
    }
    return nullptr;
}

std::string ProposeChain::tallyText(bool withChunks) const {
    const size_t n = named();
    std::string out;
    if (n > 0 || skippedNotes_.empty()) {
        out = "done for ";
        out += failed_.empty() ? plural(n, "root", "roots")
                               : std::to_string(succeeded_.size()) + " of " + plural(n, "root", "roots");
        if (withChunks) out += " in " + plural(chunksRecorded_, "chunk", "chunks");
        if (!failed_.empty()) out += "; failed: " + joined(failed_, " ");
    }
    if (!skippedNotes_.empty()) {
        if (!out.empty()) out += "; ";
        out += "skipped: " + joined(skippedNotes_, ", ");
    }
    return out;
}

std::string ProposeChain::summaryLine() const {
    // Every root skipped: "propose: nothing proposed; skipped: ...".
    std::string out = std::string("propose: ") + (named() == 0 && !skippedNotes_.empty() ? "nothing proposed; " : "") +
                      tallyText(true);
    if (failed_.empty() && !firstReason_.empty()) out += "; " + firstReason_;
    return out;
}

std::string ProposeChain::stopLine(const std::string &reason) const {
    std::string out = chunksRecorded_ == 0
                          ? "propose: stopped before the first chunk (" + reason + ")"
                          : "propose: stopped after chunk " + std::to_string(chunksRecorded_) + " of " +
                                std::to_string(chunkCount()) + " (" + reason + ")";
    if (named() > 0 || !skippedNotes_.empty()) out += "; " + tallyText(false);
    const std::vector<std::string> left = notProposed();
    if (!left.empty()) out += "; " + plural(left.size(), "root", "roots") + " not proposed: " + joined(left, " ");
    return out;
}

ActivityResult ProposeChain::result() const {
    if (named() == 0 && !skipped_.empty()) {
        // Nothing proposed: never a check.
        ActivityResult none;
        none.succeeded = false;
        none.reason = "all " + plural(skipped_.size(), "album", "albums") + " skipped (not resolved now)";
        none.detail = summaryLine();
        return none;
    }
    MutationOutcome all;
    all.succeeded = succeeded_;
    all.rootErrors = rootErrors_;
    all.failedWithoutError = failedWithoutError_;
    all.isError = !failed_.empty() || !firstReason_.empty();
    all.consoleLine = summaryLine();
    ActivityResult r = activityResultFor(all, named(), "propose");
    // Where activityResultFor would parse the summary line: the first
    // failing chunk's own reason instead.
    const bool someOfAll = !succeeded_.empty() && !failed_.empty();
    if (!r.succeeded && rootErrors_.empty() && !someOfAll && !firstReason_.empty()) r.reason = firstReason_;
    return r;
}

} // namespace intake
