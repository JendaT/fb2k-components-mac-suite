//
//  IntakeVersionGateTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeVersionGate (doc 03 v1.2 "Versioning": data.schema
//  must be the integer 1), plus the gate over the mock CLI's `version`
//  output in every scenario that changes it. Synthetic data only; the mock
//  runs with INTAKE_MOCK_STATE in a fresh temp directory.
//
// TEST_DEPS: src/Core/IntakeCapabilities.mm src/Core/IntakeCommandArgs.mm src/Core/IntakeSemver.mm
// TEST_DEPS: src/Core/IntakeSettingsParse.mm
// TEST_DEPS: src/Core/IntakeEnvelope.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeEnvelope.h"
#include "../src/Core/IntakeVersionGate.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

static id json(const char *text) {
    return parseJsonValue(text);
}

static VersionGateResult gate(const char *text) {
    return checkVersionGate(json(text));
}

static void testSchemaVariants() {
    g_context = "schema-variants";
    VersionGateResult r = gate(R"({"cli":"0.3.0","schema":1,"engine":"0.2.0"})");
    CHECK(r.passed(), "integer 1 passes");
    CHECK(r.verdict == GateVerdict::Pass, "verdict Pass");
    CHECK(r.detail.empty(), "no detail on pass");

    struct Case {
        const char *doc;
        GateVerdict verdict;
        const char *what;
    };
    const Case cases[] = {
        {R"({"schema":"1"})", GateVerdict::SchemaNotInteger, "string \"1\" fails"},
        {R"({"schema":1.0})", GateVerdict::SchemaNotInteger, "1.0 fails"},
        {R"({"schema":1e0})", GateVerdict::SchemaNotInteger, "1e0 fails"},
        {R"({"schema":true})", GateVerdict::SchemaNotInteger, "true fails"},
        {R"({"schema":false})", GateVerdict::SchemaNotInteger, "false fails"},
        {R"({"schema":[1]})", GateVerdict::SchemaNotInteger, "[1] fails"},
        {R"({"schema":{"v":1}})", GateVerdict::SchemaNotInteger, "an object fails"},
        {R"({"schema":100000000000000000001})", GateVerdict::SchemaNotInteger,
         "an integer beyond 64 bits (NSDecimalNumber) fails"},
        {R"({"schema":2})", GateVerdict::SchemaUnsupported, "2 fails"},
        {R"({"schema":0})", GateVerdict::SchemaUnsupported, "0 fails"},
        {R"({"schema":-1})", GateVerdict::SchemaUnsupported, "-1 fails"},
        {R"({"schema":null})", GateVerdict::SchemaMissing, "null fails"},
        {R"({"cli":"0.3.0","engine":"0.2.0"})", GateVerdict::SchemaMissing, "a missing schema fails"},
        {R"([{"schema":1}])", GateVerdict::DataNotObject, "an array data fails"},
        {R"("1")", GateVerdict::DataNotObject, "a string data fails"},
    };
    for (const Case &c : cases) {
        VersionGateResult f = gate(c.doc);
        CHECK(!f.passed() && f.verdict == c.verdict, c.what);
        CHECK(!f.detail.empty(), "a failure carries a detail for the log");
    }
    VersionGateResult nilData = checkVersionGate(nil);
    CHECK(nilData.verdict == GateVerdict::DataNotObject, "nil data (JSON null) fails");
    CHECK(gate(R"({"schema":2})").detail == "schema 2, supported 1", "unsupported detail names both values");
    CHECK(gate(R"({"schema":"1"})").detail == "schema is a string, not an integer", "string detail");
}

static void testEngineIgnored() {
    g_context = "engine-ignored";
    CHECK(gate(R"({"cli":"0.3.0","schema":1,"engine":null})").passed(), "engine null passes");
    CHECK(gate(R"({"cli":"0.3.0","schema":1})").passed(), "engine missing passes");
    CHECK(gate(R"({"cli":"0.3.0","schema":1,"engine":42})").passed(), "engine of another type passes");
    CHECK(gate(R"({"schema":1})").passed(), "schema alone passes (cli is feature detection's business)");
}

static void testInfoSurfaced() {
    g_context = "info";
    VersionGateResult v12 = gate(R"({"cli":"0.3.0","schema":1,"engine":"0.2.0","commands":["status","reject","income"]})");
    CHECK(v12.info.cli == "0.3.0", "cli surfaced");
    CHECK(v12.info.hasCommands, "commands surfaced");
    CHECK_EQ(v12.info.commands.size(), 3, "three commands");
    CHECK(cliSupportsCommand(v12.info, CliCommand::Income), "income detected from commands");
    CHECK(!cliSupportsCommand(v12.info, CliCommand::Gc), "an unlisted command is unsupported");

    VersionGateResult v021 = gate(R"({"cli":"0.2.1","schema":1,"engine":"0.2.0"})");
    CHECK(!v021.info.hasCommands, "no commands array on 0.2.1");
    CHECK(cliSupportsCommand(v021.info, CliCommand::Reject), "reject by semver on 0.2.1");
    CHECK(!cliSupportsCommand(v021.info, CliCommand::Income), "no income on 0.2.1");

    VersionGateResult failed = gate(R"({"cli":"0.9.0","schema":2,"commands":["status"]})");
    CHECK(!failed.passed(), "schema 2 fails");
    CHECK(failed.info.cli == "0.9.0" && failed.info.hasCommands, "info is filled on failure too");
}

static void testIsJsonInteger() {
    g_context = "isJsonInteger";
    long long v = 0;
    CHECK(isJsonInteger(@1, &v) && v == 1, "@1");
    CHECK(isJsonInteger(@(-7LL), &v) && v == -7, "@-7");
    CHECK(!isJsonInteger(@1.0, nullptr), "@1.0 is a double");
    CHECK(!isJsonInteger(@YES, nullptr), "@YES is a boolean");
    CHECK(!isJsonInteger(@"1", nullptr), "a string");
    CHECK(!isJsonInteger(nil, nullptr), "nil");
    CHECK(!isJsonInteger([NSNull null], nullptr), "NSNull");
}

// The gate over the mock's real `version --json` output.
static VersionGateResult mockGate(const std::string &scenario, bool &ran) {
    ran = false;
    std::string state = mock::setupState(scenario);
    if (state.empty()) return VersionGateResult();
    std::string out;
    int exitCode = mock::runCapture({mock::mockPath(), "version", "--json"}, mock::mockEnv(state), out);
    EnvelopeResult env = parseEnvelope(out, exitCode);
    if (env.outcome != CliOutcome::Ok) return VersionGateResult();
    ran = true;
    return checkVersionGate(env.data);
}

static void testMockScenarios() {
    g_context = "mock";
    bool ran = false;
    VersionGateResult d = mockGate("default", ran);
    CHECK(ran, "default: version ran");
    CHECK(d.passed(), "default passes");
    CHECK(d.info.cli == "0.3.0", "default reports CLI 0.3.0");
    CHECK(d.info.hasCommands, "default lists commands");
    CHECK(cliSupportsCommand(d.info, CliCommand::Income), "default: income listed");
    CHECK(cliSupportsCommand(d.info, CliCommand::Reject), "default: reject listed");

    VersionGateResult old = mockGate("cli-0.2.1", ran);
    CHECK(ran && old.passed(), "cli-0.2.1 passes");
    CHECK(old.info.cli == "0.2.1" && !old.info.hasCommands, "cli-0.2.1: no commands array");
    CHECK(!cliSupportsCommand(old.info, CliCommand::Income), "cli-0.2.1: no income");
    CHECK(cliSupportsCommand(old.info, CliCommand::Resume), "cli-0.2.1: per-root resume by semver");

    VersionGateResult v01 = mockGate("cli-0.1", ran);
    CHECK(ran && v01.passed(), "cli-0.1 passes the gate");
    CHECK(!cliSupportsCommand(v01.info, CliCommand::Reject), "cli-0.1: no reject");

    VersionGateResult s2 = mockGate("schema2", ran);
    CHECK(ran && s2.verdict == GateVerdict::SchemaUnsupported, "schema2 fails as unsupported");
    VersionGateResult ss = mockGate("schema-string", ran);
    CHECK(ran && ss.verdict == GateVerdict::SchemaNotInteger, "schema-string fails as not an integer");
}

int main(void) {
    atexit(mock::removeTempRoot);
    @autoreleasepool {
        testSchemaVariants();
        testEngineIgnored();
        testInfoSurfaced();
        testIsJsonInteger();
        testMockScenarios();
    }
    mock::removeTempRoot();
    TEST_MAIN_END();
}
