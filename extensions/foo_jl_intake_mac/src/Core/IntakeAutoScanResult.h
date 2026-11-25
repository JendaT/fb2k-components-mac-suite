//
//  IntakeAutoScanResult.h
//  foo_jl_intake
//
//  B12: what one automatic `scan <income>` call ended with, as the mutation
//  lane needs it (IntakeActions runs the scan; IntakeAutoScanDriver feeds
//  the exit to the scheduler). Pure: no I/O.
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
//  Thread-safety: pure functions; readScanReply reads Foundation objects
//  (call it inside an autorelease pool, as GCD and the main thread give).
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeActivity.h"     // ActivityResult
#include "IntakeAutoScan.h"     // AutoScanExit
#include "IntakeCliRunner.h"    // CliResult
#include "IntakeEnvelope.h"     // CliError

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

} // namespace intake
