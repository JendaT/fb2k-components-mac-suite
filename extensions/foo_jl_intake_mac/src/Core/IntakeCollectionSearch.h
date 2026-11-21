//
//  IntakeCollectionSearch.h
//  foo_jl_intake
//
//  The "Assign to other collection…" picker's search and its Recent list
//  (doc 04 "Context actions"), SDK-free.
//
//  Search: every collection name starts with "[", so a prefix completion
//  finds nothing for "folk". matchCollections matches the query as a
//  substring anywhere in the name, both sides folded by searchKey: case
//  and diacritics ignored (CFStringFold, also width), "[" and "]" removed,
//  leading and trailing whitespace trimmed. "folk" finds "[Folktronica &
//  Ezo techno]", "goa" finds "[Psytrance & Goa]", "cafe" finds "[Café]".
//  Ranking: a match at the start of the name first, then one at the start
//  of a word (after a character that is not a letter or digit), then any
//  other; within each, alphabetically by the folded name, then by the
//  name's bytes. An empty query (after folding) lists every name in the
//  given (the CLI's) order.
//
//  Rows: with the search text empty the picker lists three sections, each
//  only when it has a name: "Suggested" (suggestedCollections: the engine's
//  top-ranked collection, proposal.ranked[0], of the selected roots; one
//  when they agree, else their distinct values, at most
//  kSuggestedCollectionsMax), "Recent", and "All collections" (the CLI's
//  order). A name may appear in more than one section; headers are not
//  choosable. While searching, the sections give way to one ranked list
//  of matches (pickerRows). pickerHighlight picks the row a text change
//  highlights: nothing for an empty text (no choice is made for the user),
//  else the listed name the text stands for, else the first match.
//
//  Recent: the last kRecentCollectionsMax collections the user assigned
//  to, most recent first, kept in the hidden configStore string
//  foo_jl_intake.recent_collections, one name per line (Integration reads
//  and writes it on the main thread). updateRecentCollections runs when the
//  user confirms Assign; shownRecentCollections when the picker opens, so a
//  collection no longer listed drops out of the section.
//
//  Thread-safety: pure functions; CoreFoundation only, nothing autoreleased.
//

#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace intake {

inline constexpr size_t kRecentCollectionsMax = 5;
inline constexpr size_t kSuggestedCollectionsMax = 3;

// The folded form both sides of a search are compared in (see above).
std::string searchKey(std::string_view text);

// The indices into `names` that match `query`, best first (see above).
std::vector<size_t> matchCollections(const std::vector<std::string> &names, std::string_view query);

// The stored string: one name per line ("\r" before "\n" tolerated), empty
// lines skipped, repeats dropped (the first kept), at most
// kRecentCollectionsMax.
std::vector<std::string> parseRecentCollections(std::string_view stored);
// The names joined with "\n".
std::string formatRecentCollections(const std::vector<std::string> &recent);

// After an assign to `chosen`: it moves to the front, repeats go, names that
// `names` (the collections the picker listed) no longer has are dropped
// (listedCollectionFor; each kept as its listed bytes), at most
// kRecentCollectionsMax. An empty `chosen` changes nothing but the
// filtering. With `names` empty nothing is dropped as unknown.
std::vector<std::string> updateRecentCollections(const std::vector<std::string> &recent, const std::string &chosen,
                                                 const std::vector<std::string> &names);

// The Recent section: the stored names still in `names`, as their listed
// bytes, most recent first, repeats dropped, at most kRecentCollectionsMax.
std::vector<std::string> shownRecentCollections(const std::vector<std::string> &recent,
                                                const std::vector<std::string> &names);

// The Suggested section from the selected roots' ranked[0] collections
// (empty strings for roots without one): the distinct ones still listed in
// `names`, as their listed bytes, in selection order, at most
// kSuggestedCollectionsMax.
std::vector<std::string> suggestedCollections(const std::vector<std::string> &topRanked,
                                              const std::vector<std::string> &names);

struct PickerRow {
    bool header = false;  // a section title: shown, never chosen
    std::string text;     // the title, or a listed name

    bool operator==(const PickerRow &other) const = default;
};

// The picker's rows for `query` (see the top of this file). `suggested` and
// `recent` are already filtered (suggestedCollections,
// shownRecentCollections).
std::vector<PickerRow> pickerRows(const std::vector<std::string> &suggested, const std::vector<std::string> &recent,
                                  const std::vector<std::string> &names, std::string_view query);

// The row to highlight once `query` changed, or -1 (see the top of this
// file).
long pickerHighlight(const std::vector<PickerRow> &rows, const std::vector<std::string> &names, std::string_view query);

} // namespace intake
