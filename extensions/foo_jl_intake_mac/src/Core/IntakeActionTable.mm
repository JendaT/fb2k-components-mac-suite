//
//  IntakeActionTable.mm
//  foo_jl_intake
//

#include "IntakeActionTable.h"

#include "IntakeReviewRule.h"

#include <algorithm>
#include <unordered_set>

namespace intake {

namespace {

const char *const kEllipsis = "\xE2\x80\xA6";  // U+2026
const char *const kEnDash = " \xE2\x80\x93 ";  // " U+2013 "

constexpr uint32_t kSerialMask = 0xFFFFFFu;

bool assignable(IntakeStatus s) {
    return s == IntakeStatus::New || s == IntakeStatus::Resolved || s == IntakeStatus::Proposed ||
           s == IntakeStatus::Approved;
}

bool targetNotNull(const IntakeRecord &r) {
    // Unknown (CLI before 0.3.0) does not block: the CLI refuses itself.
    return !(r.hasProposal && r.proposal.targetPathState == TargetPathState::Null);
}

bool hasLiveRun(const ActionContext &c, const std::string &id) {
    return std::find(c.liveRunIds.begin(), c.liveRunIds.end(), id) != c.liveRunIds.end();
}

// The fixed table order (doc 04 v1.2 table), Refresh last.
const IntakeAction kOrder[] = {
    IntakeAction::Propose, IntakeAction::AssignTo, IntakeAction::AssignOther, IntakeAction::Approve,
    IntakeAction::Reject,  IntakeAction::Execute,  IntakeAction::Resume,      IntakeAction::Swap,
    IntakeAction::DeleteLocal,
};

bool exposes(const std::vector<IntakeAction> &exposed, IntakeAction a) {
    return std::find(exposed.begin(), exposed.end(), a) != exposed.end();
}

ActionEntry refreshEntry() {
    ActionEntry e;
    e.action = IntakeAction::Refresh;
    e.title = actionBaseTitle(IntakeAction::Refresh);
    e.enabled = true;
    return e;
}

std::string lastComponent(const std::string &path) {
    std::string p = path;
    while (p.size() > 1 && p.back() == '/') p.pop_back();
    const size_t slash = p.rfind('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

} // anonymous namespace

const char *actionName(IntakeAction action) {
    switch (action) {
        case IntakeAction::Propose: return "propose";
        case IntakeAction::AssignTo: return "assign";
        case IntakeAction::AssignOther: return "assign-other";
        case IntakeAction::Approve: return "approve";
        case IntakeAction::Reject: return "reject";
        case IntakeAction::Execute: return "execute";
        case IntakeAction::Resume: return "resume";
        case IntakeAction::Swap: return "swap";
        case IntakeAction::DeleteLocal: return "delete-local";
        case IntakeAction::Refresh: return "refresh";
    }
    return "unknown";
}

bool actionIsMutating(IntakeAction action) {
    return action != IntakeAction::Swap && action != IntakeAction::Refresh;
}

bool actionCommand(IntakeAction action, CliCommand &out) {
    switch (action) {
        case IntakeAction::Propose: out = CliCommand::Propose; return true;
        case IntakeAction::AssignTo:
        case IntakeAction::AssignOther: out = CliCommand::Assign; return true;
        case IntakeAction::Approve: out = CliCommand::Approve; return true;
        case IntakeAction::Reject: out = CliCommand::Reject; return true;
        case IntakeAction::Execute: out = CliCommand::Execute; return true;
        case IntakeAction::Resume: out = CliCommand::Resume; return true;
        case IntakeAction::DeleteLocal: out = CliCommand::Gc; return true;
        case IntakeAction::Swap:
        case IntakeAction::Refresh: return false;
    }
    return false;
}

std::string actionBaseTitle(IntakeAction action, const std::string &collection) {
    switch (action) {
        case IntakeAction::Propose: return "Propose";
        case IntakeAction::AssignTo: return "Assign to " + collection;
        case IntakeAction::AssignOther: return "Assign to other collection";
        case IntakeAction::Approve: return "Approve";
        case IntakeAction::Reject: return "Reject";
        case IntakeAction::Execute: return "Execute placement";
        case IntakeAction::Resume: return "Resume placement";
        case IntakeAction::Swap: return "Swap to library paths";
        case IntakeAction::DeleteLocal: return "Delete local copy";
        case IntakeAction::Refresh: return "Refresh intake status";
    }
    return std::string();
}

bool actionAsksFirst(IntakeAction action, const ActionContext &context) {
    switch (action) {
        case IntakeAction::AssignOther:
        case IntakeAction::Execute: return true;
        case IntakeAction::Reject: return context.confirmReject;
        case IntakeAction::DeleteLocal: return context.confirmGc;
        default: return false;
    }
}

const std::vector<IntakeAction> &menuActions() {
    static const std::vector<IntakeAction> actions = {
        IntakeAction::Propose, IntakeAction::AssignTo, IntakeAction::AssignOther, IntakeAction::Approve,
        IntakeAction::Reject,  IntakeAction::Execute,  IntakeAction::Resume,      IntakeAction::Swap,
        IntakeAction::DeleteLocal, IntakeAction::Refresh};
    return actions;
}

const std::vector<IntakeAction> &b6Actions() {
    static const std::vector<IntakeAction> actions = {IntakeAction::Propose, IntakeAction::Approve,
                                                      IntakeAction::Reject, IntakeAction::Refresh};
    return actions;
}

bool rootQualifies(IntakeAction action, const IntakeRecord &r, const ActionContext &c) {
    switch (action) {
        case IntakeAction::Propose:
            return r.status == IntakeStatus::Resolved;
        case IntakeAction::AssignTo:
            return assignable(r.status) && !assignAlternates(r, 1).empty();
        case IntakeAction::AssignOther:
            return assignable(r.status);
        case IntakeAction::Approve:
            return r.status == IntakeStatus::Proposed && targetNotNull(r);
        case IntakeAction::Reject:
            return assignable(r.status) && cliSupportsCommand(c.cli, CliCommand::Reject);
        case IntakeAction::Execute:
            return r.status == IntakeStatus::Approved && targetNotNull(r);
        case IntakeAction::Resume:
            return r.status == IntakeStatus::Placing && cliSupportsCommand(c.cli, CliCommand::Resume) &&
                   !hasLiveRun(c, r.id);
        case IntakeAction::Swap:
        case IntakeAction::DeleteLocal:
            return r.status == IntakeStatus::Placed && r.hasPlaced && r.placedVerified;
        case IntakeAction::Refresh:
            return true;
    }
    return false;
}

std::vector<std::string> assignAlternates(const IntakeRecord &r, size_t limit) {
    std::vector<std::string> out;
    if (!r.hasProposal || r.proposal.rankedState != RankedState::Present) return out;
    for (const RankedCandidate &c : r.proposal.ranked) {
        if (out.size() >= limit) break;
        if (c.collection.empty() || c.collection == r.proposal.targetCollection) continue;
        if (std::find(out.begin(), out.end(), c.collection) != out.end()) continue;
        out.push_back(c.collection);
    }
    return out;
}

bool assignOtherFirst(const std::vector<const IntakeRecord *> &roots, const ActionContext &c) {
    for (const IntakeRecord *r : roots) {
        if (r != nullptr && recordNeedsReview(*r) && rootQualifies(IntakeAction::AssignOther, *r, c)) return true;
    }
    return false;
}

ActionRoot actionRootFor(const IntakeRecord &r) {
    ActionRoot a;
    a.id = r.id;
    a.rootPath = r.rootPath;
    a.albumartist = r.albumartist;
    a.album = r.album;
    a.status = r.status;
    if (r.hasProposal) a.targetCollection = r.proposal.targetCollection;
    if (r.hasProposal && r.proposal.targetPathState == TargetPathState::Set) a.targetPath = r.proposal.targetPath;
    a.placedVerified = r.hasPlaced && r.placedVerified;
    if (r.hasPlaced) a.placedTargetPath = r.placedTargetPath;
    if (r.hasProposal && r.proposal.rankedState == RankedState::Present && !r.proposal.ranked.empty()) {
        a.topRanked = r.proposal.ranked.front().collection;
    }
    return a;
}

std::vector<const IntakeRecord *> selectionRoots(const std::vector<const IntakeRecord *> &rows) {
    std::vector<const IntakeRecord *> out;
    std::unordered_set<std::string> seen;
    for (const IntakeRecord *r : rows) {
        if (r == nullptr) continue;
        if (!seen.insert(r->id).second) continue;
        out.push_back(r);
    }
    return out;
}

std::vector<const IntakeRecord *> libraryOnlyRoots(const std::vector<const IntakeRecord *> &incomeRoots,
                                                   const std::vector<const IntakeRecord *> &libraryRows) {
    std::unordered_set<std::string> seen;
    for (const IntakeRecord *r : incomeRoots) {
        if (r != nullptr) seen.insert(r->id);
    }
    std::vector<const IntakeRecord *> out;
    for (const IntakeRecord *r : libraryRows) {
        if (r == nullptr || !seen.insert(r->id).second) continue;
        out.push_back(r);
    }
    return out;
}

ActionTable buildActionTable(const std::vector<const IntakeRecord *> &roots, const ActionContext &c,
                             const std::vector<IntakeAction> &exposed,
                             const std::vector<const IntakeRecord *> &libraryRoots) {
    ActionTable table;
    if (!c.cliConfigured) return table;
    const size_t m = roots.size() + libraryRoots.size();
    table.selectedRoots = m;

    if (!c.inert && m > 0) {
        for (IntakeAction action : kOrder) {
            if (!exposes(exposed, action)) continue;
            // Reject is listed only when the CLI has it (doc 04: "if detected"),
            // Resume only when the CLI resumes by id (0.2.1 or later: 0.2.0
            // would resume every placing root).
            if (action == IntakeAction::Reject && !cliSupportsCommand(c.cli, CliCommand::Reject)) continue;
            if (action == IntakeAction::Resume && !cliSupportsCommand(c.cli, CliCommand::Resume)) continue;

            if (action == IntakeAction::AssignTo) {
                // Quick assign: one selected root (an income root: library
                // roots count toward m), its alternates only; never when
                // unmapped rows may have been other roots.
                if (m != 1 || roots.size() != 1 || c.selectionIncomplete || !rootQualifies(action, *roots[0], c)) {
                    continue;
                }
                for (const std::string &collection : assignAlternates(*roots[0])) {
                    ActionEntry e;
                    e.action = action;
                    e.collection = collection;
                    e.title = actionBaseTitle(action, collection);
                    e.roots.push_back(actionRootFor(*roots[0]));
                    e.enabled = !c.laneBusy;
                    if (c.laneBusy && c.executeRunning) e.title += " (execute running)";
                    table.entries.push_back(std::move(e));
                }
                continue;
            }

            ActionEntry e;
            e.action = action;
            e.title = actionBaseTitle(action);
            for (const IntakeRecord *r : roots) {
                if (rootQualifies(action, *r, c)) e.roots.push_back(actionRootFor(*r));
            }
            // Rows already swapped to their library copies: Delete only.
            if (action == IntakeAction::DeleteLocal) {
                for (const IntakeRecord *r : libraryRoots) {
                    if (rootQualifies(action, *r, c)) e.roots.push_back(actionRootFor(*r));
                }
            }
            const size_t n = e.roots.size();
            e.enabled = n > 0;
            if (n > 0 && n < m) e.title += " (" + std::to_string(n) + " of " + std::to_string(m) + ")";
            if (actionIsMutating(action) && c.laneBusy) {
                e.enabled = false;
                if (c.executeRunning) e.title += " (execute running)";
            }
            if (actionAsksFirst(action, c)) e.title += kEllipsis;
            table.entries.push_back(std::move(e));
        }
        // "First when amber" (doc 04 v1.2): the picker moves to the top; the
        // other items keep their order.
        if (assignOtherFirst(roots, c)) {
            auto other = std::find_if(table.entries.begin(), table.entries.end(),
                                      [](const ActionEntry &e) { return e.action == IntakeAction::AssignOther; });
            if (other != table.entries.end()) std::rotate(table.entries.begin(), other, other + 1);
        }
    }
    if (table.entries.size() >= kMaxActionEntries) table.entries.resize(kMaxActionEntries - 1);
    table.entries.push_back(refreshEntry());
    return table;
}

const ActionEntry *findEntry(const ActionTable &table, IntakeAction action) {
    for (const ActionEntry &e : table.entries) {
        if (e.action == action) return &e;
    }
    return nullptr;
}

std::vector<ActionRoot> gcEligibleRoots(const std::vector<ActionRoot> &roots) {
    std::vector<ActionRoot> out;
    std::unordered_set<std::string> seen;
    for (const ActionRoot &r : roots) {
        if (r.status != IntakeStatus::Placed || !r.placedVerified || r.id.empty()) continue;
        if (!seen.insert(r.id).second) continue;
        out.push_back(r);
    }
    return out;
}

bool requestForEntry(const ActionEntry &entry, const std::string &reason, CliRequest &out, std::string *why) {
    auto refuse = [why](const char *text) {
        if (why) *why = text;
        return false;
    };
    CliCommand command;
    if (!actionCommand(entry.action, command)) return refuse("not a CLI command");
    if (!entry.enabled) return refuse("disabled");
    if (entry.roots.empty()) return refuse("no qualifying root");
    CliRequest r;
    r.command = command;
    std::unordered_set<std::string> seen;
    if (command == CliCommand::Gc) {
        // The permanent gc guard: placed, verified roots only, whatever the
        // entry holds.
        for (const ActionRoot &root : gcEligibleRoots(entry.roots)) r.ids.push_back(root.id);
        if (r.ids.empty()) return refuse("no placed root (gc never runs on another status)");
    } else {
        for (const ActionRoot &root : entry.roots) {
            if (seen.insert(root.id).second) r.ids.push_back(root.id);
        }
    }
    if (command == CliCommand::Reject) r.reason = reason;
    if (command == CliCommand::Assign) {
        if (entry.collection.empty()) return refuse("no collection");
        r.collection = entry.collection;
    }
    out = std::move(r);
    return true;
}

std::string albumLabel(const ActionRoot &root) {
    if (!root.albumartist.empty() && !root.album.empty()) return root.albumartist + kEnDash + root.album;
    if (!root.album.empty()) return root.album;
    if (!root.albumartist.empty()) return root.albumartist;
    std::string folder = lastComponent(root.rootPath);
    return folder.empty() ? root.id : folder;
}

std::string affectedAlbumsText(const std::vector<ActionRoot> &roots, size_t maxListed) {
    std::string out;
    const size_t listed = std::min(roots.size(), maxListed);
    for (size_t i = 0; i < listed; i++) {
        if (!out.empty()) out += "\n";
        out += albumLabel(roots[i]);
    }
    if (roots.size() > listed) {
        if (!out.empty()) out += "\n";
        out += "and " + std::to_string(roots.size() - listed) + " more";
    }
    return out;
}

uint32_t encodeActionId(uint32_t menuSerial, size_t index) {
    return ((menuSerial & kSerialMask) << 8) | static_cast<uint32_t>(index & 0xFF);
}

bool decodeActionId(uint32_t actionId, uint32_t &menuSerial, size_t &index) {
    menuSerial = (actionId >> 8) & kSerialMask;
    index = actionId & 0xFF;
    return menuSerial != 0;
}

uint32_t nextMenuSerial(uint32_t serial) {
    uint32_t next = (serial + 1) & kSerialMask;
    return next == 0 ? 1 : next;
}

} // namespace intake
