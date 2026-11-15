//
//  IntakeLoadPolicy.mm
//  foo_jl_intake
//

#include "IntakeLoadPolicy.h"

#include "IntakeErrorMap.h"
#include "IntakePath.h"

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
