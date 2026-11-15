//
//  IntakeErrorMapTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeErrorMap: provider-wide vs per-command scope
//  (PLAN.md 3.4) and the user-facing text for known and unknown codes.
//
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeErrorMap.h"
#include "TestHarness.h"

using intake::CliCommand;
using intake::CliError;
using intake::ErrorScope;

namespace {

CliError err(const char *code, const char *msg = "", const char *path = nullptr) {
    CliError e;
    e.code = code;
    e.msg = msg;
    if (path) {
        e.path = path;
        e.hasPath = true;
    }
    return e;
}

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        // --- scope table ---
        g_context = "scope";
        const char *inert[] = {"E_NO_CLI", "E_NO_RULES", "E_CLI_TIMEOUT"};
        int inertOk = 0;
        for (const char *code : inert) {
            if (intake::errorScope(CliCommand::Version, code) == ErrorScope::ProviderInert &&
                intake::errorScope(CliCommand::Status, code) == ErrorScope::ProviderInert) {
                inertOk++;
            }
        }
        CHECK_EQ(inertOk, 3, "E_NO_CLI, E_NO_RULES, E_CLI_TIMEOUT on version/status: provider inert");

        const CliCommand others[] = {CliCommand::Collections, CliCommand::Propose, CliCommand::Assign,
                                     CliCommand::Approve,     CliCommand::Reject,  CliCommand::Execute,
                                     CliCommand::Resume,      CliCommand::Gc};
        int perCommand = 0, total = 0;
        for (CliCommand cmd : others) {
            for (const char *code : inert) {
                total++;
                if (intake::errorScope(cmd, code) == ErrorScope::PerCommand) perCommand++;
            }
        }
        CHECK_EQ(perCommand, total, "the same codes on any other command: per command");

        CHECK(intake::errorScope(CliCommand::Status, "E_INTERNAL") == ErrorScope::PerCommand,
              "E_INTERNAL on status: per command (not E_NO_CLI)");
        CHECK(intake::errorScope(CliCommand::Status, "E_PARSE") == ErrorScope::PerCommand,
              "E_PARSE on status: per command");
        CHECK(intake::errorScope(CliCommand::Version, "E_SOMETHING_NEW") == ErrorScope::PerCommand,
              "an unknown code on version: per command");
        CHECK(intake::errorScope(CliCommand::Status, "e_no_rules") == ErrorScope::PerCommand,
              "codes are case-sensitive");

        // --- result scope ---
        g_context = "result-scope";
        intake::EnvelopeResult partial;
        partial.outcome = intake::CliOutcome::Partial;
        partial.errors = {err("E_PARSE"), err("E_NO_RULES")};
        CHECK(intake::resultScope(CliCommand::Status, partial) == ErrorScope::ProviderInert,
              "any provider-wide error makes the result provider-wide");
        CHECK(intake::resultScope(CliCommand::Approve, partial) == ErrorScope::PerCommand,
              "not on a mutating command");
        CHECK(intake::resultScope(CliCommand::Status, intake::hostNoCli("x")) == ErrorScope::ProviderInert,
              "host E_NO_CLI on status: provider inert");
        CHECK(intake::resultScope(CliCommand::Version, intake::hostTimeout("x")) == ErrorScope::ProviderInert,
              "host E_CLI_TIMEOUT on version: provider inert");
        intake::EnvelopeResult ok;
        ok.outcome = intake::CliOutcome::Ok;
        CHECK(intake::resultScope(CliCommand::Status, ok) == ErrorScope::PerCommand, "Ok: nothing provider-wide");

        // --- text ---
        g_context = "text";
        const char *known[] = {"E_NO_CLI", "E_CLI_TIMEOUT", "E_NO_RULES", "E_NO_JOURNAL", "E_INTERNAL",
                               "E_BAD_ARGS", "E_BAD_STATUS", "E_NOT_FOUND", "E_PARSE", "E_NO_TARGET",
                               "E_NO_EVIDENCE", "E_VERIFY", "E_TARGET_EXISTS", "E_EXISTS", "E_ARCHIVE",
                               "E_ARCHIVE_TOOL"};
        int withText = 0;
        for (const char *code : known) {
            const char *text = intake::knownErrorText(code);
            if (text && *text) withText++;
        }
        CHECK_EQ(withText, (int)(sizeof known / sizeof known[0]),
                 "every code CLI 0.2.1 emits, plus the host codes, has a short text");
        CHECK(intake::knownErrorText("E_MOCK_UNKNOWN_CODE") == nullptr, "an unknown code has no fixed text");

        CHECK(intake::renderError(err("E_NO_RULES")) == "Intake rules not configured",
              "known code without msg: the phrase");
        CHECK(intake::renderError(err("E_BAD_STATUS", "cannot approve from status placed", "/r/a")) ==
                  "Not allowed in the current state: cannot approve from status placed (/r/a)",
              "known code: phrase, msg, path");
        CHECK(intake::renderError(err("E_MOCK_UNKNOWN_CODE", "mock: an error code no consumer knows", "/r")) ==
                  "mock: an error code no consumer knows (/r)",
              "unknown code: rendered from msg and path");
        CHECK(intake::renderError(err("E_FUTURE")) == "E_FUTURE", "unknown code without msg: the code");
        CliError emptyPath = err("E_FUTURE", "m", "");
        CHECK(intake::renderError(emptyPath) == "m", "an empty path is not appended");
        CHECK(intake::renderError(intake::hostNoCli("exit code 127").errors[0]) ==
                  "Intake CLI not available: exit code 127",
              "host E_NO_CLI renders with its detail");
    }
    TEST_MAIN_END();
}
