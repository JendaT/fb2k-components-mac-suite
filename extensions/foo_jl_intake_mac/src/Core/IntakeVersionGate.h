//
//  IntakeVersionGate.h
//  foo_jl_intake
//
//  The version gate (doc 03 v1.2 "Versioning", "Component read patterns";
//  CR-004.1): the component decorates only when `intake version --json`
//  reports the one schema it was built for. `data.schema` must be the JSON
//  integer 1. The string "1", 1.0, 1e0, true, 2, null and a missing member
//  all fail, and so does a `data` that is not an object. `engine` is
//  ignored (it MAY be null when the beets shim is absent).
//
//  The same `data` carries `cli` and the optional `commands` array; the
//  result hands them on (parseCliVersionInfo) so feature detection
//  (cliSupportsCommand, IntakeCapabilities.h) works from the one version
//  call. They are filled even when the gate fails, for the log line.
//
//  What a failure means is the caller's business (PLAN.md 3.4): provider-wide
//  inert, one log line, the reason in the preferences status line.
//
//  Thread-safety: pure functions, no shared state. checkVersionGate reads
//  Foundation objects and adds its own autorelease pool.
//

#pragma once

#import <Foundation/Foundation.h>

#include <string>

#include "IntakeCapabilities.h"

namespace intake {

// The one `schema` value this component supports (doc 03: "The component's
// supported schema for P4 is 1").
inline constexpr long long kSupportedSchema = 1;

enum class GateVerdict {
    Pass,
    DataNotObject,     // `data` is nil, null, an array, ...
    SchemaMissing,     // no `schema` member, or JSON null
    SchemaNotInteger,  // a string, a boolean, a float (1.0), an object, ...
    SchemaUnsupported, // an integer other than kSupportedSchema
};

const char *_Nonnull gateVerdictName(GateVerdict verdict);

struct VersionGateResult {
    GateVerdict verdict = GateVerdict::DataNotObject;
    // Why it failed, for the log ("schema 2, supported 1", ...); empty on Pass.
    std::string detail;
    // `cli` and `commands` from the same `data`, for cliSupportsCommand.
    CliVersionInfo info;

    bool passed() const { return verdict == GateVerdict::Pass; }
};

// The gate over the `data` member of a version envelope.
VersionGateResult checkVersionGate(id _Nullable data);

// True when `value` is a JSON integer as NSJSONSerialization returns it: a
// CFNumber of an integer type. Booleans (CFBoolean), floats (1.0 parses as
// a double) and NSDecimalNumber (integers beyond 64 bits) are not. `out`
// (optional) receives the value.
bool isJsonInteger(id _Nullable value, long long *_Nullable out);

} // namespace intake
