//
//  IntakeIncome.h
//  foo_jl_intake
//
//  The `data` of `intake income --json` (doc 03 v1.2, CR-004.7; CLI 0.3.0
//  and later, feature-detected with cliSupportsCommand(Income)): an array
//  `[{name, path, exists}]`, one entry per income folder in income.yaml
//  order. The component only watches these folders (PLAN.md B4); it never
//  reads them for anything else.
//
//  Parsing: `data` must be an array, or the call failed (a per-command
//  error: the watch set keeps the folders of the last good call). An entry
//  that is not an object with an absolute string `path` is skipped and
//  counted. `name` is optional (empty when absent), `exists` defaults to
//  true when absent or not a boolean. Unknown fields are ignored (doc 03).
//  A folder that does not exist is still watched: it may appear later.
//
//  Thread-safety: pure; adds its own autorelease pool.
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstddef>
#include <string>
#include <vector>

namespace intake {

struct IncomeFolder {
    std::string name;
    std::string path;    // absolute, as the CLI spelled it
    bool exists = true;
};

struct IncomeParseResult {
    bool ok = false;      // `data` was an array
    std::string error;    // why not, when !ok
    std::vector<IncomeFolder> folders;
    size_t skipped = 0;   // unusable entries
};

IncomeParseResult parseIncomeFolders(id _Nullable data);

} // namespace intake
