//
//  IntakeCapabilitiesTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeCapabilities: parsing `intake version --json` data,
//  and command support from a v1.2 `commands` array or, without one, from
//  the `cli` semver (CLI 0.2.1 and older). The version data mirrors the
//  mock's `default` (CLI 0.3.0) and `cli-0.2.1` scenarios.
//
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//
// TEST_DEPS: src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCapabilities.h"
#include "TestHarness.h"

using intake::CliCommand;
using intake::CliVersionInfo;

namespace {

id json(const char *text) {
    NSData *bytes = [NSData dataWithBytes:text length:strlen(text)];
    return [NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingFragmentsAllowed error:nil];
}

bool supports(const char *versionData, CliCommand command) {
    return intake::cliSupportsCommand(intake::parseCliVersionInfo(json(versionData)), command);
}

const CliCommand kAll[] = {CliCommand::Version, CliCommand::Status, CliCommand::Collections,
                           CliCommand::Income,  CliCommand::Propose, CliCommand::Assign,
                           CliCommand::Approve, CliCommand::Reject,  CliCommand::Execute,
                           CliCommand::Resume,  CliCommand::Gc};

// The real CLI's dispatch table (feature/intake-cli cli.ts COMMANDS), as the
// mock's default scenario reports it.
const char *kV12 =
    R"({"cli":"0.3.0","schema":1,"engine":"0.2.0","commands":["scan","resolve","identify","assign",)"
    R"("propose","approve","reject","execute","gc","status","collections","income","version","bootstrap"]})";

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        // --- parsing ---
        g_context = "parse";
        CliVersionInfo info = intake::parseCliVersionInfo(json(kV12));
        CHECK(info.cli == "0.3.0", "cli read");
        CHECK(info.hasCommands, "commands array seen");
        CHECK_EQ(info.commands.size(), 14, "every command name kept");
        CHECK(info.commands.front() == "scan" && info.commands.back() == "bootstrap", "in order");

        info = intake::parseCliVersionInfo(json(R"({"cli":"0.2.1","schema":1,"engine":"0.2.0"})"));
        CHECK(info.cli == "0.2.1" && !info.hasCommands && info.commands.empty(), "0.2.1: no commands array");

        info = intake::parseCliVersionInfo(json(R"({"cli":7,"commands":"reject income"})"));
        CHECK(info.cli.empty(), "a non-string cli reads as empty");
        CHECK(!info.hasCommands, "a non-array commands counts as absent");

        info = intake::parseCliVersionInfo(json(R"({"cli":"0.3.0","commands":["income",1,null,{"x":1},"gc"]})"));
        CHECK(info.hasCommands && info.commands == std::vector<std::string>({"income", "gc"}),
              "non-string entries are ignored");

        info = intake::parseCliVersionInfo(json(R"(["income"])"));
        CHECK(info.cli.empty() && !info.hasCommands, "an array is not version data");
        info = intake::parseCliVersionInfo(nil);
        CHECK(info.cli.empty() && !info.hasCommands, "nil is not version data");

        // --- contract v1.2: the commands array decides ---
        g_context = "commands";
        int supported = 0;
        for (CliCommand c : kAll) {
            if (supports(kV12, c)) supported++;
        }
        CHECK_EQ(supported, (int)(sizeof kAll / sizeof kAll[0]), "CLI 0.3.0 supports every component command");
        CHECK(supports(kV12, CliCommand::Income), "income listed: supported");
        CHECK(supports(kV12, CliCommand::Resume), "resume is execute: supported");

        const char *noIncome = R"({"cli":"0.3.0","schema":1,"commands":["status","version","execute"]})";
        CHECK(!supports(noIncome, CliCommand::Income), "income not listed: unsupported");
        CHECK(!supports(noIncome, CliCommand::Reject), "reject not listed: unsupported, whatever cli says");
        CHECK(!supports(noIncome, CliCommand::Gc), "even an old command is unsupported when not listed");
        CHECK(supports(noIncome, CliCommand::Resume), "resume follows execute");

        // The list wins over the version: a pre-release that the strict
        // semver rejects still gets what it lists.
        const char *preRelease = R"({"cli":"0.3.0-rc.1","schema":1,"commands":["reject","execute"]})";
        CHECK(supports(preRelease, CliCommand::Reject), "listed reject on a pre-release: supported");
        CHECK(supports(preRelease, CliCommand::Resume), "listed execute on a pre-release: resume supported");
        CHECK(!supports(R"({"cli":"0.3.0","commands":[]})", CliCommand::Status),
              "an empty commands array lists nothing");

        // --- CLI 0.2.1 and older: the semver fallback ---
        g_context = "fallback";
        const char *v021 = R"({"cli":"0.2.1","schema":1,"engine":"0.2.0"})";
        CHECK(supports(v021, CliCommand::Reject), "0.2.1: reject");
        CHECK(supports(v021, CliCommand::Resume), "0.2.1: per-root resume");
        CHECK(!supports(v021, CliCommand::Income), "0.2.1: no income");
        CHECK(supports(v021, CliCommand::Gc) && supports(v021, CliCommand::Collections), "0.2.1: the rest");

        const char *v020 = R"({"cli":"0.2.0","schema":1,"engine":"0.2.0"})";
        CHECK(supports(v020, CliCommand::Reject), "0.2.0: reject");
        CHECK(!supports(v020, CliCommand::Resume), "0.2.0: resume would act on every placing root");

        const char *v010 = R"({"cli":"0.1.0","schema":1,"engine":"0.1.0"})";
        CHECK(!supports(v010, CliCommand::Reject), "0.1.0: no reject");
        CHECK(!supports(v010, CliCommand::Resume), "0.1.0: no per-root resume");
        CHECK(supports(v010, CliCommand::Approve) && supports(v010, CliCommand::Execute), "0.1.0: the rest");

        // A later version without the array still never gets income: only
        // the array announces it.
        CHECK(!supports(R"({"cli":"0.4.0","schema":1})", CliCommand::Income), "no array: income never");
        CHECK(supports(R"({"cli":"0.4.0","schema":1})", CliCommand::Reject), "no array, 0.4.0: reject");

        const char *garbage = R"({"cli":"0.2.1-beta","schema":1})";
        CHECK(!supports(garbage, CliCommand::Reject) && !supports(garbage, CliCommand::Resume),
              "an unparseable cli turns the version-gated commands off");
        CHECK(supports(garbage, CliCommand::Status), "and leaves the always-present ones on");
    }
    TEST_MAIN_END();
}
