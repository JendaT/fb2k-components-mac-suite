//
//  IntakeProcess.mm
//  foo_jl_intake
//
//  See IntakeProcess.h for the policy. Everything below runs on the runner's
//  private serial queue unless a comment says otherwise, so the per-process
//  state needs no locks.
//

#include "IntakeProcess.h"

#import <Foundation/Foundation.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <unordered_map>

namespace intake {

namespace {

using Clock = std::chrono::steady_clock;

int killGroup(pid_t pgid, int signal) {
    return ::kill(-pgid, signal);
}

double secondsSince(Clock::time_point start) {
    return std::chrono::duration<double>(Clock::now() - start).count();
}

// One-shot timer on `queue`. The handler should cancel the timer (via
// cancelTimer) so its block, and what the block captures, is released.
dispatch_source_t makeTimer(dispatch_queue_t queue, double seconds, dispatch_block_t handler) {
    if (seconds < 0) seconds = 0;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, handler);
    dispatch_resume(timer);
    return timer;
}

void cancelTimer(dispatch_source_t __strong &timer) {
    if (timer) {
        dispatch_source_cancel(timer);
        timer = nil;
    }
}

void closeIfOpen(int &fd) {
    if (fd >= 0) {
        ::close(fd);
        fd = -1;
    }
}

// Keeps descriptors the child must receive away from 0..2, so the dup2 file
// actions onto 0..2 can never overwrite one another (a parent with a closed
// stdin would otherwise get fd 0 back from pipe()). Returns -1 on failure
// and closes `fd` either way when it had to move it.
int moveAboveStdio(int fd) {
    if (fd > 2) return fd;
    int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    int saved = errno;
    ::close(fd);
    errno = saved;
    return moved;
}

bool setCloexec(int fd) {
    int flags = fcntl(fd, F_GETFD);
    return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

bool setNonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

// Reads at most `cap` bytes of `path` into `out`; `truncated` when the file
// is longer. False (and `error`) when it cannot be read.
bool readCapped(const std::string &path, size_t cap, std::string &out, bool &truncated,
                std::string &error) {
    int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        error = "cannot open " + path + ": " + strerror(errno);
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) {
        error = "cannot stat " + path + ": " + strerror(errno);
        ::close(fd);
        return false;
    }
    size_t size = st.st_size > 0 ? (size_t)st.st_size : 0;
    size_t want = size < cap ? size : cap;
    truncated = size > cap;
    out.resize(want);
    size_t got = 0;
    while (got < want) {
        ssize_t n = ::read(fd, &out[got], want - got);
        if (n > 0) {
            got += (size_t)n;
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            error = "cannot read " + path + ": " + strerror(errno);
            ::close(fd);
            out.clear();
            return false;
        }
    }
    out.resize(got);
    ::close(fd);
    return true;
}

bool hasNul(const std::string &s) {
    return s.find('\0') != std::string::npos;
}

std::vector<char *> cStringArray(std::vector<std::string> &strings) {
    std::vector<char *> out;
    out.reserve(strings.size() + 1);
    for (std::string &s : strings) out.push_back(&s[0]);
    out.push_back(nullptr);
    return out;
}

struct Proc {
    uint64_t token = 0;
    ProcessSpec spec;
    dispatch_queue_t callbackQueue = nil;
    ProcessBudgetHandler onBudget;
    ProcessCompletion onComplete;

    pid_t pid = 0;
    int outFd = -1; // Pipes: read ends, owned by the read sources once they exist
    int errFd = -1;
    std::string outPath; // Files: the output files, unlinked after reading
    std::string errPath; // unless keepOutputFiles
    dispatch_source_t procSource = nil;
    dispatch_source_t outSource = nil;
    dispatch_source_t errSource = nil;
    dispatch_source_t budgetTimer = nil;
    dispatch_source_t hardCapTimer = nil;
    dispatch_source_t killTimer = nil;
    dispatch_source_t abandonTimer = nil;
    dispatch_source_t drainTimer = nil;

    bool exited = false;
    bool outClosed = true;
    bool errClosed = true;
    bool killStarted = false;
    bool reaped = false;
    bool delivered = false;

    Clock::time_point start;
    ProcessResult result;
};

using ProcPtr = std::shared_ptr<Proc>;

} // anonymous namespace

struct ProcessRunner::Impl : std::enable_shared_from_this<ProcessRunner::Impl> {
    dispatch_queue_t queue = nil;
    ProcessSignalSender sendSignal = killGroup;
    std::unordered_map<uint64_t, ProcPtr> procs; // started and not yet reaped
    std::atomic<uint64_t> lastToken{0};
    std::vector<char> readBuffer = std::vector<char>(64 * 1024);

    void spawn(ProcPtr p);
    void failSpawn(ProcPtr p, const char *stage, int err);
    void startSources(ProcPtr p);
    void drain(ProcPtr p, bool isStdout);
    void exitObserved(ProcPtr p);
    void budgetElapsed(ProcPtr p);
    void beginKill(ProcPtr p);
    void abandon(ProcPtr p);
    void tryFinish(ProcPtr p);
    void deliver(ProcPtr p, ProcessEnd end);
    void cancelAllTimers(ProcPtr p);
    void cancelPipeSources(ProcPtr p);
};

using Impl = ProcessRunner::Impl;

void Impl::failSpawn(ProcPtr p, const char *stage, int err) {
    p->result.spawnErrno = err;
    p->result.spawnStage = stage;
    p->reaped = true; // nothing to reap
    deliver(p, ProcessEnd::SpawnFailed);
}

void Impl::spawn(ProcPtr p) {
    ProcessSpec &spec = p->spec;
    p->start = Clock::now();

    if (spec.executable.empty() || spec.arguments.empty() || hasNul(spec.executable)) {
        failSpawn(p, "arguments", EINVAL);
        return;
    }
    for (const std::string &s : spec.arguments) {
        if (hasNul(s)) { failSpawn(p, "arguments", EINVAL); return; }
    }
    for (const std::string &s : spec.environment) {
        if (hasNul(s)) { failSpawn(p, "environment", EINVAL); return; }
    }

    int childOut = -1, childErr = -1; // the ends the child receives as 1 and 2
    int outRead = -1, errRead = -1;

    if (spec.output == OutputTarget::Files) {
        if (spec.outputDirectory.empty() || spec.outputDirectory[0] != '/' ||
            hasNul(spec.outputDirectory)) {
            failSpawn(p, "output directory", EINVAL);
            return;
        }
        @autoreleasepool {
            NSString *dir = [[NSString alloc] initWithBytes:spec.outputDirectory.data()
                                                     length:spec.outputDirectory.size()
                                                   encoding:NSUTF8StringEncoding];
            NSError *error = nil;
            if (!dir || ![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                                   withIntermediateDirectories:YES
                                                                    attributes:@{NSFilePosixPermissions: @0700}
                                                                         error:&error]) {
                NSError *posix = [error.domain isEqualToString:NSPOSIXErrorDomain]
                                     ? error
                                     : error.userInfo[NSUnderlyingErrorKey];
                int err = [posix.domain isEqualToString:NSPOSIXErrorDomain] ? (int)posix.code : EACCES;
                failSpawn(p, "output directory", err > 0 ? err : EACCES);
                return;
            }
        }
        long long ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                           std::chrono::system_clock::now().time_since_epoch()).count();
        std::string base = spec.outputDirectory;
        if (base.back() != '/') base += '/';
        base += "intake-" + std::to_string(getpid()) + "-" + std::to_string(p->token) + "-" +
                std::to_string(ms);
        std::string outPath = base + ".out";
        std::string errPath = base + ".err";
        // O_EXCL: a name that exists is never reused, and never unlinked here.
        childOut = ::open(outPath.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (childOut < 0) {
            failSpawn(p, "output file", errno);
            return;
        }
        if ((childOut = moveAboveStdio(childOut)) < 0) {
            int err = errno;
            ::unlink(outPath.c_str());
            failSpawn(p, "output file", err);
            return;
        }
        childErr = ::open(errPath.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (childErr < 0) {
            int err = errno;
            ::close(childOut);
            ::unlink(outPath.c_str());
            failSpawn(p, "output file", err);
            return;
        }
        if ((childErr = moveAboveStdio(childErr)) < 0) {
            int err = errno;
            ::close(childOut);
            ::unlink(outPath.c_str());
            ::unlink(errPath.c_str());
            failSpawn(p, "output file", err);
            return;
        }
        p->outPath = outPath;
        p->errPath = errPath;
    } else {
        int outPipe[2] = {-1, -1}, errPipe[2] = {-1, -1};
        bool ok = ::pipe(outPipe) == 0;
        if (ok && ::pipe(errPipe) != 0) ok = false;
        int err = errno;
        for (int *fd : {&outPipe[0], &outPipe[1], &errPipe[0], &errPipe[1]}) {
            if (!ok || *fd < 0) continue;
            if ((*fd = moveAboveStdio(*fd)) < 0 || !setCloexec(*fd)) {
                ok = false;
                err = errno;
            }
        }
        if (ok && (!setNonblocking(outPipe[0]) || !setNonblocking(errPipe[0]))) {
            ok = false;
            err = errno;
        }
        if (!ok) {
            for (int *fd : {&outPipe[0], &outPipe[1], &errPipe[0], &errPipe[1]}) closeIfOpen(*fd);
            failSpawn(p, "pipe", err ? err : EMFILE);
            return;
        }
        outRead = outPipe[0];
        childOut = outPipe[1];
        errRead = errPipe[0];
        childErr = errPipe[1];
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    posix_spawn_file_actions_init(&actions);
    posix_spawnattr_init(&attr);

    // 1 and 2 first, then 0: childOut/childErr are above 2, so the order only
    // matters for readability. CLOEXEC_DEFAULT closes everything else,
    // including the originals of childOut/childErr.
    posix_spawn_file_actions_adddup2(&actions, childOut, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, childErr, STDERR_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);

    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT |
                                        POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    posix_spawnattr_setpgroup(&attr, 0);
    sigset_t noSignals;
    sigemptyset(&noSignals);
    posix_spawnattr_setsigmask(&attr, &noSignals);
    sigset_t allSignals;
    sigfillset(&allSignals);
    sigdelset(&allSignals, SIGKILL);
    sigdelset(&allSignals, SIGSTOP);
    posix_spawnattr_setsigdefault(&attr, &allSignals);

    std::vector<std::string> argvStorage = spec.arguments;
    std::vector<std::string> envStorage = spec.environment;
    std::vector<char *> argv = cStringArray(argvStorage);
    std::vector<char *> envp = cStringArray(envStorage);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, spec.executable.c_str(), &actions, &attr, argv.data(), envp.data());

    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    ::close(childOut);
    ::close(childErr);

    if (rc != 0) {
        closeIfOpen(outRead);
        closeIfOpen(errRead);
        if (!p->outPath.empty()) {
            ::unlink(p->outPath.c_str());
            ::unlink(p->errPath.c_str());
        }
        failSpawn(p, "spawn", rc);
        return;
    }

    p->pid = pid;
    p->result.pid = pid;
    p->outFd = outRead;
    p->errFd = errRead;
    p->outClosed = outRead < 0;
    p->errClosed = errRead < 0;
    procs[p->token] = p;
    startSources(p);
}

void Impl::startSources(ProcPtr p) {
    auto self = shared_from_this();

    if (p->outFd >= 0) {
        int fd = p->outFd;
        p->outSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
        dispatch_source_set_event_handler(p->outSource, ^{ self->drain(p, true); });
        dispatch_source_set_cancel_handler(p->outSource, ^{
            ::close(fd);
            p->outFd = -1;
            p->outClosed = true;
            p->outSource = nil;
            self->tryFinish(p);
        });
        dispatch_resume(p->outSource);
    }
    if (p->errFd >= 0) {
        int fd = p->errFd;
        p->errSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, queue);
        dispatch_source_set_event_handler(p->errSource, ^{ self->drain(p, false); });
        dispatch_source_set_cancel_handler(p->errSource, ^{
            ::close(fd);
            p->errFd = -1;
            p->errClosed = true;
            p->errSource = nil;
            self->tryFinish(p);
        });
        dispatch_resume(p->errSource);
    }

    p->procSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)p->pid,
                                           DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(p->procSource, ^{ self->exitObserved(p); });
    dispatch_resume(p->procSource);

    const ProcessLimits &limits = p->spec.limits;
    if (p->spec.policy != BudgetPolicy::Unbounded) {
        p->budgetTimer = makeTimer(queue, limits.budgetSeconds, ^{ self->budgetElapsed(p); });
    }
    if (p->spec.policy == BudgetPolicy::ReportAtBudget) {
        p->hardCapTimer = makeTimer(queue, limits.hardCapSeconds, ^{
            cancelTimer(p->hardCapTimer);
            if (p->exited) return;
            p->result.hardCapHit = true;
            p->result.killedForTimeout = true;
            self->beginKill(p);
        });
    }

    // A child that exited before the source was armed: libdispatch reports
    // that too, but check without reaping (WNOWAIT) so the exit is never
    // missed. exitObserved ignores the second report.
    siginfo_t info;
    memset(&info, 0, sizeof info);
    if (waitid(P_PID, (id_t)p->pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == p->pid) {
        exitObserved(p);
    }
}

void Impl::drain(ProcPtr p, bool isStdout) {
    int fd = isStdout ? p->outFd : p->errFd;
    dispatch_source_t source = isStdout ? p->outSource : p->errSource;
    if (fd < 0 || !source) return;
    std::string &buffer = isStdout ? p->result.stdoutData : p->result.stderrData;
    bool &truncated = isStdout ? p->result.stdoutTruncated : p->result.stderrTruncated;
    size_t cap = isStdout ? p->spec.limits.stdoutCap : p->spec.limits.stderrCap;

    // Bounded per event, so a child that writes without pause cannot starve
    // the timers sharing this queue; the source fires again while data is left.
    for (int round = 0; round < 16; round++) {
        ssize_t n = ::read(fd, readBuffer.data(), readBuffer.size());
        if (n > 0) {
            size_t room = buffer.size() < cap ? cap - buffer.size() : 0;
            size_t take = (size_t)n < room ? (size_t)n : room;
            buffer.append(readBuffer.data(), take);
            if (take < (size_t)n) truncated = true;
            continue;
        }
        if (n == 0) {
            if (isStdout) p->result.stdoutEOF = true;
            dispatch_source_cancel(source);
            return;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        dispatch_source_cancel(source); // any other read error ends this pipe
        return;
    }
}

void Impl::exitObserved(ProcPtr p) {
    if (p->exited) return;
    p->exited = true;
    if (p->procSource) {
        dispatch_source_cancel(p->procSource);
        p->procSource = nil;
    }
    cancelTimer(p->budgetTimer);
    cancelTimer(p->hardCapTimer);
    cancelTimer(p->killTimer);
    cancelTimer(p->abandonTimer);
    if (!p->outClosed || !p->errClosed) {
        // Normally EOF follows at once. An orphaned grandchild that still
        // holds a pipe gets the drain grace, then the pipes are dropped.
        auto self = shared_from_this();
        p->drainTimer = makeTimer(queue, p->spec.limits.drainGraceSeconds, ^{
            cancelTimer(p->drainTimer);
            self->cancelPipeSources(p);
        });
    }
    tryFinish(p);
}

void Impl::budgetElapsed(ProcPtr p) {
    cancelTimer(p->budgetTimer);
    if (p->exited) return;
    p->result.budgetExceeded = true;
    if (p->onBudget) {
        ProcessBudgetHandler handler = p->onBudget;
        pid_t pid = p->pid;
        dispatch_async(p->callbackQueue, ^{ handler(pid); });
    }
    if (p->spec.policy == BudgetPolicy::KillAtBudget) {
        p->result.killedForTimeout = true;
        beginKill(p);
    }
}

void Impl::beginKill(ProcPtr p) {
    if (p->killStarted || p->exited) return;
    p->killStarted = true;
    sendSignal(p->pid, SIGTERM);
    auto self = shared_from_this();
    double grace = p->spec.limits.killGraceSeconds;
    p->killTimer = makeTimer(queue, grace, ^{
        cancelTimer(p->killTimer);
        if (p->exited) return;
        self->sendSignal(p->pid, SIGKILL);
        p->abandonTimer = makeTimer(self->queue, grace, ^{
            cancelTimer(p->abandonTimer);
            if (!p->exited) self->abandon(p);
        });
    });
}

void Impl::abandon(ProcPtr p) {
    if (p->delivered) return;
    // Stop reading: the result is final now. The proc source stays armed, so
    // the pid is reaped whenever it finally exits (tryFinish).
    cancelPipeSources(p);
    deliver(p, ProcessEnd::Abandoned);
}

void Impl::cancelPipeSources(ProcPtr p) {
    if (p->outSource) dispatch_source_cancel(p->outSource);
    if (p->errSource) dispatch_source_cancel(p->errSource);
}

void Impl::cancelAllTimers(ProcPtr p) {
    cancelTimer(p->budgetTimer);
    cancelTimer(p->hardCapTimer);
    cancelTimer(p->killTimer);
    cancelTimer(p->abandonTimer);
    cancelTimer(p->drainTimer);
}

void Impl::tryFinish(ProcPtr p) {
    if (p->reaped || !p->exited || !p->outClosed || !p->errClosed) return;

    // The leader is a zombie until the waitpid below, which keeps its
    // process group id from being reused: signalling the group now cannot
    // reach an unrelated process. A read-only call leaves nothing behind.
    if (p->spec.policy == BudgetPolicy::KillAtBudget) sendSignal(p->pid, SIGKILL);

    int status = 0;
    pid_t r;
    do {
        r = waitpid(p->pid, &status, 0);
    } while (r < 0 && errno == EINTR);
    p->reaped = true;
    cancelAllTimers(p);
    procs.erase(p->token);

    ProcessResult &res = p->result;
    bool files = p->spec.output == OutputTarget::Files;
    bool unlinkFiles = files && !p->spec.keepOutputFiles;

    if (p->delivered) {
        // Abandoned earlier; only the cleanup is left.
        if (unlinkFiles) {
            ::unlink(p->outPath.c_str());
            ::unlink(p->errPath.c_str());
        }
        return;
    }

    ProcessEnd end;
    if (r == p->pid && WIFEXITED(status)) {
        end = ProcessEnd::Exited;
        res.exitCode = WEXITSTATUS(status);
    } else if (r == p->pid && WIFSIGNALED(status)) {
        end = ProcessEnd::Signaled;
        res.termSignal = WTERMSIG(status);
    } else {
        end = ProcessEnd::WaitFailed;
    }

    if (files) {
        std::string error;
        if (readCapped(p->outPath, p->spec.limits.stdoutCap, res.stdoutData, res.stdoutTruncated,
                       error)) {
            res.stdoutEOF = true;
        } else {
            res.outputError = error;
        }
        std::string ignored; // stderr is diagnostics only
        readCapped(p->errPath, p->spec.limits.stderrCap, res.stderrData, res.stderrTruncated,
                   ignored);
        if (unlinkFiles) {
            ::unlink(p->outPath.c_str());
            ::unlink(p->errPath.c_str());
        }
    }
    deliver(p, end);
}

void Impl::deliver(ProcPtr p, ProcessEnd end) {
    if (p->delivered) return;
    p->delivered = true;
    p->result.end = end;
    p->result.elapsedSeconds = secondsSince(p->start);
    if (p->spec.output == OutputTarget::Files && p->spec.keepOutputFiles) {
        p->result.stdoutPath = p->outPath;
        p->result.stderrPath = p->errPath;
    }
    auto result = std::make_shared<ProcessResult>(std::move(p->result));
    ProcessCompletion completion = std::move(p->onComplete);
    p->onComplete = nullptr;
    p->onBudget = nullptr;
    dispatch_async(p->callbackQueue, ^{
        if (completion) completion(std::move(*result));
    });
}

ProcessRunner::ProcessRunner(ProcessSignalSender signalSender) : impl_(std::make_shared<Impl>()) {
    dispatch_queue_attr_t attr =
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    impl_->queue = dispatch_queue_create("foo_jl_intake.process", attr);
    if (signalSender) impl_->sendSignal = signalSender;
}

ProcessRunner::~ProcessRunner() = default;

uint64_t ProcessRunner::start(ProcessSpec spec, dispatch_queue_t callbackQueue,
                              ProcessBudgetHandler onBudget, ProcessCompletion onComplete) {
    auto p = std::make_shared<Proc>();
    p->token = ++impl_->lastToken;
    p->spec = std::move(spec);
    p->callbackQueue = callbackQueue ? callbackQueue : dispatch_get_main_queue();
    p->onBudget = std::move(onBudget);
    p->onComplete = std::move(onComplete);
    auto impl = impl_;
    dispatch_async(impl->queue, ^{ impl->spawn(p); });
    return p->token;
}

size_t ProcessRunner::cancelReadLane() {
    __block size_t count = 0;
    auto impl = impl_;
    dispatch_sync(impl->queue, ^{
        for (auto &entry : impl->procs) {
            ProcPtr p = entry.second;
            if (p->spec.policy != BudgetPolicy::KillAtBudget || p->exited || p->delivered) continue;
            p->result.cancelled = true;
            cancelTimer(p->budgetTimer);
            cancelTimer(p->killTimer);
            impl->sendSignal(p->pid, SIGKILL);
            p->killStarted = true;
            if (!p->abandonTimer) {
                ProcPtr proc = p;
                p->abandonTimer = makeTimer(impl->queue, p->spec.limits.killGraceSeconds, ^{
                    cancelTimer(proc->abandonTimer);
                    if (!proc->exited) impl->abandon(proc);
                });
            }
            count++;
        }
    });
    return count;
}

size_t ProcessRunner::runningCount() const {
    __block size_t count = 0;
    auto impl = impl_;
    dispatch_sync(impl->queue, ^{ count = impl->procs.size(); });
    return count;
}

} // namespace intake
