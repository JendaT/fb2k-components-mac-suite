//
//  IntakeRejectReason.h
//  foo_jl_intake
//
//  The Reject… sheet's reason presets (doc 04 "Context actions"): a pop-up
//  above the free-text field offers
//
//    Already in library
//    Lower quality than library copy
//    Not wanted
//    Other…
//
//  A preset's text is the reason, sent through the usual `reject --reason`
//  (no contract change). "Other…" uses the free text, trimmed of leading
//  and trailing whitespace; empty means no reason, as before the presets.
//  Integration remembers the last choice for the session only (no setting).
//
//  Thread-safety: pure functions.
//

#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace intake {

// The pop-up's items in order: the presets, then "Other…" (U+2026).
const std::vector<std::string> &rejectReasonChoices();

// The index of "Other…" (the last item).
size_t rejectReasonOtherIndex();

// True for "Other…" and for an index past the end (treated as Other).
bool rejectChoiceIsOther(size_t choice);

// The reason `choice` gives: a preset's text, else `freeText` trimmed.
std::string rejectReasonFor(size_t choice, const std::string &freeText);

} // namespace intake
