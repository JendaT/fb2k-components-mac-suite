//
//  IntakeReviewRule.h
//  foo_jl_intake
//
//  Whether a root counts as "needs review" (amber; PLAN.md 3.3 item 4), as
//  one isolated predicate so a later amendment changes one place.
//
//  Contract v1.2 (amendment 003, CR-004.11): `needs_review` is sticky until
//  `approve`, and a proposal made by `assign --by user` keeps it ("consumers
//  show a user-assigned proposal distinctly, and still show needs_review").
//  So:
//
//    needs review = needs_review is true AND status is resolved or proposed
//
//  with no exemption for `proposal.assigned_by == "user"` (the v1.1 draft
//  rule had one). A missing proposal or confidence does not matter either:
//  a resolved or proposed root with needs_review set is amber with or
//  without them (doc 04 "Amber"). needs_review on a new root (CR-004.8) is
//  not amber: it renders as new with a "needs review" tooltip
//  (IntakeDecorationMap). On approved and later statuses the flag is
//  cleared by approve, and a stray one is ignored.
//
//  Thread-safety: pure function.
//

#pragma once

namespace intake {

struct IntakeRecord;

bool recordNeedsReview(const IntakeRecord &record);

} // namespace intake
