//
//  IntakeMockScanTests.mm
//  foo_jl_intake_mac
//
//  Tests for the mock CLI's scan and gc staging (B12, Tests/mock-cli/README.md
//  "Scan (B12)"):
//   - a scan replies one ScanBlock per income ({income, path, dry_run,
//     archives, written, kept}); with nothing queued it writes nothing and
//     keeps every folder that has a sidecar;
//   - scan.next applies a scan state: `written` lists the roots it added
//     (autoscan's scan-arrivals: two resolved, one of them needing review,
//     and one new), only sidecars are written, and the mock's propose
//     answers for the roots the component proposes (the resolved ones);
//   - the CLI's errors: no income, an unknown or a missing income, --all
//     next to a missing one, an income named by its path, a dry run, a CLI
//     without scan;
//   - a scan state that would create a folder is refused (exit 64) with
//     nothing of it applied;
//   - slow keeps a scan running, then it answers with its state applied;
//   - a gc state takes the tracks through .intake-gc-<id>/ (each rename in
//     gc.trace) and leaves no stage folder, only the tombstone sidecar.
//  Every directory is a fresh temp state (MockCliSupport), nothing real is
//  touched.
//

#import <Foundation/Foundation.h>

#include "MockCliSupport.h"
#include "TestHarness.h"

#include <string>
#include <vector>

namespace {

const char *const kArrivalResolved = "UAT Artist - 16 Arrival Resolved";
const char *const kArrivalReview = "UAT Artist - 17 Arrival Review";
const char *const kArrivalNew = "UAT Artist - 18 Arrival New";

int runMock(const std::string &state, const std::vector<std::string> &args, std::string &out) {
    std::vector<std::string> argv = {mock::mockPath()};
    argv.insert(argv.end(), args.begin(), args.end());
    return mock::runCapture(argv, mock::mockEnv(state), out);
}

NSDictionary *parse(const std::string &out) {
    NSData *data = [NSData dataWithBytes:out.data() length:out.size()];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

std::string str(id value) {
    return [value isKindOfClass:[NSString class]] ? std::string([(NSString *)value UTF8String]) : std::string();
}

NSArray *arrayOf(id value) {
    return [value isKindOfClass:[NSArray class]] ? (NSArray *)value : nil;
}

NSDictionary *dictAt(NSArray *array, NSUInteger i) {
    if (i >= array.count) return nil;
    id obj = array[i];
    return [obj isKindOfClass:[NSDictionary class]] ? (NSDictionary *)obj : nil;
}

std::string firstErrorCode(NSDictionary *envelope) {
    return str(dictAt(arrayOf(envelope[@"errors"]), 0)[@"code"]);
}

std::string statusOf(const std::string &state, const std::string &id) {
    const std::string row = mock::readFile(state + "/responses/status.d/" + id + ".json");
    const std::string key = "\"status\":\"";
    const size_t at = row.find(key);
    if (at == std::string::npos) return std::string();
    const size_t end = row.find('"', at + key.size());
    return end == std::string::npos ? std::string() : row.substr(at + key.size(), end - at - key.size());
}

size_t countWavs(const std::string &dir) {
    size_t n = 0;
    @autoreleasepool {
        NSDirectoryEnumerator *it = [[NSFileManager defaultManager] enumeratorAtPath:@(dir.c_str())];
        for (NSString *rel in it) {
            if ([rel.pathExtension isEqualToString:@"wav"]) n++;
        }
    }
    return n;
}

} // namespace

static void testScanNothingQueued() {
    g_context = "scan-nothing-queued";
    const std::string state = mock::setupState("autoscan");
    CHECK(!state.empty(), "autoscan set up");
    std::string out;
    CHECK_EQ(runMock(state, {"income", "--json"}, out), 0, "income: exit 0");
    const std::string incomePath = str(dictAt(arrayOf(parse(out)[@"data"]), 0)[@"path"]);
    CHECK(incomePath == state + "/root/income/uat", "one income, uat");

    CHECK_EQ(runMock(state, {"scan", "uat", "--json"}, out), 0, "scan uat: exit 0");
    NSDictionary *env = parse(out);
    CHECK([env[@"ok"] isEqual:@YES] && arrayOf(env[@"errors"]).count == 0, "ok, no errors");
    NSArray *blocks = arrayOf(env[@"data"]);
    CHECK_EQ(blocks.count, 1, "one block");
    NSDictionary *block = dictAt(blocks, 0);
    CHECK(str(block[@"income"]) == "uat" && str(block[@"path"]) == incomePath,
          "the block names the income and its path as income --json gives them");
    CHECK([block[@"dry_run"] isEqual:@NO] && [block[@"archives"] isEqual:@[]], "no dry run, no archives");
    CHECK(arrayOf(block[@"written"]) && arrayOf(block[@"written"]).count == 0, "nothing queued: nothing written");
    CHECK_EQ(arrayOf(block[@"kept"]).count, 15, "the 15 folders with a sidecar are kept");
    CHECK(!mock::fileExists(incomePath + "/" + kArrivalResolved + "/.intake.json"), "no sidecar written");
    CHECK(mock::lastLine(mock::callsLog(state)) == "scan\tuat\t--json", "calls.log: scan uat --json");
}

static void testScanArrivals() {
    g_context = "scan-arrivals";
    const std::string state = mock::setupState("autoscan");
    CHECK(!state.empty(), "autoscan set up");
    const std::string income = state + "/root/income/uat";
    const size_t wavsBefore = countWavs(state + "/root");
    CHECK(mock::writeFile(state + "/scan.next", "scan-arrivals\n"), "scan.next written");

    std::string out;
    CHECK_EQ(runMock(state, {"scan", "uat", "--json"}, out), 0, "scan uat: exit 0");
    NSDictionary *block = dictAt(arrayOf(parse(out)[@"data"]), 0);
    NSArray *written = arrayOf(block[@"written"]);
    CHECK_EQ(written.count, 3, "three roots written");
    NSDictionary *resolved = dictAt(written, 0), *review = dictAt(written, 1), *fresh = dictAt(written, 2);
    CHECK(str(resolved[@"id"]) == "itk_000a0010" && str(resolved[@"status"]) == "resolved" &&
              [resolved[@"needs_review"] isEqual:@NO],
          "itk_000a0010: resolved");
    CHECK(str(review[@"id"]) == "itk_000a0011" && str(review[@"status"]) == "resolved" &&
              [review[@"needs_review"] isEqual:@YES],
          "itk_000a0011: resolved, needs review");
    CHECK(str(fresh[@"id"]) == "itk_000a0012" && str(fresh[@"status"]) == "new", "itk_000a0012: new");
    CHECK(str(resolved[@"root_path"]) == income + "/" + kArrivalResolved &&
              str(resolved[@"sidecar_path"]) == income + "/" + kArrivalResolved + "/.intake.json",
          "root_path and sidecar_path");
    CHECK([resolved[@"confidence"] isKindOfClass:[NSNumber class]] &&
              fabs([resolved[@"confidence"] doubleValue] - 0.92) < 1e-9 && str(resolved[@"tier_eligible"]) == "hq" &&
              [resolved[@"virtual"] isEqual:@NO] && [resolved[@"singles"] isEqual:@NO] &&
              str(resolved[@"albumartist"]) == "UAT Artist" && str(resolved[@"album"]) == "16 Arrival Resolved",
          "the WrittenRoot fields from the summary and the sidecar");
    CHECK_EQ(arrayOf(block[@"kept"]).count, 15, "the 15 older folders kept");
    CHECK(!mock::fileExists(state + "/scan.next"), "scan.next used up");
    CHECK(mock::fileExists(income + "/" + kArrivalResolved + "/.intake.json") &&
              mock::fileExists(income + "/" + kArrivalReview + "/.intake.json") &&
              mock::fileExists(income + "/" + kArrivalNew + "/.intake.json"),
          "the three sidecars are written");
    CHECK_EQ(countWavs(state + "/root"), wavsBefore, "no track written");
    CHECK(statusOf(state, "itk_000a0010") == "resolved" && statusOf(state, "itk_000a0012") == "new",
          "status lists them");

    // What the component does next: propose the resolved roots, the one
    // that needs review too (never the new one).
    CHECK(mock::writeFile(state + "/propose.next", "arrivals-proposed\n"), "propose.next written");
    CHECK_EQ(runMock(state, {"propose", "itk_000a0010", "itk_000a0011", "--json"}, out), 0, "propose: exit 0");
    NSArray *rows = arrayOf(parse(out)[@"data"]);
    CHECK(rows.count == 2 && str(dictAt(rows, 0)[@"id"]) == "itk_000a0010" &&
              str(dictAt(rows, 0)[@"status"]) == "proposed" && str(dictAt(rows, 1)[@"id"]) == "itk_000a0011" &&
              str(dictAt(rows, 1)[@"status"]) == "proposed",
          "a proposed row for each");
    CHECK(statusOf(state, "itk_000a0010") == "proposed" && statusOf(state, "itk_000a0011") == "proposed" &&
              statusOf(state, "itk_000a0012") == "new",
          "arrivals-proposed applied; the new root untouched");
    CHECK_EQ(runMock(state, {"propose", "itk_000a0012", "--json"}, out), 2, "propose on the new root: exit 2");
    CHECK(firstErrorCode(parse(out)) == "E_BAD_STATUS", "E_BAD_STATUS");

    CHECK_EQ(runMock(state, {"scan", "uat", "--json"}, out), 0, "scan again: exit 0");
    block = dictAt(arrayOf(parse(out)[@"data"]), 0);
    CHECK(arrayOf(block[@"written"]).count == 0 && arrayOf(block[@"kept"]).count == 18,
          "nothing written, 18 folders kept");
}

static void testScanErrors() {
    g_context = "scan-errors";
    const std::string state = mock::setupState("default");
    CHECK(!state.empty(), "default set up");
    std::string out;
    CHECK_EQ(runMock(state, {"scan", "--json"}, out), 2, "no income: exit 2");
    NSDictionary *env = parse(out);
    CHECK(env[@"data"] == [NSNull null] && firstErrorCode(env) == "E_BAD_ARGS", "E_BAD_ARGS, data null");

    CHECK_EQ(runMock(state, {"scan", "nowhere", "--json"}, out), 2, "unknown income: exit 2");
    env = parse(out);
    CHECK(firstErrorCode(env) == "E_NOT_FOUND" &&
              str(dictAt(arrayOf(env[@"errors"]), 0)[@"msg"]) == "unknown income folder: nowhere",
          "E_NOT_FOUND unknown income folder");

    CHECK_EQ(runMock(state, {"scan", "offline", "--json"}, out), 2, "configured, missing on disk: exit 2");
    env = parse(out);
    CHECK(env[@"data"] == [NSNull null] && firstErrorCode(env) == "E_NOT_FOUND" &&
              str(dictAt(arrayOf(env[@"errors"]), 0)[@"path"]) == state + "/root/income/offline",
          "E_NOT_FOUND with the income's path, data null");

    CHECK_EQ(runMock(state, {"scan", "--all", "--json"}, out), 1, "--all with one missing: exit 1");
    env = parse(out);
    NSArray *blocks = arrayOf(env[@"data"]);
    CHECK(blocks.count == 2 && str(dictAt(blocks, 0)[@"income"]) == "dump" &&
              str(dictAt(blocks, 1)[@"income"]) == "shop" && arrayOf(env[@"errors"]).count == 1,
          "a block for dump and shop, one error for offline");

    CHECK_EQ(runMock(state, {"scan", state + "/root/income/./shop/", "--json"}, out), 0, "by path: exit 0");
    blocks = arrayOf(parse(out)[@"data"]);
    CHECK(blocks.count == 1 && str(dictAt(blocks, 0)[@"income"]) == "shop", "the path selects shop");

    CHECK_EQ(runMock(state, {"scan", "dump", "--dry-run", "--json"}, out), 0, "dry run: exit 0");
    NSDictionary *block = dictAt(arrayOf(parse(out)[@"data"]), 0);
    CHECK([block[@"dry_run"] isEqual:@YES] && arrayOf(block[@"written"]).count == 0, "dry_run true, nothing written");

    const std::string old = mock::setupState("cli-0.1");
    CHECK(!old.empty(), "cli-0.1 set up");
    CHECK_EQ(runMock(old, {"scan", "dump", "--json"}, out), 2, "CLI 0.1.0 has no scan: exit 2");
    CHECK(firstErrorCode(parse(out)) == "E_BAD_ARGS", "unknown command");
}

static void testScanStateGuard() {
    g_context = "scan-state-guard";
    const std::string state = mock::setupState("autoscan");
    CHECK(!state.empty(), "autoscan set up");
    const std::string income = state + "/root/income/uat";
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:@((income + "/" + kArrivalNew).c_str()) error:nil];
    }
    CHECK(!mock::fileExists(income + "/" + kArrivalNew), "one arrival folder removed");
    CHECK(mock::writeFile(state + "/scan.next", "scan-arrivals\n"), "scan.next written");
    CHECK_EQ(mock::runSync({mock::mockPath(), "scan", "uat", "--json"}, mock::mockEnv(state)), 64,
             "a scan state that would create a folder: exit 64");
    CHECK(!mock::fileExists(income + "/" + kArrivalNew), "the folder is not created");
    CHECK(!mock::fileExists(income + "/" + kArrivalResolved + "/.intake.json") &&
              !mock::fileExists(state + "/responses/status.d/itk_000a0010.json"),
          "nothing of the state is applied");
}

static void testScanSlow() {
    g_context = "scan-slow";
    const std::string state = mock::setupState("autoscan");
    CHECK(!state.empty(), "autoscan set up");
    mock::setMode(state, "scan", "slow 0.6");
    CHECK(mock::writeFile(state + "/scan.next", "scan-arrivals\n"), "scan.next written");
    std::string out;
    const auto start = mock::Clock::now();
    CHECK_EQ(runMock(state, {"scan", "uat", "--json"}, out), 0, "slow scan: exit 0");
    CHECK(mock::secondsSince(start) >= 0.6, "it takes its pause");
    CHECK_EQ(arrayOf(dictAt(arrayOf(parse(out)[@"data"]), 0)[@"written"]).count, 3,
             "then answers with its state applied");
}

static void testGcStages() {
    g_context = "gc-stages";
    const std::string state = mock::setupState("autoscan");
    CHECK(!state.empty(), "autoscan set up");
    const std::string dir = state + "/root/income/uat/UAT Artist - 09 Placed";
    CHECK(mock::fileExists(dir + "/01 - Test Track One.wav"), "the placed root's tracks are there");
    CHECK(mock::writeFile(state + "/gc.next", "uat-09-gc_done\n"), "gc.next written");
    std::string out;
    CHECK_EQ(runMock(state, {"gc", "itk_000a0009", "--json"}, out), 0, "gc: exit 0");
    const std::vector<std::string> left = mock::listDir(dir);
    CHECK(left.size() == 1 && left[0] == ".intake.json", "only the tombstone sidecar is left, no stage folder");
    // The renames at the old paths are what the component's gc mute covers.
    const std::string stage = dir + "/.intake-gc-itk_000a0009";
    CHECK(mock::readFile(state + "/gc.trace") ==
              "mv\t" + dir + "/01 - Test Track One.wav\t" + stage + "/01 - Test Track One.wav\n" + "mv\t" + dir +
                  "/02 - Test Track Two.wav\t" + stage + "/02 - Test Track Two.wav\n",
          "each track was renamed into .intake-gc-itk_000a0009/ before the stage folder went");
    CHECK(statusOf(state, "itk_000a0009") == "gc_done", "gc_done");
    CHECK(mock::fileExists(state + "/root/library/music.hq/Test Collection A/UAT Artist/UAT Artist - 2026 - 09 "
                                   "Placed/01 - Test Track One.wav"),
          "the library copy stays");

    // The shadow album: every file the sidecar lists goes, the shadow too.
    const std::string shadow = state + "/root/income/uat/UAT Artist - 12 Placed Shadow";
    CHECK(mock::writeFile(state + "/gc.next", "uat-12-gc_done\n"), "gc.next written again");
    CHECK_EQ(runMock(state, {"gc", "itk_000a000c", "--json"}, out), 0, "gc of the shadow album: exit 0");
    const std::vector<std::string> shadowLeft = mock::listDir(shadow);
    CHECK(shadowLeft.size() == 1 && shadowLeft[0] == ".intake.json", "its three tracks gone, no stage folder");
    const std::string trace = mock::readFile(state + "/gc.trace");
    const std::string shadowStage = shadow + "/.intake-gc-itk_000a000c";
    CHECK(trace.find("mv\t" + shadow + "/02 - Test Track Two (shadow).wav\t" + shadowStage +
                     "/02 - Test Track Two (shadow).wav\n") != std::string::npos,
          "the shadow file was staged too");
}

int main(void) {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        testScanNothingQueued();
        testScanArrivals();
        testScanErrors();
        testScanStateGuard();
        testScanSlow();
        testGcStages();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
