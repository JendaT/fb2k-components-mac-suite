//
//  IntakeLoadPolicy.mm
//  foo_jl_intake
//

#include "IntakeLoadPolicy.h"

#include "IntakeErrorMap.h"
#include "IntakePath.h"
#include "IntakeWatchFilter.h"

#include <algorithm>
#include <string_view>
#include <unordered_set>

namespace intake {

namespace {

constexpr const char *kDot = " \xC2\xB7 ";  // a middle dot (U+00B7) between spaces

bool sameMembers(const MemberTable &a, const MemberTable &b, const std::string &id) {
    static const RootMembers wholeDirectory;  // the snapshot's default for a missing entry
    auto ia = a.find(id);
    auto ib = b.find(id);
    const RootMembers &ma = ia == a.end() ? wholeDirectory : ia->second;
    const RootMembers &mb = ib == b.end() ? wholeDirectory : ib->second;
    if (ma.kind != mb.kind) return false;
    return ma.kind != MemberKind::Members || ma.relativePaths == mb.relativePaths;
}

std::string rootsText(size_t roots) {
    return std::to_string(roots) + (roots == 1 ? " root" : " roots");
}

char asciiLower(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

// One of two match keys is the other or lies under it, ignoring ASCII case.
bool onOnePath(std::string_view a, std::string_view b) {
    const std::string_view shorter = a.size() <= b.size() ? a : b;
    const std::string_view longer = a.size() <= b.size() ? b : a;
    if (shorter.empty()) return false;
    for (size_t i = 0; i < shorter.size(); i++) {
        if (asciiLower(shorter[i]) != asciiLower(longer[i])) return false;
    }
    return longer.size() == shorter.size() || shorter.back() == '/' || longer[shorter.size()] == '/';
}

bool anyRootOnBase(const IntakeSnapshot &snapshot, const std::vector<std::string> &bases) {
    for (const IntakeRecord &r : snapshot.records()) {
        if (r.rootKey.empty()) continue;  // matches nothing
        for (const std::string &base : bases) {
            if (onOnePath(r.rootKey, base)) return true;
        }
    }
    return false;
}

} // anonymous namespace

LoadFailureEffect loadFailureEffect(LoadStep step, const EnvelopeResult &result, bool everLoaded) {
    if (everLoaded) return LoadFailureEffect::KeepLast;
    const CliCommand command = step == LoadStep::Version ? CliCommand::Version : CliCommand::Status;
    return resultScope(command, result) == ErrorScope::ProviderInert ? LoadFailureEffect::Inert
                                                                     : LoadFailureEffect::KeepLast;
}

std::string loadErrorText(const EnvelopeResult &result) {
    if (!result.errors.empty()) {
        std::string text = renderError(result.errors.front());
        if (result.errors.size() > 1) text += " (+" + std::to_string(result.errors.size() - 1) + " more)";
        return text;
    }
    if (!result.detail.empty()) return result.detail;
    return std::string("unknown error (") + cliOutcomeName(result.outcome) + ")";
}

bool rendersAlike(const IntakeSnapshot &a, const IntakeSnapshot &b) {
    if (a.size() != b.size()) return false;
    for (const IntakeRecord &rb : b.records()) {
        const IntakeRecord *ra = a.recordForId(rb.id);
        if (!ra) return false;
        if (ra->rootKey != rb.rootKey || ra->visual != rb.visual) return false;
        if (!sameMembers(a.members(), b.members(), rb.id)) return false;
    }
    return true;
}

void applyMountAliases(std::vector<IntakeRecord> &records, const MountAliases &aliases) {
    std::string normalized;
    std::string aliased;
    for (IntakeRecord &r : records) {
        if (normalizePath(r.rootPath, normalized) != PathStatus::Ok) {
            r.rootKey.clear();
            continue;
        }
        r.rootKey.assign(aliases.rewrite(normalized, aliased));
    }
}

UnreadableSidecars carryOverUnreadable(std::vector<IntakeRecord> &records, const std::vector<CliError> &errors,
                                       const std::vector<IntakeRecord> &previous) {
    UnreadableSidecars out;
    std::unordered_set<std::string> present;
    for (const IntakeRecord &r : records) present.insert(r.id);
    std::string directory;
    std::string directoryKey;
    std::string previousKey;
    for (const CliError &e : errors) {
        if (e.code != "E_PARSE" || !e.hasPath || e.path.empty() || e.path[0] != '/') continue;
        if (!sidecarEventDirectory(e.path, directory)) continue;
        if (std::find(out.directories.begin(), out.directories.end(), directory) == out.directories.end()) {
            out.directories.push_back(directory);
        }
        const std::string_view name = pathFileName(e.path);
        const bool wholeDirectory = name == ".intake.json";
        // ".intake.<id>.json": the id between the fixed parts.
        const std::string_view id =
            wholeDirectory ? std::string_view() : name.substr(8, name.size() - 8 - 5);
        if (wholeDirectory && normalizePath(directory, directoryKey) != PathStatus::Ok) continue;
        for (const IntakeRecord &p : previous) {
            if (present.count(p.id)) continue;
            bool named = false;
            if (wholeDirectory) {
                named = normalizePath(p.rootPath, previousKey) == PathStatus::Ok && previousKey == directoryKey;
            } else if (p.id.size() == id.size()) {
                named = std::equal(id.begin(), id.end(), p.id.begin(),
                                   [](char a, char b) { return asciiLower(a) == asciiLower(b); });
            }
            if (!named) continue;
            records.push_back(p);
            present.insert(p.id);
            out.carriedIds.push_back(p.id);
        }
    }
    return out;
}

bool remountChangesRows(const IntakeSnapshot &oldSnapshot, const MountAliases &before,
                        const IntakeSnapshot &newSnapshot, const MountAliases &after) {
    if (!rendersAlike(oldSnapshot, newSnapshot)) return true;
    const std::vector<std::string> bases = MountAliases::changedBases(before, after);
    return anyRootOnBase(oldSnapshot, bases) || anyRootOnBase(newSnapshot, bases);
}

const char *loaderStateName(LoaderState state) {
    switch (state) {
        case LoaderState::NotConfigured: return "not configured";
        case LoaderState::Loading: return "loading";
        case LoaderState::Ready: return "ready";
        case LoaderState::Inert: return "inactive";
        case LoaderState::Stale: return "stale";
        case LoaderState::Failed: return "failed";
        case LoaderState::Stopped: return "stopped";
    }
    return "unknown";
}

std::string statusLine(const LoaderStatus &status) {
    std::string cli = status.cliVersion.empty() ? std::string() : "CLI " + status.cliVersion;
    switch (status.state) {
        case LoaderState::NotConfigured:
            return "Not configured: no intake CLI path";
        case LoaderState::Loading:
            return "Loading\xE2\x80\xA6";  // an ellipsis (U+2026)
        case LoaderState::Ready: {
            std::string line = "Ready";
            if (!cli.empty()) line += kDot + cli;
            line += kDot + rootsText(status.roots);
            if (status.partialErrors > 0) {
                line += kDot + std::to_string(status.partialErrors) +
                        (status.partialErrors == 1 ? " error: " : " errors: ") + status.error;
            }
            return line;
        }
        case LoaderState::Inert:
            return "Inactive: " + status.error;
        case LoaderState::Stale: {
            std::string line = "Refresh failed, showing the last data (";
            if (!cli.empty()) line += cli + kDot;
            line += rootsText(status.roots) + "): " + status.error;
            return line;
        }
        case LoaderState::Failed:
            return "Load failed: " + status.error;
        case LoaderState::Stopped:
            return "Stopped";
    }
    return std::string();
}

StatusDisplay statusDisplay(const LoaderStatus &status) {
    static const std::string kUnknown = "\xE2\x80\x94";  // an em dash (U+2014)
    StatusDisplay d;
    d.cliVersion = status.cliVersion.empty() ? kUnknown : status.cliVersion;
    d.roots = std::to_string(status.roots);
    d.lastError = status.error.empty() ? std::string("none") : status.error;
    switch (status.state) {
        case LoaderState::NotConfigured:
            d.state = "Not configured: set the CLI path";
            d.roots = kUnknown;
            break;
        case LoaderState::Loading:
            d.state = "Loading\xE2\x80\xA6";
            d.roots = kUnknown;
            break;
        case LoaderState::Ready:
            d.state = "Active";
            d.tone = StatusTone::Good;
            if (status.partialErrors > 0) {
                d.lastError = std::to_string(status.partialErrors) +
                              (status.partialErrors == 1 ? " error in the last load: " : " errors in the last load: ") +
                              status.error;
                d.tone = StatusTone::Warning;
            }
            break;
        case LoaderState::Stale:
            d.state = "Active, last refresh failed";
            d.tone = StatusTone::Warning;
            break;
        case LoaderState::Inert:
            d.state = "Inactive: " + status.error;
            d.tone = StatusTone::Error;
            break;
        case LoaderState::Failed:
            d.state = "Inactive: the first load failed";
            d.roots = kUnknown;
            d.tone = StatusTone::Error;
            break;
        case LoaderState::Stopped:
            d.state = "Stopped";
            break;
    }
    return d;
}

IncomeDisplay incomeDisplay(const LoaderStatus &status) {
    IncomeDisplay d;
    if (status.state == LoaderState::NotConfigured || status.state == LoaderState::Stopped) {
        d.note = "No CLI is running.";
        return d;
    }
    if (status.incomeOffered) {
        d.fromCli = true;
        for (const IncomeFolder &f : status.incomeFolders) d.rows.push_back({f.name, f.path, f.exists});
        if (!status.incomeError.empty()) {
            // The CLI did not answer: never shown as an empty list.
            d.note = d.rows.empty() ? "The CLI could not list the income folders: " + status.incomeError
                                    : "As the CLI listed them earlier; listing them again failed: " +
                                          status.incomeError;
        } else {
            d.note = d.rows.empty() ? "The CLI lists no income folders." : "As listed by the CLI.";
        }
        return d;
    }
    for (const std::string &folder : status.rootFolders) d.rows.push_back({std::string(), folder, true});
    if (!d.rows.empty()) {
        d.note = "This CLI version cannot list income folders; showing the folders of the loaded releases.";
    } else if (status.state == LoaderState::Loading) {
        d.note = "Loading\xE2\x80\xA6";
    } else {
        d.note = "No releases loaded.";
    }
    return d;
}

CliTestSummary cliTestSummary(const EnvelopeResult &result, const VersionGateResult &gate) {
    CliTestSummary out;
    if (result.outcome == CliOutcome::Cancelled) {
        out.text = "Cancelled";
        return out;
    }
    if (result.outcome != CliOutcome::Ok && result.outcome != CliOutcome::Partial) {
        out.text = "Failed: " + loadErrorText(result);
        return out;
    }
    if (!gate.passed()) {
        out.text = "Unsupported CLI: " + (gate.detail.empty() ? std::string("version data not understood") : gate.detail);
        if (!gate.info.cli.empty()) out.text += ", cli " + gate.info.cli;
        return out;
    }
    out.ok = true;
    out.text = "CLI " + (gate.info.cli.empty() ? std::string("(no version string)") : gate.info.cli) + ", schema " +
               std::to_string(kSupportedSchema);
    if (gate.info.hasCommands) {
        const size_t n = gate.info.commands.size();
        out.text += ", " + std::to_string(n) + (n == 1 ? " command" : " commands");
    }
    return out;
}

std::string rulesSourceDescription(const CliConfig &config) {
    if (!config.rulesDir.empty()) return "rules folder from the rules_dir preference: " + config.rulesDir;
    if (config.baseEnvironment) {
        static const std::string kName = "INTAKE_RULES_DIR=";
        for (const std::string &entry : *config.baseEnvironment) {
            if (entry.compare(0, kName.size(), kName) == 0) {
                return "INTAKE_RULES_DIR inherited from the environment: " + entry.substr(kName.size());
            }
        }
    }
    return "the CLI's own config.toml (no INTAKE_RULES_DIR)";
}

} // namespace intake
