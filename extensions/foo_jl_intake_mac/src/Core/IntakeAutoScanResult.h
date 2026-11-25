//
//  IntakeAutoScanResult.h
//  foo_jl_intake
//
//  B12: what one automatic `scan <income>` call ended with, as the mutation
//  lane needs it (IntakeActions runs the scan; IntakeAutoScanDriver feeds
//  the exit to the scheduler), and which roots the propose after it names.
//  Pure: no I/O.
//
//  The reply (readScanReply). Doc 03 does not pin scan's `data`, so it is
//  read leniently: an array of blocks, one per income scanned, each an
//  object whose `written` array holds the roots the scan wrote (objects with
//  `id`, `root_path`, `status`) and whose `kept` array the roots it left as
//  they were (CLI 0.3.0 commands.ts ScanBlock). Anything else (no array, a
//  block that is no object, a missing or mistyped member) adds nothing; the
//  counts are known once some block has a `written` or `kept` array. A row
//  of `written` counts even without a string id; only rows with one are
//  listed (the auto-propose after the scan names roots by id).
//
//  The outcome (autoScanOutcome), from the CliResult:
//   - exit: E_NO_CLI is Refused (nothing usable ran); E_CLI_TIMEOUT is
//     CapKilled (a scan is class Mutating: the runner kills it only at the
//     15-minute cap); every other outcome is Finished.
//   - line, one Info line (never an Error line, never a dialog):
//       ok        "auto-scan: local done in 12.3 s: 2 new roots, 1 kept"
//                 ("auto-scan: local done in 12.3 s" when the counts are
//                 not known)
//       partial   "auto-scan: local done in 12.3 s with errors: 2 new
//                 roots, 1 kept; <errors>"
//       failed,   "auto-scan: local failed: <errors>"
//       E_NO_CLI,
//       timeout
//       cancelled "auto-scan: local cancelled"
//     <errors>: up to three of "CODE: msg (path)" joined with "; ", then
//     "(+N more)".
//   - activity, the status bar's result: succeeded only for exit 0 (the
//     count is the roots written: "Scanned local: 2 new albums"); failed
//     otherwise, so a scan with errors never shows the check icon. Its
//     reason is the first error as "CODE: msg" ("stopped at the 15-minute
//     cap" for the timeout, "cancelled"), its detail the line.
//
//  The auto-propose (proposeAfterScan; PLAN-B12 scope addition 1): after a
//  scan that exited 0 or 1, Integration runs `propose <ids>` in the same
//  lane run for the roots this function picks, then reloads once.
//  Picked: the rows of `written` with a string id whose `status` is exactly
//  "resolved". `written` holds only the roots this scan wrote: without
//  --force the CLI never rewrites a folder that already has a sidecar, it
//  lists it in `kept` (resolver.ts resolveTree keepDir), so a root the scan
//  kept is never proposed. Its `status` is the one the resolver just gave
//  (resolver.ts buildSidecar: "resolved" at or above the review threshold,
//  else "new"), so no `status` call is needed. Skipped, with one Debug
//  line: a new root (doc 03: propose only from resolved; doc 01: new is
//  never auto-proposed), a row with any other or no status, and a root that
//  is the income folder itself (loose files at its top: the loader ignores
//  such a root, IntakeLoadPolicy dropIncomeFolderRoots, so nothing acts on
//  it; compared as IntakePath keys, as both paths are the CLI's spelling of
//  one income). Any other outcome (exit 2, E_NO_CLI, E_CLI_TIMEOUT,
//  cancelled) proposes nothing. The scan's errors do not filter: they name
//  an archive that failed to unpack or an income path that is missing,
//  never a root it wrote. Ids keep the scan's order; a repeated id counts
//  once. A resolved root that needs review is proposed too (`propose <id>`
//  by id proposes it; the flag stays).
//  No user choice is at stake: a root the scan just wrote has no assignment
//  and no proposal yet, so propose runs identify and the assign engine for
//  it (tools/intake commands-p3.ts cmdPropose). A root left with no target
//  (E_NO_TARGET) stays resolved.
//
//  Thread-safety: pure functions; readScanReply reads Foundation objects
//  (call it inside an autorelease pool, as GCD and the main thread give).
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeActivity.h"         // ActivityResult
#include "IntakeAutoScan.h"         // AutoScanExit
#include "IntakeCliRunner.h"        // CliResult
#include "IntakeEnvelope.h"         // CliError, CliOutcome
#include "IntakeMutationResult.h"   // MutationRoot

namespace intake {

// One root a scan wrote (data[].written[]).
struct ScanWrittenRoot {
    std::string id;
    std::string rootPath;  // root_path; "" when absent
    std::string status;    // the status written ("new", "resolved", ...); "" when absent
};

struct ScanReply {
    bool counted = false;     // some block has a `written` or `kept` array
    size_t writtenCount = 0;  // the rows of every block's `written`
    size_t keptCount = 0;     // the rows of every block's `kept`
    std::vector<ScanWrittenRoot> written;  // the `written` rows with a string id, in order
};

// See the top of this file. nil, or any other shape, is a reply with no
// counts.
ScanReply readScanReply(id _Nullable data);

struct AutoScanOutcome {
    AutoScanExit exit = AutoScanExit::Finished;
    std::string line;          // the Info line
    ActivityResult activity;   // the status bar's result
    size_t newRoots = 0;       // its count (reply.writtenCount): 0 for none or not known
    ScanReply reply;
};

// `income`: the income's name, for the texts.
AutoScanOutcome autoScanOutcome(const std::string &income, const CliResult &result);

// "auto-scan: scanning income local (startup)", or "(new files)".
std::string autoScanStartLine(const std::string &income, bool startup);

// The 10 s report (doc 03 "Timeouts": E_CLI_TIMEOUT, the call goes on):
// "auto-scan: local still running (E_CLI_TIMEOUT: no reply after 10 s; the
// scan continues)".
std::string autoScanBudgetLine(const std::string &income);

// "CODE: msg (path)" for up to three errors, joined with "; ", then
// "(+N more)"; "" for none.
std::string autoScanErrorsText(const std::vector<CliError> &errors);

// What the auto-propose after a scan names (see the top of this file).
struct ScanFollowUp {
    std::vector<std::string> propose;  // ids for `propose`, the scan's order
    std::vector<MutationRoot> roots;   // the same roots: root_path, status Resolved, no target
    // Written but not proposed, in order: "itk_... (new)", "itk_... (no
    // status)", "itk_... (the income folder itself)".
    std::vector<std::string> skipped;
    // "auto-scan: local: no propose for 2 roots: itk_a (new), itk_b (new)";
    // empty when nothing was skipped.
    std::string skippedLine;
};

// `income`: its name, for the line; `incomePath`: its path from `income
// --json`; `scanOutcome`: the scan's envelope outcome; `reply`: its reply
// (AutoScanOutcome::reply).
ScanFollowUp proposeAfterScan(const std::string &income, const std::string &incomePath, CliOutcome scanOutcome,
                              const ScanReply &reply);

// "propose: starting after auto-scan of local for 2 roots: itk_a itk_b".
std::string autoScanProposeStartLine(const std::string &income, const std::vector<std::string> &ids);

// The propose's 10 s report, like the scan's (one Info line, no tooltip,
// no refresh: the run reloads once, at its end): "propose: still running
// after auto-scan of local (E_CLI_TIMEOUT: no reply after 10 s; the
// propose continues)".
std::string autoScanProposeBudgetLine(const std::string &income);

} // namespace intake
