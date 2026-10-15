//
//  BpmValue.h
//  foo_jl_bpm_mac
//
//  Reading, writing and comparing BPM tag values. Plain C++, unit tested.
//

#pragma once

#include <optional>
#include <string>
#include <string_view>

namespace bpm {

// Parses a BPM tag: "128", "128.00", "127,5", " 128 ", "128 BPM".
// Returns nullopt for empty or non-numeric text and for values outside
// (0, 1000).
std::optional<double> parseBpm(std::string_view text);

// Tag text for an estimate: rounded to a whole number, the only form the
// ID3 TBPM frame and the MP4 tmpo atom can hold.
std::string formatBpmTag(double bpm);

// Tag text for an exact value, such as a doubled or halved tag: a whole
// number when integral, otherwise one decimal ("62.5").
std::string formatBpmExact(double bpm);

// Display text with one decimal ("127.9").
std::string formatBpmDisplay(double bpm);

// How an estimate relates to an existing tag value.
enum class Agreement {
    Same,       // within 1% (at least 0.5 BPM)
    Double,     // the estimate is twice the tag
    Half,       // the estimate is half the tag
    Different,
};

Agreement compareBpm(double existing, double estimate);

} // namespace bpm
