//
//  IntakeTargetPath.h
//  foo_jl_intake
//
//  The readable form of a proposal's `target_path` (B13): the path from the
//  tier folder on, i.e. relative to the tier root's parent. The CLI builds
//  target_path as `<tier root>/<collection>/<artist or slot>/<release>`
//  (doc 02 "Library layout for new placements"; tools/intake assign.ts
//  buildTargetPath), so
//
//    /volume1/music/music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware
//      -> music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware
//
//  The collection folder is found by `proposal.target_collection`, which is
//  the folder name itself: bracketed in the real rules ("[Psychill &
//  Chillout & Psydub]", doc 02), bare in the mock fixtures ("Test Collection
//  A"). The CLI writes the folder through its sanitizeComponent (`/`, `\`
//  and `:` become `-`, control characters go, leading and trailing
//  whitespace and dots go), so that spelling matches too. Both sides are
//  compared in NFC (share names may arrive NFD); matching is exact and
//  case-sensitive otherwise. The first component that matches is taken (the
//  collection sits right under the tier root), and the result starts one
//  component before it (the tier folder), or at it when it is the first
//  component.
//
//  When the collection is empty or not in the path: the last four
//  components (tier, collection, artist or slot, release in the CLI's
//  layout), or all of them when there are fewer.
//
//  Empty components ("//", a trailing "/") are skipped; the result is NFC,
//  joined with "/", without a leading "/". Empty for an empty path.
//
//  Thread-safety: pure functions; CoreFoundation only for non-ASCII input,
//  nothing autoreleased.
//

#pragma once

#include <string>
#include <string_view>

namespace intake {

// See the top of this file.
std::string displayTargetPath(std::string_view targetPath, std::string_view collection);

// The CLI's sanitizeComponent (tools/intake layout.ts) for one folder name.
std::string sanitizedPathComponent(std::string_view name);

// `text` (UTF-8) in NFC; unchanged when it is ASCII or not valid UTF-8.
std::string nfcText(std::string_view text);

} // namespace intake
