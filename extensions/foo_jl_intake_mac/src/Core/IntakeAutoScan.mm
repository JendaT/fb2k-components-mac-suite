//
//  IntakeAutoScan.mm
//  foo_jl_intake
//

#include "IntakeAutoScan.h"

#include "IntakePath.h"
#include "IntakeSettingsParse.h"  // lexicalAbsolutePath

#include <CoreServices/CoreServices.h>  // the flag values only (static_assert below)

#include <algorithm>

namespace intake {

static_assert(fsevent::kMustScanSubDirs == kFSEventStreamEventFlagMustScanSubDirs, "FSEvents flag");
static_assert(fsevent::kUserDropped == kFSEventStreamEventFlagUserDropped, "FSEvents flag");
static_assert(fsevent::kKernelDropped == kFSEventStreamEventFlagKernelDropped, "FSEvents flag");
static_assert(fsevent::kEventIdsWrapped == kFSEventStreamEventFlagEventIdsWrapped, "FSEvents flag");
static_assert(fsevent::kHistoryDone == kFSEventStreamEventFlagHistoryDone, "FSEvents flag");
static_assert(fsevent::kMount == kFSEventStreamEventFlagMount, "FSEvents flag");
static_assert(fsevent::kUnmount == kFSEventStreamEventFlagUnmount, "FSEvents flag");
static_assert(fsevent::kItemCreated == kFSEventStreamEventFlagItemCreated, "FSEvents flag");
static_assert(fsevent::kItemRemoved == kFSEventStreamEventFlagItemRemoved, "FSEvents flag");
static_assert(fsevent::kItemRenamed == kFSEventStreamEventFlagItemRenamed, "FSEvents flag");
static_assert(fsevent::kItemModified == kFSEventStreamEventFlagItemModified, "FSEvents flag");
static_assert(fsevent::kItemIsFile == kFSEventStreamEventFlagItemIsFile, "FSEvents flag");
static_assert(fsevent::kItemIsDir == kFSEventStreamEventFlagItemIsDir, "FSEvents flag");
static_assert(fsevent::kItemCloned == kFSEventStreamEventFlagItemCloned, "FSEvents flag");

namespace {

constexpr uint32_t kRescanFlags = fsevent::kMustScanSubDirs | fsevent::kUserDropped | fsevent::kKernelDropped;
constexpr uint32_t kCountFlags = fsevent::kItemCreated | fsevent::kItemRenamed | fsevent::kItemModified;
// A clone is complete when it appears (Created|Cloned, never a Modified
// after it), so Cloned closes like a write.
constexpr uint32_t kCloseFlags =
    fsevent::kItemModified | fsevent::kItemRenamed | fsevent::kItemRemoved | fsevent::kItemCloned;
constexpr uint32_t kItemChangeFlags = kCountFlags | fsevent::kItemRemoved;

char asciiLower(char c) {
    return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c;
}

// `key` equals `base` or lies under it ('/' boundary), ignoring ASCII case
// (as IntakeWatchSet.mm).
bool isUnderIgnoringCase(std::string_view key, std::string_view base) {
    if (base.empty()) return false;
    if (base == "/") return !key.empty() && key[0] == '/';
    if (key.size() < base.size() || (key.size() > base.size() && key[base.size()] != '/')) return false;
    for (size_t i = 0; i < base.size(); i++) {
        if (asciiLower(key[i]) != asciiLower(base[i])) return false;
    }
    return true;
}

bool startsWith(std::string_view lower, std::string_view prefix) {
    return lower.size() >= prefix.size() && lower.compare(0, prefix.size(), prefix) == 0;
}

bool endsWith(std::string_view lower, std::string_view suffix) {
    return lower.size() >= suffix.size() && lower.compare(lower.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string keyFor(std::string_view path) {
    std::string key;
    if (normalizePath(path, key) != PathStatus::Ok) key.clear();
    return key;
}

// The income with the longest fsKey holding `key`, or -1.
long longestIncome(std::string_view key, const std::vector<AutoScanIncome> &incomes) {
    long best = -1;
    size_t bestLength = 0;
    for (size_t i = 0; i < incomes.size(); i++) {
        const std::string &base = incomes[i].fsKey;
        if (!isUnderIgnoringCase(key, base)) continue;
        if (best < 0 || base.size() > bestLength) {
            best = static_cast<long>(i);
            bestLength = base.size();
        }
    }
    return best;
}

// Some component of `relative` (the part of a key below an income folder,
// "" or starting with '/') is ignored.
bool relativeIgnored(std::string_view relative) {
    size_t start = 0;
    while (start < relative.size()) {
        size_t end = relative.find('/', start);
        if (end == std::string_view::npos) end = relative.size();
        if (end > start && autoScanIgnoredName(relative.substr(start, end - start))) return true;
        start = end + 1;
    }
    return false;
}

struct MuteKeys {
    const AutoScanMute *mute;
    std::vector<std::string> keys;
};

bool muted(std::string_view key, WatchEventId id, const std::vector<MuteKeys> &mutes) {
    for (const MuteKeys &m : mutes) {
        if (id <= m.mute->startId) continue;
        if (m.mute->endId != kWatchSinceNow && id > m.mute->endId) continue;
        for (const std::string &base : m.keys) {
            if (isUnderIgnoringCase(key, base)) return true;
        }
    }
    return false;
}

} // anonymous namespace

std::vector<AutoScanIncome> autoScanIncomes(const std::vector<IncomeFolder> &folders, const WatchSet &set) {
    std::vector<AutoScanIncome> out;
    for (const IncomeFolder &f : folders) {
        if (f.name.empty()) continue;
        const std::string clean = lexicalAbsolutePath(f.path);
        if (clean.empty()) continue;
        bool seen = false;
        for (const AutoScanIncome &i : out) seen = seen || i.name == f.name;
        if (seen) continue;
        AutoScanIncome income;
        income.name = f.name;
        income.path = f.path;
        income.fsPath = clean;
        for (const WatchSet::Entry &e : set.entries()) {
            if (e.original == clean) {
                income.fsPath = e.fsPath;
                income.fsKey = e.fsKey;
                break;
            }
        }
        if (income.fsKey.empty()) income.fsKey = keyFor(income.fsPath);
        if (income.fsKey.empty()) continue;
        out.push_back(std::move(income));
    }
    return out;
}

bool autoScanIgnoredName(std::string_view name) {
    if (name.empty()) return false;
    std::string lower(name);
    for (char &c : lower) c = asciiLower(c);
    // CLI files (sidecars, doc 05's hint file) and gc's staging folders.
    if (startsWith(lower, ".intake") && endsWith(lower, ".json")) return true;
    if (startsWith(lower, ".intake-gc-")) return true;
    // Finder, AppleDouble, Foundation's atomic-write temp files, and the
    // CLI's junk names (util.ts JUNK_FILES, JUNK_DIRS).
    if (lower == ".ds_store" || startsWith(lower, "._") || startsWith(lower, ".dat.nosync")) return true;
    if (lower == "thumbs.db" || lower == "desktop.ini" || lower == "@eadir" || lower == ".appledouble" ||
        lower == "__macosx") {
        return true;
    }
    // Downloads still in progress.
    for (std::string_view suffix : {".part", ".tmp", ".download", ".crdownload", ".incomplete"}) {
        if (endsWith(lower, suffix)) return true;
    }
    // scan's own archive output (archive.ts: <x>.unpacked.partial, renamed
    // to <x>.unpacked).
    return endsWith(lower, ".unpacked") || endsWith(lower, ".unpacked.partial");
}

AutoScanHits autoScanHits(const std::vector<AutoScanEvent> &events, const std::vector<AutoScanIncome> &incomes,
                          const std::vector<AutoScanMute> &mutes) {
    AutoScanHits hits;
    if (incomes.empty() && mutes.empty()) return hits;

    std::vector<MuteKeys> muteKeys;
    muteKeys.reserve(mutes.size());
    for (const AutoScanMute &m : mutes) {
        MuteKeys mk{&m, {}};
        for (const std::string &p : m.paths) {
            std::string key = keyFor(p);
            if (!key.empty() && key != "/") mk.keys.push_back(std::move(key));
        }
        muteKeys.push_back(std::move(mk));
    }

    std::vector<bool> counted(incomes.size(), false);
    std::unordered_map<std::string, size_t> pathIndex;  // key -> index into hits.paths
    WatchEventId maxId = 0;
    bool anyId = false;
    std::string key;

    for (const AutoScanEvent &ev : events) {
        if (ev.flags & (fsevent::kHistoryDone | fsevent::kEventIdsWrapped)) continue;
        if (!anyId || ev.id > maxId) maxId = ev.id;
        anyId = true;
        // A share mounting or unmounting is no arrival, whatever else the
        // event carries.
        if (ev.flags & (fsevent::kMount | fsevent::kUnmount)) continue;

        key.clear();
        const bool haveKey = !ev.path.empty() && normalizePath(ev.path, key) == PathStatus::Ok;

        if (ev.flags & kRescanFlags) {
            if (!haveKey) {
                // Events lost somewhere unknown: every income may have new files.
                for (size_t i = 0; i < incomes.size(); i++) counted[i] = true;
                continue;
            }
            const long holder = longestIncome(key, incomes);
            if (holder >= 0) {
                const std::string_view relative = std::string_view(key).substr(incomes[holder].fsKey.size());
                if (!relativeIgnored(relative) && !muted(key, ev.id, muteKeys)) counted[holder] = true;
            }
            for (size_t i = 0; i < incomes.size(); i++) {
                const std::string &base = incomes[i].fsKey;
                if (base.size() > key.size() && isUnderIgnoringCase(base, key)) counted[i] = true;
            }
            continue;
        }

        if (!haveKey || !(ev.flags & kItemChangeFlags)) continue;
        const long holder = longestIncome(key, incomes);
        if (holder < 0) continue;
        const std::string_view relative = std::string_view(key).substr(incomes[holder].fsKey.size());
        if (relativeIgnored(relative) || muted(key, ev.id, muteKeys)) continue;

        if (ev.flags & kCountFlags) counted[holder] = true;

        const bool file = (ev.flags & fsevent::kItemIsFile) && !(ev.flags & fsevent::kItemIsDir);
        if (!file) continue;
        const bool closes = (ev.flags & kCloseFlags) != 0;
        const bool opens = !closes && (ev.flags & fsevent::kItemCreated);
        if (!opens && !closes) continue;
        auto it = pathIndex.find(key);
        if (it == pathIndex.end()) {
            pathIndex.emplace(key, hits.paths.size());
            hits.paths.push_back(AutoScanPathChange{static_cast<size_t>(holder), key, opens});
        } else {
            hits.paths[it->second].open = opens;
        }
    }

    for (size_t i = 0; i < incomes.size(); i++) {
        if (counted[i]) hits.incomes.push_back(i);
    }
    if (anyId) {
        for (const AutoScanMute &m : mutes) {
            if (m.endId != kWatchSinceNow && maxId > m.endId) hits.passedMutes.push_back(m.id);
        }
    }
    return hits;
}

std::vector<std::string> autoScanMutePaths(const std::vector<std::string> &rootPaths,
                                           const std::vector<AutoScanIncome> &incomes) {
    std::vector<std::string> pathKeys;  // each income's `path` as a key ("" when it has none)
    pathKeys.reserve(incomes.size());
    for (const AutoScanIncome &income : incomes) pathKeys.push_back(keyFor(income.path));
    std::vector<std::string> out;
    for (const std::string &root : rootPaths) {
        const std::string key = keyFor(root);
        if (key.empty()) continue;
        long best = -1;
        for (size_t i = 0; i < incomes.size(); i++) {
            if (incomes[i].fsKey.empty() || !isUnderIgnoringCase(key, pathKeys[i])) continue;
            if (best < 0 || pathKeys[i].size() > pathKeys[static_cast<size_t>(best)].size()) {
                best = static_cast<long>(i);
            }
        }
        if (best < 0) continue;
        const std::string &base = pathKeys[static_cast<size_t>(best)];
        const std::string &fsKey = incomes[static_cast<size_t>(best)].fsKey;
        // `base` "/" keeps the root's whole key (its '/' boundary is the first byte).
        const std::string rest = base == "/" ? key : key.substr(base.size());
        const std::string muted = fsKey == "/" ? (rest.empty() ? fsKey : rest) : fsKey + rest;
        if (std::find(out.begin(), out.end(), muted) == out.end()) out.push_back(muted);
    }
    return out;
}

IncomeCheck classifyIncome(const std::string &path, const std::vector<MountEntry> &mounts, const LinkReader &readLink) {
    IncomeCheck out;
    const std::string clean = lexicalAbsolutePath(path);
    if (clean.empty() || !readLink) return out;
    ResolveEnd end = ResolveEnd::Missing;
    out.resolved = resolveLocalPath(clean, mounts, readLink, nullptr, &end);
    switch (end) {
        case ResolveEnd::Complete:
            out.presence = IncomePresence::Local;
            break;
        case ResolveEnd::Network: {
            // The walk stopped where the mount table refuses an lstat: a
            // mounted share, or no table at all (then nothing is known).
            const MountEntry *m = mountHolding(out.resolved, mounts);
            out.presence = m != nullptr && isNetworkMount(*m) ? IncomePresence::Network : IncomePresence::Missing;
            break;
        }
        case ResolveEnd::Missing:
        case ResolveEnd::Loop:
            out.presence = IncomePresence::Missing;
            break;
    }
    return out;
}

const char *incomePresenceText(IncomePresence presence) {
    switch (presence) {
        case IncomePresence::Local: return "local";
        case IncomePresence::Network: return "on a network volume";
        case IncomePresence::Missing: return "missing";
    }
    return "";
}

// --- AutoScanScheduler ---

AutoScanScheduler::Entry *AutoScanScheduler::find(const std::string &name) {
    for (Entry &e : entries_) {
        if (e.income.name == name) return &e;
    }
    return nullptr;
}

const AutoScanScheduler::Entry *AutoScanScheduler::find(const std::string &name) const {
    for (const Entry &e : entries_) {
        if (e.income.name == name) return &e;
    }
    return nullptr;
}

void AutoScanScheduler::makeIdle(Entry &e) {
    e.state = State::Idle;
    e.startup = false;
    e.eventsDuringRun = false;
}

bool AutoScanScheduler::due(const Entry &e, TimePoint now) const {
    return e.startup || now - e.lastEvent >= kQuietPeriod;
}

bool AutoScanScheduler::held(const Entry &e, TimePoint now) const {
    for (const auto &open : e.openPaths) {
        if (now - open.second < kOpenFileCap) return true;
    }
    return false;
}

void AutoScanScheduler::pruneOpenPaths(Entry &e, TimePoint now) {
    for (auto it = e.openPaths.begin(); it != e.openPaths.end();) {
        if (now - it->second >= kOpenFileCap) {
            it = e.openPaths.erase(it);
        } else {
            ++it;
        }
    }
}

void AutoScanScheduler::setIncomes(const std::vector<AutoScanIncome> &incomes) {
    std::vector<Entry> next;
    next.reserve(incomes.size());
    for (const AutoScanIncome &income : incomes) {
        if (income.name.empty()) continue;
        bool seen = false;
        for (const Entry &e : next) seen = seen || e.income.name == income.name;
        if (seen) continue;
        Entry *old = find(income.name);
        if (old != nullptr && old->income.path == income.path) {
            Entry kept = std::move(*old);
            // Another spelling on disk: open paths were recorded in the old one.
            if (kept.income.fsKey != income.fsKey) kept.openPaths.clear();
            kept.income = income;
            next.push_back(std::move(kept));
        } else {
            Entry fresh;
            fresh.income = income;
            next.push_back(std::move(fresh));
        }
    }
    // A job whose income is gone (or moved) is forgotten when it exits.
    if (job_ && !job_->dropped) {
        bool kept = false;
        for (const Entry &e : next) {
            kept = kept || (e.income.name == job_->name && (e.state == State::Checking || e.state == State::Running));
        }
        if (!kept) job_->dropped = true;
    }
    entries_ = std::move(next);
}

void AutoScanScheduler::setEnabled(bool enabled) {
    enabled_ = enabled;
    if (enabled) return;
    for (Entry &e : entries_) {
        e.openPaths.clear();
        e.eventsDuringRun = false;  // events before this never count again
        if (e.state == State::Pending) makeIdle(e);
    }
    if (job_) job_->dropped = true;
}

void AutoScanScheduler::noteHits(const AutoScanHits &hits, const std::vector<AutoScanIncome> &incomes,
                                 TimePoint now) {
    if (!enabled_) return;
    auto entryFor = [&](size_t index) -> Entry * {
        if (index >= incomes.size()) return nullptr;
        Entry *e = find(incomes[index].name);
        if (e == nullptr || e->disabled || e->income.path != incomes[index].path) return nullptr;
        return e;
    };
    for (size_t index : hits.incomes) {
        Entry *e = entryFor(index);
        if (e == nullptr) continue;
        switch (e->state) {
            case State::Idle:
                e->state = State::Pending;
                e->pendingSince = now;
                break;
            case State::Pending:
                break;
            case State::Checking:
            case State::Running:
                e->eventsDuringRun = true;
                break;
        }
        // Later events postpone the scan, a startup entry's too (a copy in
        // progress at startup is not scanned halfway).
        e->lastEvent = now;
        e->startup = false;
    }
    for (const AutoScanPathChange &change : hits.paths) {
        Entry *e = entryFor(change.income);
        if (e == nullptr) continue;
        if (change.open) {
            e->openPaths.emplace(change.path, now);  // a path already open keeps its first time
        } else {
            e->openPaths.erase(change.path);
        }
    }
}

void AutoScanScheduler::noteStartup(const std::vector<std::string> &names, TimePoint now) {
    if (!enabled_) return;
    for (const std::string &name : names) {
        Entry *e = find(name);
        // Pending already: its own quiet period runs. Checking or Running:
        // the scan in flight covers it.
        if (e == nullptr || e->disabled || e->state != State::Idle) continue;
        e->state = State::Pending;
        e->startup = true;
        e->pendingSince = now;
        e->lastEvent = now;
    }
}

std::optional<AutoScanJob> AutoScanScheduler::next(TimePoint now, bool laneFree) {
    if (!enabled_ || job_ || !laneFree) return std::nullopt;
    Entry *best = nullptr;
    for (Entry &e : entries_) {
        if (e.state != State::Pending || e.disabled) continue;
        pruneOpenPaths(e, now);
        if (!due(e, now) || held(e, now)) continue;
        if (best == nullptr || e.pendingSince < best->pendingSince) best = &e;
    }
    if (best == nullptr) return std::nullopt;
    best->state = State::Checking;
    best->eventsDuringRun = false;
    Job job;
    job.token = nextToken_++;
    job.name = best->income.name;
    job.startup = best->startup;
    job_ = job;
    AutoScanJob out;
    out.token = job.token;
    out.income = best->income;
    out.startup = job.startup;
    return out;
}

bool AutoScanScheduler::wanted(uint64_t token) const {
    return token != 0 && job_ && job_->token == token && !job_->dropped;
}

bool AutoScanScheduler::started(uint64_t token) {
    if (!wanted(token)) return false;
    Entry *e = find(job_->name);
    if (e == nullptr || e->state != State::Checking) return false;
    e->state = State::Running;
    return true;
}

AutoScanResult AutoScanScheduler::exit(uint64_t token, AutoScanExit how, TimePoint now) {
    if (token == 0 || !job_ || job_->token != token) return AutoScanResult::Stale;
    const Job job = *job_;
    job_.reset();
    Entry *e = find(job.name);
    // Only the job's own entry: a removed income re-added under the same
    // name is a new entry (Idle or Pending), never the job's.
    const bool own = e != nullptr && (e->state == State::Checking || e->state == State::Running);
    if (job.dropped || !own) {
        if (own) {
            // Turned off and on again during the job: events since then
            // still get their scan.
            if (enabled_ && e->eventsDuringRun) {
                e->state = State::Pending;
                e->startup = false;
                e->eventsDuringRun = false;
                e->pendingSince = now;
            } else {
                makeIdle(*e);
            }
        }
        return AutoScanResult::Dropped;
    }
    switch (how) {
        case AutoScanExit::LaneTaken:
            // Retried as it was: still due, a startup entry still at once,
            // unless events came during the check (noteHits made it wait
            // for their quiet period, so a copy in progress is not scanned
            // halfway).
            e->state = State::Pending;
            e->startup = job.startup && !e->eventsDuringRun;
            return AutoScanResult::Pending;
        case AutoScanExit::CapKilled:
            makeIdle(*e);
            e->disabled = true;
            e->openPaths.clear();
            return AutoScanResult::Disabled;
        case AutoScanExit::Missing:
        case AutoScanExit::Refused:
        case AutoScanExit::Finished:
            break;
    }
    if (e->eventsDuringRun) {
        // One more run, 60 s after the latest event (lastEvent).
        e->state = State::Pending;
        e->startup = false;
        e->eventsDuringRun = false;
        e->pendingSince = now;
        return AutoScanResult::Pending;
    }
    makeIdle(*e);
    return AutoScanResult::Idle;
}

std::optional<AutoScanScheduler::TimePoint> AutoScanScheduler::nextWakeup(TimePoint now, bool laneFree) const {
    if (!enabled_ || job_) return std::nullopt;
    std::optional<TimePoint> earliest;
    for (const Entry &e : entries_) {
        if (e.state != State::Pending || e.disabled) continue;
        TimePoint at = e.startup ? e.pendingSince : e.lastEvent + kQuietPeriod;
        for (const auto &open : e.openPaths) {
            if (now - open.second < kOpenFileCap) at = std::max(at, open.second + kOpenFileCap);
        }
        if (!earliest || at < *earliest) earliest = at;
    }
    if (!earliest) return std::nullopt;
    if (*earliest > now) return earliest;
    return laneFree ? now : now + kLaneRetry;
}

AutoScanScheduler::State AutoScanScheduler::state(const std::string &name) const {
    const Entry *e = find(name);
    return e != nullptr ? e->state : State::Idle;
}

bool AutoScanScheduler::disabled(const std::string &name) const {
    const Entry *e = find(name);
    return e != nullptr && e->disabled;
}

size_t AutoScanScheduler::openPathCount(const std::string &name) const {
    const Entry *e = find(name);
    return e != nullptr ? e->openPaths.size() : 0;
}

} // namespace intake
