//
//  IntakeExecuteTracker.mm
//  foo_jl_intake
//

#include "IntakeExecuteTracker.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <dirent.h>
#include <fcntl.h>
#include <libproc.h>
#include <map>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <unordered_set>

namespace intake {

const char *const kResumeRevertedText =
    "reverted to approved: the library copy was missing or did not verify; execute it again";

namespace {

constexpr size_t kMaxTokenLength = 64;
constexpr size_t kMaxRunFileBytes = 64 * 1024;
constexpr size_t kMaxOutputBytes = size_t(32) << 20;  // the runner's stdout cap

// The code of the synthetic error a reverted resume row becomes. Never
// shown: unknown codes are rendered from their msg (IntakeErrorMap).
const char *const kRevertedCode = "E_RESUME_REVERTED";

bool tokenChar(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
}

bool endsWith(std::string_view s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string joinPath(const std::string &dir, const std::string &name) {
    if (dir.empty()) return name;
    return dir.back() == '/' ? dir + name : dir + "/" + name;
}

bool isRegularFile(const std::string &path) {
    struct stat st;
    return lstat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

bool removeIfRegular(const std::string &path) {
    return isRegularFile(path) && ::unlink(path.c_str()) == 0;
}

// Reads at most `cap` bytes of a regular file (no symlink followed).
bool readCappedFile(const std::string &path, size_t cap, std::string &out, std::string &error) {
    out.clear();
    int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        error = std::string("cannot open: ") + strerror(errno);
        return false;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        error = "not a regular file";
        ::close(fd);
        return false;
    }
    if (st.st_size > 0 && (size_t)st.st_size > cap) {
        error = "larger than " + std::to_string(cap) + " bytes";
        ::close(fd);
        return false;
    }
    char buf[16384];
    for (;;) {
        ssize_t n = ::read(fd, buf, sizeof buf);
        if (n > 0) {
            if (out.size() + (size_t)n > cap) {
                error = "larger than " + std::to_string(cap) + " bytes";
                ::close(fd);
                out.clear();
                return false;
            }
            out.append(buf, (size_t)n);
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            error = std::string("cannot read: ") + strerror(errno);
            ::close(fd);
            out.clear();
            return false;
        }
    }
    ::close(fd);
    return true;
}

NSString *toNS(const std::string &s) {
    NSString *out = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return out ?: @"";
}

std::string fromNS(NSString *s) {
    const char *c = s.UTF8String;
    return c ? std::string(c) : std::string();
}

// An integral JSON number (not a boolean, not a float) in [min, max].
bool jsonInteger(id value, long long min, long long max, long long &out) {
    if (![value isKindOfClass:[NSNumber class]]) return false;
    NSNumber *n = value;
    if (CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) return false;
    if (CFNumberIsFloatType((__bridge CFNumberRef)n)) return false;
    const long long v = n.longLongValue;
    if (v < min || v > max) return false;
    out = v;
    return true;
}

} // anonymous namespace

// --- names ---

bool isRunStem(std::string_view stem) {
    const std::string_view prefix = kRunFilePrefix;
    if (stem.size() <= prefix.size() || stem.compare(0, prefix.size(), prefix) != 0) return false;
    const std::string_view token = stem.substr(prefix.size());
    if (token.empty() || token.size() > kMaxTokenLength) return false;
    return std::all_of(token.begin(), token.end(), tokenChar);
}

bool parseRunFileName(std::string_view name, std::string &stem, RunFileKind &kind) {
    static const struct {
        const char *ext;
        RunFileKind kind;
    } kExts[] = {{".run", RunFileKind::Run}, {".json", RunFileKind::Output}, {".tmp", RunFileKind::Temp}};
    for (const auto &e : kExts) {
        if (!endsWith(name, e.ext)) continue;
        const std::string_view s = name.substr(0, name.size() - strlen(e.ext));
        if (!isRunStem(s)) return false;
        stem = std::string(s);
        kind = e.kind;
        return true;
    }
    return false;
}

std::string runFileName(const std::string &stem) {
    return stem + ".run";
}

std::string runOutputName(const std::string &stem) {
    return stem + ".json";
}

std::string runTempName(const std::string &stem) {
    return stem + ".tmp";
}

std::string newRunStem(std::chrono::system_clock::time_point now) {
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
    const time_t secs = (time_t)(ms / 1000);
    struct tm local;
    localtime_r(&secs, &local);
    char buf[64];
    snprintf(buf, sizeof buf, "%s%04d%02d%02d-%02d%02d%02d-%03d", kRunFilePrefix, local.tm_year + 1900,
             local.tm_mon + 1, local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec, (int)(ms % 1000));
    return buf;
}

std::string uniqueRunStem(const std::string &dir, std::chrono::system_clock::time_point now) {
    const std::string base = newRunStem(now);
    std::string stem = base;
    for (int n = 2; n <= 100; n++) {
        struct stat st;
        const bool taken = lstat(joinPath(dir, runFileName(stem)).c_str(), &st) == 0 ||
                           lstat(joinPath(dir, runOutputName(stem)).c_str(), &st) == 0 ||
                           lstat(joinPath(dir, runTempName(stem)).c_str(), &st) == 0;
        if (!taken) return stem;
        stem = base + "-" + std::to_string(n);
    }
    return stem;
}

// --- the run file ---

std::string formatRunFile(const RunFile &file) {
    @autoreleasepool {
        NSMutableArray *ids = [NSMutableArray array];
        for (const std::string &id : file.ids) [ids addObject:toNS(id)];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"format"] = @1;
        dict[@"command"] = file.command == CliCommand::Resume ? @"resume" : @"execute";
        if (!file.provisional) {
            dict[@"pid"] = @((long long)file.pid);
            dict[@"start_sec"] = @((unsigned long long)file.start.seconds);
            dict[@"start_usec"] = @((unsigned long long)file.start.micros);
        }
        dict[@"ids"] = ids;
        if (!file.rootPaths.empty() && file.rootPaths.size() == file.ids.size()) {
            NSMutableArray *paths = [NSMutableArray array];
            for (const std::string &p : file.rootPaths) [paths addObject:toNS(p)];
            dict[@"root_paths"] = paths;
        }
        dict[@"output"] = toNS(file.output);
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                       options:NSJSONWritingSortedKeys |
                                                               NSJSONWritingWithoutEscapingSlashes
                                                         error:nil];
        if (!data) return std::string();
        std::string out((const char *)data.bytes, data.length);
        out += "\n";
        return out;
    }
}

bool parseRunFile(std::string_view text, RunFile &out, std::string &error) {
    @autoreleasepool {
        id value = parseJsonValue(text);
        if (![value isKindOfClass:[NSDictionary class]]) {
            error = "not a JSON object";
            return false;
        }
        NSDictionary *d = value;
        long long format = 0;
        if (!jsonInteger(d[@"format"], 1, 1, format)) {
            error = "format is not 1";
            return false;
        }
        RunFile f;
        id command = d[@"command"];
        if ([command isEqual:@"execute"]) {
            f.command = CliCommand::Execute;
        } else if ([command isEqual:@"resume"]) {
            f.command = CliCommand::Resume;
        } else {
            error = "command is not execute or resume";
            return false;
        }
        long long pid = 0, sec = 0, usec = 0;
        const int present = (d[@"pid"] != nil) + (d[@"start_sec"] != nil) + (d[@"start_usec"] != nil);
        if (present == 0) {
            f.provisional = true;  // written before the spawn
        } else if (!jsonInteger(d[@"pid"], 2, INT32_MAX, pid)) {
            error = "pid is not an integer of 2 or more";
            return false;
        } else if (!jsonInteger(d[@"start_sec"], 1, LLONG_MAX, sec)) {
            error = "start_sec is not a positive integer";
            return false;
        } else if (!jsonInteger(d[@"start_usec"], 0, 999999, usec)) {
            error = "start_usec is not an integer from 0 to 999999";
            return false;
        }
        f.pid = (pid_t)pid;
        f.start.seconds = (uint64_t)sec;
        f.start.micros = (uint32_t)usec;
        NSArray *ids = d[@"ids"];
        if (![ids isKindOfClass:[NSArray class]] || ids.count == 0) {
            error = "ids is not a non-empty array";
            return false;
        }
        NSArray *paths = d[@"root_paths"];
        const bool usePaths = [paths isKindOfClass:[NSArray class]] && paths.count == ids.count;
        std::unordered_set<std::string> seen;
        for (NSUInteger i = 0; i < ids.count; i++) {
            id entry = ids[i];
            const std::string sid = [entry isKindOfClass:[NSString class]] ? fromNS(entry) : std::string();
            if (!isSidecarId(sid)) {
                error = "ids holds something that is not a sidecar id";
                return false;
            }
            if (!seen.insert(sid).second) continue;
            f.ids.push_back(sid);
            if (usePaths) {
                id path = paths[i];
                f.rootPaths.push_back([path isKindOfClass:[NSString class]] ? fromNS(path) : std::string());
            }
        }
        id output = d[@"output"];
        std::string stem;
        RunFileKind kind;
        if (![output isKindOfClass:[NSString class]] || !parseRunFileName(fromNS(output), stem, kind) ||
            kind != RunFileKind::Output) {
            error = "output is not an execute-<token>.json file name";
            return false;
        }
        f.output = fromNS(output);
        out = std::move(f);
        return true;
    }
}

bool writeRunFile(const std::string &dir, const std::string &stem, const RunFile &file, std::string &error) {
    if (!isRunStem(stem)) {
        error = "not a run stem: " + stem;
        return false;
    }
    const std::string text = formatRunFile(file);
    if (text.empty()) {
        error = "cannot format the run file";
        return false;
    }
    const std::string tmp = joinPath(dir, runTempName(stem));
    const std::string final = joinPath(dir, runFileName(stem));
    struct stat dirStat;
    if (!dir.empty() && lstat(dir.c_str(), &dirStat) != 0 && errno == ENOENT) {
        @autoreleasepool {
            NSError *mkdirError = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:toNS(dir)
                                           withIntermediateDirectories:YES
                                                            attributes:@{NSFilePosixPermissions : @0700}
                                                                 error:&mkdirError]) {
                error = "cannot create " + dir + ": " + fromNS(mkdirError.localizedDescription);
                return false;
            }
        }
    }
    int fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0 && errno == EEXIST && removeIfRegular(tmp)) {
        fd = ::open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    }
    if (fd < 0) {
        error = "cannot create " + tmp + ": " + strerror(errno);
        return false;
    }
    size_t done = 0;
    while (done < text.size()) {
        ssize_t n = ::write(fd, text.data() + done, text.size() - done);
        if (n > 0) {
            done += (size_t)n;
        } else if (n < 0 && errno != EINTR) {
            error = "cannot write " + tmp + ": " + strerror(errno);
            ::close(fd);
            ::unlink(tmp.c_str());
            return false;
        }
    }
    if (fsync(fd) != 0) {
        error = "cannot sync " + tmp + ": " + strerror(errno);
        ::close(fd);
        ::unlink(tmp.c_str());
        return false;
    }
    ::close(fd);
    if (::rename(tmp.c_str(), final.c_str()) != 0) {
        error = "cannot rename " + tmp + ": " + strerror(errno);
        ::unlink(tmp.c_str());
        return false;
    }
    return true;
}

// --- liveness ---

bool processIsLive(pid_t pid, const ProcessStartTime &start) {
    ProcessStartTime now;
    return readProcessStartTime(pid, now) && now == start;
}

namespace {

// `pid`'s stdout is the file `target` (same device and inode).
bool stdoutIs(pid_t pid, const struct stat &target) {
    struct vnode_fdinfowithpath info;
    const int n = proc_pidfdinfo(pid, STDOUT_FILENO, PROC_PIDFDVNODEPATHINFO, &info, sizeof info);
    if (n < (int)sizeof info) return false;
    return (dev_t)info.pvip.vip_vi.vi_stat.vst_dev == target.st_dev &&
           (ino_t)info.pvip.vip_vi.vi_stat.vst_ino == target.st_ino;
}

} // anonymous namespace

bool findOutputWriter(const std::string &path, pid_t &pidOut, ProcessStartTime &startOut) {
    struct stat target;
    if (stat(path.c_str(), &target) != 0) return false;
    std::vector<int> pids(1024);
    const int bytes = proc_listpidspath(PROC_UID_ONLY, getuid(), path.c_str(), PROC_LISTPIDSPATH_EXCLUDE_EVTONLY,
                                        pids.data(), (int)(pids.size() * sizeof(int)));
    if (bytes <= 0) return false;
    pids.resize(std::min(pids.size(), (size_t)bytes / sizeof(int)));
    std::sort(pids.begin(), pids.end());
    // The spawned CLI has the output as its stdout and leads its own
    // process group (IntakeProcess): rank those first, then any process
    // that has it open (a reader keeps the lane held, the safe side).
    int bestRank = 4;
    for (int pid : pids) {
        if (pid <= 1 || pid == getpid()) continue;
        ProcessStartTime start;
        if (!readProcessStartTime(pid, start)) continue;
        const int rank = (stdoutIs(pid, target) ? 0 : 2) + (getpgid(pid) == pid ? 0 : 1);
        if (rank >= bestRank) continue;
        bestRank = rank;
        pidOut = pid;
        startOut = start;
    }
    return bestRank < 4;
}

// --- leftovers ---

bool readRunOutput(const std::string &dir, const std::string &name, std::string &text, std::string &error) {
    return readCappedFile(joinPath(dir, name), kMaxOutputBytes, text, error);
}

size_t deleteRunFiles(const std::string &dir, const std::string &stem) {
    if (!isRunStem(stem)) return 0;
    size_t n = 0;
    for (const std::string &name : {runFileName(stem), runOutputName(stem), runTempName(stem)}) {
        if (removeIfRegular(joinPath(dir, name))) n++;
    }
    return n;
}

LeftoverScan scanLeftoverRuns(const std::string &dir, const LivenessCheck &live, const OutputWriterLookup &writer) {
    LeftoverScan scan;
    DIR *d = opendir(dir.c_str());
    if (!d) {
        if (errno != ENOENT) scan.error = "cannot list " + dir + ": " + strerror(errno);
        return scan;
    }
    struct Files {
        bool run = false;
        bool output = false;
        bool temp = false;
    };
    std::map<std::string, Files> stems;  // name order
    while (struct dirent *entry = readdir(d)) {
        std::string stem;
        RunFileKind kind;
        if (!parseRunFileName(entry->d_name, stem, kind)) continue;
        if (!isRegularFile(joinPath(dir, entry->d_name))) continue;  // never a directory or a symlink
        Files &f = stems[stem];
        if (kind == RunFileKind::Run) f.run = true;
        if (kind == RunFileKind::Output) f.output = true;
        if (kind == RunFileKind::Temp) f.temp = true;
    }
    closedir(d);

    auto sweep = [&](const std::string &name, const std::string &why) {
        if (removeIfRegular(joinPath(dir, name))) {
            scan.swept.push_back(name);
            scan.notes.push_back(name + ": " + why);
        }
    };

    for (const auto &entry : stems) {
        const std::string &stem = entry.first;
        const Files &f = entry.second;
        if (!f.run) {
            if (f.output) sweep(runOutputName(stem), "an output file with no run file");
            if (f.temp) sweep(runTempName(stem), "a temporary file with no run file");
            continue;
        }
        std::string text, error;
        RunFile file;
        bool ok = readCappedFile(joinPath(dir, runFileName(stem)), kMaxRunFileBytes, text, error) &&
                  parseRunFile(text, file, error);
        if (ok && file.output != runOutputName(stem)) {
            ok = false;
            error = "it names another output file (" + file.output + ")";
        }
        if (!ok) {
            const std::string why = "unusable run file (" + error + ")";
            sweep(runFileName(stem), why);
            if (f.output) sweep(runOutputName(stem), "the output of an " + why);
            if (f.temp) sweep(runTempName(stem), "a temporary file of an " + why);
            continue;
        }
        if (f.temp) sweep(runTempName(stem), "a stale temporary file next to its run file");
        LeftoverRun run;
        run.stem = stem;
        run.file = file;
        if (file.provisional) {
            // Written before the spawn: live while a process has the output
            // open; no output means the CLI never started.
            if (!f.output) {
                sweep(runFileName(stem), "a run file written before a start that never happened (no output)");
                continue;
            }
            pid_t pid = 0;
            ProcessStartTime start;
            if (writer && writer(joinPath(dir, runOutputName(stem)), pid, start)) {
                run.file.pid = pid;
                run.file.start = start;
                run.byOutput = true;
                scan.adopt.push_back(std::move(run));
                continue;
            }
        } else if (live && live(file.pid, file.start)) {
            scan.adopt.push_back(std::move(run));
            continue;
        }
        if (f.output) {
            if (!readRunOutput(dir, file.output, run.output, run.outputError)) run.output.clear();
        } else {
            run.outputError = "no output file";
        }
        scan.finish.push_back(std::move(run));
    }
    return scan;
}

// --- results ---

EnvelopeResult parseDetachedOutput(std::string_view text, const std::string &readError) {
    if (!readError.empty()) return hostNoCli("the run left no readable output (" + readError + ")");
    bool blank = true;
    for (char c : text) {
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') {
            blank = false;
            break;
        }
    }
    if (blank) return hostNoCli("the run left no result (empty output; it may have been stopped)");
    int exitCode = 0;
    @autoreleasepool {
        id value = parseJsonValue(text);
        if ([value isKindOfClass:[NSDictionary class]]) {
            id ok = ((NSDictionary *)value)[@"ok"];
            id data = ((NSDictionary *)value)[@"data"];
            if ([ok isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)ok) == CFBooleanGetTypeID()) {
                if ([ok boolValue]) {
                    exitCode = 0;
                } else {
                    // As parseEnvelope's exit 2: data null, or an empty array.
                    const bool noData = data == nil || data == [NSNull null] ||
                                        ([data isKindOfClass:[NSArray class]] && [(NSArray *)data count] == 0);
                    exitCode = noData ? 2 : 1;
                }
            }
        }
    }
    return parseEnvelope(text, exitCode);
}

RunSummary summarizeRun(CliCommand command, const std::vector<MutationRoot> &roots, const EnvelopeResult &envelope) {
    RunSummary summary;
    if (command != CliCommand::Resume ||
        (envelope.outcome != CliOutcome::Ok && envelope.outcome != CliOutcome::Partial) ||
        ![envelope.data isKindOfClass:[NSArray class]]) {
        summary.outcome = summarizeMutation(command, roots, envelope);
        return summary;
    }
    std::unordered_set<std::string> named;
    for (const MutationRoot &r : roots) named.insert(r.id);
    EnvelopeResult adjusted = envelope;
    NSMutableArray *kept = [NSMutableArray array];
    for (id row in (NSArray *)envelope.data) {
        if ([row isKindOfClass:[NSDictionary class]]) {
            id rid = ((NSDictionary *)row)[@"id"];
            id resumed = ((NSDictionary *)row)[@"resumed"];
            if ([rid isKindOfClass:[NSString class]] && [resumed isEqual:@"reverted_to_approved"]) {
                const std::string sid = fromNS(rid);
                // Not one of ours: dropped, never broadcast.
                if (named.count(sid) &&
                    std::find(summary.reverted.begin(), summary.reverted.end(), sid) == summary.reverted.end()) {
                    summary.reverted.push_back(sid);
                    CliError e;
                    e.code = kRevertedCode;
                    e.msg = kResumeRevertedText;
                    e.path = sid;  // a named id: that root's error only (IntakeMutationResult rule 1)
                    e.hasPath = true;
                    adjusted.errors.push_back(e);
                }
                continue;
            }
        }
        [kept addObject:row];
    }
    if (!summary.reverted.empty()) {
        adjusted.data = kept;
        adjusted.outcome = kept.count > 0 ? CliOutcome::Partial : CliOutcome::Failed;
    }
    summary.outcome = summarizeMutation(command, roots, adjusted);
    return summary;
}

// --- the tracker ---

TrackedRun *ExecuteTracker::findMutable(const std::string &stem) {
    for (TrackedRun &r : runs_) {
        if (r.stem == stem) return &r;
    }
    return nullptr;
}

const TrackedRun *ExecuteTracker::find(const std::string &stem) const {
    for (const TrackedRun &r : runs_) {
        if (r.stem == stem) return &r;
    }
    return nullptr;
}

bool ExecuteTracker::begin(const std::string &stem, CliCommand command, std::vector<std::string> ids,
                           std::vector<std::string> rootPaths) {
    if (stem.empty() || ids.empty() || find(stem) != nullptr) return false;
    TrackedRun r;
    r.stem = stem;
    r.command = command;
    r.state = RunState::Starting;
    r.ids = std::move(ids);
    if (rootPaths.size() == r.ids.size()) r.rootPaths = std::move(rootPaths);
    runs_.push_back(std::move(r));
    return true;
}

bool ExecuteTracker::spawned(const std::string &stem, pid_t pid, const ProcessStartTime &start) {
    TrackedRun *r = findMutable(stem);
    if (r == nullptr || r->state != RunState::Starting || pid <= 0) return false;
    r->state = RunState::Running;
    r->pid = pid;
    r->start = start;
    return true;
}

bool ExecuteTracker::adopt(const std::string &stem, const RunFile &file) {
    if (stem.empty() || file.ids.empty() || find(stem) != nullptr) return false;
    TrackedRun r;
    r.stem = stem;
    r.command = file.command;
    r.state = RunState::Adopted;
    r.pid = file.pid;
    r.start = file.start;
    r.ids = file.ids;
    if (file.rootPaths.size() == file.ids.size()) r.rootPaths = file.rootPaths;
    runs_.push_back(std::move(r));
    return true;
}

bool ExecuteTracker::exited(const std::string &stem) {
    TrackedRun *r = findMutable(stem);
    if (r == nullptr || (r->state != RunState::Running && r->state != RunState::Adopted)) return false;
    r->state = RunState::Exited;
    return true;
}

bool ExecuteTracker::remove(const std::string &stem) {
    auto it = std::find_if(runs_.begin(), runs_.end(), [&stem](const TrackedRun &r) { return r.stem == stem; });
    if (it == runs_.end()) return false;
    runs_.erase(it);
    return true;
}

std::vector<std::string> ExecuteTracker::liveRunIds() const {
    std::vector<std::string> out;
    for (const TrackedRun &r : runs_) {
        for (const std::string &id : r.ids) {
            if (std::find(out.begin(), out.end(), id) == out.end()) out.push_back(id);
        }
    }
    return out;
}

// --- ProcessExitWatch ---

struct ProcessExitWatch::State {
    std::atomic<bool> done{false};
    dispatch_source_t source = nil;  // set once in the constructor
    std::function<void()> onExit;
    pid_t pid = 0;

    // On the watch's queue. Exactly once, unless cancelled first.
    // `exitSeen`: the source reported the exit, so a child of ours is a
    // zombie now (or about to be) and waitpid may block for it; after the
    // liveness check only WNOHANG, since a live process that merely failed
    // the start-time comparison must never be waited for. A pid that is not
    // our child fails with ECHILD at once either way.
    void fire(bool exitSeen) {
        if (done.exchange(true)) return;
        dispatch_source_cancel(source);
        int status = 0;
        while (waitpid(pid, &status, exitSeen ? 0 : WNOHANG) < 0 && errno == EINTR) {
        }
        std::function<void()> handler = std::move(onExit);
        onExit = nullptr;
        if (handler) handler();
    }
};

ProcessExitWatch::ProcessExitWatch(pid_t pid, const ProcessStartTime &start, dispatch_queue_t queue,
                                   std::function<void()> onExit, LivenessCheck live)
    : pid_(pid), state_(std::make_shared<State>()) {
    if (!queue) queue = dispatch_get_main_queue();
    std::shared_ptr<State> state = state_;
    state->pid = pid;
    state->onExit = std::move(onExit);
    state->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, queue);
    dispatch_source_set_event_handler(state->source, ^{
        state->fire(true);
    });
    dispatch_resume(state->source);
    // A process that ended before the source was armed, or whose pid now
    // belongs to another process, is reported now.
    const ProcessStartTime expected = start;
    LivenessCheck check = live ? live : LivenessCheck(processIsLive);
    dispatch_async(queue, ^{
        if (state->done.load()) return;
        if (!check(state->pid, expected)) state->fire(false);
    });
}

ProcessExitWatch::~ProcessExitWatch() {
    cancel();
}

void ProcessExitWatch::cancel() {
    if (state_->done.exchange(true)) return;
    dispatch_source_cancel(state_->source);
    // The handler is released on the queue; dropping it here is enough to
    // keep it from running (done is set).
}

} // namespace intake
