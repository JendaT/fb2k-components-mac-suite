//
//  IntakeFields.mm
//  foo_jl_intake
//

#include "IntakeFields.h"

#include "IntakeStatusModel.h"
#include "IntakeTargetPath.h"

namespace intake {

namespace {

constexpr std::string_view kFieldNames[kIntakeFieldCount] = {
    "intake_status",
    "intake_target",
    "intake_collection",
};

} // anonymous namespace

std::string_view intakeFieldName(uint32_t index) {
    return index < kIntakeFieldCount ? kFieldNames[index] : std::string_view();
}

const std::string &IntakeFieldValues::value(uint32_t index) const {
    static const std::string none;
    switch (static_cast<IntakeField>(index)) {
        case IntakeField::Status: return status;
        case IntakeField::Target: return target;
        case IntakeField::Collection: return collection;
    }
    return none;
}

IntakeFieldValues fieldValuesFor(const IntakeRecord &record) {
    IntakeFieldValues v;
    v.status = record.status == IntakeStatus::Unknown ? record.statusText
                                                      : std::string(intakeStatusName(record.status));
    if (record.hasProposal) {
        const IntakeProposal &p = record.proposal;
        if (p.targetPathState == TargetPathState::Set && !p.targetPath.empty()) {
            v.target = displayTargetPath(p.targetPath, p.targetCollection);
        }
        v.collection = p.targetCollection;
    }
    return v;
}

} // namespace intake
