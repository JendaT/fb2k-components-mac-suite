//
//  IntakeReviewRuleTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeReviewRule (contract v1.2, CR-004.11: needs review =
//  needs_review AND status resolved or proposed; a user-assigned proposal
//  keeps it). Synthetic records only.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeReviewRule.h"
#include "../src/Core/IntakeStatusModel.h"
#include "TestHarness.h"

using namespace intake;

static IntakeRecord record(IntakeStatus status, bool needsReview) {
    IntakeRecord r;
    r.id = "itk_00000001";
    r.rootPath = r.rootKey = "/income/dump/Fixture Artist - Test Album";
    r.status = status;
    r.needsReview = needsReview;
    return r;
}

static IntakeRecord withProposal(IntakeRecord r, AssignedBy by, bool hasConfidence) {
    r.hasProposal = true;
    r.proposal.targetCollection = "Test Collection A";
    r.proposal.assignedBy = by;
    r.proposal.hasConfidence = hasConfidence;
    r.proposal.confidence = hasConfidence ? 1.0 : 0.0;
    return r;
}

int main(void) {
    @autoreleasepool {
        g_context = "matrix";
        const IntakeStatus all[] = {IntakeStatus::New, IntakeStatus::Resolved, IntakeStatus::Proposed,
                                    IntakeStatus::Approved, IntakeStatus::Placing, IntakeStatus::Placed,
                                    IntakeStatus::GcDone, IntakeStatus::Rejected, IntakeStatus::Unknown};
        int flaggedAmber = 0, unflaggedAmber = 0;
        for (IntakeStatus s : all) {
            if (recordNeedsReview(record(s, true))) flaggedAmber++;
            if (recordNeedsReview(record(s, false))) unflaggedAmber++;
        }
        CHECK_EQ(flaggedAmber, 2, "with needs_review, exactly resolved and proposed need review");
        CHECK_EQ(unflaggedAmber, 0, "without needs_review, no status needs review");
        CHECK(recordNeedsReview(record(IntakeStatus::Resolved, true)), "resolved + needs_review");
        CHECK(recordNeedsReview(record(IntakeStatus::Proposed, true)), "proposed + needs_review");

        g_context = "v1.2";
        CHECK(recordNeedsReview(withProposal(record(IntakeStatus::Proposed, true), AssignedBy::User, true)),
              "a user-assigned proposal with needs_review still needs review (no exemption)");
        CHECK(recordNeedsReview(withProposal(record(IntakeStatus::Resolved, true), AssignedBy::User, true)),
              "a resolved root with a stored user proposal and needs_review needs review");
        CHECK(recordNeedsReview(withProposal(record(IntakeStatus::Proposed, true), AssignedBy::Engine, true)),
              "an engine proposal with needs_review needs review");
        CHECK(recordNeedsReview(withProposal(record(IntakeStatus::Proposed, true), AssignedBy::Unknown, true)),
              "assigned_by unknown (CLI 0.2.1) with needs_review needs review");
        CHECK(!recordNeedsReview(withProposal(record(IntakeStatus::Proposed, false), AssignedBy::User, true)),
              "a user-assigned proposal without needs_review does not");

        g_context = "missing-parts";
        CHECK(recordNeedsReview(record(IntakeStatus::Resolved, true)),
              "resolved + needs_review with no proposal needs review");
        CHECK(recordNeedsReview(withProposal(record(IntakeStatus::Proposed, true), AssignedBy::Engine, false)),
              "proposed + needs_review with no confidence needs review");
        CHECK(!recordNeedsReview(withProposal(record(IntakeStatus::Resolved, false), AssignedBy::Engine, false)),
              "a missing confidence alone does not make a root need review");

        g_context = "other-statuses";
        CHECK(!recordNeedsReview(record(IntakeStatus::New, true)), "new + needs_review is not amber (tooltip only)");
        CHECK(!recordNeedsReview(record(IntakeStatus::Approved, true)), "approved ignores a stray flag");
        CHECK(!recordNeedsReview(record(IntakeStatus::Rejected, true)), "rejected ignores the flag");
    }
    TEST_MAIN_END();
}
