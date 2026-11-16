//
//  IntakeView.mm
//  foo_jl_intake
//

#include "IntakeView.h"

#include "IntakePath.h"

namespace intake {

const char *const kInertTooltipPrefix = "intake inactive: ";

IntakeRowVisual inertVisual(const std::string &reason) {
    IntakeRowVisual v;
    v.tooltip = std::string(kInertTooltipPrefix) + reason;
    return v;
}

std::shared_ptr<const IntakeView> IntakeView::make(std::shared_ptr<const IntakeSnapshot> snapshot,
                                                   std::shared_ptr<const MountAliases> aliases,
                                                   std::string inertReason,
                                                   std::shared_ptr<const LibraryIndex> library) {
    return std::make_shared<IntakeView>(Token{}, std::move(snapshot), std::move(aliases), std::move(inertReason),
                                        std::move(library));
}

IntakeView::IntakeView(Token, std::shared_ptr<const IntakeSnapshot> snapshot,
                       std::shared_ptr<const MountAliases> aliases, std::string inertReason,
                       std::shared_ptr<const LibraryIndex> library)
    : snapshot_(snapshot ? std::move(snapshot) : IntakeSnapshot::empty()),
      aliases_(aliases ? std::move(aliases) : MountAliases::none()),
      library_(library ? std::move(library) : LibraryIndex::empty()),
      inertReason_(std::move(inertReason)) {
    if (!inertReason_.empty()) inertVisual_ = inertVisual(inertReason_);
}

const IntakeRecord *IntakeView::recordFor(std::string_view path, ViewScratch &scratch) const {
    if (snapshot_->isEmpty() || path.empty()) return nullptr;
    std::string_view key;
    if (normalizePath(path, scratch.normalized, key) != PathStatus::Ok) return nullptr;
    // `key` views `path` or scratch.normalized, never scratch.aliased.
    return snapshot_->lookupKey(aliases_->rewrite(key, scratch.aliased));
}

bool IntakeView::matchKey(std::string_view path, ViewScratch &scratch, std::string &out) const {
    out.clear();
    if (path.empty()) return false;
    std::string_view key;
    if (normalizePath(path, scratch.normalized, key) != PathStatus::Ok) return false;
    out.assign(aliases_->rewrite(key, scratch.aliased));
    return true;
}

const IntakeRecord *IntakeView::libraryRecordFor(std::string_view path, ViewScratch &scratch) const {
    if (library_->isEmpty() || snapshot_->isEmpty() || path.empty()) return nullptr;
    std::string_view key;
    if (normalizePath(path, scratch.normalized, key) != PathStatus::Ok) return nullptr;
    const std::string *rootId = library_->rootForKey(aliases_->rewrite(key, scratch.aliased));
    if (rootId == nullptr) return nullptr;
    const IntakeRecord *record = snapshot_->recordForId(*rootId);
    if (record == nullptr || record->status != IntakeStatus::Placed || !record->hasPlaced || !record->placedVerified) {
        return nullptr;
    }
    return record;
}

const IntakeRowVisual *IntakeView::visualFor(std::string_view path, ViewScratch &scratch) const {
    const IntakeRecord *record = recordFor(path, scratch);
    if (!record) return nullptr;
    if (!inertReason_.empty()) return &inertVisual_;
    return record->visual.isNone() ? nullptr : &record->visual;
}

} // namespace intake
