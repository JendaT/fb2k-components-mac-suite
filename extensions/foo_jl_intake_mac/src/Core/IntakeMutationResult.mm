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

bool idChar(char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

// `msg` names `id` as a whole word ("no sidecar with id itk_0000000a").
bool namesId(const std::string &msg, const std::string &id) {
    if (id.empty()) return false;
    for (size_t at = msg.find(id); at != std::string::npos; at = msg.find(id, at + 1)) {
        const bool startOk = at == 0 || !idChar(msg[at - 1]);
        const size_t end = at + id.size();
        const bool endOk = end == msg.size() || !idChar(msg[end]);
        if (startOk && endOk) return true;
    }
    return false;
}

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
        // Pass 1: errors that name a root by id, so they never take another
        // root's place in pass 2's folder order.
        std::vector<bool> placed(envelope.errors.size(), false);
        for (size_t i = 0; i < envelope.errors.size(); i++) {
            const CliError &e = envelope.errors[i];
            if (e.hasPath && !e.path.empty()) {
                // 1. a path that is a named id: that root's (none when it
                // succeeded), never broadcast.
                for (const MutationRoot &r : roots) {
                    if (r.id == e.path) placed[i] = true;
                }
                if (!placed[i]) continue;
                for (FailedRoot &f : failed) {
                    if (roots[f.index].id != e.path) continue;
                    CliError shown = e;
                    shown.hasPath = false;
                    addText(f.text, renderError(shown));
                    break;
                }
                continue;
            }
            // 1b. no path, but the msg names roots of the call ("no sidecar
            // with id itk_..."): it is theirs, never broadcast.
            bool namesAny = false;
            for (const MutationRoot &r : roots) {
                if (namesId(e.msg, r.id)) {
                    namesAny = true;
                    break;
                }
            }
            if (!namesAny) continue;
            placed[i] = true;
            for (FailedRoot &f : failed) {
                if (namesId(e.msg, roots[f.index].id)) addText(f.text, renderError(e));
            }
        }

        // Pass 2: folders, then the command's own errors.
        std::vector<const CliError *> general;
        for (size_t i = 0; i < envelope.errors.size(); i++) {
            if (placed[i]) continue;
            const CliError &e = envelope.errors[i];
            FailedRoot *target = nullptr;
            bool ownPath = false;
            if (e.hasPath && !e.path.empty()) {
                // 2. a folder: the first failed root there without an error,
                // else the last one there.
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
