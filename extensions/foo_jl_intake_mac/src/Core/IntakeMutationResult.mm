//
//  IntakeMutationResult.mm
//  foo_jl_intake
//

#include "IntakeMutationResult.h"

#include "IntakeErrorMap.h"
#include "IntakePath.h"

#include <algorithm>
#include <unordered_set>

namespace intake {

namespace {

const char *const kJoin = " \xC2\xB7 ";  // " U+00B7 "

std::string pathKey(const std::string &path) {
    std::string normalized;
    if (normalizePath(path, normalized) == PathStatus::Ok) return normalized;
    return path;
}

std::string rootsText(size_t n) {
    return std::to_string(n) + (n == 1 ? " root" : " roots");
}

struct FailedRoot {
    size_t index;  // into roots
    std::string key;
    std::string text;
};

} // anonymous namespace

MutationOutcome summarizeMutation(CliCommand command, const std::vector<MutationRoot> &roots,
                                  const EnvelopeResult &envelope) {
    MutationOutcome out;
    const std::string name = cliCommandName(command);
    const CliOutcome outcome = envelope.outcome;

    if (outcome == CliOutcome::Cancelled) {
        out.consoleLine = name + ": cancelled";
        for (const MutationRoot &r : roots) out.failedWithoutError.push_back(r.id);
        return out;
    }

    // Who succeeded.
    std::unordered_set<std::string> inData;
    if (outcome == CliOutcome::Ok || outcome == CliOutcome::Partial) {
        for (const std::string &id : idsInData(envelope.data)) inData.insert(id);
    }
    std::vector<FailedRoot> failed;
    for (size_t i = 0; i < roots.size(); i++) {
        if (inData.count(roots[i].id)) {
            out.succeeded.push_back(roots[i].id);
        } else {
            failed.push_back({i, pathKey(roots[i].rootPath), std::string()});
        }
    }

    auto addText = [&name](std::string &into, const std::string &rendered) {
        if (into.empty()) {
            into = name + ": " + rendered;
        } else {
            into += kJoin;
            into += rendered;
        }
    };

    if (outcome == CliOutcome::NoCli || outcome == CliOutcome::Timeout) {
        // Host-synthesized: one entry, the whole call.
        const std::string rendered = envelope.errors.empty()
                                         ? std::string(outcome == CliOutcome::NoCli ? "Intake CLI not available"
                                                                                    : "Intake CLI timed out")
                                         : renderError(envelope.errors.front());
        for (FailedRoot &f : failed) addText(f.text, rendered);
    } else {
        std::vector<const CliError *> general;
        for (const CliError &e : envelope.errors) {
            FailedRoot *target = nullptr;
            bool ownPath = false;
            if (e.hasPath && !e.path.empty()) {
                // 1. an id
                for (FailedRoot &f : failed) {
                    if (roots[f.index].id == e.path) {
                        target = &f;
                        ownPath = true;
                        break;
                    }
                }
                // 2. a folder: the first failed root there without an error,
                // else the last one there.
                if (target == nullptr) {
                    const std::string key = pathKey(e.path);
                    FailedRoot *last = nullptr;
                    for (FailedRoot &f : failed) {
                        if (f.key != key && roots[f.index].rootPath != e.path) continue;
                        last = &f;
                        if (f.text.empty()) {
                            target = &f;
                            break;
                        }
                    }
                    if (target == nullptr) target = last;
                    ownPath = target != nullptr;
                }
            }
            if (target == nullptr) {
                general.push_back(&e);
                continue;
            }
            CliError shown = e;
            if (ownPath) shown.hasPath = false;
            addText(target->text, renderError(shown));
        }
        // 3. the command's own errors: every failed root left without one.
        if (!general.empty()) {
            std::vector<FailedRoot *> bare;
            for (FailedRoot &f : failed) {
                if (f.text.empty()) bare.push_back(&f);
            }
            for (FailedRoot *f : bare) {
                for (const CliError *e : general) addText(f->text, renderError(*e));
            }
        }
    }

    for (const FailedRoot &f : failed) {
        if (f.text.empty()) {
            out.failedWithoutError.push_back(roots[f.index].id);
        } else {
            out.rootErrors.emplace_back(roots[f.index].id, f.text);
        }
    }

    // The console line.
    std::string firstError;
    size_t errorCount = envelope.errors.size();
    if (!envelope.errors.empty()) {
        firstError = renderError(envelope.errors.front());
    } else if (!envelope.detail.empty()) {
        firstError = envelope.detail;
    }
    if (errorCount > 1) firstError += " (+" + std::to_string(errorCount - 1) + " more)";

    switch (outcome) {
        case CliOutcome::Ok:
            out.consoleLine = name + ": done for " + rootsText(out.succeeded.size());
            if (out.succeeded.size() != roots.size()) {
                out.consoleLine = name + ": done for " + std::to_string(out.succeeded.size()) + " of " +
                                  rootsText(roots.size());
            }
            break;
        case CliOutcome::Partial:
            out.consoleLine = name + ": done for " + std::to_string(out.succeeded.size()) + " of " +
                              rootsText(roots.size()) + "; " + firstError;
            out.isError = true;
            break;
        case CliOutcome::Failed:
        case CliOutcome::NoCli:
        case CliOutcome::Timeout:
            out.consoleLine = name + " failed for " + rootsText(roots.size()) + ": " +
                              (firstError.empty() ? std::string(cliOutcomeName(outcome)) : firstError);
            out.isError = true;
            break;
        case CliOutcome::Cancelled:
            break;
    }
    return out;
}

} // namespace intake
