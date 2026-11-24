//
//  IntakeFields.h
//  foo_jl_intake
//
//  The title-formatting fields (B13 "Fields batch" item 4; doc 04
//  "Title-formatting fields"): %intake_status%, %intake_target% and
//  %intake_collection%, usable in any title-formatting script, such as
//  SimPlaylist columns and group patterns. The provider that answers them is
//  Integration (IntakeFieldProvider); what it reads per row is
//  IntakeFieldState.
//
//  The values are worked out once per record, when IntakeSnapshot::build
//  makes the snapshot (IntakeRecord::fields), never per call: a host may
//  evaluate a field for every row of every playlist, on any thread, and
//  displayTargetPath goes through CoreFoundation for non-ASCII text.
//   - intake_status: the doc 03 status id (new, resolved, proposed,
//     approved, placing, placed, rejected, gc_done). A status this build
//     does not know: the CLI's own text (IntakeRecord::statusText), so a
//     script can still show or test it.
//   - intake_target: the readable target path, from the tier folder on
//     (IntakeTargetPath displayTargetPath of proposal.target_path with
//     proposal.target_collection), when target_path is set; else empty
//     (no proposal, a null target, or a CLI before 0.3.0 that sends none).
//   - intake_collection: proposal.target_collection; else empty.
//  An empty value means "no field": the provider returns false and writes
//  nothing, so "[%intake_target%]" collapses and "$if(%intake_target%,...)"
//  takes its else branch. Field names are fixed for the session (the SDK
//  enumerates them once).
//
//  Thread-safety: pure functions; the values are plain strings.
//

#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace intake {

struct IntakeRecord;

// The field indexes the provider reports, in get_field_name order.
enum class IntakeField : uint32_t {
    Status = 0,
    Target = 1,
    Collection = 2,
};
inline constexpr uint32_t kIntakeFieldCount = 3;

// "intake_status", "intake_target", "intake_collection"; "" past the end.
std::string_view intakeFieldName(uint32_t index);

// One record's three values (empty: no value).
struct IntakeFieldValues {
    std::string status;
    std::string target;
    std::string collection;

    // By field index; an empty string past the end.
    const std::string &value(uint32_t index) const;
    bool operator==(const IntakeFieldValues &other) const = default;
};

// See the top of this file.
IntakeFieldValues fieldValuesFor(const IntakeRecord &record);

} // namespace intake
