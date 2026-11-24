//
//  IntakeGroupBadge.h
//  foo_jl_intake
//
//  The group header badge (doc 04 v1.2 "Group header badge"; PLAN.md B6).
//  SDK-free: the provider's decorate_group copies an IntakeBadge into a
//  jl_group_decoration.
//
//  Shown only when every mapped member of the group (SimPlaylist passes at
//  most 64) belongs to one root, and that root is `proposed` or `approved`
//  with a target collection. Members that map to no root are ignored; two
//  roots in one group hide the badge.
//
//  Text (UTF-8; "->" is U+2192, "." between parts is U+00B7), X being
//  target_collection as the CLI wrote it (real collection names carry
//  their own brackets, "[Collection A]", doc 02; none are added here):
//    "→ X · 0.91"                the target and the confidence, two decimals
//    "→ X · yours"               proposal.assigned_by is "user" (instead of
//                                the 1.00 the CLI writes)
//    "→ X · slot pending"        proposal.target_path is present and null
//                                on a singles root (IntakeRecord::singlesRoot);
//                                always amber, no alt hint
//    "→ X · cannot be placed"    the same on any other root (tier reject, no
//                                album name: a target that can never be
//                                built), whoever assigned it; amber, no hint
//    "→ X"                       no confidence (not a JSON number)
//  Amber when the review rule fires (IntakeReviewRule) or the confidence is
//  below 0.6; an amber badge then gets " (alt: Y)", Y being the first
//  `ranked` entry that is not the target, also as written. No hint when
//  `ranked` is absent, empty, or holds only the target.
//  An unknown assigned_by or target_path (CLI before 0.3.0) gives neither
//  "yours" nor "slot pending" / "cannot be placed": the confidence is shown.
//
//  Colour: amber is the review tint at full alpha (opaqueColor), at any
//  tint alpha: the group header is not tinted, so unlike a row icon
//  (rowIconColor) it stays readable; otherwise 0, the host's secondary
//  colour.
//
//  IntakeSnapshot::build stores each record's badge (IntakeRecord::badge),
//  so decorate_group only looks it up, and the load diff (rendersAlike)
//  sees badge changes that leave the row visual alone (a new confidence).
//
//  Thread-safety: pure functions.
//

#pragma once

#include <string>
#include <vector>

#include "IntakeDecorationMap.h"

namespace intake {

struct IntakeRecord;

struct IntakeBadge {
    std::string text;      // UTF-8; empty: no badge
    IntakeRgba color = 0;  // 0: the host's default secondary colour
    bool amber = false;

    bool shown() const { return !text.empty(); }
    bool operator==(const IntakeBadge &o) const { return text == o.text && color == o.color && amber == o.amber; }
    bool operator!=(const IntakeBadge &o) const { return !(*this == o); }
};

// Below this confidence a badge is amber (doc 02 / doc 04 v1.2: 0.6), in
// the hundredths the badge shows.
inline constexpr long kBadgeAmberHundredths = 60;

// The confidence in hundredths as the badge shows it: clamped to [0, 1]
// and truncated (0.597 is 59, 0.999 is 99), so a confidence below 0.6
// never shows as "0.60" and the amber rule and the text agree. -1 for a
// value that is not finite.
long confidenceHundredths(double confidence);

// "0.91": confidenceHundredths with two decimals; independent of the C
// locale. "?" for a value that is not finite.
std::string formatConfidence(double confidence);

// The badge of a group made of `record`'s rows only (see the top of this
// file); not shown for other statuses or without a target collection.
IntakeBadge recordBadge(const IntakeRecord &record, const IntakePalette &palette = IntakePalette());

// The group rule over the records of a group's members, in any order:
// nullptr entries (members that map to no root) are ignored. The single
// root, or nullptr when no member maps or two roots (by id) are present.
const IntakeRecord *groupRoot(const std::vector<const IntakeRecord *> &memberRecords);

// The badge to show for the group, or nullptr: groupRoot's badge when it is
// shown. Points into the record (valid while the caller holds its snapshot).
const IntakeBadge *groupBadge(const std::vector<const IntakeRecord *> &memberRecords);

} // namespace intake
