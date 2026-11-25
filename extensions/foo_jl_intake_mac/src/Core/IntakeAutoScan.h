//
//  IntakeAutoScan.h
//  foo_jl_intake
//
//  B12: the component runs `intake scan <income>` by itself when new music
//  lands in an income folder. This file is the pure part: which FSEvents
//  events count (autoScanHits), whether an income folder is local, on a
//  mounted share or missing (classifyIncome), and when which income is
//  scanned (AutoScanScheduler). Integration (IntakeAutoScanDriver, wired by
//  IntakeService; the lane in IntakeActions) feeds them from the watcher's
//  sink, the loader, a utility queue and the mutation lane, and runs the
//  scans; nothing here touches a file.
//
//  Income entries (AutoScanIncome, autoScanIncomes): the name and path from
//  `intake income --json`, plus the spelling FSEvents reports for that
//  folder: the loader's WatchSet entry for it (resolved symlinks on a local
//  disk, e.g. /var -> /private/var; as written on a share). The loader
//  builds them where it builds the WatchSet, on its own queue, because the
//  resolution reads the disk.
//
//  The filter (autoScanHits), over one FSEvents callback:
//   - An event belongs to the income with the longest fsPath that holds it
//     at a '/' boundary, ASCII case ignored (FSEvents reports the case on
//     disk), compared as IntakePath keys (NFC). The income folder itself
//     counts.
//   - It counts when it has Created, Renamed or Modified. An event with
//     none of them (only Removed, or only metadata such as xattrs) does
//     not count.
//   - MustScanSubDirs, UserDropped or KernelDropped (events FSEvents could
//     not deliver one by one) count for the income holding the event path
//     and for every income under it; an empty event path counts for every
//     income. Mount and Unmount never count (a share mounting is not an
//     arrival), nor does HistoryDone or EventIdsWrapped (markers).
//   - Ignored, with everything under them (autoScanIgnoredName on every
//     component below the income folder, ASCII case ignored): sidecars and
//     other CLI files `.intake*.json`; `.DS_Store`, `._*`, `.dat.nosync*`
//     (Foundation's atomic-write temp files), and the CLI's junk names
//     `Thumbs.db`, `desktop.ini`, `@eaDir`, `.AppleDouble`, `__MACOSX`;
//     partial downloads ending in `.part`, `.tmp`, `.download`,
//     `.crdownload`, `.incomplete`; scan's own archive output `*.unpacked`
//     and `*.unpacked.partial`, and gc's staging folders `.intake-gc-*`.
//     Without the last group every scan that unpacks an archive, and every
//     gc, would schedule the next scan.
//   - Muted (AutoScanMute): an event at or under a mute path whose event id
//     is after the mute's start id and at or before its end id (any id
//     after the start while the end is not known yet). gc renames income
//     files into its staging folder, and those renames at the old paths
//     would look like arrivals. Event ids order exactly, even when the
//     watcher's queue delivers late. A mute whose end id is known is
//     reported in `passedMutes` once an event in the callback has a later
//     id: FSEvents delivers in id order, so nothing muted can follow.
//   - Open files: FSEvents reports a file's content change when the writer
//     closes it, so a file event with Created and none of Modified, Renamed,
//     Removed or Cloned means a file still being written (open). A later
//     file event for the path with any of those closes it. A clone (`cp -c`,
//     ditto, a Finder copy within one APFS volume) arrives as Created|Cloned
//     and never gets a Modified: its content is complete when it appears, so
//     it never opens. Only files open (ItemIsFile without ItemIsDir): a new
//     folder is never written to.
//     Ignored and muted events neither count nor open or close a path.
//   - Each income is reported once per callback, so a bulk copy posts once.
//
//  Presence (classifyIncome): resolveLocalPath walks the income path with
//  the link reader, never past a network mount point (the mount table
//  decides first). A walk that finished is a folder on a local disk (the
//  caller then makes one local lstat for S_ISDIR on `resolved`); one that
//  stopped at a network mount is on a share when the mount table holds it
//  under a mounted network filesystem, and missing otherwise (no table);
//  one that stopped at a missing component (an unmounted share's mount
//  point, an absent folder) or in a symlink loop is missing. Nothing is
//  examined under a share.
//
//  The scheduler (AutoScanScheduler), per income: Idle, Pending, Checking
//  (the presence check runs), Running (the scan runs). Time is injected
//  (steady_clock time points), so tests use fake clocks.
//   - noteHits: Idle -> Pending; a Pending income waits again for 60 s of
//     quiet after the latest event; an income Checking or Running notes
//     that events came during its run. Open and closed paths are tracked
//     per income.
//   - noteStartup (once per session, the local incomes): an Idle income
//     becomes Pending and due at once. A Pending one already waits for its
//     own quiet period, and later events make a startup entry wait too.
//   - next(now, laneFree): the oldest Pending income (by when it became
//     Pending, then income order) that is due (60 s quiet, or a startup
//     entry), has no open file younger than 30 min, and is not disabled,
//     while no income is Checking or Running and the lane is free (lane
//     not busy, the leftover-run scan done, no Execute follow-up pending;
//     Integration decides). It moves to Checking under a new token.
//   - Exits (exit(token, how, now)), every one of them ends the job:
//       Missing (presence check)        -> Idle
//       LaneTaken (after the check)     -> Pending, retried
//       Refused (startCliCommand false,
//                or E_NO_CLI)           -> Idle
//       Finished (any outcome)          -> Idle
//       CapKilled (15-min cap)          -> Idle and disabled for the session
//     Missing, Refused and Finished go to Pending instead when events came
//     during the job (exactly one more run, 60 s after the latest event).
//     started(token) moves Checking to Running.
//   - setEnabled(false) (the auto_scan setting off): Pending incomes go
//     Idle, their open paths forgotten, and hits are ignored until it is on
//     again; a job Checking or Running is dropped when its exit arrives
//     (wanted() is false meanwhile, so a checked job is not started), and
//     only events noted after auto-scan was turned on again give its
//     income one more run. setEnabled(true) starts nothing: the next event
//     does.
//   - setIncomes (every load): incomes are matched by name and path; a new
//     one starts Idle, a removed one (or one whose path changed) is
//     forgotten, and its job, if any, is dropped when the exit arrives.
//   - nextWakeup: when to call next() again: the earliest quiet-period end
//     or open-file cap of a Pending income, or 5 s from now while the lane
//     is busy and one is due; none while a job is in flight (its exit
//     reschedules), while off, or with nothing Pending.
//
//  Thread-safety: autoScanHits, autoScanIgnoredName and autoScanIncomes are
//  pure; classifyIncome runs `readLink` on the calling thread (a utility
//  queue, never main or the watcher's queue). AutoScanScheduler: none, one
//  owner (the main thread).
//

#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "IntakeIncome.h"       // IncomeFolder
#include "IntakeWatchFilter.h"  // WatchEventId, kWatchSinceNow
#include "IntakeWatchSet.h"     // MountEntry, LinkReader, WatchSet

namespace intake {

// FSEventStreamEventFlags bits the filter reads, copied from FSEvents.h so
// this module needs no CoreServices (IntakeAutoScan.mm checks them).
namespace fsevent {
inline constexpr uint32_t kMustScanSubDirs = 0x00000001;
inline constexpr uint32_t kUserDropped = 0x00000002;
inline constexpr uint32_t kKernelDropped = 0x00000004;
inline constexpr uint32_t kEventIdsWrapped = 0x00000008;
inline constexpr uint32_t kHistoryDone = 0x00000010;
inline constexpr uint32_t kMount = 0x00000040;
inline constexpr uint32_t kUnmount = 0x00000080;
inline constexpr uint32_t kItemCreated = 0x00000100;
inline constexpr uint32_t kItemRemoved = 0x00000200;
inline constexpr uint32_t kItemRenamed = 0x00000800;
inline constexpr uint32_t kItemModified = 0x00001000;
inline constexpr uint32_t kItemIsFile = 0x00010000;
inline constexpr uint32_t kItemIsDir = 0x00020000;
inline constexpr uint32_t kItemCloned = 0x00400000;
} // namespace fsevent

struct AutoScanIncome {
    std::string name;    // from `income --json`
    std::string path;    // from `income --json` (the CLI's spelling): the presence check, and scan's
                         // argument for a name starting with '-'
    std::string fsPath;  // the WatchSet spelling (WatchSet::Entry::fsPath): what FSEvents reports
    std::string fsKey;   // IntakePath key of fsPath (WatchSet::Entry::fsKey)
};

// One entry per income folder with a name and an absolute path, in order,
// the first of two with the same name kept. fsPath/fsKey come from the
// WatchSet entry built from that path (matched by its lexically clean
// spelling); an income the set does not hold keeps that clean spelling.
std::vector<AutoScanIncome> autoScanIncomes(const std::vector<IncomeFolder> &folders, const WatchSet &set);

// One FSEvents event. `path` is valid for the call only (the callback's).
struct AutoScanEvent {
    std::string_view path;
    uint32_t flags = 0;   // FSEventStreamEventFlags
    WatchEventId id = 0;  // FSEventStreamEventId
};

// gc's renames under `paths` (physical spellings, as FSEvents reports them)
// are no arrivals: see the top of this file.
struct AutoScanMute {
    uint64_t id = 0;                     // the caller's handle, echoed in passedMutes
    std::vector<std::string> paths;      // folders muted with everything under them
    WatchEventId startId = 0;            // FSEventsGetCurrentEventId() before gc was dispatched
    WatchEventId endId = kWatchSinceNow; // the same after it exited; kWatchSinceNow while it runs
};

struct AutoScanPathChange {
    size_t income = 0;  // index into the incomes given to autoScanHits
    std::string path;   // the event path as an IntakePath key
    bool open = false;  // true: created and not closed; false: closed
};

struct AutoScanHits {
    std::vector<size_t> incomes;            // indices into the incomes given, ascending, each once
    std::vector<AutoScanPathChange> paths;  // the last open or close per path, first-seen order
    std::vector<uint64_t> passedMutes;      // mutes an event of this callback is past: remove them
    bool empty() const { return incomes.empty() && paths.empty() && passedMutes.empty(); }
};

// True for a name the filter ignores, with everything under it (see the
// top of this file); `name` is one path component.
bool autoScanIgnoredName(std::string_view name);

// One callback's events against the incomes and mutes (see the top of this
// file). Pure string work: no filesystem access.
AutoScanHits autoScanHits(const std::vector<AutoScanEvent> &events, const std::vector<AutoScanIncome> &incomes,
                          const std::vector<AutoScanMute> &mutes);

// gc's root folders (`rootPaths`, the CLI's spelling from `status`) in the
// spelling FSEvents reports, for an AutoScanMute: each root under an
// income's `path` (the longest one; IntakePath keys, ASCII case ignored)
// becomes that income's fsKey plus the rest of the root's key. A root under
// no income is left out (its events never count anyway), and so is a
// repeat. Pure string work.
std::vector<std::string> autoScanMutePaths(const std::vector<std::string> &rootPaths,
                                           const std::vector<AutoScanIncome> &incomes);

enum class IncomePresence {
    Local,   // on a local disk, every component examined; the caller lstat()s `resolved` for S_ISDIR
    Network, // on a mounted network filesystem: never examined
    Missing, // an absent component, an unmounted share, a loop, or no mount table
};

struct IncomeCheck {
    IncomePresence presence = IncomePresence::Missing;
    std::string resolved;  // the path as far as resolveLocalPath took it
};

// See the top of this file. `readLink` runs only where mayResolvePath
// allows; an empty function or a path that is not absolute is Missing.
IncomeCheck classifyIncome(const std::string &path, const std::vector<MountEntry> &mounts, const LinkReader &readLink);

// "local", "on a network volume" or "missing", for log lines.
const char *incomePresenceText(IncomePresence presence);

// A scan next() hands out.
struct AutoScanJob {
    uint64_t token = 0;
    AutoScanIncome income;
    bool startup = false;  // the startup scan (for the log line), else new files
};

enum class AutoScanExit {
    Missing,   // the presence check found the folder missing or unmounted
    LaneTaken, // present, but the lane was taken before the scan could start
    Refused,   // startCliCommand refused it, or it ended with E_NO_CLI
    Finished,  // the scan exited (any other outcome)
    CapKilled, // the runner killed it at the 15-minute cap
};

enum class AutoScanResult {
    Stale,    // not the job in flight: nothing changed
    Dropped,  // the income was removed, or auto-scan turned off, meanwhile: forgotten
    Idle,
    Pending,  // retried (LaneTaken), or events came during the job
    Disabled, // CapKilled: no more scans of this income this session
};

class AutoScanScheduler {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;

    static constexpr std::chrono::seconds kQuietPeriod{60};
    static constexpr std::chrono::minutes kOpenFileCap{30};
    static constexpr std::chrono::seconds kLaneRetry{5};

    enum class State : uint8_t { Idle, Pending, Checking, Running };

    // See the top of this file.
    void setIncomes(const std::vector<AutoScanIncome> &incomes);
    void setEnabled(bool enabled);
    bool enabled() const { return enabled_; }

    // `incomes`: the list autoScanHits ran against (hits name incomes by
    // index into it); an income it names is found here by name and path.
    void noteHits(const AutoScanHits &hits, const std::vector<AutoScanIncome> &incomes, TimePoint now);
    void noteStartup(const std::vector<std::string> &names, TimePoint now);

    std::optional<AutoScanJob> next(TimePoint now, bool laneFree);
    // The job is in flight under `token` and not dropped.
    bool wanted(uint64_t token) const;
    // Checking -> Running. False when `token` is not a wanted job Checking:
    // do not start it, end it with exit() (Dropped or Stale).
    bool started(uint64_t token);
    AutoScanResult exit(uint64_t token, AutoScanExit how, TimePoint now);

    std::optional<TimePoint> nextWakeup(TimePoint now, bool laneFree) const;

    // For tests and log lines. An unknown income is Idle, not disabled,
    // with no open path.
    State state(const std::string &name) const;
    bool disabled(const std::string &name) const;
    size_t openPathCount(const std::string &name) const;
    bool busy() const { return job_.has_value(); }

private:
    struct Entry {
        AutoScanIncome income;
        State state = State::Idle;
        bool startup = false;          // Pending from noteStartup: due at once
        bool eventsDuringRun = false;  // hits while Checking or Running
        bool disabled = false;         // CapKilled
        TimePoint pendingSince{};
        TimePoint lastEvent{};
        std::unordered_map<std::string, TimePoint> openPaths;  // key -> when it opened
    };
    struct Job {
        uint64_t token = 0;
        std::string name;
        bool startup = false;
        bool dropped = false;
    };

    Entry *find(const std::string &name);
    const Entry *find(const std::string &name) const;
    bool due(const Entry &e, TimePoint now) const;
    bool held(const Entry &e, TimePoint now) const;
    void pruneOpenPaths(Entry &e, TimePoint now);
    void makeIdle(Entry &e);

    std::vector<Entry> entries_;  // income order
    std::optional<Job> job_;
    uint64_t nextToken_ = 1;
    bool enabled_ = true;
};

} // namespace intake
