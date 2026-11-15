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
//  folder. So, over the failed roots in the order they were named:
//   1. an error whose `path` is a named id goes to that root;
//   2. an error whose `path` is a root's folder (compared as IntakePath
//      keys, else byte for byte) goes to the first failed root in that
//      folder that has no error yet: the CLI walks the roots in argument
//      order, so the k-th error for a folder belongs to the k-th failed
//      root there. Surplus errors for a folder join the last root's text;
//   3. an error matching no failed root (no path, a path outside them) is
//      the command's own: it goes to every failed root left without one.
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

namespace intake {

// A root as it was named in the call (captured at menu time).
struct MutationRoot {
    std::string id;
    std::string rootPath;  // as the CLI spelled it in `status`
};

struct MutationOutcome {
    std::vector<std::string> succeeded;                         // ids in `data`, in naming order
    std::vector<std::pair<std::string, std::string>> rootErrors; // id -> tooltip text, naming order
    std::vector<std::string> failedWithoutError;                // failed, but no error named them
    std::string consoleLine;
    bool isError = false;  // log the line at Error level
};

MutationOutcome summarizeMutation(CliCommand command, const std::vector<MutationRoot> &roots,
                                  const EnvelopeResult &envelope);

} // namespace intake
