//
//  IntakeMockExecuteModesTests.mm
//  foo_jl_intake_mac
//
//  Tests for the mock CLI's B14 execute modes (Tests/mock-cli/README.md):
//   - per-root: a real execute walks its roots one by one (placing, a pause,
//     then placed, or approved for a root that fails), as the real CLI does,
//     in the summary rows and the sidecars, with the library copy; a resume
//     writes no placing; a dry run answers at once; replies are made up for
//     generated roots (perf-200);
//   - slow-dry-run: an execute dry run answers only after its pause, while
//     a real execute walks as per-root does;
//   - bad mode arguments exit 64.
//  Short pauses (0.2-0.6 s) keep the run fast; every directory is a fresh
//  temp state (MockCliSupport), nothing real is touched.
//

#import <Foundation/Foundation.h>

#include "MockCliSupport.h"
#include "TestHarness.h"

#include <atomic>
#include <string>
#include <thread>
#include <vector>

namespace {

std::string statusOf(const std::string &state, const std::string &id) {
    const std::string row = mock::readFile(state + "/responses/status.d/" + id + ".json");
    const std::string key = "\"status\":\"";
    const size_t at = row.find(key);
    if (at == std::string::npos) return std::string();
    const size_t end = row.find('"', at + key.size());
    return end == std::string::npos ? std::string() : row.substr(at + key.size(), end - at - key.size());
}

bool contains(const std::string &text, const std::string &part) {
    return text.find(part) != std::string::npos;
}

// Runs the mock with `args` on a thread; `done` flips when it exits.
struct Background {
    std::thread thread;
    std::atomic<bool> done{false};
    int rc = -1;
    std::string out;

    void start(const std::vector<std::string> &args, const std::vector<std::string> &env) {
        thread = std::thread([this, args, env] {
            std::vector<std::string> argv = {mock::mockPath()};
            argv.insert(argv.end(), args.begin(), args.end());
            rc = mock::runCapture(argv, env, out);
            done = true;
        });
    }
    void join() {
        if (thread.joinable()) thread.join();
    }
};

const char *const kPerf4 = "itk_c0000004";
const char *const kPerf12 = "itk_c000000c";
const char *const kPerf20 = "itk_c0000014";

} // namespace

static void testPerRootWalk() {
    g_context = "per-root-walk";
    const std::string state = mock::setupState("perf-200");
    CHECK(!state.empty(), "perf-200 set up");
    CHECK(statusOf(state, kPerf4) == "approved" && statusOf(state, kPerf12) == "approved" &&
              statusOf(state, kPerf20) == "approved",
          "three approved generated roots (no reply files)");
    mock::setMode(state, "execute", std::string("per-root 0.4 ") + kPerf12);

    Background run;
    run.start({"execute", kPerf4, kPerf12, kPerf20, "--json"}, mock::mockEnv(state));
    // The distinct status triples seen while it runs.
    std::vector<std::string> seen;
    while (!run.done) {
        const std::string t = statusOf(state, kPerf4) + "," + statusOf(state, kPerf12) + "," + statusOf(state, kPerf20);
        if (seen.empty() || seen.back() != t) seen.push_back(t);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    run.join();
    auto indexOf = [&seen](const std::string &t) {
        for (size_t i = 0; i < seen.size(); i++) {
            if (seen[i] == t) return static_cast<long>(i);
        }
        return -1L;
    };
    const long a = indexOf("placing,approved,approved");
    const long b = indexOf("placed,placing,approved");
    const long c = indexOf("placed,approved,placing");
    CHECK(a >= 0 && b > a && c > b, "one root placing at a time, in the order named");
    CHECK(!seen.empty() && seen.back() == "placed,approved,placed", "ends placed, reverted, placed");
    for (const std::string &t : seen) {
        const size_t first = t.find("placing");
        if (first != std::string::npos && t.find("placing", first + 1) != std::string::npos) {
            CHECK(false, "never two roots placing at once");
        }
    }
    CHECK_EQ(run.rc, 1, "exit 1: rows and an error");
    CHECK(contains(run.out, "\"ok\":false") && contains(run.out, "\"E_VERIFY\""), "the failed root's E_VERIFY");
    CHECK(contains(run.out, "\"id\":\"itk_c0000004\"") && contains(run.out, "\"id\":\"itk_c0000014\"") &&
              !contains(run.out, "\"id\":\"itk_c000000c\""),
          "rows for the placed roots only");
    const std::string sidecar4 = mock::readFile(state + "/root/income/perf/Fixture Artist 4 - Test Album 4/.intake.json");
    CHECK(contains(sidecar4, "\"status\":\"placed\"") && contains(sidecar4, "\"verified\":true"),
          "the sidecar says placed, with placed.verified");
    const std::string sidecar12 =
        mock::readFile(state + "/root/income/perf/Fixture Artist 12 - Test Album 12/.intake.json");
    CHECK(contains(sidecar12, "\"status\":\"approved\"") && !contains(sidecar12, "\"placed\":{"),
          "the failed root's sidecar is approved again");
    CHECK(mock::fileExists(state +
                           "/root/library/music.hq/Test Collection A/Fixture Artist 4/Fixture Artist 4 - 2026 - "
                           "Test Album 4/01 - Test Track.wav"),
          "the library copy of a placed root");
    CHECK(!mock::fileExists(state + "/root/library/music.hq/Test Collection A/Fixture Artist 12"),
          "none for the failed root");
    const std::string row4 = mock::readFile(state + "/responses/status.d/itk_c0000004.json");
    CHECK(contains(row4, "\"placed\":{\"verified\":true"), "the summary row has placed too");
}

static void testPerRootDryRunAndResume() {
    g_context = "per-root-dry-resume";
    const std::string state = mock::setupState("perf-200");
    CHECK(!state.empty(), "perf-200 set up");
    mock::setMode(state, "execute", "per-root 2");
    std::string out;
    const auto start = mock::Clock::now();
    int rc = mock::runCapture({mock::mockPath(), "execute", kPerf4, kPerf20, "--dry-run", "--json"},
                              mock::mockEnv(state), out);
    CHECK(mock::secondsSince(start) < 1.5, "the dry run answers at once");
    CHECK_EQ(rc, 0, "exit 0");
    CHECK(contains(out, "\"dry_run\":true") && contains(out, "\"id\":\"itk_c0000014\""),
          "made-up dry-run rows for generated roots");
    CHECK(statusOf(state, kPerf4) == "approved", "a dry run changes nothing");

    // Resume: no placing; placed, or approved for a listed root.
    const std::string def = mock::setupState("default");
    CHECK(!def.empty(), "default set up");
    mock::setMode(def, "execute", "per-root 0.2");
    rc = mock::runCapture({mock::mockPath(), "execute", "itk_00000011", "--resume", "--json"}, mock::mockEnv(def), out);
    CHECK(rc == 0 && contains(out, "\"resumed\":\"completed\""), "resume answers from the scenario's reply");
    CHECK(statusOf(def, "itk_00000011") == "placed", "and the root ends placed");
    CHECK(contains(mock::readFile(def + "/root/income/dump/Fixture Artist - Placing Album/.intake.json"),
                   "\"status\":\"placed\""),
          "its sidecar too");

    const std::string rev = mock::setupState("default");
    mock::setMode(rev, "execute", "per-root 0.2 itk_00000011");
    rc = mock::runCapture({mock::mockPath(), "execute", "itk_00000011", "--resume", "--json"}, mock::mockEnv(rev), out);
    CHECK(rc == 0 && contains(out, "\"resumed\":\"reverted_to_approved\""), "a listed root is reverted");
    CHECK(statusOf(rev, "itk_00000011") == "approved", "and ends approved");

    // The scenario's own execute reply (itk_00000010) walks too.
    const std::string own = mock::setupState("default");
    mock::setMode(own, "execute", "per-root 0.2");
    rc = mock::runCapture({mock::mockPath(), "execute", "itk_00000010", "--json"}, mock::mockEnv(own), out);
    CHECK(rc == 0 && contains(out, "\"journal_seq\":42"), "the fixture's reply");
    CHECK(statusOf(own, "itk_00000010") == "placed", "placed");
    CHECK(mock::fileExists(own +
                           "/root/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Approved "
                           "Album/01 - Test Track One.wav"),
          "with its library copy");
}

static void testSlowDryRun() {
    g_context = "slow-dry-run";
    const std::string state = mock::setupState("perf-200");
    CHECK(!state.empty(), "perf-200 set up");
    mock::setMode(state, "execute", "slow-dry-run 0.6");
    std::vector<std::string> env = mock::mockEnv(state);
    env.push_back("INTAKE_MOCK_ROOT_SECONDS=0.1");
    std::string out;
    auto start = mock::Clock::now();
    int rc = mock::runCapture({mock::mockPath(), "execute", kPerf4, "--dry-run", "--json"}, env, out);
    CHECK(mock::secondsSince(start) >= 0.6, "the dry run takes its pause");
    CHECK(rc == 0 && contains(out, "\"dry_run\":true"), "then answers normally");
    CHECK(statusOf(state, kPerf4) == "approved", "and changes nothing");
    start = mock::Clock::now();
    rc = mock::runCapture({mock::mockPath(), "execute", kPerf4, "--json"}, env, out);
    CHECK(mock::secondsSince(start) < 0.6, "a real execute does not take the dry run's pause");
    CHECK(rc == 0 && statusOf(state, kPerf4) == "placed", "it walks its root as per-root does");
}

static void testBadArguments() {
    g_context = "bad-arguments";
    const std::string state = mock::setupState("default");
    CHECK(!state.empty(), "default set up");
    mock::setMode(state, "execute", "per-root soon");
    CHECK_EQ(mock::runSync({mock::mockPath(), "execute", "itk_00000010", "--json"}, mock::mockEnv(state)), 64,
             "per-root with a word that is no seconds or id: exit 64");
    mock::setMode(state, "execute", "per-root 1.2.3");
    CHECK_EQ(mock::runSync({mock::mockPath(), "execute", "itk_00000010", "--json"}, mock::mockEnv(state)), 64,
             "bad seconds: exit 64");
    mock::setMode(state, "execute", "slow-dry-run x");
    CHECK_EQ(mock::runSync({mock::mockPath(), "execute", "itk_00000010", "--dry-run", "--json"}, mock::mockEnv(state)),
             64, "slow-dry-run with bad seconds: exit 64");
    CHECK(statusOf(state, "itk_00000010") == "approved", "nothing was written");
}

int main(void) {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        testPerRootWalk();
        testPerRootDryRunAndResume();
        testSlowDryRun();
        testBadArguments();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
