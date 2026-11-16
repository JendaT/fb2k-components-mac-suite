//
//  IntakeMutationResult.h
//  foo_jl_intake
//
//  What one finished mutating call means for each root it named (doc 04 v1.2
//  "Envelope", "Failure behavior"; doc 03 v1.2 "Legal source statuses",
//  "Error surfaces"; PLAN.md B6). Pure: Integration records the per-root
//  errors (IntakeRootErrors), logs the line and refreshes.
//
//  Success: a root succeeded when its id is in `data` (Ok, or Partial:
//  exit 1 applies the subset). Every other named root failed.
//
//  Which root an error belongs to. CLI errors carry {code, msg, path}, and
//  the per-root ones name the root's folder in `path` (commands-p2/p3.ts
//  `path: root.dir`), never its id; virtual roots and singles share a
//  folder. So, over the failed roots in the order they were named, first
//  the errors that name a root by id (rule 1), then the rest:
//   1. an error whose `path` is a named id goes to that root; one without
//      a path whose msg names ids of the call as whole words (the CLI's
//      E_NOT_FOUND "no sidecar with id itk_...", path null) goes to each
//      failed root it names. Neither is ever broadcast, and both are
//      placed before rule 2 so they never take another root's folder slot;
//   2. an error whose `path` is a root's folder (compared as IntakePath
//      keys, else byte for byte) goes to the first failed root in that
//      folder that has no error yet: the CLI walks the roots in argument
//      order, so the k-th error for a folder belongs to the k-th failed
//      root there. Surplus errors for a folder join the last root's text;
//  1c. an error whose `path` is a named root's target folder
//      (proposal.target_path, compared as IntakePath keys, else byte for
//      byte: the CLI's E_TARGET_EXISTS and the out-of-tier E_NO_TARGET name
//      the target, commands-p3.ts) goes to the first failed root with that
//      target that has no error yet, else the last one; the path stays in
//      the text. Never broadcast (a target only succeeded roots have places
//      it nowhere); placed in pass 1 like the id rules;
//   3. an error matching no root (no path and no id in its msg, a path
//      outside them) is the command's own: it goes to every failed root
//      left without one.
//  E_BAD_STATUS on one root therefore never touches the others.
//  Host-synthesized results (E_NO_CLI, E_CLI_TIMEOUT at the hard cap) fail
//  every named root with that text. Cancelled has no errors.
//
//  Text: "<command>: <renderError>" (IntakeErrorMap: known codes get their
//  phrase, unknown codes are rendered from msg, or the code). The path is
//  left out when it only repeats the root's own folder or id; any other
//  path stays. Two errors for one root are joined with " · " (U+00B7).
//
//  Console line (one per call): what ran, how many roots succeeded, the
//  first error rendered with its path and "(+N more)".
//
//  Thread-safety: pure function.
//

#pragma once

#include <string>
#include <utility>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeEnvelope.h"
#include "IntakeStatusModel.h"

namespace intake {

// A root as it was named in the call (captured at menu time).
struct MutationRoot {
    std::string id;
    std::string rootPath;  // as the CLI spelled it in `status`
    // The status the menu showed when the action was chosen: the baseline
    // of the root's error (RootErrorStore::set). Unknown: none.
    IntakeStatus status = IntakeStatus::Unknown;
    // proposal.target_path when known (rule 1c); empty otherwise.
    std::string targetPath;
};

struct MutationOutcome {
    std::vector<std::string> succeeded;                         // ids in `data`, in naming order
    std::vector<std::pair<std::string, std::string>> rootErrors; // id -> tooltip text, naming order
    std::vector<std::string> failedWithoutError;                // failed, but no error named them
    std::string consoleLine;
    bool isError = false;  // log the line at Error level
};

// `displayName` replaces cliCommandName(command) in the texts and the
// console line when given ("execute dry run", B8).
MutationOutcome summarizeMutation(CliCommand command, const std::vector<MutationRoot> &roots,
                                  const EnvelopeResult &envelope, const std::string &displayName = std::string());

} // namespace intake
