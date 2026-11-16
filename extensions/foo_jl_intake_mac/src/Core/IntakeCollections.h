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
//   - More than `maxEntries` entries (kMaxCollectionEntries by default)
//     is not a usable reply either: the picker would be unusable, and the
//     main thread builds it.
//  The CLI's order is kept, never re-sorted. Names are kept byte for byte
//  as the CLI wrote them: `collection` is usable with `assign --collection`
//  as is, so the picker passes a listed name's own bytes, never the typed
//  text (listedCollectionFor: case sensitive, no trimming; typed text
//  matches a name that differs only in Unicode normalisation).
//
//  Thread-safety: parseCollections and listedCollectionFor are reentrant
//  and add their own autorelease pool; the rest are pure functions.
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

inline constexpr size_t kMaxCollectionEntries = 10000;

CollectionsParseResult parseCollections(id _Nullable data, size_t maxEntries = kMaxCollectionEntries);

// The names, in order.
std::vector<std::string> collectionNames(const std::vector<CollectionInfo> &collections);

// The listed name `text` stands for, or nullptr: the name with exactly
// `text`'s bytes, else the only name canonically equivalent to it (the
// same NFC form: typed text is NFC, a name the CLI took from a folder may
// be NFD). Case-sensitive, no trimming; empty text, or two equivalent names
// and no exact one, stand for none. The caller passes the returned name
// (into `names`) to --collection.
const std::string *_Nullable listedCollectionFor(const std::vector<std::string> &names, const std::string &text);

// listedCollectionFor finds a name.
bool isListedCollection(const std::vector<std::string> &names, const std::string &text);

// Why a `collections` result gives no picker, for one console line: the
// first error rendered (IntakeErrorMap renderError, which covers the
// host-synthesized E_NO_CLI and E_CLI_TIMEOUT too) plus " (+N more)"; the
// outcome name when there is no error. Every outcome but Ok counts: a
// partial listing could hide the collection the user is looking for.
std::string collectionsFailureText(const EnvelopeResult &result);

} // namespace intake
