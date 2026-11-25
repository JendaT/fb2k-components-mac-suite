//
//  IntakeAutoScanDriver.mm
//  foo_jl_intake
//
//  See IntakeAutoScanDriver.h. Everything in DriverState is main-thread
//  only, except the snapshot (main writes, the watcher's queue reads, under
//  snapshotMutex) and presenceQueue (set once).
//

#import <Foundation/Foundation.h>

#include "IntakeAutoScanDriver.h"

#include "IntakeActions.h"
#include "IntakeMounts.h"

#include "../Core/IntakeCapabilities.h"
#include "../Core/IntakeLog.h"

#include <sys/stat.h>

#include <chrono>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace intake {

namespace {

using Clock = AutoScanScheduler::Clock;
using TimePoint = AutoScanScheduler::TimePoint;

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

// PLAN-B12 step 5 fills this in. Main thread, from a wakeup that found an
// income due with the lane free (stopped already checked). It is to take
// next(now, actionsLaneFree()), run checkPresence on presenceQueue with a
// fresh readMountTable(), then on the main thread re-check stopped and
// wanted(token), take LaneHolder::Scan and start the scan on the mutation
// lane (IntakeActions), and end every path with scheduler.exit(token, ...)
// followed by scheduleWakeup(). A wakeup that calls this arms nothing
// itself (the scheduler would still report the same income due), so until
// it starts something a due income waits for the next change.
void autoScanStartDue() {}

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
    // hits.passedMutes: PLAN-B12 step 6 removes those mutes here.
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
