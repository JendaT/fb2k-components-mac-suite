//
//  IntakeEnvelopeTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeEnvelope: envelope rules 1 to 7 (PLAN.md 3.4,
//  doc 03 contract v1.1) on synthetic stdout, and the runner verdicts
//  (timeout, cancel, spawn failure, signal, truncation) on synthetic
//  ProcessResults. No process is started here.
//
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeEnvelope.h"
#include "TestHarness.h"

#include <csignal>
#include <cerrno>

using intake::CliOutcome;
using intake::EnvelopeResult;
using intake::ProcessEnd;
using intake::ProcessResult;

namespace {

bool isNoCli(const EnvelopeResult &r) {
    return r.outcome == CliOutcome::NoCli && r.errors.size() == 1 && r.errors[0].code == "E_NO_CLI" &&
           !r.detail.empty() && r.data == nil;
}

ProcessResult exited(int code, std::string out) {
    ProcessResult p;
    p.end = ProcessEnd::Exited;
    p.exitCode = code;
    p.stdoutData = std::move(out);
    p.stdoutEOF = true;
    p.pid = 4242;
    return p;
}

const char *kOkStatus = R"({"ok":true,"data":[{"id":"itk_0000000a","status":"new"},)"
                        R"({"id":"itk_0000000b","status":"resolved"}],"errors":[]})";

} // anonymous namespace

int main(void) {
    @autoreleasepool {
        // --- rule 2: Ok ---
        g_context = "ok";
        EnvelopeResult r = intake::parseEnvelope(kOkStatus, 0);
        CHECK(r.outcome == CliOutcome::Ok, "exit 0 + ok true: Ok");
        CHECK(r.errors.empty(), "Ok has no errors");
        CHECK([r.data isKindOfClass:[NSArray class]] && [r.data count] == 2, "data kept");
        std::vector<std::string> ids = intake::idsInData(r.data);
        CHECK(ids.size() == 2 && ids[0] == "itk_0000000a" && ids[1] == "itk_0000000b",
              "rule 7: ids in data, in order");

        r = intake::parseEnvelope(R"({"ok":true,"data":{"cli":"0.2.1","schema":1,"engine":null},"errors":[]})", 0);
        CHECK(r.outcome == CliOutcome::Ok && [r.data isKindOfClass:[NSDictionary class]],
              "object data (version) is fine");
        CHECK(intake::idsInData(r.data).empty(), "object data has no ids");

        r = intake::parseEnvelope(R"({"ok":true,"data":[],"errors":[]})", 0);
        CHECK(r.outcome == CliOutcome::Ok && intake::idsInData(r.data).empty(),
              "rule 7: empty data with exit 0 means nothing was done");
        r = intake::parseEnvelope(R"({"ok":true,"data":null,"errors":[]})", 0);
        CHECK(r.outcome == CliOutcome::Ok && r.data == nil, "null data reads as nil");

        r = intake::parseEnvelope("\n\n  " + std::string(kOkStatus) + "  \r\n\t", 0);
        CHECK(r.outcome == CliOutcome::Ok, "rule 1: surrounding whitespace is trimmed (noise mode)");
        r = intake::parseEnvelope(
            R"({"ok":true,"data":[],"errors":[],"warnings":["x"],"meta":{"schema":1}})", 0);
        CHECK(r.outcome == CliOutcome::Ok, "unknown top-level fields are ignored");

        // --- rule 3: Partial ---
        g_context = "partial";
        r = intake::parseEnvelope(
            R"({"ok":false,"data":[{"id":"itk_0000000b"}],"errors":[{"code":"E_NO_TARGET","msg":"cannot propose","path":"/r/x"}]})",
            1);
        CHECK(r.outcome == CliOutcome::Partial, "exit 1 + ok false + errors: Partial");
        CHECK(intake::idsInData(r.data) == std::vector<std::string>({"itk_0000000b"}), "the successful subset");
        CHECK(r.errors.size() == 1 && r.errors[0].code == "E_NO_TARGET" && r.errors[0].msg == "cannot propose" &&
                  r.errors[0].hasPath && r.errors[0].path == "/r/x",
              "rule 6: code, msg and path kept");
        r = intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[{"code":"E_PARSE","msg":"m","path":null}]})", 1);
        CHECK(r.outcome == CliOutcome::Partial && r.data == nil, "partial with null data is tolerated");
        CHECK(!r.errors[0].hasPath, "a null path is no path");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":[],"errors":[]})", 1)),
              "exit 1 without errors: E_NO_CLI");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"data":[],"errors":[]})", 1)),
              "exit 1 with ok true: E_NO_CLI");

        // --- rule 4: Failed ---
        g_context = "failed";
        r = intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[{"code":"E_NO_RULES","msg":"no rules","path":null}]})", 2);
        CHECK(r.outcome == CliOutcome::Failed && r.data == nil, "exit 2 + data null: Failed");
        CHECK(r.errors.size() == 1 && r.errors[0].code == "E_NO_RULES", "the CLI error is kept");
        r = intake::parseEnvelope(R"({"ok":false,"data":[],"errors":[{"code":"E_BAD_ARGS","msg":"m","path":null}]})", 2);
        CHECK(r.outcome == CliOutcome::Failed && r.data == nil, "exit 2 + data [] (older CLI) is tolerated");
        r = intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[{"code":"E_INTERNAL","msg":"boom","path":null}]})", 2);
        CHECK(r.outcome == CliOutcome::Failed && r.errors[0].code == "E_INTERNAL",
              "E_INTERNAL (uncaught throw, CLI 0.2.1) is an ordinary Failed result, not E_NO_CLI");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":{"x":1},"errors":[{"code":"E_X","msg":"","path":null}]})", 2)),
              "exit 2 with object data: E_NO_CLI");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":[1],"errors":[{"code":"E_X","msg":"","path":null}]})", 2)),
              "exit 2 with non-empty array data: E_NO_CLI");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[]})", 2)),
              "exit 2 without errors: E_NO_CLI");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"data":null,"errors":[]})", 2)),
              "exit 2 with ok true: E_NO_CLI");

        // --- rule 5: everything else is E_NO_CLI ---
        g_context = "no-cli";
        CHECK(isNoCli(intake::parseEnvelope("", 0)), "empty stdout");
        CHECK(isNoCli(intake::parseEnvelope(" \n\t ", 0)), "whitespace-only stdout");
        CHECK(isNoCli(intake::parseEnvelope("intake-mock: this is not JSON {\"ok\":\n", 0)), "garbage");
        CHECK(isNoCli(intake::parseEnvelope(R"([{"id":"itk_0000000a"}])", 0)), "bare array");
        CHECK(isNoCli(intake::parseEnvelope(R"("ok")", 0)), "bare string");
        CHECK(isNoCli(intake::parseEnvelope("42", 0)), "bare number");
        CHECK(isNoCli(intake::parseEnvelope(std::string(kOkStatus) + "\n" + kOkStatus, 0)),
              "two envelopes: not exactly one value");
        CHECK(isNoCli(intake::parseEnvelope(std::string(kOkStatus) + " trailing", 0)), "trailing text");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":1,"data":[],"errors":[]})", 0)), "ok is a number");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":"true","data":[],"errors":[]})", 0)), "ok is a string");
        CHECK(isNoCli(intake::parseEnvelope(R"({"data":[],"errors":[]})", 0)), "ok missing");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"errors":[]})", 0)), "data missing");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"data":[]})", 0)), "errors missing");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"data":[],"errors":{}})", 0)), "errors not an array");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":[],"errors":[]})", 0)), "exit 0 with ok false");
        CHECK(isNoCli(intake::parseEnvelope(
                  R"({"ok":true,"data":[],"errors":[{"code":"E_X","msg":"","path":null}]})", 0)),
              "exit 0 with errors");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":null,"errors":["E_X"]})", 2)),
              "an error entry that is not an object");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[{"msg":"m"}]})", 2)),
              "an error entry without a code");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[{"code":""}]})", 2)),
              "an error entry with an empty code");
        CHECK(isNoCli(intake::parseEnvelope(std::string("{\"ok\":true,\"data\":[\"\xff\xfe\"],\"errors\":[]}"), 0)),
              "invalid UTF-8");
        for (int code : {3, 64, 126, 127, 255, -1}) {
            CHECK(isNoCli(intake::parseEnvelope(kOkStatus, code)), "any other exit code, even with a valid envelope");
        }
        r = intake::parseEnvelope(R"({"ok":false,"data":null,"errors":[{"code":"E_X","msg":5,"path":7}]})", 2);
        CHECK(r.outcome == CliOutcome::Failed && r.errors[0].msg.empty() && !r.errors[0].hasPath,
              "rule 6: a non-string msg reads as empty, a non-string path as none");

        // --- unpaired surrogate escapes (rule 1) ---
        g_context = "lone-surrogates";
        // What bun 1.4.2's JSON.stringify writes for an execute issue cut by
        // .slice(0, 120) inside a surrogate pair: the high half alone.
        const std::string issue = "metaflac_failed: " + std::string(119 - 17, 'x') + "\\ud835";
        r = intake::parseEnvelope(
            R"({"ok":true,"data":[{"id":"itk_00000010","root_path":"/r/x","issues":[")" + issue +
                R"("]}],"errors":[]})",
            0);
        CHECK(r.outcome == CliOutcome::Ok, "a placed release with a lone high surrogate in an issue is Ok, not E_NO_CLI");
        ids = intake::idsInData(r.data);
        CHECK(ids.size() == 1 && ids[0] == "itk_00000010", "its id is in data");
        NSString *issueText = r.outcome == CliOutcome::Ok ? r.data[0][@"issues"][0] : nil;
        CHECK(issueText.length == 120 && [issueText hasSuffix:@"x\uFFFD"], "the lone half reads as U+FFFD");

        auto stringField = [](const EnvelopeResult &e, NSString *key) -> NSString * {
            if (e.outcome != CliOutcome::Ok || ![e.data isKindOfClass:[NSArray class]]) return nil;
            return e.data[0][key];
        };
        r = intake::parseEnvelope(R"({"ok":true,"data":[{"id":"itk_0000000a","m":"\udc00y"}],"errors":[]})", 0);
        CHECK([stringField(r, @"m") isEqualToString:@"\uFFFDy"], "a lone low surrogate reads as U+FFFD");
        r = intake::parseEnvelope(R"({"ok":true,"data":[{"id":"itk_0000000a","m":"\uD835\u0041"}],"errors":[]})", 0);
        CHECK([stringField(r, @"m") isEqualToString:@"\uFFFDA"],
              "a high surrogate followed by a non-surrogate escape (uppercase hex) reads as U+FFFD");
        r = intake::parseEnvelope(
            R"({"ok":true,"data":[{"id":"itk_0000000a","p":"\ud835\udd82","a":"\\ud835","b":"\ud835"}],"errors":[]})", 0);
        CHECK([stringField(r, @"p") isEqualToString:@"\U0001D582"], "a proper pair is kept");
        CHECK([stringField(r, @"a") isEqualToString:@"\\ud835"], "an escaped backslash before 'ud835' is no escape");
        CHECK([stringField(r, @"b") isEqualToString:@"\uFFFD"], "while a real lone surrogate beside it is replaced");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"data":["\ud835)", 0)),
              "a truncated document with a lone surrogate is still E_NO_CLI");
        CHECK(isNoCli(intake::parseEnvelope(R"({"ok":true,"data":[],"errors":[]} \ud835)", 0)),
              "a surrogate escape outside a string is not repaired");

        // --- runner verdicts ---
        g_context = "process";
        CHECK(intake::interpretProcessResult(exited(0, kOkStatus)).outcome == CliOutcome::Ok,
              "an exited process is parsed");

        ProcessResult spawn;
        spawn.end = ProcessEnd::SpawnFailed;
        spawn.spawnErrno = ENOENT;
        spawn.spawnStage = "spawn";
        r = intake::interpretProcessResult(spawn);
        CHECK(isNoCli(r) && r.detail.find("No such file") != std::string::npos,
              "spawn errno: E_NO_CLI with the reason");

        ProcessResult signaled = exited(0, kOkStatus);
        signaled.end = ProcessEnd::Signaled;
        signaled.termSignal = SIGSEGV;
        CHECK(isNoCli(intake::interpretProcessResult(signaled)), "death by a foreign signal: E_NO_CLI");

        ProcessResult lost = exited(0, kOkStatus);
        lost.end = ProcessEnd::WaitFailed;
        CHECK(isNoCli(intake::interpretProcessResult(lost)), "lost exit status: E_NO_CLI");

        ProcessResult killed = exited(0, "");
        killed.end = ProcessEnd::Signaled;
        killed.termSignal = SIGTERM;
        killed.budgetExceeded = killed.killedForTimeout = true;
        r = intake::interpretProcessResult(killed);
        CHECK(r.outcome == CliOutcome::Timeout && r.errors.size() == 1 && r.errors[0].code == "E_CLI_TIMEOUT",
              "killed for the budget: E_CLI_TIMEOUT");

        ProcessResult capped = killed;
        capped.hardCapHit = true;
        r = intake::interpretProcessResult(capped);
        CHECK(r.outcome == CliOutcome::Timeout && r.detail.find("hard cap") != std::string::npos,
              "killed at the hard cap: E_CLI_TIMEOUT naming the cap");

        ProcessResult abandoned = killed;
        abandoned.end = ProcessEnd::Abandoned;
        CHECK(intake::interpretProcessResult(abandoned).outcome == CliOutcome::Timeout,
              "abandoned after SIGKILL: E_CLI_TIMEOUT");

        ProcessResult late = exited(0, kOkStatus);
        late.budgetExceeded = true; // a mutating call that ran past its budget, then exited
        CHECK(intake::interpretProcessResult(late).outcome == CliOutcome::Ok,
              "past the budget but exited on its own: the real result counts");

        ProcessResult cancelled = killed;
        cancelled.killedForTimeout = false;
        cancelled.cancelled = true;
        r = intake::interpretProcessResult(cancelled);
        CHECK(r.outcome == CliOutcome::Cancelled && r.errors.empty(), "cancelled: its own outcome, no error");

        ProcessResult truncated = exited(0, std::string(kOkStatus).substr(0, 20));
        truncated.stdoutTruncated = true;
        CHECK(isNoCli(intake::interpretProcessResult(truncated)), "truncated stdout: E_NO_CLI");

        ProcessResult unreadable = exited(0, "");
        unreadable.outputError = "cannot open /x.out: No such file or directory";
        r = intake::interpretProcessResult(unreadable);
        CHECK(isNoCli(r) && r.detail == unreadable.outputError, "unreadable output file: E_NO_CLI");

        ProcessResult exit127 = exited(127, "");
        CHECK(isNoCli(intake::interpretProcessResult(exit127)), "exit 127: E_NO_CLI");

        // --- host results and names ---
        g_context = "host";
        r = intake::hostNoCli("why");
        CHECK(isNoCli(r) && r.errors[0].msg == "why" && !r.errors[0].hasPath, "hostNoCli carries the detail as msg");
        r = intake::hostTimeout("slow");
        CHECK(r.outcome == CliOutcome::Timeout && r.errors[0].code == intake::kErrorCliTimeout, "hostTimeout");
        CHECK(std::string(intake::cliOutcomeName(CliOutcome::Partial)) == "partial", "outcome names for logs");

        // --- rule 7 on odd data ---
        g_context = "ids";
        r = intake::parseEnvelope(R"({"ok":true,"data":[{"id":"itk_0000000a"},{"id":5},"x",{"noid":1},{"id":"itk_0000000c"}],"errors":[]})", 0);
        CHECK(intake::idsInData(r.data) == std::vector<std::string>({"itk_0000000a", "itk_0000000c"}),
              "rows without a string id contribute nothing");
        CHECK(intake::idsInData(nil).empty(), "nil data: no ids");
    }
    TEST_MAIN_END();
}
