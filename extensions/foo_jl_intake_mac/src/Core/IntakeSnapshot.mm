//
//  IntakeSnapshot.mm
//  foo_jl_intake
//

#include "IntakeSnapshot.h"

#include "IntakeLog.h"
#include "IntakePath.h"

namespace intake {

bool singlesRootFor(const IntakeRecord &record, const RootMembers *members) {
    if (members != nullptr) {
        switch (members->kind) {
            case MemberKind::Members:
                return members->singles;
            case MemberKind::None:
                return false;
            case MemberKind::WholeDirectory:
                if (members->source == MemberSource::Listed || members->source == MemberSource::Reused) return false;
                break;
        }
    }
    return record.album.empty();
}

std::shared_ptr<const IntakeSnapshot> IntakeSnapshot::build(std::vector<IntakeRecord> records,
                                                            MemberTable members,
                                                            const IntakePalette &palette) {
    auto snapshot = std::make_shared<IntakeSnapshot>(Token{});
    IntakeSnapshot &s = *snapshot;
    s.records_ = std::move(records);
    s.members_ = std::move(members);
    s.byDirectory_.reserve(s.records_.size());
    s.byId_.reserve(s.records_.size());

    const bool debug = isLogEnabled(LogLevel::Debug);
    std::vector<IntakeRecord> &recs = s.records_;
    // Lowest id wins a tie, whatever the row order.
    auto lowerId = [&recs, debug](const char *map, std::string_view key) {
        return [&recs, debug, map, key](uint32_t existing, uint32_t candidate) {
            const bool replace = recs[candidate].id < recs[existing].id;
            if (debug) {
                logDebug(std::string("snapshot: ") + map + " key " + std::string(key) + " claimed by " +
                         recs[existing].id + " and " + recs[candidate].id + "; " +
                         recs[replace ? candidate : existing].id + " wins");
            }
            return replace;
        };
    };

    std::string joined;
    std::string normalized;
    for (uint32_t i = 0; i < recs.size(); i++) {
        IntakeRecord &r = recs[i];
        auto found = s.members_.find(r.id);
        r.singlesRoot = singlesRootFor(r, found == s.members_.end() ? nullptr : &found->second);
        r.visual = rowVisualFor(r, palette);
        r.badge = recordBadge(r, palette);
        s.byId_.try_emplace(r.id, i);  // parseStatusRows already dropped repeats
        if (r.rootKey.empty()) continue;

        const MemberKind kind = found == s.members_.end() ? MemberKind::WholeDirectory : found->second.kind;
        switch (kind) {
            case MemberKind::WholeDirectory:
                // Normalized like the member keys: a rootKey that Integration
                // rewrote (B3 mount alias of an NFD root_path) still meets
                // NFC queries. Idempotent on a key that is already normal.
                if (normalizePath(r.rootKey, normalized) != PathStatus::Ok) break;
                s.byDirectory_.insert(normalized, i, lowerId("directory", normalized));
                break;
            case MemberKind::Members:
                for (const std::string &relative : found->second.relativePaths) {
                    joined = r.rootKey;
                    if (joined.back() != '/') joined += '/';
                    joined += relative;
                    if (normalizePath(joined, normalized) != PathStatus::Ok) continue;
                    s.byMember_.insert(normalized, i, lowerId("member", normalized));
                }
                break;
            case MemberKind::None:
                break;
        }
    }
    return snapshot;
}

std::shared_ptr<const IntakeSnapshot> IntakeSnapshot::empty() {
    static const std::shared_ptr<const IntakeSnapshot> none = std::make_shared<IntakeSnapshot>(Token{});
    return none;
}

const IntakeRecord *IntakeSnapshot::lookupKey(std::string_view key) const {
    if (key.empty()) return nullptr;
    if (const uint32_t *hit = byMember_.find(key)) return &records_[*hit];
    if (const uint32_t *hit = byDirectory_.findNearest(key)) return &records_[*hit];
    return nullptr;
}

const IntakeRecord *IntakeSnapshot::lookup(std::string_view path) const {
    if (records_.empty() || path.empty()) return nullptr;
    std::string buffer;
    std::string_view key;
    if (normalizePath(path, buffer, key) != PathStatus::Ok) return nullptr;
    return lookupKey(key);
}

const IntakeRecord *IntakeSnapshot::recordForId(std::string_view id) const {
    auto it = byId_.find(id);
    return it == byId_.end() ? nullptr : &records_[it->second];
}

} // namespace intake
