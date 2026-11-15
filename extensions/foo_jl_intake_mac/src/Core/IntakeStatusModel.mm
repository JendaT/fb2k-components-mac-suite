//
//  IntakeStatusModel.mm
//  foo_jl_intake
//

#include "IntakeStatusModel.h"

#include "IntakeLog.h"
#include "IntakePath.h"

#import <CoreFoundation/CoreFoundation.h>

#include <unordered_set>

namespace intake {

namespace {

constexpr size_t kDropLogLimit = 10;

bool isString(id value) {
    return [value isKindOfClass:[NSString class]];
}

bool isBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] &&
           CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

// A JSON number that is not a boolean.
bool numberValue(id value, double &out) {
    if (![value isKindOfClass:[NSNumber class]] || isBoolean(value)) return false;
    out = [value doubleValue];
    return true;
}

std::string stringValue(id value) {
    std::string out;
    if (isString(value)) copyUTF8(value, out);
    return out;
}

void parseProposal(NSDictionary *dict, IntakeProposal &p) {
    p.targetCollection = stringValue(dict[@"target_collection"]);
    p.hasConfidence = numberValue(dict[@"confidence"], p.confidence);

    id ranked = dict[@"ranked"];
    if ([ranked isKindOfClass:[NSArray class]]) {
        NSArray *list = ranked;
        for (id entry in list) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            id collection = ((NSDictionary *)entry)[@"collection"];
            if (!isString(collection)) continue;
            RankedCandidate c;
            copyUTF8(collection, c.collection);
            c.hasConfidence = numberValue(((NSDictionary *)entry)[@"confidence"], c.confidence);
            p.ranked.push_back(std::move(c));
        }
        // Decided after the filter: Present promises ranked[0]. An array with
        // no usable entry says nothing, like a ranked that is not an array.
        if (list.count == 0) {
            p.rankedState = RankedState::Empty;
        } else if (!p.ranked.empty()) {
            p.rankedState = RankedState::Present;
        } else {
            logDebug("status: proposal.ranked has no usable entry; treated as absent");
        }
    }

    id assignedBy = dict[@"assigned_by"];
    if (isString(assignedBy)) {
        copyUTF8(assignedBy, p.assignedByText);
        if (p.assignedByText == "engine") {
            p.assignedBy = AssignedBy::Engine;
        } else if (p.assignedByText == "user") {
            p.assignedBy = AssignedBy::User;
        } else {
            p.assignedBy = AssignedBy::Other;
        }
    }

    id targetPath = dict[@"target_path"];
    if (targetPath == [NSNull null]) {
        p.targetPathState = TargetPathState::Null;
    } else if (isString(targetPath)) {
        copyUTF8(targetPath, p.targetPath);
        p.targetPathState = p.targetPath.empty() ? TargetPathState::Null : TargetPathState::Set;
    }
}

struct DropLog {
    size_t count = 0;

    void drop(size_t index, const std::string &id, const char *why) {
        count++;
        if (count > kDropLogLimit) return;
        std::string line = "status row " + std::to_string(index);
        if (!id.empty()) line += " (" + id + ")";
        line += " dropped: ";
        line += why;
        logInfo(line);
    }

    void summary() const {
        if (count > kDropLogLimit) {
            logInfo("status: " + std::to_string(count) + " rows dropped (" +
                    std::to_string(kDropLogLimit) + " logged)");
        }
    }
};

} // anonymous namespace

const char *intakeStatusName(IntakeStatus status) {
    switch (status) {
        case IntakeStatus::New: return "new";
        case IntakeStatus::Resolved: return "resolved";
        case IntakeStatus::Proposed: return "proposed";
        case IntakeStatus::Approved: return "approved";
        case IntakeStatus::Placing: return "placing";
        case IntakeStatus::Placed: return "placed";
        case IntakeStatus::GcDone: return "gc_done";
        case IntakeStatus::Rejected: return "rejected";
        case IntakeStatus::Unknown: return "unknown";
    }
    return "unknown";
}

IntakeStatus intakeStatusFromString(const std::string &text) {
    if (text == "new") return IntakeStatus::New;
    if (text == "resolved") return IntakeStatus::Resolved;
    if (text == "proposed") return IntakeStatus::Proposed;
    if (text == "approved") return IntakeStatus::Approved;
    if (text == "placing") return IntakeStatus::Placing;
    if (text == "placed") return IntakeStatus::Placed;
    if (text == "gc_done") return IntakeStatus::GcDone;
    if (text == "rejected") return IntakeStatus::Rejected;
    return IntakeStatus::Unknown;
}

StatusParseResult parseStatusRows(id data) {
    StatusParseResult result;
    @autoreleasepool {
        if (![data isKindOfClass:[NSArray class]]) {
            result.error = "status data is not an array";
            return result;
        }
        result.ok = true;
        NSArray *rows = data;
        result.records.reserve(rows.count);
        std::unordered_set<std::string> seen;
        seen.reserve(rows.count);
        DropLog drops;

        size_t index = 0;
        for (id row in rows) {
            const size_t i = index++;
            if (![row isKindOfClass:[NSDictionary class]]) {
                drops.drop(i, std::string(), "not an object");
                continue;
            }
            NSDictionary *dict = row;
            IntakeRecord r;
            r.id = stringValue(dict[@"id"]);
            if (r.id.empty()) {
                drops.drop(i, std::string(), "no id");
                continue;
            }
            r.rootPath = stringValue(dict[@"root_path"]);
            if (r.rootPath.empty()) {
                drops.drop(i, r.id, "no root_path");
                continue;
            }
            const PathStatus pathStatus = normalizePath(r.rootPath, r.rootKey);
            if (pathStatus != PathStatus::Ok) {
                drops.drop(i, r.id, (std::string("root_path is ") + pathStatusName(pathStatus)).c_str());
                continue;
            }
            r.statusText = stringValue(dict[@"status"]);
            if (r.statusText.empty()) {
                drops.drop(i, r.id, "no status");
                continue;
            }
            if (!seen.insert(r.id).second) {
                drops.drop(i, r.id, "repeated id");
                continue;
            }
            r.status = intakeStatusFromString(r.statusText);
            if (r.status == IntakeStatus::Unknown) {
                logDebug("status row " + std::to_string(i) + " (" + r.id + "): unknown status \"" +
                         r.statusText + "\", renders nothing");
            }

            id needsReview = dict[@"needs_review"];
            r.needsReview = isBoolean(needsReview) && [needsReview boolValue];

            id cluster = dict[@"cluster"];
            if ([cluster isKindOfClass:[NSDictionary class]]) {
                r.albumartist = stringValue(((NSDictionary *)cluster)[@"albumartist"]);
                r.album = stringValue(((NSDictionary *)cluster)[@"album"]);
            }

            id proposal = dict[@"proposal"];
            if ([proposal isKindOfClass:[NSDictionary class]]) {
                r.hasProposal = true;
                parseProposal(proposal, r.proposal);
            }

            id placed = dict[@"placed"];
            if ([placed isKindOfClass:[NSDictionary class]]) {
                r.hasPlaced = true;
                id verified = ((NSDictionary *)placed)[@"verified"];
                r.placedVerified = isBoolean(verified) && [verified boolValue];
                r.placedTargetPath = stringValue(((NSDictionary *)placed)[@"target_path"]);
            }

            result.records.push_back(std::move(r));
        }
        drops.summary();
        result.dropped = drops.count;
    }
    return result;
}

} // namespace intake
