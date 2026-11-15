//
//  IntakeCommandArgsTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeCommandArgs: argv shapes, the zero-id invariant,
//  id validation, the forbidden flags, bun resolution, the environment, and
//  one real run of a built argv against Tests/mock-cli/intake-mock to show
//  "[A & B]" arrives literally (calls.log).
//
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//
// TEST_DEPS: src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeCommandArgs.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <algorithm>
#include <cstdlib>

using intake::BuildStatus;
using intake::CliCommand;
using intake::CliConfig;
using intake::CliInvocation;
using intake::CliRequest;
using intake::CommandClass;

namespace {

const std::string kCli = "/opt/intake/bin/intake";
std::string g_noBunDir;

CliConfig plainConfig() {
    CliConfig c;
    c.cliPath = kCli;
    c.bunSearchDirs = {g_noBunDir};
    c.baseEnvironment = std::vector<std::string>{"HOME=/Users/test", "PATH=/usr/bin:/bin", "LANG=C"};
    c.cliVersion = "0.2.1";
    return c;
}

CliRequest req(CliCommand command, std::vector<std::string> ids = {}) {
    CliRequest r;
    r.command = command;
    r.ids = std::move(ids);
    return r;
}

std::vector<std::string> args(const CliInvocation &inv) {
    return inv.arguments;
}

std::vector<std::string> v(std::initializer_list<const char *> items) {
    std::vector<std::string> out;
    for (const char *s : items) out.emplace_back(s);
    return out;
}

std::string envValue(const CliInvocation &inv, const std::string &name) {
    for (const std::string &e : inv.environment) {
        if (e.compare(0, name.size() + 1, name + "=") == 0) return e.substr(name.size() + 1);
    }
    return "<unset>";
}

int envCount(const CliInvocation &inv, const std::string &name) {
    int n = 0;
    for (const std::string &e : inv.environment) {
        if (e.compare(0, name.size() + 1, name + "=") == 0) n++;
    }
    return n;
}

bool refusedFor(const CliRequest &r) {
    CliInvocation inv = intake::buildInvocation(plainConfig(), r);
    return inv.status == BuildStatus::Refused && !inv.message.empty() && inv.arguments.empty();
}

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        g_noBunDir = mock::newDir("nobun");

        // --- argv shapes ---
        g_context = "argv";
        CliInvocation inv = intake::buildInvocation(plainConfig(), req(CliCommand::Version));
        CHECK(inv.status == BuildStatus::Ok, "version builds");
        CHECK(inv.executable == kCli, "a non-.ts CLI runs directly");
        CHECK(args(inv) == v({"/opt/intake/bin/intake", "version", "--json"}), "version argv");

        CliRequest status = req(CliCommand::Status);
        status.filters = {{"status", "proposed"}, {"root_path", "/a=b"}};
        CHECK(args(intake::buildInvocation(plainConfig(), status)) ==
                  v({"/opt/intake/bin/intake", "status", "--filter", "status=proposed", "--filter",
                     "root_path=/a=b", "--json"}),
              "status --filter argv (value may contain '=')");
        CHECK(args(intake::buildInvocation(plainConfig(), req(CliCommand::Collections))) ==
                  v({"/opt/intake/bin/intake", "collections", "--json"}),
              "collections argv");
        CHECK(args(intake::buildInvocation(plainConfig(), req(CliCommand::Income))) ==
                  v({"/opt/intake/bin/intake", "income", "--json"}),
              "income argv");
        CHECK(args(intake::buildInvocation(plainConfig(),
                                           req(CliCommand::Propose, {"itk_0000000b", "itk_0000000c"}))) ==
                  v({"/opt/intake/bin/intake", "propose", "itk_0000000b", "itk_0000000c", "--json"}),
              "propose argv");

        CliRequest assign = req(CliCommand::Assign, {"itk_0000000e"});
        assign.collection = "[A & B]";
        CHECK(args(intake::buildInvocation(plainConfig(), assign)) ==
                  v({"/opt/intake/bin/intake", "assign", "itk_0000000e", "--collection", "[A & B]", "--by",
                     "user", "--json"}),
              "assign argv: collection as one literal argument, --by user");

        CHECK(args(intake::buildInvocation(plainConfig(), req(CliCommand::Approve, {"itk_0000000d"}))) ==
                  v({"/opt/intake/bin/intake", "approve", "itk_0000000d", "--json"}),
              "approve argv");
        CliRequest reject = req(CliCommand::Reject, {"itk_0000000a"});
        CHECK(args(intake::buildInvocation(plainConfig(), reject)) ==
                  v({"/opt/intake/bin/intake", "reject", "itk_0000000a", "--json"}),
              "reject argv without a reason");
        reject.reason = "--approved";
        CHECK(args(intake::buildInvocation(plainConfig(), reject)) ==
                  v({"/opt/intake/bin/intake", "reject", "itk_0000000a", "--reason", "--approved", "--json"}),
              "a reason that looks like a flag stays the value of --reason");
        CHECK(args(intake::buildInvocation(plainConfig(), req(CliCommand::Execute, {"itk_00000010"}))) ==
                  v({"/opt/intake/bin/intake", "execute", "itk_00000010", "--json"}),
              "execute argv");
        CHECK(args(intake::buildInvocation(plainConfig(), req(CliCommand::Resume, {"itk_00000011"}))) ==
                  v({"/opt/intake/bin/intake", "execute", "itk_00000011", "--resume", "--json"}),
              "resume argv");
        CliRequest gc = req(CliCommand::Gc, {"itk_00000012"});
        gc.dryRun = true;
        CHECK(args(intake::buildInvocation(plainConfig(), gc)) ==
                  v({"/opt/intake/bin/intake", "gc", "itk_00000012", "--dry-run", "--json"}),
              "gc --dry-run argv");
        CHECK(args(intake::buildInvocation(plainConfig(),
                                           req(CliCommand::Approve,
                                               {"itk_0000000d", "itk_0000000e", "itk_0000000d"}))) ==
                  v({"/opt/intake/bin/intake", "approve", "itk_0000000d", "itk_0000000e", "--json"}),
              "a repeated id is passed once, first position kept");

        // --- the zero-id invariant, every mutating command, dry runs too ---
        g_context = "zero-ids";
        const CliCommand mutating[] = {CliCommand::Propose, CliCommand::Assign, CliCommand::Approve,
                                       CliCommand::Reject,  CliCommand::Execute, CliCommand::Resume,
                                       CliCommand::Gc};
        int refusedCount = 0, total = 0;
        for (CliCommand cmd : mutating) {
            for (bool dry : {false, true}) {
                CliRequest r = req(cmd);
                r.dryRun = dry;
                if (cmd == CliCommand::Assign) r.collection = "Test Collection A";
                total++;
                if (refusedFor(r)) refusedCount++;
            }
        }
        CHECK_EQ(refusedCount, total, "every mutating command with no ids is refused");
        CHECK(intake::buildInvocation(plainConfig(), req(CliCommand::Gc)).message.find("every root") !=
                  std::string::npos,
              "the gc refusal explains the danger");
        CliRequest gcOnlyBad = req(CliCommand::Gc, {});
        gcOnlyBad.dryRun = true;
        CHECK(refusedFor(gcOnlyBad), "bare gc --dry-run is refused");

        // --- ids must be sidecar ids ---
        g_context = "ids";
        const char *badIds[] = {"--approved", "--all", "--all-resolved", "-x", "itk_0000000G", "itk_000000b",
                                "itk_0000000bb", "ITK_0000000B", " itk_0000000b", "", "/Volumes/x",
                                "income/dump", "itk_0000000b\n"};
        int badRefused = 0;
        for (const char *bad : badIds) {
            if (refusedFor(req(CliCommand::Approve, {"itk_0000000d", bad}))) badRefused++;
        }
        CHECK_EQ(badRefused, (int)(sizeof badIds / sizeof badIds[0]), "every non-id ref is refused");
        CHECK(intake::isSidecarId("itk_0123abcd"), "a sidecar id is accepted");
        CHECK(!intake::isSidecarId(std::string("itk_0123abc\0", 12)), "a NUL inside an id is not an id");

        // --- other request checks ---
        g_context = "request-checks";
        CHECK(refusedFor(req(CliCommand::Status, {"itk_0000000b"})), "status takes no ids");
        CHECK(refusedFor(req(CliCommand::Income, {"itk_0000000b"})), "income takes no ids");
        CliRequest dryRead = req(CliCommand::Version);
        dryRead.dryRun = true;
        CHECK(refusedFor(dryRead), "read commands have no --dry-run");
        CliRequest dryIncome = req(CliCommand::Income);
        dryIncome.dryRun = true;
        CHECK(refusedFor(dryIncome), "income has no --dry-run");
        CliRequest noCollection = req(CliCommand::Assign, {"itk_0000000e"});
        CHECK(refusedFor(noCollection), "assign without a collection is refused");
        CliRequest stray = req(CliCommand::Approve, {"itk_0000000d"});
        stray.collection = "X";
        CHECK(refusedFor(stray), "a collection on another command is refused");
        CliRequest strayReason = req(CliCommand::Approve, {"itk_0000000d"});
        strayReason.reason = "x";
        CHECK(refusedFor(strayReason), "a reason on another command is refused");
        CliRequest strayFilter = req(CliCommand::Collections);
        strayFilter.filters = {{"status", "new"}};
        CHECK(refusedFor(strayFilter), "filters on another command are refused");
        CliRequest badKey = req(CliCommand::Status);
        badKey.filters = {{"", "new"}};
        CHECK(refusedFor(badKey), "an empty filter key is refused");
        badKey.filters = {{"a=b", "c"}};
        CHECK(refusedFor(badKey), "a filter key containing '=' is refused");
        CliRequest nul = req(CliCommand::Assign, {"itk_0000000e"});
        nul.collection = std::string("A\0B", 3);
        CHECK(refusedFor(nul), "a NUL byte in the collection is refused");

        // --- forbidden flags never appear in any argv ---
        g_context = "forbidden-flags";
        std::vector<CliRequest> all = {req(CliCommand::Version), req(CliCommand::Status),
                                       req(CliCommand::Collections), req(CliCommand::Income)};
        for (CliCommand cmd : mutating) {
            for (bool dry : {false, true}) {
                CliRequest r = req(cmd, {"itk_0000000b"});
                r.dryRun = dry;
                if (cmd == CliCommand::Assign) r.collection = "C";
                if (cmd == CliCommand::Reject) r.reason = "why";
                all.push_back(r);
            }
        }
        bool clean = true, allBuilt = true, allJson = true;
        for (const CliRequest &r : all) {
            CliInvocation i = intake::buildInvocation(plainConfig(), r);
            if (i.status != BuildStatus::Ok) allBuilt = false;
            for (const std::string &a : i.arguments) {
                if (a == "--all-resolved" || a == "--approved" || a == "--all") clean = false;
            }
            if (i.arguments.empty() || i.arguments.back() != "--json") allJson = false;
            if (r.command == CliCommand::Gc && i.arguments.size() < 4) clean = false; // bare gc
        }
        CHECK(allBuilt, "every valid request builds");
        CHECK(clean, "no --all-resolved, --approved, --all or bare gc in any argv");
        CHECK(allJson, "every argv ends with --json");

        // --- command classes (doc 03 v1.2 "Timeouts") ---
        g_context = "classes";
        CHECK(intake::commandClass(req(CliCommand::Status)) == CommandClass::ReadOnly, "status: read-only");
        CHECK(intake::commandClass(req(CliCommand::Income)) == CommandClass::ReadOnly,
              "income: read-only, killable at the budget");
        CHECK(!intake::isMutatingCommand(CliCommand::Income), "income is not mutating");
        CHECK(intake::commandClass(req(CliCommand::Approve, {"itk_0000000d"})) == CommandClass::Mutating,
              "approve: mutating");
        CHECK(intake::commandClass(req(CliCommand::Execute, {"itk_00000010"})) == CommandClass::Detached,
              "execute: detached");
        CHECK(intake::commandClass(req(CliCommand::Resume, {"itk_00000011"})) == CommandClass::Detached,
              "resume: detached");
        // A mutating command is classified by command, whatever its flags: a
        // dry run is never killed at the budget.
        CliRequest dryExec = req(CliCommand::Execute, {"itk_00000010"});
        dryExec.dryRun = true;
        CHECK(intake::commandClass(dryExec) == CommandClass::ExecuteDryRun,
              "execute --dry-run: reported at the budget, never killed");
        CliRequest dryGc = req(CliCommand::Gc, {"itk_00000012"});
        dryGc.dryRun = true;
        CHECK(intake::commandClass(dryGc) == CommandClass::Mutating, "gc --dry-run: mutating policy");
        CliRequest dryResume = req(CliCommand::Resume, {"itk_00000011"});
        dryResume.dryRun = true;
        CHECK(intake::commandClass(dryResume) == CommandClass::ExecuteDryRun,
              "resume --dry-run: execute's dry-run policy");
        CliRequest dryPropose = req(CliCommand::Propose, {"itk_0000000b"});
        dryPropose.dryRun = true;
        CHECK(intake::commandClass(dryPropose) == CommandClass::Mutating, "propose --dry-run: mutating policy");
        CliRequest dryReject = req(CliCommand::Reject, {"itk_0000000a"});
        dryReject.dryRun = true;
        CHECK(intake::commandClass(dryReject) == CommandClass::Mutating, "reject --dry-run: mutating policy");
        CHECK(intake::commandClass(req(CliCommand::Gc, {"itk_00000012"})) == CommandClass::Mutating,
              "gc: mutating");
        CHECK(std::string(intake::cliCommandName(CliCommand::Resume)) == "resume" &&
                  std::string(intake::cliCommandWord(CliCommand::Resume)) == "execute",
              "resume is logged as resume, sent as execute");

        // --- resume needs a CLI that scopes it to the ids (0.2.1, 5a665e93) ---
        g_context = "resume-version";
        CliConfig old = plainConfig();
        int resumeRefused = 0;
        const char *tooOld[] = {"", "0.1.0", "0.2.0", "0.2.1-rc.1", "garbage"};
        for (const char *version : tooOld) {
            old.cliVersion = version;
            CliInvocation i = intake::buildInvocation(old, req(CliCommand::Resume, {"itk_00000011"}));
            if (i.status == BuildStatus::Refused && i.arguments.empty() &&
                i.message.find("every placing root") != std::string::npos) {
                resumeRefused++;
            }
        }
        CHECK_EQ(resumeRefused, (int)(sizeof tooOld / sizeof tooOld[0]),
                 "resume is refused while the CLI is unknown or older than 0.2.1");
        old.cliVersion = "0.2.0";
        CHECK(intake::buildInvocation(old, dryResume).status == BuildStatus::Refused,
              "resume --dry-run is refused on 0.2.0 too");
        CHECK(intake::buildInvocation(old, req(CliCommand::Execute, {"itk_00000010"})).status == BuildStatus::Ok,
              "plain execute is scoped by its ids on every version");
        old.cliVersion = "0.3.0";
        CHECK(intake::buildInvocation(old, req(CliCommand::Resume, {"itk_00000011"})).status == BuildStatus::Ok,
              "resume builds on a later CLI");
        // A v1.2 CLI (it lists commands) scopes resume to the ids whatever
        // its cli string: the same rule as cliSupportsCommand.
        CliConfig listed = plainConfig();
        listed.cliListsCommands = true;
        listed.cliVersion = "0.3.0-rc.1";
        CHECK(intake::buildInvocation(listed, req(CliCommand::Resume, {"itk_00000011"})).status == BuildStatus::Ok,
              "resume builds on a pre-release that lists commands");
        listed.cliVersion.clear();
        CHECK(intake::buildInvocation(listed, dryResume).status == BuildStatus::Ok,
              "and on a CLI that lists commands without a cli string");

        // --- configuration problems are NoCli, never a spawn ---
        g_context = "no-cli";
        CliConfig c = plainConfig();
        c.cliPath.clear();
        CHECK(intake::buildInvocation(c, req(CliCommand::Status)).status == BuildStatus::NoCli,
              "no CLI path: NoCli");
        c.cliPath = "intake";
        CHECK(intake::buildInvocation(c, req(CliCommand::Status)).status == BuildStatus::NoCli,
              "a relative CLI path: NoCli");
        c.cliPath = "~/intake/cli.ts";
        CHECK(intake::buildInvocation(c, req(CliCommand::Status)).status == BuildStatus::NoCli,
              "an unexpanded ~ path: NoCli");
        c = plainConfig();
        c.cliPath = "";
        CHECK(intake::buildInvocation(c, req(CliCommand::Gc)).status == BuildStatus::Refused,
              "request checks come first: a bare gc is refused even when unconfigured");

        // --- .ts through bun ---
        g_context = "bun";
        std::string dirA = mock::newDir("bunA"), dirB = mock::newDir("bunB"), dirC = mock::newDir("bunC");
        std::string cliTs = mock::newDir("cli") + "/cli.ts";
        mock::writeFile(cliTs, "// cli\n");
        mock::writeFile(dirA + "/bun", "#!/bin/bash\n", 0644); // not executable: skipped
        mock::writeFile(dirB + "/bun", "#!/bin/bash\n", 0755);
        mock::writeFile(dirC + "/bun", "#!/bin/bash\n", 0755);
        c = plainConfig();
        c.cliPath = cliTs;
        c.bunSearchDirs = {g_noBunDir, dirA, dirB + "/", dirC};
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(inv.status == BuildStatus::Ok, ".ts with bun builds");
        CHECK(inv.executable == dirB + "/bun", "first executable bun wins; a non-executable one is skipped");
        CHECK(args(inv) == std::vector<std::string>({dirB + "/bun", cliTs, "status", "--json"}),
              ".ts argv: [bun, cli.ts, command, --json]");
        CHECK(envValue(inv, "PATH") == dirB + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
              "PATH: bun dir, standard dirs, inherited extras, no duplicates");

        c.bunPath = dirC + "/bun";
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(inv.executable == dirC + "/bun", "an explicit bun path wins over the search");
        c.bunPath = dirA + "/bun";
        CHECK(intake::buildInvocation(c, req(CliCommand::Status)).status == BuildStatus::NoCli,
              "a .ts CLI with an explicit bun that is not executable: NoCli, no fallback");
        c.bunPath.clear();
        c.bunSearchDirs = {g_noBunDir, dirA};
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(inv.status == BuildStatus::NoCli && inv.message.find("bun") != std::string::npos,
              "no executable bun: NoCli naming bun");
        c.bunSearchDirs = {dirB};
        c.cliPath = cliTs + ".missing.ts";
        CHECK(intake::buildInvocation(c, req(CliCommand::Status)).status == BuildStatus::NoCli,
              "a missing .ts script: NoCli");

        // A non-.ts CLI still gets the bun directory on PATH (bun shebang).
        c = plainConfig();
        c.bunSearchDirs = {dirB};
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(inv.executable == kCli && envValue(inv, "PATH").rfind(dirB + ":", 0) == 0,
              "non-.ts CLI: run directly, bun dir still first on PATH");
        // It does not need bun, so a stale explicit bun is ignored, not fatal.
        for (const std::string &stale : {dirA + "/bun", std::string("/nonexistent/bun"), std::string("bun")}) {
            c.bunPath = stale;
            inv = intake::buildInvocation(c, req(CliCommand::Status));
            CHECK(inv.status == BuildStatus::Ok && inv.executable == kCli &&
                      envValue(inv, "PATH").rfind(dirB + ":", 0) == 0,
                  "non-.ts CLI with an unusable explicit bun: ignored, bun probed instead");
        }

        std::vector<std::string> dirs =
            intake::defaultBunSearchDirs({"HOME=/Users/test/", "PATH=/x"});
        CHECK(dirs == std::vector<std::string>({"/Users/test/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"}),
              "default bun dirs: ~/.bun/bin, /opt/homebrew/bin, /usr/local/bin");
        CHECK(intake::defaultBunSearchDirs({"PATH=/x"}).size() == 2, "no HOME: ~/.bun/bin skipped");
        CHECK(intake::defaultBunSearchDirs({"HOME=relative"}).size() == 2, "relative HOME: skipped");

        // --- environment ---
        g_context = "env";
        c = plainConfig();
        c.baseEnvironment = std::vector<std::string>{
            "HOME=/Users/test", "PATH=/custom/bin:/usr/bin::/sbin", "INTAKE_RULES_DIR=/inherited/rules",
            "MALFORMED", "=nokey", "KEEP=a=b"};
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(envValue(inv, "PATH") == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/custom/bin",
              "PATH: standard dirs first, inherited extras kept, empty entries dropped");
        CHECK_EQ(envCount(inv, "PATH"), 1, "exactly one PATH");
        CHECK(envValue(inv, "INTAKE_RULES_DIR") == "/inherited/rules",
              "not configured: an inherited INTAKE_RULES_DIR is kept");
        CHECK(envValue(inv, "KEEP") == "a=b" && envValue(inv, "HOME") == "/Users/test",
              "other variables pass through");
        CHECK(std::find(inv.environment.begin(), inv.environment.end(), "MALFORMED") == inv.environment.end() &&
                  std::find(inv.environment.begin(), inv.environment.end(), "=nokey") == inv.environment.end(),
              "malformed entries are dropped");
        c.rulesDir = "/Users/test/music-rules";
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(envValue(inv, "INTAKE_RULES_DIR") == "/Users/test/music-rules" &&
                  envCount(inv, "INTAKE_RULES_DIR") == 1,
              "configured: INTAKE_RULES_DIR set, replacing the inherited one");
        c.baseEnvironment = std::vector<std::string>{"HOME=/h"};
        c.rulesDir.clear();
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(envValue(inv, "INTAKE_RULES_DIR") == "<unset>", "not configured and not inherited: unset");
        CHECK(envValue(inv, "PATH") == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
              "no inherited PATH: the standard directories");

        // buildInvocation never reads environ (worker queues); the caller
        // snapshots it on the main thread.
        setenv("INTAKE_B1_TEST_MARKER", "present", 1);
        c.baseEnvironment.reset();
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(inv.status == BuildStatus::NoCli && inv.message.find("environment") != std::string::npos,
              "no environment snapshot: NoCli, environ is not read");
        c.baseEnvironment = intake::processEnvironmentSnapshot();
        inv = intake::buildInvocation(c, req(CliCommand::Status));
        CHECK(inv.status == BuildStatus::Ok && envValue(inv, "INTAKE_B1_TEST_MARKER") == "present",
              "a snapshot of this process's environment is inherited");
        unsetenv("INTAKE_B1_TEST_MARKER");

        // --- a built argv against the mock: "[A & B]" arrives literally ---
        g_context = "mock";
        std::string state = mock::setupState();
        CHECK(!state.empty(), "mock state set up");
        c = plainConfig();
        c.cliPath = mock::mockPath();
        c.baseEnvironment = mock::mockEnv(state);
        assign.collection = "[A & B]";
        inv = intake::buildInvocation(c, assign);
        CHECK(inv.status == BuildStatus::Ok, "assign against the mock builds");
        CHECK_EQ(mock::runSync(inv.arguments, inv.environment), 0, "the mock accepted the call");
        CHECK(mock::lastLine(mock::callsLog(state)) ==
                  "assign\titk_0000000e\t--collection\t[A & B]\t--by\tuser\t--json",
              "calls.log shows --collection [A & B] as one literal argument");

        assign.collection = "Rock 'n' Roll; $(echo x) `id` * ?";
        inv = intake::buildInvocation(c, assign);
        CHECK_EQ(mock::runSync(inv.arguments, inv.environment), 0, "shell metacharacters: accepted");
        CHECK(mock::lastLine(mock::callsLog(state)) ==
                  "assign\titk_0000000e\t--collection\tRock 'n' Roll; $(echo x) `id` * ?\t--by\tuser\t--json",
              "no shell: metacharacters arrive untouched");

        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
