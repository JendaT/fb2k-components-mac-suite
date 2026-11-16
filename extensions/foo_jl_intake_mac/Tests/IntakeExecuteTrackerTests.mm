//
//  IntakeExecuteTrackerTests.mm
//  foo_jl_intake_mac
//
//  IntakeExecuteTracker (PLAN.md B8): run file names, the run file format
//  and its atomic write, liveness by pid and start time, the leftover scan
//  (adopt, finish, sweep, foreign files untouched), detached output parsing
//  without an exit code, the resume "reverted_to_approved" rule, the tracker
//  states, ProcessExitWatch, and an adopted run of the mock end to end (a
//  real orphan process, so waitpid gets ECHILD as in production).
//
//  Hermetic: temp directories only (MockCliSupport.h), the mock with a
//  fresh state directory, every wait bounded, leftovers swept.
//
// TEST_DEPS: src/Core/IntakeEnvelope.mm src/Core/IntakeProcess.mm src/Core/IntakeMutationResult.mm
// TEST_DEPS: src/Core/IntakeErrorMap.mm src/Core/IntakePath.mm src/Core/IntakeCommandArgs.mm
// TEST_DEPS: src/Core/IntakeSemver.mm src/Core/IntakeSettingsParse.mm src/Core/IntakeLog.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeExecuteTracker.h"
#include "MockCliSupport.h"
#include "TestHarness.h"

#include <atomic>
#include <memory>
#include <string>
#include <vector>

using namespace intake;

namespace {

dispatch_queue_t g_queue;

std::vector<std::string> v(std::initializer_list<std::string> items) {
    return std::vector<std::string>(items);
}

// A pid that existed a moment ago and has been reaped.
pid_t deadPid() {
    pid_t pid = 0;
    char arg0[] = "/usr/bin/true";
    char *argv[] = {arg0, nullptr};
    char *envp[] = {nullptr};
    if (posix_spawn(&pid, arg0, nullptr, nullptr, argv, envp) != 0) return 0;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    return pid;
}

// /bin/sleep <seconds> as a child of this process.
pid_t spawnSleep(const char *seconds) {
    pid_t pid = 0;
    char arg0[] = "/bin/sleep";
    std::string s = seconds;
    char *argv[] = {arg0, &s[0], nullptr};
    char *envp[] = {nullptr};
    if (posix_spawn(&pid, arg0, nullptr, nullptr, argv, envp) != 0) return 0;
    return pid;
}

RunFile sampleRun(pid_t pid, ProcessStartTime start, const std::string &stem) {
    RunFile f;
    f.command = CliCommand::Execute;
    f.pid = pid;
    f.start = start;
    f.ids = {"itk_00000010", "itk_0000000b"};
    f.rootPaths = {"/income/dump/Fixture Artist - Approved Album", "/income/dump/Fixture Artist - Resolved Album"};
    f.output = runOutputName(stem);
    return f;
}

bool parseFails(const std::string &text, const std::string &errorPart) {
    RunFile f;
    std::string error;
    const bool ok = parseRunFile(text, f, error);
    if (ok || error.find(errorPart) == std::string::npos) {
        printf("  parse of %s: ok=%d error=%s\n", text.c_str(), ok, error.c_str());
        return false;
    }
    return true;
}

const char *kGoodRun =
    R"({"format":1,"command":"execute","pid":4242,"start_sec":1794791491,"start_usec":628172,)"
    R"("ids":["itk_00000010"],"output":"execute-x.json"})";

std::string withField(const std::string &json, const std::string &key, const std::string &value) {
    // Replaces "key":<old> in kGoodRun-shaped JSON (no nesting in the value).
    const std::string needle = "\"" + key + "\":";
    size_t at = json.find(needle);
    if (at == std::string::npos) return json;
    size_t start = at + needle.size();
    size_t end = start;
    int depth = 0;
    bool inString = false;
    for (; end < json.size(); end++) {
        char c = json[end];
        if (inString) {
            if (c == '"') inString = false;
            continue;
        }
        if (c == '"') inString = true;
        else if (c == '[' || c == '{') depth++;
        else if (c == ']' || c == '}') {
            if (depth == 0) break;
            depth--;
        } else if (c == ',' && depth == 0) break;
    }
    return json.substr(0, start) + value + json.substr(end);
}

const char *kNoFormat =
    R"({"command":"execute","pid":4242,"start_sec":1794791491,"start_usec":628172,"ids":["itk_00000010"],"output":"execute-x.json"})";
const char *kNoStartSec =
    R"({"format":1,"command":"execute","pid":4242,"start_usec":628172,"ids":["itk_00000010"],"output":"execute-x.json"})";
const char *kNoOutput =
    R"({"format":1,"command":"execute","pid":4242,"start_sec":1794791491,"start_usec":628172,"ids":["itk_00000010"]})";

bool contains(const std::vector<std::string> &list, const std::string &item) {
    return std::find(list.begin(), list.end(), item) != list.end();
}

} // namespace

// --- names ---

static void testNames() {
    g_context = "names";
    std::string stem;
    RunFileKind kind;
    CHECK(parseRunFileName("execute-20261116-101500-123.run", stem, kind) && kind == RunFileKind::Run &&
              stem == "execute-20261116-101500-123",
          "a run file");
    CHECK(parseRunFileName("execute-20261116-101500-123.json", stem, kind) && kind == RunFileKind::Output,
          "an output file");
    CHECK(parseRunFileName("execute-a-2.tmp", stem, kind) && kind == RunFileKind::Temp && stem == "execute-a-2",
          "a temp file");
    CHECK(!parseRunFileName("execute-.run", stem, kind), "an empty token is not ours");
    CHECK(!parseRunFileName("execute-a_b.run", stem, kind), "only [A-Za-z0-9-] in the token");
    CHECK(!parseRunFileName("execute-x.run.bak", stem, kind), "another extension is not ours");
    CHECK(!parseRunFileName("intake-123-1-1.out", stem, kind), "the runner's files are not ours");
    CHECK(!parseRunFileName("execute-" + std::string(65, 'a') + ".run", stem, kind), "a token over 64 is not ours");
    CHECK(parseRunFileName("execute-" + std::string(64, 'a') + ".run", stem, kind), "64 is the limit");
    CHECK(runFileName("execute-x") == "execute-x.run" && runOutputName("execute-x") == "execute-x.json" &&
              runTempName("execute-x") == "execute-x.tmp",
          "the three names of a stem");

    const std::string fresh = newRunStem(std::chrono::system_clock::now());
    CHECK(isRunStem(fresh) && fresh.size() == std::string("execute-YYYYMMDD-HHMMSS-mmm").size(),
          "newRunStem: execute-YYYYMMDD-HHMMSS-mmm");

    std::string dir = mock::newDir("stems");
    auto now = std::chrono::system_clock::now();
    const std::string first = uniqueRunStem(dir, now);
    CHECK(first == newRunStem(now), "a free stem is used as it is");
    mock::writeFile(dir + "/" + runOutputName(first), "");
    const std::string second = uniqueRunStem(dir, now);
    CHECK(second == first + "-2" && isRunStem(second), "a taken stem gets -2");
    mock::writeFile(dir + "/" + runTempName(second), "");
    CHECK(uniqueRunStem(dir, now) == first + "-3", "a temp file takes its stem too");
}

// --- the run file ---

static void testRunFileRoundTrip() {
    g_context = "run-file";
    ProcessStartTime start{1794791491, 628172};
    RunFile f = sampleRun(4242, start, "execute-20261116-101500-123");
    const std::string text = formatRunFile(f);
    CHECK(!text.empty() && text.back() == '\n', "one JSON object and a newline");
    RunFile back;
    std::string error;
    CHECK(parseRunFile(text, back, error), "it parses back");
    CHECK(back.command == CliCommand::Execute && back.pid == 4242 && back.start == start, "command, pid, start");
    CHECK(back.ids == f.ids && back.rootPaths == f.rootPaths, "ids and root paths, aligned");
    CHECK(back.output == "execute-20261116-101500-123.json", "the output name");

    f.command = CliCommand::Resume;
    f.rootPaths.clear();
    CHECK(parseRunFile(formatRunFile(f), back, error) && back.command == CliCommand::Resume && back.rootPaths.empty(),
          "resume, without root paths");
    f.rootPaths = {"/odd \"quoted\" path/\\ and \xC3\xA9"};
    f.ids = {"itk_00000011"};
    CHECK(parseRunFile(formatRunFile(f), back, error) && back.rootPaths == f.rootPaths,
          "a root path with quotes, a backslash and UTF-8 survives");
}

static void testRunFileMalformed() {
    g_context = "run-file-malformed";
    RunFile f;
    std::string error;
    CHECK(parseRunFile(kGoodRun, f, error) && f.pid == 4242 && f.ids == v({"itk_00000010"}), "the base case parses");
    CHECK(parseFails("", "not a JSON object"), "empty");
    CHECK(parseFails("{\"format\":1", "not a JSON object"), "truncated");
    CHECK(parseFails("[1,2]", "not a JSON object"), "an array");
    CHECK(parseFails(withField(kGoodRun, "format", "2"), "format"), "format 2");
    CHECK(parseFails(kNoFormat, "format"), "no format");
    CHECK(parseFails(withField(kGoodRun, "command", "\"gc\""), "command"), "another command");
    CHECK(parseFails(withField(kGoodRun, "pid", "1"), "pid"), "pid 1 (launchd)");
    CHECK(parseFails(withField(kGoodRun, "pid", "0"), "pid"), "pid 0");
    CHECK(parseFails(withField(kGoodRun, "pid", "-5"), "pid"), "a negative pid");
    CHECK(parseFails(withField(kGoodRun, "pid", "\"4242\""), "pid"), "a pid as a string");
    CHECK(parseFails(withField(kGoodRun, "pid", "4242.5"), "pid"), "a fractional pid");
    CHECK(parseFails(withField(kGoodRun, "pid", "true"), "pid"), "a boolean pid");
    CHECK(parseFails(withField(kGoodRun, "pid", "99999999999"), "pid"), "a pid past int32");
    CHECK(parseFails(withField(kGoodRun, "start_sec", "0"), "start_sec"), "start_sec 0 (unknown)");
    CHECK(parseFails(kNoStartSec, "start_sec"), "no start_sec");
    CHECK(parseFails(withField(kGoodRun, "start_usec", "1000000"), "start_usec"), "start_usec past a second");
    CHECK(parseFails(withField(kGoodRun, "ids", "[]"), "ids"), "no ids");
    CHECK(parseFails(withField(kGoodRun, "ids", "\"itk_00000010\""), "ids"), "ids not an array");
    CHECK(parseFails(withField(kGoodRun, "ids", "[\"itk_00000010\",\"/income/dump\"]"), "sidecar id"),
          "a path among the ids");
    CHECK(parseFails(withField(kGoodRun, "output", "\"../x.json\""), "output"), "an output outside the folder");
    CHECK(parseFails(withField(kGoodRun, "output", "\"execute-x.run\""), "output"), "an output that is a run file");
    CHECK(parseFails(withField(kGoodRun, "output", "\"notes.json\""), "output"), "an output not of our form");
    CHECK(parseFails(kNoOutput, "output"), "no output");

    CHECK(parseRunFile(withField(kGoodRun, "ids", "[\"itk_00000010\",\"itk_00000010\",\"itk_0000000b\"]"), f, error) &&
              f.ids == v({"itk_00000010", "itk_0000000b"}),
          "repeated ids are kept once");
    std::string mismatched = std::string(kGoodRun);
    mismatched.insert(mismatched.size() - 1, R"(,"root_paths":["/a","/b"])");
    CHECK(parseRunFile(mismatched, f, error) && f.rootPaths.empty(),
          "root_paths of another length are ignored (optional)");
    std::string extra = std::string(kGoodRun);
    extra.insert(extra.size() - 1, R"(,"future":{"x":1})");
    CHECK(parseRunFile(extra, f, error), "unknown keys are ignored");
}

static void testRunFileWrite() {
    g_context = "run-file-write";
    std::string dir = mock::newDir("write");
    const std::string stem = "execute-20261116-101500-123";
    RunFile f = sampleRun(4242, ProcessStartTime{1794791491, 5}, stem);
    std::string error;
    mock::writeFile(dir + "/" + runTempName(stem), "stale");
    CHECK(writeRunFile(dir, stem, f, error), "written");
    CHECK(!mock::fileExists(dir + "/" + runTempName(stem)), "through the temp file, which is gone (a stale one replaced)");
    RunFile back;
    CHECK(parseRunFile(mock::readFile(dir + "/" + runFileName(stem)), back, error) && back.pid == 4242 &&
              back.start.micros == 5,
          "the run file on disk parses");
    CHECK(!writeRunFile(dir, "notes", f, error) && !error.empty(), "only run stems");
    struct stat st;
    CHECK(writeRunFile(dir + "/missing/deeper", stem, f, error) &&
              mock::fileExists(dir + "/missing/deeper/" + runFileName(stem)) &&
              stat((dir + "/missing/deeper").c_str(), &st) == 0 && (st.st_mode & 0777) == 0700,
          "a missing directory is created (0700), as the runner does for the output");
    mock::writeFile(dir + "/plain", "a file");
    CHECK(!writeRunFile(dir + "/plain/sub", stem, f, error) && !error.empty(), "a directory that cannot exist fails");
    f.provisional = true;
    CHECK(writeRunFile(dir, stem, f, error), "a provisional run file replaces nothing it should not");
    RunFile again = sampleRun(4343, ProcessStartTime{1794791491, 6}, stem);
    CHECK(writeRunFile(dir, stem, again, error) &&
              parseRunFile(mock::readFile(dir + "/" + runFileName(stem)), back, error) && !back.provisional &&
              back.pid == 4343,
          "the full run file replaces the provisional one");
}

// A child of ours whose stdout is `path`, in its own process group (as the
// runner spawns the CLI): /bin/sleep <seconds>.
pid_t spawnSleepWritingTo(const std::string &path, const char *seconds) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, path.c_str(), O_WRONLY | O_APPEND, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attr, 0);
    pid_t pid = 0;
    char arg0[] = "/bin/sleep";
    std::string s = seconds;
    char *argv[] = {arg0, &s[0], nullptr};
    char *envp[] = {nullptr};
    const int rc = posix_spawn(&pid, arg0, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    return rc == 0 ? pid : 0;
}

// A run file written before the spawn (no pid): its liveness is a process
// that still has the output open.
static void testProvisional() {
    g_context = "provisional";
    RunFile p;
    p.command = CliCommand::Execute;
    p.provisional = true;
    p.ids = {"itk_00000010"};
    p.rootPaths = {"/income/dump/Fixture Artist - Approved Album"};
    p.output = runOutputName("execute-p");
    const std::string text = formatRunFile(p);
    CHECK(text.find("\"pid\"") == std::string::npos && text.find("start_sec") == std::string::npos &&
              text.find("start_usec") == std::string::npos,
          "no pid and no start time on disk");
    RunFile back;
    std::string error;
    CHECK(parseRunFile(text, back, error) && back.provisional && back.pid == 0 && back.ids == p.ids &&
              back.rootPaths == p.rootPaths,
          "it parses back as provisional, with ids and root paths");
    CHECK(parseRunFile(kGoodRun, back, error) && !back.provisional, "a full run file is not provisional");
    CHECK(parseFails(R"({"format":1,"command":"execute","start_sec":1794791491,"start_usec":1,"ids":["itk_00000010"],"output":"execute-x.json"})",
                     "pid"),
          "a start time without a pid is malformed");
    CHECK(parseFails(R"({"format":1,"command":"execute","pid":4242,"ids":["itk_00000010"],"output":"execute-x.json"})",
                     "start_sec"),
          "a pid without a start time is malformed");
    CHECK(parseFails(R"({"format":1,"command":"execute","pid":null,"start_sec":null,"start_usec":null,"ids":["itk_00000010"],"output":"execute-x.json"})",
                     "pid"),
          "null is not absent");

    // The scan, with a stand-in for the writer lookup.
    std::string dir = mock::newDir("provisional");
    auto put = [&dir](const std::string &name, const std::string &content) { mock::writeFile(dir + "/" + name, content); };
    auto provisionalFor = [&p](const std::string &stem) {
        RunFile f = p;
        f.output = runOutputName(stem);
        return formatRunFile(f);
    };
    put("execute-gone.run", provisionalFor("execute-gone"));  // the CLI never started: no output
    put("execute-held.run", provisionalFor("execute-held"));
    put("execute-held.json", "");
    put("execute-ended.run", provisionalFor("execute-ended"));
    put("execute-ended.json", "{\"ok\":true,\"data\":[{\"id\":\"itk_00000010\"}],\"errors\":[]}\n");
    auto livenessAsked = std::make_shared<int>(0);
    LivenessCheck live = [livenessAsked](pid_t, const ProcessStartTime &) {
        (*livenessAsked)++;
        return true;
    };
    OutputWriterLookup writer = [](const std::string &path, pid_t &pid, ProcessStartTime &start) {
        if (path.size() < 18 || path.compare(path.size() - 18, 18, "/execute-held.json") != 0) return false;
        pid = 4242;
        start = ProcessStartTime{7, 8};
        return true;
    };
    LeftoverScan scan = scanLeftoverRuns(dir, live, writer);
    CHECK(*livenessAsked == 0, "a provisional run has no pid to check");
    CHECK(scan.adopt.size() == 1 && scan.adopt[0].stem == "execute-held" && scan.adopt[0].byOutput &&
              scan.adopt[0].file.pid == 4242 && scan.adopt[0].file.start == (ProcessStartTime{7, 8}) &&
              scan.adopt[0].file.ids == v({"itk_00000010"}),
          "one with a live writer is adopted with the writer's pid and start time");
    CHECK(scan.finish.size() == 1 && scan.finish[0].stem == "execute-ended" &&
              scan.finish[0].output.find("itk_00000010") != std::string::npos,
          "one with an output nobody writes is finished from its output");
    CHECK(scan.swept == v({"execute-gone.run"}) && !mock::fileExists(dir + "/execute-gone.run"),
          "one without an output never started: swept");
    CHECK(mock::fileExists(dir + "/execute-held.run") && mock::fileExists(dir + "/execute-held.json") &&
              mock::fileExists(dir + "/execute-ended.run"),
          "the others' files stay");

    // The real lookup: a child with the output as its stdout.
    std::string real = mock::newDir("provisional-real");
    const std::string out = real + "/execute-real.json";
    mock::writeFile(out, "");
    mock::writeFile(real + "/" + runFileName("execute-real"), provisionalFor("execute-real"));
    pid_t found = 0;
    ProcessStartTime foundStart;
    int mine = ::open(out.c_str(), O_RDONLY);
    CHECK(mine >= 0 && !findOutputWriter(out, found, foundStart), "this process is never its own run's writer");
    pid_t child = spawnSleepWritingTo(out, "10");
    ProcessStartTime childStart;
    CHECK(child > 0 && readProcessStartTime(child, childStart), "a child writing the output");
    if (child > 0) mock::trackGroup(child, child);
    CHECK(findOutputWriter(out, found, foundStart) && found == child && foundStart == childStart,
          "findOutputWriter: the child, with its start time");
    LeftoverScan held = scanLeftoverRuns(real, processIsLive);
    CHECK(held.adopt.size() == 1 && held.adopt[0].file.pid == child && held.adopt[0].file.start == childStart &&
              held.finish.empty() && held.swept.empty(),
          "the default lookup adopts it (a live run whose pid was never written)");
    if (child > 0) {
        ::kill(child, SIGKILL);
        int status = 0;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        }
    }
    CHECK(!findOutputWriter(out, found, foundStart), "no writer once it has exited (a reader is not this process)");
    LeftoverScan ended = scanLeftoverRuns(real, processIsLive);
    CHECK(ended.adopt.empty() && ended.finish.size() == 1 &&
              parseDetachedOutput(ended.finish[0].output, ended.finish[0].outputError).outcome == CliOutcome::NoCli,
          "then it is finished: an empty output is E_NO_CLI");
    CHECK(!findOutputWriter(real + "/missing.json", found, foundStart), "no writer for a missing file");
    if (mine >= 0) ::close(mine);
}

// --- liveness ---

static void testLiveness() {
    g_context = "liveness";
    ProcessStartTime me;
    CHECK(readProcessStartTime(getpid(), me) && me.seconds > 0, "this process's start time");
    CHECK(processIsLive(getpid(), me), "live: the pid exists and the start time matches");
    pid_t dead = deadPid();
    CHECK(dead > 0 && !processIsLive(dead, me), "dead: the pid is gone");
    ProcessStartTime later = me;
    later.seconds += 1;
    CHECK(!processIsLive(getpid(), later), "reused pid: another start time (seconds)");
    ProcessStartTime otherMicros = me;
    otherMicros.micros = (me.micros + 1) % 1000000;
    CHECK(!processIsLive(getpid(), otherMicros), "reused pid: another start time (microseconds)");
    ProcessStartTime ignored;
    CHECK(!readProcessStartTime(0, ignored) && !readProcessStartTime(-1, ignored), "no start time for 0 or -1");
    CHECK(!processIsLive(1, me), "launchd (another user's, or another start time) is never one of our runs");
}

// --- leftovers ---

static void testScan() {
    g_context = "scan";
    std::string dir = mock::newDir("scan");
    const pid_t livePid = 4242, deadPidValue = 4343;
    LivenessCheck live = [](pid_t pid, const ProcessStartTime &) { return pid == 4242; };
    ProcessStartTime start{1794791491, 1};

    auto put = [&dir](const std::string &name, const std::string &content) { mock::writeFile(dir + "/" + name, content); };
    // A live run with its output (still being written).
    put("execute-live.run", formatRunFile(sampleRun(livePid, start, "execute-live")));
    put("execute-live.json", "");
    // A dead run with a result.
    put("execute-dead.run", formatRunFile(sampleRun(deadPidValue, start, "execute-dead")));
    put("execute-dead.json", "{\"ok\":true,\"data\":[{\"id\":\"itk_00000010\"}],\"errors\":[]}\n");
    // A dead run that left no output.
    put("execute-nooutput.run", formatRunFile(sampleRun(deadPidValue, start, "execute-nooutput")));
    // A run file that does not parse, with its output.
    put("execute-garbage.run", "not json");
    put("execute-garbage.json", "{}");
    // A run file naming another output.
    RunFile other = sampleRun(deadPidValue, start, "execute-other");
    other.output = "execute-elsewhere.json";
    put("execute-other.run", formatRunFile(other));
    // Orphans.
    put("execute-orphan.json", "{}");
    put("execute-orphan2.tmp", "{}");
    // A stale temp file next to a good (live) run.
    put("execute-live.tmp", "half");
    // Foreign files and things that are not regular files.
    put("intake-4343-1-1.out", "runner's");
    put("notes.txt", "mine");
    put("execute-x.log", "not ours");
    mkdir((dir + "/execute-dir.json").c_str(), 0700);
    symlink((dir + "/notes.txt").c_str(), (dir + "/execute-link.run").c_str());

    LeftoverScan scan = scanLeftoverRuns(dir, live);
    CHECK(scan.error.empty(), "no error");
    CHECK(scan.adopt.size() == 1 && scan.adopt[0].stem == "execute-live" && scan.adopt[0].file.pid == livePid,
          "the live run is adopted");
    CHECK(scan.adopt.size() == 1 && scan.adopt[0].file.ids == v({"itk_00000010", "itk_0000000b"}) &&
              scan.adopt[0].file.rootPaths.size() == 2,
          "with its ids and root paths");
    CHECK(scan.finish.size() == 2, "two dead runs to finish");
    const LeftoverRun *dead = nullptr, *noOutput = nullptr;
    for (const LeftoverRun &r : scan.finish) {
        if (r.stem == "execute-dead") dead = &r;
        if (r.stem == "execute-nooutput") noOutput = &r;
    }
    CHECK(dead != nullptr && dead->output.find("itk_00000010") != std::string::npos && dead->outputError.empty(),
          "a dead run's output is read");
    CHECK(noOutput != nullptr && noOutput->output.empty() && noOutput->outputError == "no output file",
          "a dead run without output says so");
    CHECK(mock::fileExists(dir + "/execute-dead.run") && mock::fileExists(dir + "/execute-dead.json"),
          "a dead run's files stay until its result is applied");
    CHECK(mock::fileExists(dir + "/execute-live.run") && mock::fileExists(dir + "/execute-live.json"),
          "a live run's files stay");

    CHECK(contains(scan.swept, "execute-garbage.run") && contains(scan.swept, "execute-garbage.json"),
          "an unparseable run file and its output are swept");
    CHECK(contains(scan.swept, "execute-other.run"), "a run file naming another output is swept");
    CHECK(contains(scan.swept, "execute-orphan.json") && contains(scan.swept, "execute-orphan2.tmp"),
          "orphan output and temp files are swept");
    CHECK(contains(scan.swept, "execute-live.tmp"), "a stale temp file next to a run file is swept");
    CHECK_EQ(scan.swept.size(), 6, "six files swept");
    CHECK_EQ(scan.notes.size(), scan.swept.size(), "one note per swept file");
    bool notesName = true;
    for (size_t i = 0; i < scan.swept.size(); i++) notesName = notesName && scan.notes[i].rfind(scan.swept[i], 0) == 0;
    CHECK(notesName, "each note starts with the file's name");
    for (const std::string &name : scan.swept) {
        CHECK(!mock::fileExists(dir + "/" + name), ("swept file is gone: " + name).c_str());
    }
    CHECK(mock::readFile(dir + "/intake-4343-1-1.out") == "runner's" && mock::readFile(dir + "/notes.txt") == "mine" &&
              mock::fileExists(dir + "/execute-x.log"),
          "foreign files are untouched");
    struct stat st;
    CHECK(lstat((dir + "/execute-dir.json").c_str(), &st) == 0 && S_ISDIR(st.st_mode), "a directory is untouched");
    CHECK(lstat((dir + "/execute-link.run").c_str(), &st) == 0 && S_ISLNK(st.st_mode), "a symlink is untouched");

    // A second scan finds the same runs and nothing more to sweep.
    LeftoverScan again = scanLeftoverRuns(dir, live);
    CHECK(again.adopt.size() == 1 && again.finish.size() == 2 && again.swept.empty(), "a second scan sweeps nothing");

    CHECK_EQ(deleteRunFiles(dir, "execute-dead"), 2, "deleteRunFiles: the run file and its output");
    CHECK(!mock::fileExists(dir + "/execute-dead.run") && !mock::fileExists(dir + "/execute-dead.json"),
          "both are gone");
    CHECK_EQ(deleteRunFiles(dir, "notes"), 0, "only run stems");
    CHECK(mock::fileExists(dir + "/notes.txt"), "nothing else deleted");

    LeftoverScan missing = scanLeftoverRuns(dir + "/does-not-exist", live);
    CHECK(missing.error.empty() && missing.adopt.empty() && missing.finish.empty(), "a missing folder is empty, not an error");
}

// --- results ---

static void testDetachedOutput() {
    g_context = "detached-output";
    EnvelopeResult ok = parseDetachedOutput("{\"ok\":true,\"data\":[{\"id\":\"itk_00000010\"}],\"errors\":[]}\n");
    CHECK(ok.outcome == CliOutcome::Ok && idsInData(ok.data) == v({"itk_00000010"}), "ok true: exit 0, Ok");
    EnvelopeResult failed = parseDetachedOutput(
        "{\"ok\":false,\"data\":null,\"errors\":[{\"code\":\"E_VERIFY\",\"msg\":\"verify failed\",\"path\":\"/x\"}]}");
    CHECK(failed.outcome == CliOutcome::Failed && failed.errors.size() == 1 && failed.errors[0].code == "E_VERIFY",
          "ok false, data null: exit 2, Failed");
    EnvelopeResult emptyFailed = parseDetachedOutput(
        "{\"ok\":false,\"data\":[],\"errors\":[{\"code\":\"E_VERIFY\",\"msg\":\"verify failed\",\"path\":\"/x\"}]}");
    CHECK(emptyFailed.outcome == CliOutcome::Failed,
          "ok false, data []: exit 2, Failed (as parseEnvelope accepts for our own child)");
    CHECK(parseEnvelope("{\"ok\":false,\"data\":[],\"errors\":[{\"code\":\"E_VERIFY\",\"msg\":\"m\",\"path\":\"/x\"}]}", 2)
                  .outcome == emptyFailed.outcome,
          "the same outcome as our own child's exit 2");
    EnvelopeResult partial = parseDetachedOutput(
        "{\"ok\":false,\"data\":[{\"id\":\"itk_00000010\"}],\"errors\":[{\"code\":\"E_VERIFY\",\"msg\":\"m\",\"path\":null}]}");
    CHECK(partial.outcome == CliOutcome::Partial && idsInData(partial.data) == v({"itk_00000010"}),
          "ok false with data: exit 1, Partial");
    CHECK(parseDetachedOutput("").outcome == CliOutcome::NoCli, "empty: E_NO_CLI");
    CHECK(parseDetachedOutput("  \n").outcome == CliOutcome::NoCli, "blank: E_NO_CLI");
    CHECK(parseDetachedOutput("{\"ok\":true,\"data\":[").outcome == CliOutcome::NoCli, "truncated: E_NO_CLI");
    CHECK(parseDetachedOutput("[]").outcome == CliOutcome::NoCli, "a bare array: E_NO_CLI");
    CHECK(parseDetachedOutput("{\"ok\":true,\"data\":[],\"errors\":[{\"code\":\"E_X\",\"msg\":\"\",\"path\":null}]}")
                  .outcome == CliOutcome::NoCli,
          "ok true with errors: E_NO_CLI (the usual mismatch rule)");
    EnvelopeResult unreadable = parseDetachedOutput("{}", "no output file");
    CHECK(unreadable.outcome == CliOutcome::NoCli && !unreadable.errors.empty() &&
              unreadable.errors[0].msg.find("no output file") != std::string::npos,
          "an unreadable output: E_NO_CLI naming why");
}

static void testSummarizeRun() {
    g_context = "summarize-run";
    std::vector<MutationRoot> roots = {{"itk_00000011", "/income/dump/Fixture Artist - Placing Album", IntakeStatus::Unknown},
                                       {"itk_00000010", "/income/dump/Fixture Artist - Approved Album", IntakeStatus::Unknown}};
    EnvelopeResult both = parseEnvelope(
        R"({"ok":true,"data":[{"id":"itk_00000011","root_path":"/income/dump/Fixture Artist - Placing Album","resumed":"reverted_to_approved"},)"
        R"({"id":"itk_00000010","root_path":"/income/dump/Fixture Artist - Approved Album","resumed":"completed","target_path":"/lib/x"}],"errors":[]})",
        0);
    RunSummary s = summarizeRun(CliCommand::Resume, roots, both);
    CHECK(s.reverted == v({"itk_00000011"}), "the reverted root is a failure");
    CHECK(s.outcome.succeeded == v({"itk_00000010"}), "the completed root succeeded");
    CHECK(s.outcome.rootErrors.size() == 1 && s.outcome.rootErrors[0].first == "itk_00000011" &&
              s.outcome.rootErrors[0].second == std::string("resume: ") + kResumeRevertedText,
          "its tooltip: resume: reverted to approved ...");
    CHECK(s.outcome.isError && s.outcome.consoleLine.rfind("resume: done for 1 of 2 roots; reverted to approved", 0) == 0,
          "console: done for 1 of 2 roots; reverted to approved ...");

    std::vector<MutationRoot> one = {roots[0]};
    EnvelopeResult onlyReverted = parseEnvelope(
        R"({"ok":true,"data":[{"id":"itk_00000011","root_path":"/income/dump/Fixture Artist - Placing Album","resumed":"reverted_to_approved"}],"errors":[]})",
        0);
    RunSummary r = summarizeRun(CliCommand::Resume, one, onlyReverted);
    CHECK(r.reverted == v({"itk_00000011"}) && r.outcome.succeeded.empty(), "only reverted: no success");
    CHECK(r.outcome.consoleLine == std::string("resume failed for 1 root: ") + kResumeRevertedText + " (itk_00000011)",
          "console: resume failed for 1 root: reverted to approved ...");

    EnvelopeResult foreign = parseEnvelope(
        R"({"ok":true,"data":[{"id":"itk_00000011","resumed":"completed"},{"id":"itk_000000ff","resumed":"reverted_to_approved"}],"errors":[]})",
        0);
    RunSummary f = summarizeRun(CliCommand::Resume, one, foreign);
    CHECK(f.reverted.empty() && f.outcome.succeeded == v({"itk_00000011"}) && !f.outcome.isError &&
              f.outcome.consoleLine == "resume: done for 1 root",
          "a reverted row for a root this run did not name is dropped, never broadcast");

    EnvelopeResult executeOk = parseEnvelope(
        R"({"ok":true,"data":[{"id":"itk_00000010","root_path":"/income/dump/Fixture Artist - Approved Album","resumed":"reverted_to_approved"}],"errors":[]})",
        0);
    RunSummary e = summarizeRun(CliCommand::Execute, {roots[1]}, executeOk);
    CHECK(e.reverted.empty() && e.outcome.consoleLine == "execute: done for 1 root",
          "execute rows are never read as resume rows");

    EnvelopeResult executeFailed = parseEnvelope(
        R"({"ok":false,"data":null,"errors":[{"code":"E_VERIFY","msg":"verify failed: hash","path":"/income/dump/Fixture Artist - Approved Album"}]})",
        2);
    RunSummary ef = summarizeRun(CliCommand::Execute, {roots[1]}, executeFailed);
    CHECK(ef.outcome.rootErrors.size() == 1 &&
              ef.outcome.rootErrors[0].second == "execute: Verification failed: verify failed: hash" &&
              ef.outcome.consoleLine == "execute failed for 1 root: Verification failed: verify failed: hash "
                                        "(/income/dump/Fixture Artist - Approved Album)",
          "an execute failure: the B6 texts");
}

// --- the tracker ---

static void testTracker() {
    g_context = "tracker";
    ExecuteTracker t;
    CHECK(t.empty() && t.describe() == "none" && t.liveRunIds().empty(), "empty");
    CHECK(!t.begin("execute-a", CliCommand::Execute, {}), "no run without ids");
    CHECK(t.begin("execute-a", CliCommand::Execute, {"itk_00000010", "itk_0000000b"}, {"/a", "/b"}), "begin");
    CHECK(!t.begin("execute-a", CliCommand::Execute, {"itk_00000010"}), "a stem once");
    const TrackedRun *a = t.find("execute-a");
    CHECK(a != nullptr && a->state == RunState::Starting && a->pid == 0 && a->rootPaths == v({"/a", "/b"}), "Starting");
    CHECK(t.describe() == "execute starting (itk_00000010 itk_0000000b)", "describe: starting, no pid yet");
    CHECK(!t.exited("execute-a"), "Starting cannot exit (it never ran)");
    CHECK(t.spawned("execute-a", 4242, ProcessStartTime{1, 2}), "spawned");
    CHECK(t.find("execute-a")->state == RunState::Running && t.find("execute-a")->pid == 4242, "Running with a pid");
    CHECK(!t.spawned("execute-a", 4243, ProcessStartTime{}), "spawned once");
    CHECK(t.describe() == "execute pid 4242 running (itk_00000010 itk_0000000b)", "describe: running");

    RunFile adopted;
    adopted.command = CliCommand::Resume;
    adopted.pid = 5151;
    adopted.start = ProcessStartTime{3, 4};
    adopted.ids = {"itk_00000011", "itk_00000010"};
    adopted.output = "execute-b.json";
    CHECK(t.adopt("execute-b", adopted), "adopt");
    CHECK(!t.adopt("execute-b", adopted), "adopt a stem once");
    CHECK(t.find("execute-b")->state == RunState::Adopted && t.find("execute-b")->command == CliCommand::Resume,
          "Adopted, its command kept");
    CHECK(t.liveRunIds() == v({"itk_00000010", "itk_0000000b", "itk_00000011"}), "live roots: every run's, once");
    CHECK(t.describe() == "execute pid 4242 running (itk_00000010 itk_0000000b); resume pid 5151 adopted "
                          "(itk_00000011 itk_00000010)",
          "describe: both");
    CHECK(t.exited("execute-b") && t.find("execute-b")->state == RunState::Exited, "Adopted -> Exited");
    CHECK(!t.exited("execute-b"), "exits once");
    CHECK(t.liveRunIds().size() == 3, "an exited run's roots stay live until its result is applied");
    CHECK(t.exited("execute-a"), "Running -> Exited");
    CHECK(t.remove("execute-a") && t.remove("execute-b") && t.empty(), "removed");
    CHECK(!t.remove("execute-a") && !t.spawned("execute-zz", 1, ProcessStartTime{}), "unknown stems");
    CHECK(t.begin("execute-c", CliCommand::Execute, {"itk_00000010"}) && t.remove("execute-c"),
          "a run can be removed while Starting (refused, spawn failed)");
}

// --- ProcessExitWatch ---

static void testExitWatch() {
    g_context = "exit-watch";
    // A child of ours: reported once, and reaped by the watch.
    pid_t child = spawnSleep("0.3");
    ProcessStartTime start;
    CHECK(child > 0 && readProcessStartTime(child, start), "a sleeping child");
    auto fired = std::make_shared<std::atomic<int>>(0);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    {
        ProcessExitWatch watch(child, start, g_queue, [fired, sem]() {
            (*fired)++;
            dispatch_semaphore_signal(sem);
        });
        CHECK(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              "its exit is reported");
        dispatch_sync(g_queue, ^{});
    }
    CHECK_EQ(fired->load(), 1, "once");
    int status = 0;
    CHECK(waitpid(child, &status, WNOHANG) == -1 && errno == ECHILD, "reaped: no zombie left");

    // A pid that is already gone: reported at once.
    pid_t dead = deadPid();
    auto deadFired = std::make_shared<std::atomic<int>>(0);
    dispatch_semaphore_t deadSem = dispatch_semaphore_create(0);
    auto t0 = mock::Clock::now();
    ProcessExitWatch deadWatch(dead, start, g_queue, [deadFired, deadSem]() {
        (*deadFired)++;
        dispatch_semaphore_signal(deadSem);
    });
    CHECK(dispatch_semaphore_wait(deadSem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 &&
              mock::secondsSince(t0) < 3,
          "a dead pid is reported at once");

    // A live pid with another start time (a reused pid): reported at once,
    // and never waited for.
    pid_t other = spawnSleep("5");
    auto otherFired = std::make_shared<std::atomic<int>>(0);
    dispatch_semaphore_t otherSem = dispatch_semaphore_create(0);
    ProcessStartTime wrong{1, 0};
    t0 = mock::Clock::now();
    {
        ProcessExitWatch reused(other, wrong, g_queue, [otherFired, otherSem]() {
            (*otherFired)++;
            dispatch_semaphore_signal(otherSem);
        });
        CHECK(dispatch_semaphore_wait(otherSem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 &&
                  mock::secondsSince(t0) < 3,
              "another start time: reported at once, not after the 5 s sleep");
        dispatch_sync(g_queue, ^{});
    }
    CHECK(::kill(other, 0) == 0, "and never signalled");
    ::kill(other, SIGKILL);
    while (waitpid(other, &status, 0) < 0 && errno == EINTR) {
    }

    // Cancelled before the exit: never reported.
    pid_t cancelled = spawnSleep("0.3");
    ProcessStartTime cancelledStart;
    readProcessStartTime(cancelled, cancelledStart);
    auto cancelledFired = std::make_shared<std::atomic<int>>(0);
    {
        ProcessExitWatch watch(cancelled, cancelledStart, g_queue, [cancelledFired]() { (*cancelledFired)++; });
        watch.cancel();
    }
    usleep(800 * 1000);
    dispatch_sync(g_queue, ^{});
    CHECK_EQ(cancelledFired->load(), 0, "a cancelled watch never reports");
    CHECK(waitpid(cancelled, &status, 0) == cancelled, "the cancelled watch did not reap it");
}

// --- an adopted run of the mock, end to end ---

static void testAdoptedMockRun() {
    g_context = "adopted-run";
    std::string state = mock::setupState();
    CHECK(!state.empty(), "mock state set up");
    mock::writeFile(state + "/execute.start", "approved-placing\n");
    mock::writeFile(state + "/execute.next", "approved-placed\n");
    mock::setMode(state, "execute", "slow-real 1.5");
    std::string dir = mock::newDir("cache");
    const std::string stem = "execute-adopt-1";
    const std::string out = dir + "/" + runOutputName(stem);

    // The way an earlier foobar2000 left it: an orphan in its own process
    // group (set -m), stdout to the run's output file, not our child.
    std::string pidText;
    int rc = mock::runCapture({"/bin/sh", "-c",
                               "set -m; \"$0\" execute itk_00000010 --json > \"$1\" 2>/dev/null < /dev/null & echo $!",
                               mock::mockPath(), out},
                              mock::mockEnv(state), pidText);
    const pid_t pid = (pid_t)atoi(pidText.c_str());
    CHECK(rc == 0 && pid > 1, "the orphan mock started");
    ProcessStartTime start;
    CHECK(readProcessStartTime(pid, start), "its start time");
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof info);
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) == (int)sizeof info &&
        (pid_t)info.pbi_pgid == pid) {
        mock::trackGroup(pid, pid);
    }
    RunFile file;
    file.command = CliCommand::Execute;
    file.pid = pid;
    file.start = start;
    file.ids = {"itk_00000010"};
    file.rootPaths = {state + "/root/income/dump/Fixture Artist - Approved Album"};
    file.output = runOutputName(stem);
    std::string error;
    CHECK(writeRunFile(dir, stem, file, error), "its run file");

    LeftoverScan scan = scanLeftoverRuns(dir, processIsLive);
    CHECK(scan.adopt.size() == 1 && scan.adopt[0].stem == stem && scan.finish.empty() && scan.swept.empty(),
          "the live run is adopted, its files kept");
    const std::string sidecar = state + "/root/income/dump/Fixture Artist - Approved Album/.intake.json";
    CHECK(mock::waitUntil([&] { return mock::readFile(sidecar).find("\"status\": \"placing\"") != std::string::npos; },
                          5.0),
          "while it runs the sidecar says placing (execute.start)");

    auto fired = std::make_shared<std::atomic<int>>(0);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    auto watch = std::make_unique<ProcessExitWatch>(pid, start, g_queue, [fired, sem]() {
        (*fired)++;
        dispatch_semaphore_signal(sem);
    });
    CHECK(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) == 0,
          "the adopted run's exit is reported (a PROC source on a pid that is not our child)");
    watch.reset();
    int status = 0;
    CHECK(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD, "not our child: waitpid says ECHILD");
    CHECK(mock::readFile(sidecar).find("\"status\": \"placed\"") != std::string::npos, "the sidecar ends placed");

    std::string text;
    CHECK(readRunOutput(dir, runOutputName(stem), text, error), "its output is read");
    EnvelopeResult envelope = parseDetachedOutput(text, error);
    CHECK(envelope.outcome == CliOutcome::Ok && idsInData(envelope.data) == v({"itk_00000010"}),
          "parsed without an exit code: Ok");
    std::vector<MutationRoot> roots = {{"itk_00000010", file.rootPaths[0], IntakeStatus::Unknown}};
    RunSummary summary = summarizeRun(CliCommand::Execute, roots, envelope);
    CHECK(summary.outcome.consoleLine == "execute: done for 1 root" && summary.outcome.rootErrors.empty(),
          "execute: done for 1 root");

    // Found dead by a later scan (the run ended while foobar2000 was away).
    LeftoverScan later = scanLeftoverRuns(dir, processIsLive);
    CHECK(later.adopt.empty() && later.finish.size() == 1 && later.finish[0].output == text,
          "a later session finishes it from its output");
    CHECK_EQ(deleteRunFiles(dir, stem), 2, "then both files are deleted");
    CHECK(mock::listDir(dir).empty(), "nothing left in the folder");
    std::string log = mock::callsLog(state);
    CHECK(log.find("execute\titk_00000010\t--json\n") != std::string::npos, "calls.log: execute itk_00000010 --json");
}

int main() {
    @autoreleasepool {
        mock::trackedMutex();
        mock::tracked();
        atexit([] { mock::killLeftovers(); });
        g_queue = dispatch_queue_create("intake.tests.tracker", DISPATCH_QUEUE_SERIAL);
        testNames();
        testRunFileRoundTrip();
        testRunFileMalformed();
        testRunFileWrite();
        testProvisional();
        testLiveness();
        testScan();
        testDetachedOutput();
        testSummarizeRun();
        testTracker();
        testExitWatch();
        testAdoptedMockRun();
        mock::killLeftovers();
        mock::removeTempRoot();
    }
    TEST_MAIN_END();
}
