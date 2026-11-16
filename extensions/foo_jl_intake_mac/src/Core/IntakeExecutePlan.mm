//
//  IntakeExecutePlan.mm
//  foo_jl_intake
//

#include "IntakeExecutePlan.h"

#include <algorithm>
#include <unordered_map>
#include <unordered_set>

namespace intake {

const char *const kExecuteDryRunName = "execute dry run";

namespace {

const char *const kArrow = " \xE2\x86\x92 ";  // " U+2192 "

std::string fromNS(NSString *s) {
    const char *c = s.UTF8String;
    return c ? std::string(c) : std::string();
}

bool readString(NSDictionary *row, NSString *key, std::string &out) {
    id v = row[key];
    if (![v isKindOfClass:[NSString class]]) return false;
    out = fromNS(v);
    return true;
}

bool readCount(NSDictionary *row, NSString *key, long long &out) {
    id v = row[key];
    if (![v isKindOfClass:[NSNumber class]]) return false;
    if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return false;
    if (CFNumberIsFloatType((__bridge CFNumberRef)v)) return false;
    const long long n = [v longLongValue];
    if (n < 0) return false;
    out = n;
    return true;
}

std::string plural(long long n, const char *one, const char *many) {
    return std::to_string(n) + " " + (n == 1 ? one : many);
}

std::string labelFor(const ActionRoot &root, const DryRunRow *row) {
    if (root.rootPath.empty() && row != nullptr && !row->rootPath.empty()) {
        ActionRoot withPath = root;
        withPath.rootPath = row->rootPath;
        return albumLabel(withPath);
    }
    return albumLabel(root);
}

} // anonymous namespace

DryRunParse parseDryRunRows(id data) {
    DryRunParse out;
    if (![data isKindOfClass:[NSArray class]]) return out;
    out.isArray = true;
    std::unordered_set<std::string> seen;
    for (id entry in (NSArray *)data) {
        if (![entry isKindOfClass:[NSDictionary class]]) {
            out.skipped++;
            continue;
        }
        NSDictionary *d = entry;
        DryRunRow row;
        if (!readString(d, @"id", row.id) || row.id.empty() || !seen.insert(row.id).second) {
            out.skipped++;
            continue;
        }
        readString(d, @"root_path", row.rootPath);
        readString(d, @"target_path", row.targetPath);
        row.hasFiles = readCount(d, @"files", row.files);
        row.hasArtifacts = readCount(d, @"artifacts", row.artifacts);
        row.hasShadows = readCount(d, @"skipped_shadows", row.skippedShadows);
        out.rows.push_back(std::move(row));
    }
    return out;
}

ExecutePlan planExecute(const std::vector<ActionRoot> &roots, const EnvelopeResult &dryRun) {
    ExecutePlan plan;
    std::vector<MutationRoot> mroots;
    for (const ActionRoot &r : roots) mroots.push_back({r.id, r.rootPath, r.status});
    plan.outcome = summarizeMutation(CliCommand::Execute, mroots, dryRun, kExecuteDryRunName);

    std::unordered_map<std::string, DryRunRow> byId;
    if (dryRun.outcome == CliOutcome::Ok || dryRun.outcome == CliOutcome::Partial) {
        for (DryRunRow &row : parseDryRunRows(dryRun.data).rows) byId.emplace(row.id, std::move(row));
    }
    std::unordered_map<std::string, std::string> why;
    const std::string prefix = std::string(kExecuteDryRunName) + ": ";
    for (const auto &e : plan.outcome.rootErrors) {
        std::string text = e.second;
        if (text.compare(0, prefix.size(), prefix) == 0) text = text.substr(prefix.size());
        why.emplace(e.first, text);
    }
    std::unordered_set<std::string> done;
    for (const ActionRoot &r : roots) {
        if (!done.insert(r.id).second) continue;
        auto row = byId.find(r.id);
        if (row != byId.end()) {
            plan.placeable.push_back(r);
            plan.rows.push_back(row->second);
            continue;
        }
        plan.excluded.push_back(r);
        auto w = why.find(r.id);
        plan.excludedWhy.push_back(w != why.end() ? w->second : std::string("not listed by the dry run"));
    }
    return plan;
}

std::vector<std::string> placeableIds(const ExecutePlan &plan) {
    std::vector<std::string> out;
    for (const ActionRoot &r : plan.placeable) out.push_back(r.id);
    return out;
}

std::string executeSheetRow(const ActionRoot &root, const DryRunRow &row) {
    std::string out = labelFor(root, &row);
    if (!row.targetPath.empty()) out += kArrow + row.targetPath;
    std::vector<std::string> parts;
    if (row.hasFiles) parts.push_back(plural(row.files, "file", "files"));
    if (row.hasShadows) parts.push_back(plural(row.skippedShadows, "shadow skipped", "shadows skipped"));
    if (!parts.empty()) {
        out += " (";
        for (size_t i = 0; i < parts.size(); i++) out += (i ? ", " : "") + parts[i];
        out += ")";
    }
    return out;
}

std::string executeSheetTitle(const ExecutePlan &plan) {
    const size_t n = plan.placeable.size();
    if (n == 1) return "Place this album in the library?";
    return "Place " + std::to_string(n) + " albums in the library?";
}

namespace {

std::vector<std::string> placeableLines(const ExecutePlan &plan, size_t maxListed) {
    std::vector<std::string> lines;
    const size_t listed = std::min(plan.placeable.size(), maxListed);
    for (size_t i = 0; i < listed; i++) lines.push_back(executeSheetRow(plan.placeable[i], plan.rows[i]));
    if (plan.placeable.size() > listed) {
        lines.push_back("and " + std::to_string(plan.placeable.size() - listed) + " more");
    }
    return lines;
}

std::vector<std::string> excludedLines(const ExecutePlan &plan, size_t maxListed) {
    std::vector<std::string> lines;
    const size_t listed = std::min(plan.excluded.size(), maxListed);
    for (size_t i = 0; i < listed; i++) {
        lines.push_back(labelFor(plan.excluded[i], nullptr) + ": " + plan.excludedWhy[i]);
    }
    if (plan.excluded.size() > listed) {
        lines.push_back("and " + std::to_string(plan.excluded.size() - listed) + " more");
    }
    return lines;
}

} // anonymous namespace

std::string executeSheetText(const ExecutePlan &plan, size_t maxListed) {
    std::string out;
    for (const std::string &line : placeableLines(plan, maxListed)) out += (out.empty() ? "" : "\n") + line;
    const std::vector<std::string> excluded = excludedLines(plan, maxListed);
    if (!excluded.empty()) {
        out += "\n\nExcluded:";
        for (const std::string &line : excluded) out += "\n" + line;
    }
    out += "\n\nThe placement runs in the background and keeps running if foobar2000 quits.";
    return out;
}

std::string executeSheetSummary(const ExecutePlan &plan, size_t maxListed) {
    std::string out = std::to_string(plan.placeable.size()) + " placeable, " + std::to_string(plan.excluded.size()) +
                      " excluded";
    const std::vector<std::string> rows = placeableLines(plan, maxListed);
    const std::vector<std::string> excluded = excludedLines(plan, maxListed);
    std::string body;
    for (const std::string &line : rows) body += (body.empty() ? "" : " | ") + line;
    if (!excluded.empty()) {
        body += std::string(body.empty() ? "" : " | ") + "excluded: ";
        for (size_t i = 0; i < excluded.size(); i++) body += (i ? " | " : "") + excluded[i];
    }
    if (!body.empty()) out += ": " + body;
    return out;
}

} // namespace intake
