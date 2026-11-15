//
//  IntakeErrorMap.mm
//  foo_jl_intake
//

#include "IntakeErrorMap.h"

namespace intake {

namespace {

struct KnownCode {
    const char *code;
    const char *text;
};

// Host codes (doc 03) plus the codes CLI 0.2.1 emits
// (feature/intake-cli tools/intake/src). Unknown codes stay renderable.
const KnownCode kKnownCodes[] = {
    {"E_NO_CLI", "Intake CLI not available"},
    {"E_CLI_TIMEOUT", "Intake CLI timed out"},
    {"E_NO_RULES", "Intake rules not configured"},
    {"E_NO_JOURNAL", "Intake journal unavailable"},
    {"E_INTERNAL", "Intake CLI internal error"},
    {"E_BAD_ARGS", "Invalid intake command"},
    {"E_BAD_STATUS", "Not allowed in the current state"},
    {"E_NOT_FOUND", "Release not found"},
    {"E_PARSE", "Unreadable sidecar"},
    {"E_NO_TARGET", "No target collection"},
    {"E_NO_EVIDENCE", "Not enough evidence to identify"},
    {"E_VERIFY", "Verification failed"},
    {"E_TARGET_EXISTS", "Target folder already exists"},
    {"E_EXISTS", "Already exists"},
    {"E_ARCHIVE", "Archive could not be unpacked"},
    {"E_ARCHIVE_TOOL", "Archive tool missing"},
};

bool isProviderWideCode(std::string_view code) {
    return code == kErrorNoCli || code == kErrorCliTimeout || code == "E_NO_RULES";
}

} // anonymous namespace

ErrorScope errorScope(CliCommand command, std::string_view code) {
    bool inventoryCall = command == CliCommand::Version || command == CliCommand::Status;
    return inventoryCall && isProviderWideCode(code) ? ErrorScope::ProviderInert
                                                     : ErrorScope::PerCommand;
}

ErrorScope resultScope(CliCommand command, const EnvelopeResult &result) {
    for (const CliError &e : result.errors) {
        if (errorScope(command, e.code) == ErrorScope::ProviderInert) return ErrorScope::ProviderInert;
    }
    return ErrorScope::PerCommand;
}

const char *knownErrorText(std::string_view code) {
    for (const KnownCode &k : kKnownCodes) {
        if (code == k.code) return k.text;
    }
    return nullptr;
}

std::string renderError(const CliError &error) {
    std::string out;
    if (const char *known = knownErrorText(error.code)) {
        out = known;
        if (!error.msg.empty()) out += ": " + error.msg;
    } else {
        out = error.msg.empty() ? error.code : error.msg;
    }
    if (out.empty()) out = "Unknown intake error";
    if (error.hasPath && !error.path.empty()) out += " (" + error.path + ")";
    return out;
}

} // namespace intake
