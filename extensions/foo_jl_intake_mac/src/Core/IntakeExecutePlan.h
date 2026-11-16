//
//  IntakeExecutePlan.h
//  foo_jl_intake
//
//  Execute placement…, describe then confirm (doc 04 v1.2 "Context
//  actions", Execute bullet; doc 03 v1.2 `execute --dry-run --json`; PLAN.md
//  3.7 steps 1 and 2). SDK-free: Integration runs the dry run, builds the
//  plan here and shows the sheet text.
//
//  The dry-run reply: `data` is an array with one row per root that passed
//  the pre-checks, {id, root_path, target_path, dry_run, files, artifacts,
//  skipped_shadows}. Every field is optional here: a row without a string
//  id is skipped (nothing could run on it), a field of the wrong type
//  counts as missing, and a count must be a non-negative integer. A root
//  that fails a pre-check is in `errors[]` only.
//
//  Plan: the captured roots (selection order) split into the placeable ones
//  (a row with their id) and the excluded ones, each with the dry run's
//  error text for it (IntakeMutationResult decides which error is whose,
//  shown without the "execute dry run: " prefix) or "not listed by the dry
//  run". A Failed, NoCli or Cancelled dry run places nothing.
//
//  Sheet (main window sheet, buttons Execute and Cancel):
//   - title: "Place this album in the library?" or "Place N albums in the
//     library?" (N placeable);
//   - up to 10 rows "artist – album → target_path (n files, k shadows
//     skipped)", then "and N more". The label is albumLabel (artist and
//     album as the menu captured them, either alone, else the root's folder
//     name, from the row's root_path when the menu had none); " → target"
//     only with a target_path; the parenthesis only with a count, each part
//     only when present ("1 file", "0 shadows skipped": a present 0 is
//     shown, a missing count is left out). Artifacts are not listed;
//   - "Excluded:" and up to 10 "label: why" lines, then "and N more", when
//     any root was excluded;
//   - a last line saying the run continues in the background.
//
//  Thread-safety: pure functions (Foundation objects are only read).
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeActionTable.h"
#include "IntakeEnvelope.h"
#include "IntakeMutationResult.h"

namespace intake {

struct DryRunRow {
    std::string id;
    std::string rootPath;     // empty when absent
    std::string targetPath;   // empty when absent or null
    bool hasFiles = false;
    long long files = 0;
    bool hasArtifacts = false;
    long long artifacts = 0;
    bool hasShadows = false;
    long long skippedShadows = 0;
};

struct DryRunParse {
    bool isArray = false;          // `data` was an array
    std::vector<DryRunRow> rows;   // in reply order, one per id (the first)
    size_t skipped = 0;            // rows without a usable id, and repeats
};

DryRunParse parseDryRunRows(id _Nullable data);

// The name the dry run goes by in texts and log lines.
extern const char *_Nonnull const kExecuteDryRunName;  // "execute dry run"

struct ExecutePlan {
    std::vector<ActionRoot> placeable;     // selection order
    std::vector<DryRunRow> rows;           // aligned with placeable
    std::vector<ActionRoot> excluded;      // selection order
    std::vector<std::string> excludedWhy;  // aligned with excluded
    // summarizeMutation(Execute, roots, dryRun, "execute dry run"): the
    // excluded roots' tooltips (rootErrors) and the console line.
    MutationOutcome outcome;
};

ExecutePlan planExecute(const std::vector<ActionRoot> &roots, const EnvelopeResult &dryRun);

// The ids of plan.placeable, in order.
std::vector<std::string> placeableIds(const ExecutePlan &plan);

std::string executeSheetRow(const ActionRoot &root, const DryRunRow &row);
std::string executeSheetTitle(const ExecutePlan &plan);
std::string executeSheetText(const ExecutePlan &plan, size_t maxListed = 10);
// One line for logs and the test aid: "N placeable, M excluded: <row> |
// <row> | excluded: <label>: <why>" with the sheet's caps.
std::string executeSheetSummary(const ExecutePlan &plan, size_t maxListed = 10);

} // namespace intake
