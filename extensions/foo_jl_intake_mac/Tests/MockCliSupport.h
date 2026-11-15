//
//  MockCliSupport.h
//  foo_jl_intake_mac
//
//  Helpers for the tests that run Tests/mock-cli/intake-mock: hermetic
//  temp directories, mock state setup, file helpers, bounded waits, the
//  list of open descriptors, and a leftover-process sweep.
//
//  Hermetic: every directory is created under one mkdtemp root in
//  NSTemporaryDirectory() (never ~/Library) and removed at the end. The mock
//  gets a minimal environment with INTAKE_MOCK_STATE pointing at a fresh,
//  set-up state directory. Nothing here runs the real intake CLI or touches
//  real music.
//
//  Leftovers: every pid a test learns about (a result's pid, the pids the
//  mock's hang mode writes to hang.pid) is tracked. killLeftovers() SIGKILLs
//  only a tracked pid that is still bash or sleep, still in the recorded
//  process group, and whose parent is this test process or launchd, so a
//  reused pid can never hit an unrelated process. Tests call it after the
//  hang cases and at the end of main, and register it with atexit. The mock
//  also gets INTAKE_MOCK_HANG_SECONDS=30, which bounds a leftover even if
//  the sweep never runs (a crash).
//

#pragma once

#import <Foundation/Foundation.h>

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace mock {

using Clock = std::chrono::steady_clock;

inline double secondsSince(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}

inline std::string testsDir() {
    std::string file = __FILE__;
    return file.substr(0, file.rfind('/'));
}

inline std::string mockPath() {
    return testsDir() + "/mock-cli/intake-mock";
}

// --- temp directories ---

inline std::string &tempRootStorage() {
    static std::string root;
    return root;
}

inline std::string makeTemp(const std::string &pattern) {
    std::vector<char> buf(pattern.begin(), pattern.end());
    buf.push_back('\0');
    return mkdtemp(buf.data()) ? std::string(buf.data()) : std::string();
}

inline std::string tempRoot() {
    std::string &root = tempRootStorage();
    if (root.empty()) {
        std::string base = NSTemporaryDirectory().UTF8String;
        if (base.empty() || base.back() != '/') base += '/';
        root = makeTemp(base + "intake-b1-XXXXXX");
        if (root.empty()) {
            fprintf(stderr, "cannot create a temp directory under %s\n", base.c_str());
            std::abort();
        }
    }
    return root;
}

inline std::string newDir(const std::string &label) {
    return makeTemp(tempRoot() + "/" + label + "-XXXXXX");
}

inline void removeTempRoot() {
    std::string &root = tempRootStorage();
    if (root.empty()) return;
    @autoreleasepool {
        [[NSFileManager defaultManager] removeItemAtPath:@(root.c_str()) error:nil];
    }
    root.clear();
}

// --- files ---

inline bool fileExists(const std::string &path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

inline std::string readFile(const std::string &path) {
    std::string out;
    int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return out;
    char buf[8192];
    ssize_t n;
    while ((n = ::read(fd, buf, sizeof buf)) > 0) out.append(buf, (size_t)n);
    ::close(fd);
    return out;
}

inline bool writeFile(const std::string &path, const std::string &content, mode_t mode = 0644) {
    int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd < 0) return false;
    bool ok = ::write(fd, content.data(), content.size()) == (ssize_t)content.size();
    ::close(fd);
    return ok && chmod(path.c_str(), mode) == 0;
}

inline std::vector<std::string> listDir(const std::string &dir) {
    std::vector<std::string> names;
    @autoreleasepool {
        NSArray<NSString *> *items =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(dir.c_str()) error:nil];
        for (NSString *name in items) names.push_back(name.UTF8String);
    }
    return names;
}

inline std::string lastLine(const std::string &text) {
    std::string t = text;
    while (!t.empty() && t.back() == '\n') t.pop_back();
    size_t nl = t.rfind('\n');
    return nl == std::string::npos ? t : t.substr(nl + 1);
}

// --- bounded waits (never an unbounded sleep or wait) ---

template <class Condition>
bool waitUntil(Condition condition, double timeoutSeconds) {
    auto start = Clock::now();
    while (!condition()) {
        if (secondsSince(start) > timeoutSeconds) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
    return true;
}

inline bool groupGone(pid_t pgid) {
    return ::kill(-pgid, 0) == -1 && errno == ESRCH;
}

inline bool pidGone(pid_t pid) {
    return ::kill(pid, 0) == -1 && errno == ESRCH;
}

inline bool notOurChild(pid_t pid) {
    int status = 0;
    return waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD;
}

// The open descriptor numbers of this process, sorted; empty when they
// cannot be listed. Comparing the numbers, not just the count, catches a
// leak hidden by a descriptor closed by mistake.
inline std::vector<int> openFds() {
    std::vector<int> out;
    int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nullptr, 0);
    if (bytes <= 0) return out;
    std::vector<proc_fdinfo> fds((size_t)bytes / sizeof(proc_fdinfo) + 16);
    bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, fds.data(), (int)(fds.size() * sizeof(proc_fdinfo)));
    for (int i = 0; bytes > 0 && i < bytes / (int)sizeof(proc_fdinfo); i++) out.push_back(fds[i].proc_fd);
    std::sort(out.begin(), out.end());
    return out;
}

// The numbers in `a` that are not in `b`, space-separated (both sorted).
inline std::string fdsMissingFrom(const std::vector<int> &a, const std::vector<int> &b) {
    std::vector<int> diff;
    std::set_difference(a.begin(), a.end(), b.begin(), b.end(), std::back_inserter(diff));
    std::string out;
    for (int fd : diff) out += (out.empty() ? "" : " ") + std::to_string(fd);
    return out.empty() ? "none" : out;
}

// --- leftover sweep ---

struct Tracked {
    pid_t pid;
    pid_t pgid;
};

inline std::mutex &trackedMutex() {
    static std::mutex m;
    return m;
}

inline std::vector<Tracked> &tracked() {
    static std::vector<Tracked> list;
    return list;
}

inline void trackGroup(pid_t pid, pid_t pgid) {
    if (pid <= 1 || pgid <= 1) return;
    std::lock_guard<std::mutex> lock(trackedMutex());
    tracked().push_back({pid, pgid});
}

// hang.pid holds "<shell pid> <child pid>"; the shell leads the group.
inline void trackHangPids(const std::string &state) {
    std::string text = readFile(state + "/hang.pid");
    int shell = 0, child = 0;
    if (sscanf(text.c_str(), "%d %d", &shell, &child) == 2) {
        trackGroup(shell, shell);
        trackGroup(child, shell);
    }
}

// SIGKILLs `pid` only when it is still bash or sleep, still in `pgid`, and a
// child of this process or of launchd (an orphan).
inline void killIfLeftover(pid_t pid, pid_t pgid) {
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof info);
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof info) != (int)sizeof info) return;
    bool ours = (pid_t)info.pbi_pgid == pgid && ((pid_t)info.pbi_ppid == getpid() || info.pbi_ppid == 1);
    bool expected = strcmp(info.pbi_comm, "bash") == 0 || strcmp(info.pbi_comm, "sleep") == 0;
    if (ours && expected) {
        printf("  killing leftover %s pid %d\n", info.pbi_comm, pid);
        ::kill(pid, SIGKILL);
    }
}

inline void killLeftovers() {
    std::lock_guard<std::mutex> lock(trackedMutex());
    for (const Tracked &t : tracked()) {
        killIfLeftover(t.pid, t.pgid);
        // Members nobody recorded, e.g. a script's backgrounded sleep.
        pid_t members[64];
        int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)t.pgid, members, (int)sizeof members);
        for (int i = 0; bytes > 0 && i < bytes / (int)sizeof(pid_t); i++) {
            if (members[i] > 1) killIfLeftover(members[i], t.pgid);
        }
    }
}

// --- the mock ---

inline std::vector<std::string> mockEnv(const std::string &state) {
    std::vector<std::string> env = {
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
        "LC_ALL=C",
        "INTAKE_MOCK_HANG_SECONDS=30",
    };
    if (!state.empty()) env.push_back("INTAKE_MOCK_STATE=" + state);
    return env;
}

// Runs argv synchronously (argv[0] is the executable) with stdout and stderr
// on /dev/null; returns the exit code, or -1.
inline int runSync(const std::vector<std::string> &argv, const std::vector<std::string> &env) {
    std::vector<std::string> a = argv, e = env;
    std::vector<char *> av, ev;
    for (std::string &s : a) av.push_back(&s[0]);
    av.push_back(nullptr);
    for (std::string &s : e) ev.push_back(&s[0]);
    ev.push_back(nullptr);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, a[0].c_str(), &actions, &attr, av.data(), ev.data());
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) return -1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

// A fresh state directory with `scenario` set up, or "" on failure.
inline std::string setupState(const std::string &scenario = "default") {
    std::string dir = newDir("state");
    if (dir.empty()) return dir;
    int rc = runSync({mockPath(), "--mock-setup", scenario}, mockEnv(dir));
    return rc == 0 ? dir : std::string();
}

inline void setMode(const std::string &state, const std::string &command, const std::string &mode) {
    writeFile(state + "/" + command + ".mode", mode + "\n");
}

inline std::string callsLog(const std::string &state) {
    return readFile(state + "/calls.log");
}

} // namespace mock
