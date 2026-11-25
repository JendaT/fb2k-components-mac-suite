//
//  IntakeAutoScanDriver.mm
//  foo_jl_intake
//
//  See IntakeAutoScanDriver.h. Everything in DriverState is main-thread
//  only, except the snapshot (main writes, the watcher's queue reads, under
//  snapshotMutex) and presenceQueue (set once).
//

#import <Foundation/Foundation.h>

#include <CoreServices/CoreServices.h>  // FSEventsGetCurrentEventId

#include "IntakeAutoScanDriver.h"

#include "IntakeActions.h"
#include "IntakeMounts.h"

#include "../Core/IntakeCapabilities.h"
#include "../Core/IntakeLog.h"

#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace intake {

namespace {

using Clock = AutoScanScheduler::Clock;
using TimePoint = AutoScanScheduler::TimePoint;

// How long an ended gc mute stays when no later event passes it.
constexpr double kMuteLingerSeconds = 10 * 60;

// What the sink matches one callback against. Immutable once published: a
// sink call keeps the one it took, and its post hands that same one to
// noteHits (hits name incomes by index into it).
struct AutoScanSnapshot {
    std::vector<AutoScanIncome> incomes;  // empty while auto-scan is off, the CLI has no scan, or after quit
    std::vector<AutoScanMute> mutes;      // gc's (PLAN-B12 step 6)
};

// Leaked on purpose: sink posts, presence results and wakeups may arrive
// after on_quit.
struct DriverState {
    DriverState() {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_UTILITY, 0);
        presenceQueue = dispatch_queue_create("com.foobar2000.intake.autoscan", attr);
    }

    // main
    AutoScanScheduler scheduler;
    std::vector<AutoScanIncome> incomes;  // the scheduler's: the last load's, none while the CLI has no scan
    std::vector<AutoScanMute> mutes;      // in force (PLAN-B12 step 6)
    bool stopped = false;                 // after autoScanShutdown (on_quit)
    bool statusSeen = false;              // a load attempt has ended
    bool scanOffered = false;             // its CLI lists `scan`
    std::string cliVersion;               // its `cli`, for the Info line below
    bool notOfferedLogged = false;        // that Info line, once per session
    bool startupConsidered = false;       // the session's first Ready load has come
    uint64_t wakeGeneration = 0;          // the armed wakeup; older ones do nothing
    std::optional<TimePoint> armedFor;    // when it fires; none: nothing armed
    uint64_t nextMuteId = 1;              // the next gc mute's handle

    // Set once above, then used from main.
    dispatch_queue_t presenceQueue = nil;

    // main writes, the watcher's queue reads
    std::mutex snapshotMutex;
    std::shared_ptr<const AutoScanSnapshot> snapshot = std::make_shared<const AutoScanSnapshot>();
};

DriverState &driver() {
    static DriverState *state = new DriverState();
    return *state;
}

std::shared_ptr<const AutoScanSnapshot> currentSnapshot() {
    DriverState &d = driver();
    std::lock_guard<std::mutex> lock(d.snapshotMutex);
    return d.snapshot;
}

// Main: what the sink matches from now on.
void publishSnapshot(DriverState &d) {
    auto next = std::make_shared<AutoScanSnapshot>();
    if (!d.stopped) {
        if (d.scheduler.enabled()) next->incomes = d.incomes;
        next->mutes = d.mutes;
    }
    std::lock_guard<std::mutex> lock(d.snapshotMutex);
    d.snapshot = std::move(next);
}

// Main: the CLI has no `scan` (one Info line per session, only while
// auto_scan is on: off, nothing would be scanned anyway).
void logNotOffered(DriverState &d) {
    if (d.notOfferedLogged || !d.statusSeen || d.scanOffered || !d.scheduler.enabled()) return;
    d.notOfferedLogged = true;
    logInfo("auto-scan: the CLI" + (d.cliVersion.empty() ? std::string() : " " + d.cliVersion) +
            " does not offer scan; income folders are not scanned automatically");
}

// Utility queue only (presenceQueue): never the main thread or the watcher's
// queue. The mount table decides first; nothing at or under a network mount
// is examined (classifyIncome); a local folder gets one lstat.
IncomeCheck checkPresence(const AutoScanIncome &income, const std::vector<MountEntry> &mounts) {
    static const LinkReader reader = &posixLinkReader;
    IncomeCheck check = classifyIncome(income.path, mounts, reader);
    if (check.presence != IncomePresence::Local) return check;
    struct stat st;
    if (::lstat(check.resolved.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) check.presence = IncomePresence::Missing;
    return check;
}

void scheduleWakeup(DriverState &d);

// Main: the job on `token` has ended (`how`); the next wakeup follows.
void endJob(DriverState &d, uint64_t token, const std::string &name, AutoScanExit how) {
    const AutoScanResult result = d.scheduler.exit(token, how, Clock::now());
    if (result == AutoScanResult::Disabled) {
        logInfo("auto-scan: income " + name +
                " is not scanned automatically again this session (its scan was stopped at the 15-minute cap)");
    } else if (result == AutoScanResult::Pending && how != AutoScanExit::LaneTaken) {
        logDebug("auto-scan: new files in income " + name + " during its scan; scanning it again once they "
                 "stopped for 60 s");
    }
    scheduleWakeup(d);
}

// Main, from IntakeActions: the scan on `token` ended (its lane is free,
// its line logged, its refresh asked for). Never after on_quit.
void onScanExit(uint64_t token, const std::string &name, AutoScanExit how) {
    DriverState &d = driver();
    if (d.stopped) return;
    endJob(d, token, name, how);
}

// Main: the presence check of `job` is back.
void afterPresence(const AutoScanJob &job, IncomePresence presence) {
    DriverState &d = driver();
    if (d.stopped) return;
    const uint64_t token = job.token;
    const std::string name = job.income.name;
    if (!d.scheduler.wanted(token)) {
        // Turned off, or the income removed, during the check: exit()
        // forgets it (whatever the exit), and nothing starts.
        endJob(d, token, name, AutoScanExit::Missing);
        return;
    }
    if (presence == IncomePresence::Missing) {
        logDebug("auto-scan: income " + name + " is missing or not mounted; not scanned");
        endJob(d, token, name, AutoScanExit::Missing);
        return;
    }
    switch (actionsStartAutoScan(job, [token, name](AutoScanExit how) { onScanExit(token, name, how); })) {
        case AutoScanStart::Started:
            // Same main-queue turn as wanted() above, so this holds; the
            // exit comes later, through onScanExit, which reschedules.
            d.scheduler.started(token);
            return;
        case AutoScanStart::LaneTaken:
            endJob(d, token, name, AutoScanExit::LaneTaken);  // retried 5 s after the lane is seen busy
            return;
        case AutoScanStart::Refused:
            endJob(d, token, name, AutoScanExit::Refused);
            return;
    }
}

// Main thread, from a wakeup that found an income due with the lane free
// (stopped already checked; the wakeup arms nothing after calling this).
// The presence check runs on presenceQueue with a fresh mount table; its
// result comes back to afterPresence, which starts the scan or ends the job.
// Every path ends with the scheduler's exit and scheduleWakeup (endJob).
void autoScanStartDue() {
    DriverState &d = driver();
    std::optional<AutoScanJob> next = d.scheduler.next(Clock::now(), actionsLaneFree());
    if (!next) {
        scheduleWakeup(d);  // not due after all: the next change, or the retry, arms one
        return;
    }
    auto job = std::make_shared<const AutoScanJob>(std::move(*next));
    dispatch_async(d.presenceQueue, ^{
        const std::vector<MountEntry> mounts = readMountTable();
        const IncomePresence presence = checkPresence(job->income, mounts).presence;
        dispatch_async(dispatch_get_main_queue(), ^{
            afterPresence(*job, presence);
        });
    });
}

void onWakeup(uint64_t generation) {
    DriverState &d = driver();
    if (d.stopped || generation != d.wakeGeneration) return;
    d.armedFor.reset();
    const TimePoint now = Clock::now();
    const std::optional<TimePoint> at = d.scheduler.nextWakeup(now, actionsLaneFree());
    if (!at) return;  // nothing pending any more, or a job in flight (its exit reschedules)
    if (*at > now) {
        // Not due yet (later events postponed it), or due with the lane
        // busy (the 5 s retry).
        scheduleWakeup(d);
        return;
    }
    autoScanStartDue();
}

// Main: arms the wakeup at the scheduler's nextWakeup, unless one is armed
// for that time or earlier (it re-checks when it fires).
void scheduleWakeup(DriverState &d) {
    if (d.stopped) return;
    const TimePoint now = Clock::now();
    const std::optional<TimePoint> at = d.scheduler.nextWakeup(now, actionsLaneFree());
    if (!at) return;
    if (d.armedFor && *d.armedFor <= *at) return;
    const uint64_t generation = ++d.wakeGeneration;
    d.armedFor = *at;
    int64_t nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(*at - now).count();
    if (nanos < 0) nanos = 0;
    // The wall clock: a timer on the uptime clock would not count the time
    // the Mac slept, while the scheduler's steady_clock does.
    dispatch_after(dispatch_walltime(nullptr, nanos), dispatch_get_main_queue(), ^{
        onWakeup(generation);
    });
}

// Main: one sink post. `snapshot` is the one the hits were found in.
void noteHits(const AutoScanHits &hits, const AutoScanSnapshot &snapshot) {
    DriverState &d = driver();
    if (d.stopped) return;
    // A mute an event of this callback is past: FSEvents delivers in id
    // order, so nothing it mutes can follow.
    if (!hits.passedMutes.empty()) {
        const size_t before = d.mutes.size();
        d.mutes.erase(std::remove_if(d.mutes.begin(), d.mutes.end(),
                                     [&hits](const AutoScanMute &m) {
                                         return std::find(hits.passedMutes.begin(), hits.passedMutes.end(),
                                                          m.id) != hits.passedMutes.end();
                                     }),
                      d.mutes.end());
        if (d.mutes.size() != before) publishSnapshot(d);
    }
    if (hits.incomes.empty() && hits.paths.empty()) return;
    std::vector<std::string> fresh;  // incomes that were idle until now
    if (isLogEnabled(LogLevel::Debug)) {
        for (size_t index : hits.incomes) {
            if (index < snapshot.incomes.size() &&
                d.scheduler.state(snapshot.incomes[index].name) == AutoScanScheduler::State::Idle) {
                fresh.push_back(snapshot.incomes[index].name);
            }
        }
    }
    d.scheduler.noteHits(hits, snapshot.incomes, Clock::now());
    for (const std::string &name : fresh) {
        if (d.scheduler.state(name) != AutoScanScheduler::State::Pending) continue;  // disabled, or off
        logDebug("auto-scan: new files in income " + name + "; scanning it once they stopped for 60 s");
    }
    scheduleWakeup(d);
}

// Main, once per session (after the first Ready load and the leftover-run
// scan): every local income folder is due for one scan at once.
void startupCheck() {
    DriverState &d = driver();
    if (d.stopped || !d.scheduler.enabled() || d.incomes.empty()) return;
    auto incomes = std::make_shared<const std::vector<AutoScanIncome>>(d.incomes);
    dispatch_async(d.presenceQueue, ^{
        const std::vector<MountEntry> mounts = readMountTable();
        auto local = std::make_shared<std::vector<std::string>>();
        for (const AutoScanIncome &income : *incomes) {
            const IncomeCheck check = checkPresence(income, mounts);
            if (check.presence == IncomePresence::Local) local->push_back(income.name);
            logDebug("auto-scan: startup: income " + income.name + " is " + incomePresenceText(check.presence) +
                     (check.presence == IncomePresence::Local     ? std::string(": scanning it once")
                      : check.presence == IncomePresence::Network ? std::string(": scanned on new files only")
                                                                  : std::string(": not scanned")));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            DriverState &main = driver();
            if (main.stopped || !main.scheduler.enabled() || local->empty()) return;
            main.scheduler.noteStartup(*local, Clock::now());
            scheduleWakeup(main);
        });
    });
}

// Main: the gc mute `id` goes (passed by a later event, or 10 min after
// gc exited).
void removeMute(uint64_t id) {
    DriverState &d = driver();
    if (d.stopped) return;
    const size_t before = d.mutes.size();
    d.mutes.erase(std::remove_if(d.mutes.begin(), d.mutes.end(), [id](const AutoScanMute &m) { return m.id == id; }),
                  d.mutes.end());
    if (d.mutes.size() != before) publishSnapshot(d);
}

} // anonymous namespace

void autoScanSink(const std::vector<AutoScanEvent> &events) {
    std::shared_ptr<const AutoScanSnapshot> snapshot = currentSnapshot();
    if (snapshot->incomes.empty() && snapshot->mutes.empty()) return;
    auto hits = std::make_shared<const AutoScanHits>(autoScanHits(events, snapshot->incomes, snapshot->mutes));
    if (hits->empty()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        noteHits(*hits, *snapshot);
    });
}

void autoScanAfterLoad(const LoaderStatus &status) {
    DriverState &d = driver();
    if (d.stopped) return;
    d.statusSeen = true;
    d.scanOffered = cliSupportsCommand(status.cliInfo, CliCommand::Scan);
    d.cliVersion = status.cliInfo.cli;
    if (status.state == LoaderState::Ready) logNotOffered(d);
    // Without `scan` the scheduler and the sink get no incomes: nothing is
    // counted, scheduled or scanned.
    d.incomes = d.scanOffered ? status.autoScanIncomes : std::vector<AutoScanIncome>();
    d.scheduler.setIncomes(d.incomes);
    publishSnapshot(d);
    if (status.state == LoaderState::Ready && !d.startupConsidered) {
        d.startupConsidered = true;
        // After the leftover-run scan: a live execute run found there holds
        // the lane first, and the scans wait for it.
        if (d.scheduler.enabled() && !d.incomes.empty()) actionsAfterRunScan([] { startupCheck(); });
    }
    scheduleWakeup(d);
}

void autoScanSetEnabled(bool enabled) {
    DriverState &d = driver();
    if (d.stopped || d.scheduler.enabled() == enabled) return;
    d.scheduler.setEnabled(enabled);
    publishSnapshot(d);
    if (enabled) {
        logNotOffered(d);
        scheduleWakeup(d);
    }
}

uint64_t autoScanMuteGc(const std::vector<std::string> &rootPaths) {
    DriverState &d = driver();
    if (d.stopped) return 0;
    AutoScanMute mute;
    mute.paths = autoScanMutePaths(rootPaths, d.incomes);
    if (mute.paths.empty()) return 0;
    mute.id = d.nextMuteId++;
    // Before gc is dispatched: every event of its renames has a later id.
    mute.startId = FSEventsGetCurrentEventId();
    d.mutes.push_back(mute);
    publishSnapshot(d);
    logDebug("auto-scan: gc on " + std::to_string(mute.paths.size()) +
             " folder(s) in income folders: their events are no arrivals from event id " +
             std::to_string(mute.startId) + " until gc exits");
    return mute.id;
}

void autoScanUnmuteGc(uint64_t muteId) {
    DriverState &d = driver();
    if (d.stopped || muteId == 0) return;
    auto it = std::find_if(d.mutes.begin(), d.mutes.end(), [muteId](const AutoScanMute &m) { return m.id == muteId; });
    if (it == d.mutes.end() || it->endId != kWatchSinceNow) return;
    // gc has exited: its events all have this id or an earlier one.
    it->endId = FSEventsGetCurrentEventId();
    publishSnapshot(d);
    // The first later event removes it (noteHits); with none, this does.
    dispatch_after(dispatch_walltime(nullptr, static_cast<int64_t>(kMuteLingerSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       removeMute(muteId);
                   });
}

void autoScanShutdown() {
    DriverState &d = driver();
    if (d.stopped) return;
    d.scheduler.setEnabled(false);  // Pending dropped, a job in flight dropped at its exit
    d.stopped = true;
    d.wakeGeneration++;  // an armed wakeup does nothing
    d.armedFor.reset();
    d.incomes.clear();
    d.mutes.clear();
    publishSnapshot(d);  // empty: the sink matches nothing
}

} // namespace intake
