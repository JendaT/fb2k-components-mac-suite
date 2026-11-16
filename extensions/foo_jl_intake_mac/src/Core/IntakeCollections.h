//
//  IntakeCollections.h
//  foo_jl_intake
//
//  The reply of `intake collections --json`, which feeds the "Assign to
//  other collection…" picker (doc 03 v1.2 "JSON conventions"; doc 04 v1.2
//  "Context actions"; PLAN.md B7). Input is the envelope's `data` member
//  (IntakeEnvelope) of an Ok result:
//
//    [{collection, artists, releases}]   sorted by collection ascending
//
//  Tolerant parsing:
//   - `data` must be an array; anything else is not a usable reply (ok
//     false, with `error`).
//   - An entry needs a non-empty string `collection`. An entry that is not
//     an object, or has no such name, is skipped and counted. So is a name
//     with a NUL byte: IntakeCommandArgs refuses to pass one.
//   - `artists` and `releases` are optional JSON numbers (booleans are not
//     numbers); `releases` may be fractional (weighted priors). A missing,
//     non-finite or wrong-typed count reads as absent and the entry stays:
//     the counts are informational only.
//   - Unknown fields are ignored (doc 03 "Versioning").
//   - A repeated name (exact bytes) is dropped, the first one kept, and
//     counted.
//  The CLI's order is kept, never re-sorted. Names are kept byte for byte
//  as the CLI wrote them: `collection` is usable with `assign --collection`
//  as is, so the picker compares exactly (isListedCollection: case
//  sensitive, no trimming, no Unicode normalisation).
//
//  Thread-safety: parseCollections is reentrant and adds its own autorelease
//  pool; the rest are pure functions.
//

#pragma once

#import <Foundation/Foundation.h>

#include <cstddef>
#include <string>
#include <vector>

#include "IntakeEnvelope.h"

namespace intake {

struct CollectionInfo {
    std::string name;  // `collection`, UTF-8, as written
    bool hasArtists = false;
    double artists = 0;
    bool hasReleases = false;
    double releases = 0;  // may be fractional
};

struct CollectionsParseResult {
    bool ok = false;      // `data` was an array
    std::string error;    // why not, when !ok
    std::vector<CollectionInfo> collections;  // the usable entries, CLI order
    size_t skipped = 0;     // entries without a usable `collection`
    size_t duplicates = 0;  // repeated names dropped
};

CollectionsParseResult parseCollections(id _Nullable data);

// The names, in order.
std::vector<std::string> collectionNames(const std::vector<CollectionInfo> &collections);

// `text` is exactly one of `names` (byte for byte).
bool isListedCollection(const std::vector<std::string> &names, const std::string &text);

// Why a `collections` result gives no picker, for one console line: the
// first error rendered (IntakeErrorMap renderError, which covers the
// host-synthesized E_NO_CLI and E_CLI_TIMEOUT too) plus " (+N more)"; the
// outcome name when there is no error. Every outcome but Ok counts: a
// partial listing could hide the collection the user is looking for.
std::string collectionsFailureText(const EnvelopeResult &result);

} // namespace intake
