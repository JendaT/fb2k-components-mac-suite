//
//  IntakeStatusModel.h
//  foo_jl_intake
//
//  One record per row of `intake status --json` (doc 03 v1.2 "JSON
//  conventions"; PLAN.md 3.3). Input is the envelope's `data` member
//  (IntakeEnvelope), an array of sidecar summaries:
//
//    {id, root_path, status, needs_review, cluster:{albumartist, album},
//     proposal:{target_collection, confidence, ranked:[{collection,
//     confidence}], assigned_by, target_path}, placed:{verified,
//     target_path}}
//
//  Rules:
//   - A row lacking a string `id`, `root_path` or `status` (missing, null,
//     another type, empty), or whose `root_path` IntakePath cannot use
//     (relative, another scheme), is dropped and logged. So is a repeat of an
//     id already seen (the first row wins).
//   - An unrecognised `status` string becomes Unknown (renders nothing);
//     the text is kept for the log.
//   - `needs_review` is true only when it is the JSON boolean true.
//   - `proposal` and `placed` may be null or missing.
//   - `proposal.ranked`: absent (CLI before 0.2.0, or not an array) is kept
//     distinct from [] (a proposal made only by `assign --by user`).
//   - `proposal.assigned_by` and `proposal.target_path` are new in contract
//     v1.2 (CLI 0.3.0). Absent (CLI 0.2.1) they are Unknown, never guessed,
//     and never filled in from the sidecar: reading sidecars costs tens of
//     milliseconds each on the share. A present null `target_path` is
//     Null: no target can be built yet ("slot pending": singles,
//     compilations, tier reject).
//   - Unknown fields are ignored (doc 03 "Versioning").
//   - State follows `status`, never the presence of `proposal`.
//
//  root_path is kept twice: `rootPath` exactly as the CLI spelled it (the
//  only spelling sure to address the folder on disk: NFD names on SMB), and
//  `rootKey`, its IntakePath match key (lexical normalisation, NFC), never
//  used for I/O. Integration may rewrite rootKey before the snapshot is built
//  (B3 mount aliases: "/smbfs:<share>/<relative>"); member keys are derived
//  from it, so they follow.
//
//  Thread-safety: parseStatusRows is reentrant and adds its own autorelease
//  pool. IntakeRecord is a plain value.
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeDecorationMap.h"

namespace intake {

enum class IntakeStatus {
    New,
    Resolved,
    Proposed,
    Approved,
    Placing,
    Placed,
    GcDone,
    Rejected,
    Unknown,
};

// "new", "resolved", ..., "gc_done", "rejected"; "unknown" for Unknown.
const char *_Nonnull intakeStatusName(IntakeStatus status);
// The doc 03 status word to IntakeStatus (exact, case-sensitive); Unknown
// for anything else.
IntakeStatus intakeStatusFromString(const std::string &text);

enum class RankedState {
    Absent,  // no `ranked` member, or not an array
    Empty,   // [] : a proposal made only by the user
    Present, // a non-empty array (entries that are not {collection: string} are skipped)
};

struct RankedCandidate {
    std::string collection;
    double confidence = 0;
    bool hasConfidence = false;
};

enum class AssignedBy {
    Unknown, // absent, null or not a string (CLI 0.2.1)
    Engine,  // "engine"
    User,    // "user"
    Other,   // another string (kept in assignedByText)
};

enum class TargetPathState {
    Unknown, // absent (CLI 0.2.1) or not a string
    Null,    // present and null (or ""): slot pending
    Set,     // a non-empty string
};

struct IntakeProposal {
    std::string targetCollection;  // empty when absent
    double confidence = 0;
    bool hasConfidence = false;    // a JSON number (not a boolean)
    RankedState rankedState = RankedState::Absent;
    std::vector<RankedCandidate> ranked;
    AssignedBy assignedBy = AssignedBy::Unknown;
    std::string assignedByText;    // the raw string, when it was one
    TargetPathState targetPathState = TargetPathState::Unknown;
    std::string targetPath;        // when Set
};

struct IntakeRecord {
    std::string id;
    std::string rootPath;   // as the CLI spelled it: for I/O only
    std::string rootKey;    // IntakePath match key: for matching only
    IntakeStatus status = IntakeStatus::Unknown;
    std::string statusText; // the CLI's status string
    bool needsReview = false;
    std::string albumartist; // empty when null or absent
    std::string album;
    bool hasProposal = false;
    IntakeProposal proposal;
    bool hasPlaced = false;
    bool placedVerified = false;
    std::string placedTargetPath;
    // Derived and runtime state, not parsed from the row:
    IntakeRowVisual visual; // set by IntakeSnapshot::build (IntakeDecorationMap)
    std::string lastError;  // set by Integration: a per-command error until the status changes
};

struct StatusParseResult {
    bool ok = false;            // `data` was an array
    std::string error;          // why not, when !ok
    std::vector<IntakeRecord> records;  // in the CLI's order (unspecified: do not rely on it)
    size_t dropped = 0;         // rows dropped and logged
};

// Parses the `data` member of a status envelope (Ok or Partial). Dropped
// rows are logged through IntakeLog: one Info line each for the first 10,
// then one summary line.
StatusParseResult parseStatusRows(id _Nullable data);

} // namespace intake
