//
//  IntakeReviewRule.mm
//  foo_jl_intake
//

#include "IntakeReviewRule.h"

#include "IntakeStatusModel.h"

namespace intake {

bool recordNeedsReview(const IntakeRecord &record) {
    if (!record.needsReview) return false;
    return record.status == IntakeStatus::Resolved || record.status == IntakeStatus::Proposed;
}

} // namespace intake
