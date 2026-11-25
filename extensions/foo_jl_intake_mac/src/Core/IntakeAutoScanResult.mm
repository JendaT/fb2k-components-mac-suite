//
//  IntakeAutoScanResult.mm
//  foo_jl_intake
//

#include "IntakeAutoScanResult.h"

#include <cstdio>
#include <unordered_set>

#include "IntakePath.h"

namespace intake {

namespace {

std::string utf8(id value) {
    if (![value isKindOfClass:[NSString class]]) return std::string();
    const char *bytes = [(NSString *)value UTF8String];
    return bytes ? std::string(bytes) : std::string();
}

std::string plural(size_t n, const char *one, const char *many) {
    return std::to_string(n) + " " + (n == 1 ? one : many);
}

std::string secondsText(double seconds) {
    char buf[32];
    snprintf(buf, sizeof buf, "%.1f s", seconds < 0 ? 0.0 : seconds);
    return buf;
}

// "CODE: msg" (no path), for the status bar's short reason.
std::string shortError(const CliError &e) {
    if (e.msg.empty()) return e.code;
    return e.code.empty() ? e.msg : e.code + ": " + e.msg;
}

std::string longError(const CliError &e) {
    std::string out = shortError(e);
    if (e.hasPath && !e.path.empty()) out += (out.empty() ? "" : " ") + std::string("(") + e.path + ")";
    return out;
}

ActivityResult failedWith(std::string reason, const std::string &line) {
    ActivityResult r;
    r.succeeded = false;
    r.reason = std::move(reason);
    r.detail = line;
    return r;
}

} // anonymous namespace

ScanReply readScanReply(id data) {
    ScanReply reply;
    if (![data isKindOfClass:[NSArray class]]) return reply;
    for (id block in (NSArray *)data) {
        if (![block isKindOfClass:[NSDictionary class]]) continue;
        id written = ((NSDictionary *)block)[@"written"];
        if ([written isKindOfClass:[NSArray class]]) {
            reply.counted = true;
            reply.writtenCount += [(NSArray *)written count];
            for (id row in (NSArray *)written) {
                if (![row isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *fields = (NSDictionary *)row;
                ScanWrittenRoot root;
                root.id = utf8(fields[@"id"]);
                if (root.id.empty()) continue;
                root.rootPath = utf8(fields[@"root_path"]);
                root.status = utf8(fields[@"status"]);
                reply.written.push_back(std::move(root));
            }
        }
        id kept = ((NSDictionary *)block)[@"kept"];
        if ([kept isKindOfClass:[NSArray class]]) {
            reply.counted = true;
            reply.keptCount += [(NSArray *)kept count];
        }
    }
    return reply;
}

std::string autoScanErrorsText(const std::vector<CliError> &errors) {
    constexpr size_t kShown = 3;
    std::string out;
    for (size_t i = 0; i < errors.size() && i < kShown; i++) {
        out += (out.empty() ? "" : "; ") + longError(errors[i]);
    }
    if (errors.size() > kShown) out += " (+" + std::to_string(errors.size() - kShown) + " more)";
    return out;
}

ScanFollowUp proposeAfterScan(const std::string &income, const std::string &incomePath, CliOutcome scanOutcome,
                              const ScanReply &reply) {
    ScanFollowUp out;
    if (scanOutcome != CliOutcome::Ok && scanOutcome != CliOutcome::Partial) return out;

    std::string incomeKey;
    const bool haveIncomeKey = normalizePath(incomePath, incomeKey) == PathStatus::Ok;
    std::string rootKey;
    std::unordered_set<std::string> seen;
    for (const ScanWrittenRoot &w : reply.written) {
        if (!seen.insert(w.id).second) continue;
        if (w.status != "resolved") {
            out.skipped.push_back(w.id + " (" + (w.status.empty() ? std::string("no status") : w.status) + ")");
            continue;
        }
        if (haveIncomeKey && normalizePath(w.rootPath, rootKey) == PathStatus::Ok && rootKey == incomeKey) {
            out.skipped.push_back(w.id + " (the income folder itself)");
            continue;
        }
        out.propose.push_back(w.id);
        out.roots.push_back(MutationRoot{w.id, w.rootPath, IntakeStatus::Resolved, std::string()});
    }

    if (!out.skipped.empty()) {
        out.skippedLine = "auto-scan: " + income + ": no propose for " + plural(out.skipped.size(), "root", "roots") +
                          ": ";
        for (size_t i = 0; i < out.skipped.size(); i++) {
            if (i) out.skippedLine += ", ";
            out.skippedLine += out.skipped[i];
        }
    }
    return out;
}

std::string autoScanProposeStartLine(const std::string &income, const std::vector<std::string> &ids) {
    std::string out = "propose: starting after auto-scan of " + income + " for " + plural(ids.size(), "root", "roots") +
                      ":";
    for (const std::string &id : ids) out += " " + id;
    return out;
}

std::string autoScanProposeBudgetLine(const std::string &income) {
    return "propose: still running after auto-scan of " + income +
           " (E_CLI_TIMEOUT: no reply after 10 s; the propose continues)";
}

std::string autoScanStartLine(const std::string &income, bool startup) {
    return "auto-scan: scanning income " + income + (startup ? " (startup)" : " (new files)");
}

std::string autoScanBudgetLine(const std::string &income) {
    return "auto-scan: " + income + " still running (E_CLI_TIMEOUT: no reply after 10 s; the scan continues)";
}

AutoScanOutcome autoScanOutcome(const std::string &income, const CliResult &result) {
    AutoScanOutcome out;
    const EnvelopeResult &envelope = result.envelope;
    const std::string prefix = "auto-scan: " + income;
    const std::string errors = autoScanErrorsText(envelope.errors);
    const std::string firstError = envelope.errors.empty() ? std::string() : shortError(envelope.errors.front());
    const std::string failedLine = prefix + " failed" + (errors.empty() ? std::string() : ": " + errors);

    switch (envelope.outcome) {
        case CliOutcome::Ok:
        case CliOutcome::Partial: {
            out.reply = readScanReply(envelope.data);
            out.newRoots = out.reply.writtenCount;
            const bool partial = envelope.outcome == CliOutcome::Partial;
            out.line = prefix + " done in " + secondsText(result.process.elapsedSeconds);
            if (partial) out.line += " with errors";
            if (out.reply.counted) {
                out.line += ": " + plural(out.reply.writtenCount, "new root", "new roots") + ", " +
                            std::to_string(out.reply.keptCount) + " kept";
            }
            if (partial) {
                if (!errors.empty()) out.line += (out.reply.counted ? "; " : ": ") + errors;
                out.activity = failedWith(firstError, out.line);
            }
            break;
        }
        case CliOutcome::Failed:
            out.line = failedLine;
            out.activity = failedWith(firstError, out.line);
            break;
        case CliOutcome::NoCli:
            out.exit = AutoScanExit::Refused;
            out.line = failedLine;
            out.activity = failedWith(firstError, out.line);
            break;
        case CliOutcome::Timeout:
            out.exit = AutoScanExit::CapKilled;
            out.line = failedLine;
            out.activity = failedWith("stopped at the 15-minute cap", out.line);
            break;
        case CliOutcome::Cancelled:
            out.line = prefix + " cancelled";
            out.activity = failedWith("cancelled", out.line);
            break;
    }
    return out;
}

} // namespace intake
