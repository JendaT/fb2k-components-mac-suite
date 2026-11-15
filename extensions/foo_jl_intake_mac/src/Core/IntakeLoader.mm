//
//  IntakeLoader.mm
//  foo_jl_intake
//

#include "IntakeLoader.h"

#include "IntakeCapabilities.h"
#include "IntakeCliRunner.h"
#include "IntakeIncome.h"
#include "IntakeLog.h"
#include "IntakePath.h"
#include "IntakeStatusModel.h"
#include "IntakeVersionGate.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <unordered_map>

namespace intake {

namespace {

using Clock = std::chrono::steady_clock;

std::string secondsText(double seconds) {
    char buf[32];
    snprintf(buf, sizeof buf, "%.2f s", seconds);
    return buf;
}

bool sameMountEntries(const std::vector<MountEntry> &a, const std::vector<MountEntry> &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (a[i].mountPoint != b[i].mountPoint || a[i].source != b[i].source || a[i].fsType != b[i].fsType ||
            a[i].local != b[i].local) {
            return false;
        }
    }
    return true;
}

void appendUnique(std::vector<std::string> &into, const std::vector<std::string> &from) {
    for (const std::string &s : from) {
        if (std::find(into.begin(), into.end(), s) == into.end()) into.push_back(s);
    }
}

// The parent folder of every root, lexically clean, sorted, each once.
std::vector<std::string> rootFoldersOf(const std::shared_ptr<const IntakeSnapshot> &snapshot) {
    std::vector<std::string> out;
    if (!snapshot) return out;
    out.reserve(snapshot->size());
    for (const IntakeRecord &rec : snapshot->records()) {
        std::string parent = parentDirectory(lexicalAbsolutePath(rec.rootPath));
        if (!parent.empty()) out.push_back(std::move(parent));
    }
    std::sort(out.begin(), out.end());
    out.erase(std::unique(out.begin(), out.end()), out.end());
    return out;
}

const char *stopName(MemberLoadStop stop) {
    switch (stop) {
        case MemberLoadStop::None: return "none";
        case MemberLoadStop::Cancelled: return "cancelled";
        case MemberLoadStop::Deadline: return "deadline";
        case MemberLoadStop::ShareUnreachable: return "share unreachable";
    }
    return "unknown";
}

} // anonymous namespace

struct IntakeLoader::Impl : std::enable_shared_from_this<IntakeLoader::Impl> {
    explicit Impl(LoaderSettings s) : settings(std::move(s)) {
        files = settings.files ? settings.files : &posixSidecarFileAccess();
        // Every block (loads, CLI completions) gets its own autorelease
        // pool: the envelope, gate, status and sidecar parsers build
        // Foundation objects.
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.foobar2000.intake.loader", attr);
    }

    LoaderSettings settings;     // settings.cli is loader-queue state
    SidecarFileAccess *files = nullptr;
    dispatch_queue_t queue = nil;
    ProcessRunner runner;
    std::atomic<bool> stopped{false};  // also the member load's cancel flag

    // Loader queue only.
    // Bumped by reconfigure(): a CLI result or timer of an older generation
    // belongs to the previous settings and is discarded.
    uint64_t generation = 0;
    bool loading = false;
    bool again = false;
    bool againRecheck = false;
    bool needVersion = true;
    bool everLoaded = false;
    bool gateFailed = false;  // the last `version` that answered failed the gate
    bool mountsRead = false;
    bool notConfiguredLogged = false;
    std::shared_ptr<const MountAliases> aliases = MountAliases::none();
    std::shared_ptr<const IntakeSnapshot> lastGood;  // the last successful load (keys rebuilt on remount)
    std::shared_ptr<const IntakeView> published;
    Clock::time_point loadStart;

    // B4, loader queue only.
    std::vector<MountEntry> mountEntries;     // the last table read (remount or watch set)
    std::vector<std::string> incomePaths;     // the last good `income` call
    std::vector<IncomeFolder> incomeFolders;  // the same call, for the status (B5)
    bool incomeOffered = false;               // the last passing `version` listed `income`
    std::string incomeError;                  // why the last `income` call failed; "" after a good one
    WatchSet watchSet;                        // the last one built
    std::vector<std::string> watchInputs;     // the candidates it was built from
    bool watchBuilt = false;
    bool watchDirty = true;                   // the mount table changed since
    std::vector<std::string> watchHandedOver; // the last onWatchSet paths
    bool watchHandedOverOnce = false;
    bool pendingFull = true;                  // the next load lists everything
    std::vector<std::string> pendingKeys;     // changed directories for the next load
    bool inFlightFull = true;                 // the running load's
    std::vector<std::string> inFlightKeys;
    bool memberPassRan = false;               // the running load reached its member pass
    bool parseRetryArmed = false;             // the 1 s E_PARSE retry timer is set
    std::vector<std::string> parseRetryKeys;  // folders of the unreadable sidecars, as match keys
    bool pendingParseRetry = false;           // the next load is that retry
    bool inFlightParseRetry = false;          // the running load is
    CliVersionInfo cliInfo;                   // the last passing `version` (B6), for the status
    WatchEventId statusEventId = kWatchSinceNow; // taken before the latest `status` call
    bool statusSinceRequest = false;          // a `status` call started after the latest reload()

    // B5, loader queue only: reload() requests waiting for their load.
    std::vector<LoadFinishedHandler> waitersNext;     // served by the next load to start
    std::vector<LoadFinishedHandler> waitersInFlight; // served by the running load

    mutable std::mutex statusMutex;
    LoaderStatus status;

    // --- status ---

    void setStatus(LoaderState state, std::string error = std::string(), size_t partialErrors = 0) {
        LoaderStatus s;
        s.state = state;
        s.cliVersion = settings.cli.cliVersion;
        s.roots = lastGood ? lastGood->size() : 0;
        s.error = std::move(error);
        s.partialErrors = partialErrors;
        s.incomeOffered = incomeOffered;
        s.incomeFolders = incomeFolders;
        s.incomeError = incomeError;
        s.rootFolders = rootFoldersOf(lastGood);
        s.cliInfo = cliInfo;
        {
            std::lock_guard<std::mutex> lock(statusMutex);
            if (status.state == LoaderState::Stopped) return;
            status = s;
        }
        if (settings.onStatusChanged) settings.onStatusChanged(s);
    }

    LoaderStatus currentStatus() const {
        std::lock_guard<std::mutex> lock(statusMutex);
        return status;
    }

    // --- loads ---

    void serveWaiters() {
        if (waitersInFlight.empty()) return;
        std::vector<LoadFinishedHandler> waiters = std::move(waitersInFlight);
        waitersInFlight.clear();
        const LoaderStatus s = currentStatus();
        for (const LoadFinishedHandler &w : waiters) w(s);
    }

    void requestLoad(bool recheck, LoadFinishedHandler served = nullptr) {
        if (stopped) return;
        if (served) waitersNext.push_back(std::move(served));
        pendingFull = true;
        statusSinceRequest = false;
        if (loading) {
            again = true;
            againRecheck = againRecheck || recheck;
            return;
        }
        if (recheck) needVersion = true;
        startLoad();
    }

    // An FSEvents batch: the directories become match keys through the
    // watch set and the aliases the stream was built with.
    void requestChangeLoad(const std::vector<std::string> &directories, bool rescan) {
        if (stopped) return;
        size_t unmapped = 0;
        if (rescan) {
            pendingFull = true;
        } else {
            std::vector<std::string> keys;
            for (const std::string &dir : directories) {
                if (!watchSet.mapEventDirectory(dir, *aliases, keys)) unmapped++;
            }
            if (unmapped) pendingFull = true;
            appendUnique(pendingKeys, keys);
        }
        if (isLogEnabled(LogLevel::Debug)) {
            std::string line = "watch: changes in " + std::to_string(directories.size()) + " folder(s)";
            if (rescan) line += ", rescan requested";
            if (unmapped) line += ", " + std::to_string(unmapped) + " outside the watched folders";
            line += loading ? "; one more load after the running one" : "; reloading";
            logDebug(line);
        }
        if (loading) {
            again = true;
            return;
        }
        startLoad();
    }

    void startLoad() {
        if (!mountsRead) readMounts(false);
        // The requests made before this attempt are the ones it serves.
        for (LoadFinishedHandler &w : waitersNext) waitersInFlight.push_back(std::move(w));
        waitersNext.clear();
        if (settings.cli.cliPath.empty()) {
            if (!notConfiguredLogged) {
                logInfo("not configured: foo_jl_intake.cli_path is empty, so no CLI runs and nothing is decorated");
                notConfiguredLogged = true;
            }
            setStatus(LoaderState::NotConfigured);
            // Nothing can reload without a CLI: the watch set empties (a
            // cleared CLI path stops watching the last load's folders).
            updateWatchSet();
            if (settings.onLoadFinished) settings.onLoadFinished(currentStatus());
            serveWaiters();
            return;
        }
        notConfiguredLogged = false;
        loading = true;
        loadStart = Clock::now();
        inFlightFull = pendingFull;
        inFlightKeys = std::move(pendingKeys);
        pendingKeys.clear();
        pendingFull = false;
        inFlightParseRetry = pendingParseRetry;
        pendingParseRetry = false;
        memberPassRan = false;
        if (!everLoaded) setStatus(LoaderState::Loading);
        if (isLogEnabled(LogLevel::Debug)) logDebug("load: rules from " + rulesSourceDescription(settings.cli));
        startCall(needVersion ? LoadStep::Version : LoadStep::Status);
    }

    void startCall(LoadStep step) {
        CliRequest request;
        request.command = step == LoadStep::Version ? CliCommand::Version : CliCommand::Status;
        if (step == LoadStep::Status) {
            // Before the call: a stream started from this id replays every
            // change `status` may not have seen (see the header).
            statusEventId = settings.currentEventId ? settings.currentEventId() : kWatchSinceNow;
            statusSinceRequest = true;
        }
        CliRunOptions options;
        options.limits = settings.limits;
        std::shared_ptr<Impl> self = shared_from_this();
        const uint64_t gen = generation;
        std::string refusal;
        const bool started = startCliCommand(
            runner, settings.cli, request, options, queue, nullptr,
            [self, step, gen](CliResult &&result) {
                if (gen != self->generation) {
                    self->discardStale(result);
                    return;
                }
                if (step == LoadStep::Version) {
                    self->onVersion(std::move(result));
                } else {
                    self->onStatus(std::move(result));
                }
            },
            &refusal);
        // A read-only call is never refused; kept as a failure, not a hang.
        if (!started) failLoad(step, hostNoCli("refused: " + refusal));
    }

    void onVersion(CliResult &&r) {
        logCliResult(r);
        if (stopped || r.envelope.outcome == CliOutcome::Cancelled) {
            finishLoad(false);
            return;
        }
        if (r.envelope.outcome != CliOutcome::Ok && r.envelope.outcome != CliOutcome::Partial) {
            failLoad(LoadStep::Version, r.envelope);
            return;
        }
        VersionGateResult gate = checkVersionGate(r.envelope.data);
        if (!gate.passed()) {
            failGate(gate);
            return;
        }
        settings.cli.cliVersion = gate.info.cli;
        settings.cli.cliListsCommands = gate.info.hasCommands;
        cliInfo = gate.info;
        needVersion = false;
        gateFailed = false;
        logDebug("version: cli " + (gate.info.cli.empty() ? std::string("(none)") : gate.info.cli) +
                 ", schema 1" + (gate.info.hasCommands ? ", commands listed" : ", no commands list"));
        incomeOffered = cliSupportsCommand(gate.info, CliCommand::Income);
        if (incomeOffered) {
            startIncomeCall();
        } else {
            if (!incomePaths.empty()) logDebug("income: not offered by this CLI; no income folders watched");
            incomePaths.clear();
            incomeFolders.clear();
            incomeError.clear();
            startCall(LoadStep::Status);
        }
    }

    // A result of a load started before reconfigure(): its settings are
    // gone. The load ends here; the "reload again" flag reconfigure() set
    // starts the next one.
    void discardStale(const CliResult &r) {
        logCliResult(r);
        logDebug(std::string(cliCommandName(r.command)) + ": discarded, the CLI settings changed");
        finishLoad(false, false);
    }

    // `income --json` (read-only, so killable like status). Any failure is
    // this command's alone: the load goes on with `status`.
    void startIncomeCall() {
        CliRequest request;
        request.command = CliCommand::Income;
        CliRunOptions options;
        options.limits = settings.limits;
        std::shared_ptr<Impl> self = shared_from_this();
        const uint64_t gen = generation;
        std::string refusal;
        const bool started = startCliCommand(
            runner, settings.cli, request, options, queue, nullptr,
            [self, gen](CliResult &&result) {
                if (gen != self->generation) {
                    self->discardStale(result);
                    return;
                }
                self->onIncome(std::move(result));
            },
            &refusal);
        if (!started) {
            incomeError = "refused: " + refusal;
            logError("income failed; watching the last known income folders: " + incomeError);
            startCall(LoadStep::Status);
        }
    }

    void onIncome(CliResult &&r) {
        logCliResult(r);
        if (stopped || r.envelope.outcome == CliOutcome::Cancelled) {
            finishLoad(false);
            return;
        }
        const EnvelopeResult &env = r.envelope;
        if (env.outcome == CliOutcome::Ok || env.outcome == CliOutcome::Partial) {
            IncomeParseResult parsed = parseIncomeFolders(env.data);
            if (parsed.ok) {
                std::vector<std::string> paths;
                for (const IncomeFolder &f : parsed.folders) paths.push_back(f.path);
                incomePaths = std::move(paths);
                incomeFolders = parsed.folders;
                incomeError.clear();
                if (isLogEnabled(LogLevel::Debug)) {
                    logDebug("income: " + std::to_string(parsed.folders.size()) + " folder(s)" +
                             (parsed.skipped ? ", " + std::to_string(parsed.skipped) + " unusable entries skipped"
                                             : std::string()));
                }
                if (env.outcome == CliOutcome::Partial) logInfo("income: partial result: " + loadErrorText(env));
            } else {
                incomeError = parsed.error;
                logError("income failed; watching the last known income folders: " + incomeError);
            }
        } else {
            incomeError = loadErrorText(env);
            logError("income failed; watching the last known income folders: " + incomeError);
        }
        startCall(LoadStep::Status);
    }

    void onStatus(CliResult &&r) {
        logCliResult(r);
        if (stopped || r.envelope.outcome == CliOutcome::Cancelled) {
            finishLoad(false);
            return;
        }
        const EnvelopeResult &env = r.envelope;
        if (env.outcome != CliOutcome::Ok && env.outcome != CliOutcome::Partial) {
            failLoad(LoadStep::Status, env);
            return;
        }
        StatusParseResult parsed = parseStatusRows(env.data);
        if (!parsed.ok) {
            // A shape the contract does not allow: a CLI that cannot be
            // understood is absent (doc 03 E_NO_CLI).
            failLoad(LoadStep::Status, hostNoCli("status data: " + parsed.error));
            return;
        }
        size_t partialErrors = 0;
        std::string partialText;
        UnreadableSidecars unreadable;
        if (env.outcome == CliOutcome::Partial) {
            partialErrors = env.errors.size();
            partialText = loadErrorText(env);
            logInfo("status: partial result, " + std::to_string(partialErrors) + " error(s); loaded the rest: " +
                    partialText);
            static const std::vector<IntakeRecord> kNoRecords;
            unreadable = carryOverUnreadable(parsed.records, env.errors, lastGood ? lastGood->records() : kNoRecords);
        }

        applyMountAliases(parsed.records, *aliases);
        if (!unreadable.directories.empty()) noteUnreadable(unreadable);
        if (settings.annotateRecords) settings.annotateRecords(parsed.records);

        MemberLoadLimits limits;
        limits.cancel = &stopped;
        limits.deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                             std::chrono::duration<double>(settings.memberLoadSeconds));
        MemberReuse reuse;
        std::unordered_map<std::string, std::string> previousKeys;
        if (!inFlightFull && lastGood) {
            reuse.enabled = true;
            reuse.changedKeys = inFlightKeys;
            previousKeys.reserve(lastGood->size());
            for (const IntakeRecord &rec : lastGood->records()) previousKeys.emplace(rec.id, rec.rootKey);
            reuse.previousKeys = &previousKeys;
        }
        MemberLoadStats stats;
        MemberTable members = loadMembers(parsed.records, *files, lastGood ? &lastGood->members() : nullptr,
                                          statusHasVisual, &stats, limits, reuse);
        if (stopped) {
            finishLoad(false);
            return;
        }
        memberPassRan = true;
        // A stop leaves directories unverified: the next load lists all.
        if (stats.stop != MemberLoadStop::None) pendingFull = true;
        if (stats.stop != MemberLoadStop::None && stats.stop != MemberLoadStop::Cancelled) {
            logInfo(std::string("member lists: stopped early (") + stopName(stats.stop) +
                    (stats.stopError ? ", errno " + std::to_string(stats.stopError) : std::string()) +
                    "); unanswered roots keep their previous membership");
        }
        if (isLogEnabled(LogLevel::Debug)) {
            logDebug(std::string("member lists (") + (reuse.enabled ? "incremental" : "full") +
                     "): " + std::to_string(stats.directories) + " directories, " +
                     std::to_string(stats.directoriesListed) + " listed, " +
                     std::to_string(stats.directoriesReused) + " reused, " + std::to_string(stats.sidecarReads) +
                     " sidecar reads, " + std::to_string(stats.keptPrevious) + " kept from the last load");
        }

        auto snapshot = IntakeSnapshot::build(std::move(parsed.records), std::move(members), settings.palette);
        const bool first = !everLoaded;
        const bool wasInert = published && published->isInert();
        const bool changed = first || wasInert || !lastGood || !rendersAlike(*lastGood, *snapshot);
        everLoaded = true;
        lastGood = snapshot;
        publish(IntakeView::make(snapshot, aliases), changed, PublishReason::Load);

        const double seconds = std::chrono::duration<double>(Clock::now() - loadStart).count();
        const std::string summary = std::to_string(snapshot->size()) + " roots (CLI " +
                                    (settings.cli.cliVersion.empty() ? std::string("?") : settings.cli.cliVersion) +
                                    ") in " + secondsText(seconds);
        if (first) {
            logInfo("loaded " + summary);
        } else if (changed) {
            logInfo("reloaded " + summary + "; decorations changed");
        } else {
            logDebug("reloaded " + summary + "; no change");
        }
        setStatus(LoaderState::Ready, partialText, partialErrors);
        finishLoad(true);
    }

    // A partial `status` met half-written sidecars: their roots kept the
    // last record (carryOverUnreadable); one retry 1 s later, unless this
    // load is that retry.
    void noteUnreadable(const UnreadableSidecars &unreadable) {
        std::vector<std::string> keys;
        std::string normalized;
        std::string buffer;
        for (const std::string &dir : unreadable.directories) {
            if (normalizePath(dir, normalized) != PathStatus::Ok) continue;
            std::string key(aliases->rewrite(normalized, buffer));
            if (std::find(keys.begin(), keys.end(), key) == keys.end()) keys.push_back(std::move(key));
        }
        const bool retry = !inFlightParseRetry;
        logInfo("status: " + std::to_string(unreadable.directories.size()) +
                " folder(s) with an unreadable sidecar (a write in progress?); kept the last record of " +
                std::to_string(unreadable.carriedIds.size()) + " root(s)" +
                (retry ? "; retrying in 1 s" : "; already a retry, waiting for the next change"));
        if (retry) armParseRetry(std::move(keys));
    }

    void armParseRetry(std::vector<std::string> keys) {
        appendUnique(parseRetryKeys, keys);
        if (parseRetryArmed) return;
        parseRetryArmed = true;
        std::weak_ptr<Impl> weak = shared_from_this();
        const uint64_t gen = generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(NSEC_PER_SEC)), queue, ^{
            std::shared_ptr<Impl> self = weak.lock();
            if (!self) return;
            self->parseRetryArmed = false;
            if (self->stopped || gen != self->generation) return;
            appendUnique(self->pendingKeys, self->parseRetryKeys);
            self->parseRetryKeys.clear();
            self->pendingParseRetry = true;
            if (self->loading) {
                self->again = true;
                return;
            }
            self->startLoad();
        });
    }

    void failLoad(LoadStep step, const EnvelopeResult &result) {
        const char *command = step == LoadStep::Version ? "version" : "status";
        if (step == LoadStep::Version) needVersion = true;
        const std::string text = loadErrorText(result);
        if (loadFailureEffect(step, result, everLoaded) == LoadFailureEffect::Inert) {
            becomeInert(std::string(command) + ": " + text);
        } else if (!everLoaded) {
            logError(std::string(command) + " failed; nothing to show yet: " + text);
            setStatus(LoaderState::Failed, std::string(command) + ": " + text);
        } else if (published && published->isInert() && gateFailed) {
            // After a successful load only a gate failure is inert, and the
            // gate has not passed since, so the inert view stays.
            logError(std::string(command) + " failed; still inactive: " + text);
            setStatus(LoaderState::Inert, published->inertReason());
        } else if (published && published->isInert()) {
            // The gate failed after a successful load and this load's
            // `version` passed it again: doc 03 v1.2 is inert only while the
            // gate fails, and a failed refresh keeps the last loaded data.
            publish(IntakeView::make(lastGood, aliases), !lastGood->isEmpty(), PublishReason::GatePassed);
            logError(std::string(command) + " failed; the version gate passes again, showing the last loaded data: " +
                     text);
            setStatus(LoaderState::Stale, std::string(command) + ": " + text);
        } else {
            logError(std::string(command) + " failed; keeping the last loaded data: " + text);
            setStatus(LoaderState::Stale, std::string(command) + ": " + text);
        }
        finishLoad(true);
    }

    void failGate(const VersionGateResult &gate) {
        needVersion = true;
        gateFailed = true;
        std::string reason = std::string("unsupported intake CLI (") + gateVerdictName(gate.verdict);
        if (!gate.detail.empty()) reason += ": " + gate.detail;
        if (!gate.info.cli.empty()) reason += ", cli " + gate.info.cli;
        reason += ")";
        becomeInert(reason);
        finishLoad(true);
    }

    // Rows under the last-known roots get a tooltip naming `reason`; with no
    // successful load there are none and nothing renders.
    void becomeInert(const std::string &reason) {
        std::shared_ptr<const IntakeSnapshot> snapshot =
            everLoaded && lastGood ? lastGood : IntakeSnapshot::empty();
        const bool sameAsShown = published && published->isInert() && published->inertReason() == reason;
        publish(IntakeView::make(snapshot, aliases, reason), !snapshot->isEmpty() && !sameAsShown,
                PublishReason::Inert);
        logError("inactive: " + reason);
        setStatus(LoaderState::Inert, reason);
    }

    // `updateWatch` false: a load discarded after reconfigure(); its
    // successor, already due, computes the set from the new settings and
    // serves the reload requests this one was serving.
    void finishLoad(bool notify, bool updateWatch = true) {
        loading = false;
        if (stopped) return;
        if (!memberPassRan) {
            // Nothing was re-listed: what this load was asked to look at
            // carries over to the next one.
            pendingFull = pendingFull || inFlightFull;
            appendUnique(pendingKeys, inFlightKeys);
        }
        inFlightKeys.clear();
        inFlightFull = false;
        memberPassRan = false;
        if (updateWatch) updateWatchSet();
        if (notify && settings.onLoadFinished) settings.onLoadFinished(currentStatus());
        if (updateWatch) {
            serveWaiters();
        } else {
            waitersNext.insert(waitersNext.begin(), std::make_move_iterator(waitersInFlight.begin()),
                               std::make_move_iterator(waitersInFlight.end()));
            waitersInFlight.clear();
        }
        if (again) {
            again = false;
            if (againRecheck) needVersion = true;
            againRecheck = false;
            startLoad();
        }
    }

    // --- settings (B5) ---

    void applyReconfigure(CliConfig cli) {
        if (stopped) return;
        generation++;
        cli.cliVersion.clear();
        cli.cliListsCommands = false;
        settings.cli = std::move(cli);
        cliInfo = CliVersionInfo();
        needVersion = true;
        gateFailed = false;
        everLoaded = false;
        notConfiguredLogged = false;
        incomeOffered = false;
        incomeFolders.clear();
        incomePaths.clear();
        incomeError.clear();
        lastGood.reset();
        pendingFull = true;
        pendingKeys.clear();
        parseRetryKeys.clear();
        pendingParseRetry = false;
        if (published) {
            const bool shown = !published->rendersNothing();
            publish(IntakeView::make(IntakeSnapshot::empty(), aliases), shown, PublishReason::Reconfigured);
        }
        logInfo(settings.cli.cliPath.empty() ? "CLI settings changed: no CLI path"
                                             : "CLI settings changed: loading with the new settings");
        if (loading) {
            // The running call belongs to the old settings: kill it (read
            // lane only), discard what it delivers, then load again.
            again = true;
            againRecheck = true;
            runner.cancelReadLane();
            setStatus(settings.cli.cliPath.empty() ? LoaderState::NotConfigured : LoaderState::Loading);
            return;
        }
        startLoad();
    }

    void applyWatchFolders(std::vector<std::string> folders) {
        if (stopped) return;
        settings.watchFolders = std::move(folders);
        // A running load recomputes the set when it finishes.
        if (!loading) updateWatchSet();
    }

    // --- watch set ---

    void updateWatchSet() {
        if (stopped || !settings.onWatchSet) return;
        // MNT_NOWAIT, no server contact: the local/network decision below
        // must see a share that mounted while the load ran (its
        // notification's remount() is still queued behind this block).
        if (settings.readMounts) {
            std::vector<MountEntry> fresh = settings.readMounts();
            if (!sameMountEntries(fresh, mountEntries)) {
                mountEntries = std::move(fresh);
                watchDirty = true;
            }
        }
        std::vector<std::string> rootPaths;
        if (lastGood) {
            rootPaths.reserve(lastGood->size());
            for (const IntakeRecord &rec : lastGood->records()) rootPaths.push_back(rec.rootPath);
        }
        // No CLI path: nothing to reload, so nothing to watch.
        std::vector<std::string> inputs = settings.cli.cliPath.empty()
                                              ? std::vector<std::string>()
                                              : watchCandidates(settings.watchFolders, incomePaths, rootPaths);
        if (watchBuilt && !watchDirty && inputs == watchInputs) return;
        const LinkReader &readLink = settings.readLink ? settings.readLink : posixLinkReaderFunction();
        watchSet = WatchSet::build(inputs, mountEntries, readLink);
        watchInputs = std::move(inputs);
        watchBuilt = true;
        watchDirty = false;
        if (watchHandedOverOnce && watchSet.streamPaths() == watchHandedOver) return;
        watchHandedOver = watchSet.streamPaths();
        watchHandedOverOnce = true;
        if (isLogEnabled(LogLevel::Debug)) {
            logDebug("watch set: " + std::to_string(watchHandedOver.size()) + " folder(s) from " +
                     std::to_string(watchInputs.size()) + " candidate(s)");
        }
        WatchHandover handover;
        handover.paths = watchHandedOver;
        handover.sinceEventId = statusEventId;
        settings.onWatchSet(handover);
    }

    // After a mount or unmount (see the header): the reload(false) queued
    // just before this has started its `status` when the loader was idle,
    // and not when a load was running or `version` comes first.
    void applyRestartWatch() {
        if (stopped || !settings.onWatchSet || !watchHandedOverOnce) return;
        WatchHandover handover;
        handover.paths = watchHandedOver;
        handover.sinceEventId = statusSinceRequest ? statusEventId : kWatchSinceNow;
        handover.restart = true;
        logDebug(handover.sinceEventId == kWatchSinceNow
                     ? std::string("watch: restarting the stream from now; the reload's status follows")
                     : std::string("watch: restarting the stream from the reload's status call"));
        settings.onWatchSet(handover);
    }

    static const LinkReader &posixLinkReaderFunction() {
        static const LinkReader reader = &posixLinkReader;
        return reader;
    }

    // --- mounts ---

    void readMounts(bool publishChange) {
        std::vector<MountEntry> entries;
        if (settings.readMounts) entries = settings.readMounts();
        if (!sameMountEntries(entries, mountEntries)) {
            mountEntries = entries;
            watchDirty = true;
        }
        std::shared_ptr<const MountAliases> next = MountAliases::build(entries);
        const bool firstRead = !mountsRead;
        mountsRead = true;
        if (next->sameAs(*aliases)) {
            if (firstRead) logDebug("mount aliases: " + next->describe());
            return;
        }
        const std::shared_ptr<const MountAliases> previous = aliases;
        aliases = next;
        if (firstRead) {
            logDebug("mount aliases: " + aliases->describe());
        } else {
            logInfo("mount aliases changed: " + aliases->describe());
        }
        if (!publishChange || !lastGood || stopped) return;

        std::vector<IntakeRecord> records = lastGood->records();
        applyMountAliases(records, *aliases);
        auto rebuilt = IntakeSnapshot::build(std::move(records), lastGood->members(), settings.palette);
        // The new table is published either way (rows and roots must be
        // keyed with one table), but invalidated only when a row can change:
        // a share holding no root mounting or unmounting changes none.
        const bool rowsChange = remountChangesRows(*lastGood, *previous, *rebuilt, *aliases);
        lastGood = rebuilt;
        const std::string reason = published ? published->inertReason() : std::string();
        publish(IntakeView::make(rebuilt, aliases, reason), rowsChange, PublishReason::Remount);
        if (!rowsChange) logDebug("mount aliases changed under no intake root: no row changes, no invalidation");
    }

    void publish(std::shared_ptr<const IntakeView> view, bool invalidate, PublishReason reason) {
        if (stopped) return;
        published = view;
        if (settings.publish) settings.publish(std::move(view), invalidate, reason);
    }
};

IntakeLoader::IntakeLoader(LoaderSettings settings) : impl_(std::make_shared<Impl>(std::move(settings))) {}

IntakeLoader::~IntakeLoader() {
    shutdown();
}

void IntakeLoader::reload(bool recheckVersion, LoadFinishedHandler served) {
    std::shared_ptr<Impl> impl = impl_;
    auto handler = std::make_shared<LoadFinishedHandler>(std::move(served));
    dispatch_async(impl->queue, ^{
        impl->requestLoad(recheckVersion, std::move(*handler));
    });
}

void IntakeLoader::reloadForChanges(std::vector<std::string> directories, bool rescan) {
    std::shared_ptr<Impl> impl = impl_;
    auto dirs = std::make_shared<std::vector<std::string>>(std::move(directories));
    dispatch_async(impl->queue, ^{
        impl->requestChangeLoad(*dirs, rescan);
    });
}

void IntakeLoader::remount() {
    std::shared_ptr<Impl> impl = impl_;
    dispatch_async(impl->queue, ^{
        if (impl->stopped) return;
        impl->readMounts(true);
        // A mount change may move keys and folders: the next load lists all.
        impl->pendingFull = true;
        if (!impl->loading) impl->updateWatchSet();
    });
}

void IntakeLoader::restartWatch() {
    std::shared_ptr<Impl> impl = impl_;
    dispatch_async(impl->queue, ^{
        impl->applyRestartWatch();
    });
}

void IntakeLoader::reconfigure(CliConfig cli) {
    std::shared_ptr<Impl> impl = impl_;
    auto config = std::make_shared<CliConfig>(std::move(cli));
    dispatch_async(impl->queue, ^{
        impl->applyReconfigure(std::move(*config));
    });
}

void IntakeLoader::setWatchFolders(std::vector<std::string> folders) {
    std::shared_ptr<Impl> impl = impl_;
    auto list = std::make_shared<std::vector<std::string>>(std::move(folders));
    dispatch_async(impl->queue, ^{
        impl->applyWatchFolders(std::move(*list));
    });
}

void IntakeLoader::shutdown() {
    if (impl_->stopped.exchange(true)) return;
    // Closed, not only cancelled: a call the loader queue starts after the
    // `stopped` check it already passed is refused instead of outliving
    // the sweep.
    impl_->runner.closeReadLane();
    std::lock_guard<std::mutex> lock(impl_->statusMutex);
    impl_->status.state = LoaderState::Stopped;
}

LoaderStatus IntakeLoader::status() const {
    return impl_->currentStatus();
}

std::string IntakeLoader::statusLine() const {
    return intake::statusLine(status());
}

} // namespace intake
