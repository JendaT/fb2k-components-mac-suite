//
//  IntakeLoader.mm
//  foo_jl_intake
//

#include "IntakeLoader.h"

#include "IntakeCliRunner.h"
#include "IntakeLog.h"
#include "IntakeStatusModel.h"
#include "IntakeVersionGate.h"

#include <dispatch/dispatch.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>

namespace intake {

namespace {

using Clock = std::chrono::steady_clock;

std::string secondsText(double seconds) {
    char buf[32];
    snprintf(buf, sizeof buf, "%.2f s", seconds);
    return buf;
}

// Debug (PLAN.md 3.10): the call, how it ended, its duration and error
// codes. Never stdout.
void logCall(const CliResult &r) {
    if (!isLogEnabled(LogLevel::Debug)) return;
    std::string line = std::string(cliCommandName(r.command)) + ": " + cliOutcomeName(r.envelope.outcome);
    switch (r.process.end) {
        case ProcessEnd::Exited:
            line += ", exit " + std::to_string(r.process.exitCode);
            break;
        case ProcessEnd::Signaled:
            line += ", signal " + std::to_string(r.process.termSignal);
            break;
        case ProcessEnd::SpawnFailed:
            if (r.process.spawnStage.empty()) {
                line += ", not run";
            } else {
                line += ", spawn failed (" + r.process.spawnStage + ", errno " +
                        std::to_string(r.process.spawnErrno) + ")";
            }
            break;
        case ProcessEnd::Abandoned:
            line += ", abandoned after kill";
            break;
        case ProcessEnd::WaitFailed:
            line += ", wait failed";
            break;
    }
    line += ", " + secondsText(r.process.elapsedSeconds);
    if (!r.envelope.errors.empty()) {
        line += ", errors:";
        for (const CliError &e : r.envelope.errors) line += " " + e.code;
    }
    logDebug(line);
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
        std::lock_guard<std::mutex> lock(statusMutex);
        if (status.state == LoaderState::Stopped) return;
        status = std::move(s);
    }

    LoaderStatus currentStatus() const {
        std::lock_guard<std::mutex> lock(statusMutex);
        return status;
    }

    // --- loads ---

    void requestLoad(bool recheck) {
        if (stopped) return;
        if (loading) {
            again = true;
            againRecheck = againRecheck || recheck;
            return;
        }
        if (recheck) needVersion = true;
        startLoad();
    }

    void startLoad() {
        if (!mountsRead) readMounts(false);
        if (settings.cli.cliPath.empty()) {
            if (!notConfiguredLogged) {
                logInfo("not configured: foo_jl_intake.cli_path is empty, so no CLI runs and nothing is decorated");
                notConfiguredLogged = true;
            }
            setStatus(LoaderState::NotConfigured);
            if (settings.onLoadFinished) settings.onLoadFinished(currentStatus());
            return;
        }
        notConfiguredLogged = false;
        loading = true;
        loadStart = Clock::now();
        if (!everLoaded) setStatus(LoaderState::Loading);
        if (isLogEnabled(LogLevel::Debug)) logDebug("load: rules from " + rulesSourceDescription(settings.cli));
        startCall(needVersion ? LoadStep::Version : LoadStep::Status);
    }

    void startCall(LoadStep step) {
        CliRequest request;
        request.command = step == LoadStep::Version ? CliCommand::Version : CliCommand::Status;
        CliRunOptions options;
        options.limits = settings.limits;
        std::shared_ptr<Impl> self = shared_from_this();
        std::string refusal;
        const bool started = startCliCommand(
            runner, settings.cli, request, options, queue, nullptr,
            [self, step](CliResult &&result) {
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
        logCall(r);
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
        needVersion = false;
        gateFailed = false;
        logDebug("version: cli " + (gate.info.cli.empty() ? std::string("(none)") : gate.info.cli) +
                 ", schema 1" + (gate.info.hasCommands ? ", commands listed" : ", no commands list"));
        startCall(LoadStep::Status);
    }

    void onStatus(CliResult &&r) {
        logCall(r);
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
        if (env.outcome == CliOutcome::Partial) {
            partialErrors = env.errors.size();
            partialText = loadErrorText(env);
            logInfo("status: partial result, " + std::to_string(partialErrors) + " error(s); loaded the rest: " +
                    partialText);
        }

        applyMountAliases(parsed.records, *aliases);

        MemberLoadLimits limits;
        limits.cancel = &stopped;
        limits.deadline = Clock::now() + std::chrono::duration_cast<Clock::duration>(
                                             std::chrono::duration<double>(settings.memberLoadSeconds));
        MemberLoadStats stats;
        MemberTable members = loadMembers(parsed.records, *files, lastGood ? &lastGood->members() : nullptr,
                                          statusHasVisual, &stats, limits);
        if (stopped) {
            finishLoad(false);
            return;
        }
        if (stats.stop != MemberLoadStop::None && stats.stop != MemberLoadStop::Cancelled) {
            logInfo(std::string("member lists: stopped early (") + stopName(stats.stop) +
                    (stats.stopError ? ", errno " + std::to_string(stats.stopError) : std::string()) +
                    "); unanswered roots keep their previous membership");
        }
        if (isLogEnabled(LogLevel::Debug)) {
            logDebug("member lists: " + std::to_string(stats.directories) + " directories, " +
                     std::to_string(stats.directoriesListed) + " listed, " + std::to_string(stats.sidecarReads) +
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

    void finishLoad(bool notify) {
        loading = false;
        if (stopped) return;
        if (notify && settings.onLoadFinished) settings.onLoadFinished(currentStatus());
        if (again) {
            again = false;
            if (againRecheck) needVersion = true;
            againRecheck = false;
            startLoad();
        }
    }

    // --- mounts ---

    void readMounts(bool publishChange) {
        std::vector<MountEntry> entries;
        if (settings.readMounts) entries = settings.readMounts();
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

void IntakeLoader::reload(bool recheckVersion) {
    std::shared_ptr<Impl> impl = impl_;
    dispatch_async(impl->queue, ^{
        impl->requestLoad(recheckVersion);
    });
}

void IntakeLoader::remount() {
    std::shared_ptr<Impl> impl = impl_;
    dispatch_async(impl->queue, ^{
        if (!impl->stopped) impl->readMounts(true);
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
