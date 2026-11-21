//
//  IntakeAssignPropose.h
//  foo_jl_intake
//
//  Assign, then propose (B13-lite; doc 04 "Context actions"): after a
//  successful `assign <ids> --collection X --by user` from "Assign to X" or
//  the picker, Integration runs `propose <ids>` in the same lane run for the
//  roots this function picks, then reloads once.
//
//  Picked: the roots the assign named whose status was `resolved` when the
//  menu captured them, and that the assign did not fail or name in its
//  errors:
//   - the assign's outcome is Ok or Partial (exit 0 or 1). Anything else
//     (exit 2, E_NO_CLI, E_CLI_TIMEOUT, cancelled) proposes nothing;
//   - the id is in MutationOutcome::succeeded (in `data`), has no entry in
//     MutationOutcome::rootErrors, and no error's `path` is the id.
//  Skipped, with one Debug line: roots the assign changed whose status was
//  not resolved. A new root cannot be proposed (doc 03: propose only from
//  resolved, E_BAD_STATUS otherwise), and on a proposed or approved root
//  the assign already rewrote the target in place (tools/intake
//  commands-p2.ts). Roots whose assign failed are neither picked nor
//  listed: their error already shows.
//  Ids keep the assign's naming order; a repeated id counts once.
//
//  Why propose keeps the user's choice: propose runs the assign engine only
//  when no proposal exists, and its target refresh keeps the collection
//  (commands-p2.ts cmdPropose, refreshTarget), so a resolved root keeps the
//  collection the user assigned and gains its status `proposed`.
//
//  Thread-safety: pure function.
//

#pragma once

#include <string>
#include <vector>

#include "IntakeEnvelope.h"
#include "IntakeMutationResult.h"

namespace intake {

struct AssignFollowUp {
    std::vector<std::string> propose;  // ids for `propose`, naming order
    std::vector<MutationRoot> roots;   // the same roots, as the assign named them
    std::vector<std::string> skipped;  // assigned but not resolved: "itk_... (new)", naming order
    // "assign: no propose for N root(s) not resolved before the assign:
    // itk_a (new), itk_b (proposed)"; empty when nothing was skipped.
    std::string skippedLine;
};

AssignFollowUp proposeAfterAssign(const std::vector<MutationRoot> &assigned, CliOutcome assignOutcome,
                                  const MutationOutcome &outcome, const std::vector<CliError> &errors);

} // namespace intake
