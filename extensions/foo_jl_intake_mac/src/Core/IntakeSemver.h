//
//  IntakeSemver.h
//  foo_jl_intake
//
//  Version checks against the `cli` string of `intake version --json`
//  (doc 03, "Versioning": `cli` is a semver string). Used for feature
//  detection where the contract has no capability list yet (PLAN.md 3.4,
//  "Reject feature detection"; CR-004 C10 asks for `commands[]`).
//
//  Deliberately strict: only a plain "MAJOR.MINOR.PATCH" counts, each part
//  decimal digits with no leading zero (except "0" itself) and at most nine
//  digits. Anything else (a pre-release such as "0.2.1-beta", build metadata,
//  a "v" prefix, whitespace, garbage, an empty string) is unparseable, and an
//  unparseable version never satisfies a minimum. A feature then stays off,
//  which is the safe side for every check made with it.
//
//  Thread-safety: pure functions, no shared state.
//

#pragma once

#include <string_view>

namespace intake {

struct SemVer {
    int major = 0;
    int minor = 0;
    int patch = 0;
};

// True and `out` filled when `text` is exactly "MAJOR.MINOR.PATCH" (see
// above); false and `out` untouched otherwise.
bool parseSemver(std::string_view text, SemVer &out);

// True when `version` parses and is at least major.minor.patch.
bool semverAtLeast(std::string_view version, int major, int minor, int patch);

// `intake reject` exists from CLI 0.2.0 (feature/intake-cli 0533e25).
inline bool cliSupportsReject(std::string_view cliVersion) {
    return semverAtLeast(cliVersion, 0, 2, 0);
}

// `intake execute <ids...> --resume` resumes only the named roots from CLI
// 0.2.1; older CLIs resume every `placing` root.
inline bool cliSupportsPerRootResume(std::string_view cliVersion) {
    return semverAtLeast(cliVersion, 0, 2, 1);
}

} // namespace intake
