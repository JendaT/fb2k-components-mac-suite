//
//  IntakeService.mm
//  foo_jl_intake
//

#import "../fb2k_sdk.h"

#import <AppKit/AppKit.h>
#include <CoreServices/CoreServices.h>

#include "IntakeService.h"

#include "IntakeActions.h"
#include "IntakeConfig.h"
#include "IntakeDecoratorProvider.h"
#include "IntakeMounts.h"
#include "IntakeNativePath.h"

#include "../Core/IntakeCliRunner.h"
#include "../Core/IntakeCommandArgs.h"
#include "../Core/IntakeLoader.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeTint.h"
#include "../Core/IntakeVersionGate.h"
#include "../Core/IntakeWatcher.h"

#include <atomic>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <sys/time.h>

NSNotificationName const IntakeSettingsDidChangeNotification = @"JLIntakeSettingsDidChange";
NSNotificationName const IntakeStatusDidChangeNotification = @"JLIntakeStatusDidChange";

namespace intake {

namespace {

// Hidden option log_file (docs/hidden-options.md): mirror every line that
// reaches the console to a file, so in-app checks can be read without the
// console window. Set once in on_init before the backend is installed.
std::atomic<bool> g_logToFile{false};
std::mutex g_logFileMutex;

const std::string &logFilePath() {
    static const std::string path = [] {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/foobar2000"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        return std::string([dir stringByAppendingPathComponent:@"jl_intake.log"].fileSystemRepresentation);
    }();
    return path;
}

void appendToLogFile(LogLevel level, const char *message) {
    struct timeval tv;
    gettimeofday(&tv, nullptr);
    struct tm local;
    time_t secs = tv.tv_sec;
    localtime_r(&secs, &local);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local);
    std::lock_guard<std::mutex> lock(g_logFileMutex);
    if (FILE *f = fopen(logFilePath().c_str(), "a")) {
        fprintf(f, "%s.%03d %s%s\n", stamp, static_cast<int>(tv.tv_usec / 1000),
                level == LogLevel::Error ? "ERROR " : "", message);
        fclose(f);
    }
}

// IntakeLog messages arrive "[intake] "-prefixed, from any thread.
void consoleBackend(LogLevel level, const char *message) {
    if (level == LogLevel::Error) {
        console::error(message);
    } else {
        console::info(message);
    }
    if (g_logToFile.load(std::memory_order_relaxed)) appendToLogFile(level, message);
}

// The loader's status changed (loader queue): one notification on the main
// thread, coalesced while one is still queued.
std::atomic<bool> g_statusPostQueued{false};

void postStatusChanged() {
    if (g_statusPostQueued.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_statusPostQueued = false;
        [[NSNotificationCenter defaultCenter] postNotificationName:IntakeStatusDidChangeNotification object:nil];
    });
}

void logIgnoredWatchFolders(const std::vector<std::string> &ignored) {
    for (const std::string &line : ignored) {
        logInfo("watch_folders: ignoring \"" + line + "\" (not an absolute path)");
    }
}

// B10: the tint_* keys that are not 0 or a colour (each falls back to its
// default), then the colours that differ from the defaults.
void logPalette(const IntakeSettings &settings) {
    for (const std::string &problem : settings.tintProblems) logDebug(problem);
    const std::string changes = describePaletteChanges(settings.palette);
    if (!changes.empty()) logDebug("row colours: " + changes + "; the rest default");
}

class Service {
public:
    explicit Service(const IntakeSettings &settings) : settings_(settings) {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_USER_INITIATED, 0);
        testQueue_ = dispatch_queue_create("com.foobar2000.intake.cli-test", attr);
    }

    void start() {
        logIgnoredWatchFolders(settings_.ignoredWatchFolders);
        logPalette(settings_);
        // The handler runs on the watcher's queue; stop() in on_quit clears
        // it (waiting out a running call) before the loader goes, so the raw
        // pointer never outlives the loader.
        IntakeLoader **loaderSlot = &loaderForWatcher_;
        watcher_ = std::make_shared<IntakeWatcher>([loaderSlot](WatchBatch batch) {
            if (IntakeLoader *loader = *loaderSlot) loader->reloadForChanges(std::move(batch.directories), batch.rescan);
        });

        LoaderSettings ls;
        ls.cli = cliConfig();
        ls.readMounts = [] { return readMountTable(); };
        ls.publish = [](std::shared_ptr<const IntakeView> view, bool invalidateAll, PublishReason reason) {
            providerPublish(std::move(view), invalidateAll, reason == PublishReason::Load);
        };
        ls.watchFolders = settings_.watchFolders;
        ls.libraryPrefix = makeLibraryPrefix(settings_.swapPrefixFrom, settings_.swapPrefixTo);
        // B10: the row colours reach the rows only through the snapshot's
        // visuals; decorate never reads a setting.
        ls.palette = settings_.palette;
        ls.onStatusChanged = [](const LoaderStatus &) { postStatusChanged(); };
        // B6: per-root command errors reach the records before the snapshot.
        ls.annotateRecords = [](std::vector<IntakeRecord> &records, std::chrono::steady_clock::time_point started) {
            actionsErrorStore().apply(records, started);
        };
        // Runs on the loader queue; a weak reference, so a watch set handed
        // over while on_quit runs finds the watcher gone (or stopped).
        std::weak_ptr<IntakeWatcher> weakWatcher = watcher_;
        ls.onWatchSet = [weakWatcher](const WatchHandover &handover) {
            std::shared_ptr<IntakeWatcher> watcher = weakWatcher.lock();
            if (!watcher) return;
            if (handover.restart) {
                watcher->restart(handover.sinceEventId);
            } else {
                watcher->setPaths(handover.paths, handover.sinceEventId);
            }
        };
        // Taken before each `status` call: a stream started from it replays
        // what that call may have missed (IntakeWatcher).
        ls.currentEventId = [] { return static_cast<WatchEventId>(FSEventsGetCurrentEventId()); };
        loader_ = std::make_unique<IntakeLoader>(std::move(ls));
        loaderForWatcher_ = loader_.get();

        NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
        NSOperationQueue *main = [NSOperationQueue mainQueue];
        mountObserver_ = [center addObserverForName:NSWorkspaceDidMountNotification
                                             object:nil
                                              queue:main
                                         usingBlock:^(NSNotification *) {
                                             volumesChanged();
                                         }];
        unmountObserver_ = [center addObserverForName:NSWorkspaceDidUnmountNotification
                                               object:nil
                                                queue:main
                                           usingBlock:^(NSNotification *) {
                                               volumesChanged();
                                           }];
        // Removed in stop(), before the service is deleted.
        Service *service = this;
        settingsObserver_ = [[NSNotificationCenter defaultCenter] addObserverForName:IntakeSettingsDidChangeNotification
                                                                              object:nil
                                                                               queue:main
                                                                          usingBlock:^(NSNotification *) {
                                                                              service->applySettings();
                                                                          }];

        loader_->reload(true);
    }

    void stop() {
        NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
        if (mountObserver_) [center removeObserver:mountObserver_];
        if (unmountObserver_) [center removeObserver:unmountObserver_];
        mountObserver_ = nil;
        unmountObserver_ = nil;
        if (settingsObserver_) [[NSNotificationCenter defaultCenter] removeObserver:settingsObserver_];
        settingsObserver_ = nil;
        testRunner_->closeReadLane();  // a running Test CLI call is killed, none starts
        if (watcher_) {
            watcher_->stop();  // no batch reaches the loader after this
            watcher_.reset();
        }
        loaderForWatcher_ = nullptr;
        if (loader_) {
            loader_->shutdown();  // cancel flag, then the read lane is killed
            loader_.reset();
        }
    }

    void reload(bool recheckVersion, std::function<void(const LoaderStatus &)> finished) {
        // Refresh is the user's way back from a volume the guard marked.
        if (resetSlowVolumes("refresh")) providerInvalidateAll();
        if (!loader_) {
            if (finished) finished(status());
            return;
        }
        loader_->reload(recheckVersion, onMainThread(std::move(finished)));
    }

    void refreshAfterCommand(std::function<void(const LoaderStatus &)> finished) {
        if (!loader_) {
            if (finished) finished(status());
            return;
        }
        loader_->reload(false, onMainThread(std::move(finished)));
    }

    // A load-finished handler (loader queue) that hands the status to
    // `finished` on the main thread; empty for an empty one.
    static LoadFinishedHandler onMainThread(std::function<void(const LoaderStatus &)> finished) {
        if (!finished) return LoadFinishedHandler();
        return [finished](const LoaderStatus &st) {
            std::function<void(const LoaderStatus &)> done = finished;
            LoaderStatus copy = st;
            dispatch_async(dispatch_get_main_queue(), ^{
                done(copy);
            });
        };
    }

    std::string statusLine() const { return loader_ ? loader_->statusLine() : std::string("Stopped"); }

    LoaderStatus status() const {
        if (loader_) return loader_->status();
        LoaderStatus stopped;
        stopped.state = LoaderState::Stopped;
        return stopped;
    }

    // Main thread: the page wrote a setting. Applies what changed (see
    // IntakeService.h).
    void applySettings() {
        if (!loader_) return;
        IntakeSettings next = config::load();
        if (next.logLevel != settings_.logLevel) {
            setLogLevel(next.logLevel);
            logInfo("log level " + std::to_string(next.logLevel));
        }
        const bool cliChanged = next.cliPath != settings_.cliPath || next.bunPath != settings_.bunPath ||
                                next.rulesDir != settings_.rulesDir;
        const bool watchChanged = next.watchFolders != settings_.watchFolders;
        const bool prefixChanged =
            next.swapPrefixFrom != settings_.swapPrefixFrom || next.swapPrefixTo != settings_.swapPrefixTo;
        const bool paletteChanged = !(next.palette == settings_.palette);
        const bool tintProblemsChanged = next.tintProblems != settings_.tintProblems;
        // Hidden options (decor_stats, log_file) keep their startup values.
        next.decorStats = settings_.decorStats;
        next.logFile = settings_.logFile;
        settings_ = std::move(next);
        // Another CLI or rules folder: the errors of the old one say nothing.
        if (cliChanged) actionsErrorStore().clearAll();
        if (watchChanged) {
            logIgnoredWatchFolders(settings_.ignoredWatchFolders);
            loader_->setWatchFolders(settings_.watchFolders);
        }
        if (prefixChanged) loader_->setLibraryPrefix(makeLibraryPrefix(settings_.swapPrefixFrom, settings_.swapPrefixTo));
        // One rebuild and at most one invalidate-all per colour change.
        if (paletteChanged || tintProblemsChanged) logPalette(settings_);
        if (paletteChanged) loader_->setPalette(settings_.palette);
        if (cliChanged) loader_->reconfigure(cliConfig());
    }

    // Main thread (see serviceTestCli).
    void testCli(std::function<void(bool, const std::string &)> completion) {
        // The page saved its fields just before: test what is stored, even
        // if that notification has not been handled yet (a no-op when it
        // has).
        applySettings();
        // The environment snapshot is main-thread only; everything after it
        // runs on testQueue_: building the call stats the CLI and bun paths
        // (IntakeCommandArgs), which may lie on a share that stalls.
        auto config = std::make_shared<CliConfig>(cliConfig());
        std::shared_ptr<ProcessRunner> runner = testRunner_;
        dispatch_queue_t queue = testQueue_;
        dispatch_async(queue, ^{
            auto report = [completion](bool ok, const std::string &text) {
                // Local copies: the main-queue block copies them in.
                std::function<void(bool, const std::string &)> done = completion;
                std::string message = text;
                dispatch_async(dispatch_get_main_queue(), ^{
                    done(ok, message);
                });
            };
            CliRequest request;
            request.command = CliCommand::Version;
            CliRunOptions options;
            std::string refusal;
            const bool started = startCliCommand(
                *runner, *config, request, options, queue, nullptr,
                [report](CliResult &&result) {
                    // testQueue_: parse here, report on main.
                    logCliResult(result);
                    VersionGateResult gate;
                    if (result.envelope.outcome == CliOutcome::Ok ||
                        result.envelope.outcome == CliOutcome::Partial) {
                        gate = checkVersionGate(result.envelope.data);
                    }
                    const CliTestSummary summary = cliTestSummary(result.envelope, gate);
                    logInfo(std::string("Test CLI: ") + summary.text);
                    report(summary.ok, summary.text);
                },
                &refusal);
            if (!started) report(false, "refused: " + refusal);
        });
    }

    // Main thread (serviceActionInfo).
    ServiceActionInfo actionInfo() const {
        ServiceActionInfo info;
        info.running = loader_ != nullptr;
        info.cliConfigured = !settings_.cliPath.empty();
        info.confirmReject = settings_.confirmReject;
        info.confirmGc = settings_.confirmGc;
        info.libraryPrefix = makeLibraryPrefix(settings_.swapPrefixFrom, settings_.swapPrefixTo);
        if (loader_) info.cli = loader_->status().cliInfo;
        return info;
    }

    // Main thread (serviceMutationConfig).
    bool mutationConfig(CliConfig &out) const {
        if (!loader_ || settings_.cliPath.empty()) return false;
        out = cliConfig();
        const LoaderStatus st = loader_->status();
        out.cliVersion = st.cliInfo.cli;
        out.cliListsCommands = st.cliInfo.hasCommands;
        return true;
    }

    // A volume came or went: the share may have mounted after startup
    // (`status` skips missing income folders) or one alias may be gone.
    static void volumesChanged();

private:
    // Main thread: the CLI settings with a fresh environment snapshot.
    CliConfig cliConfig() const {
        CliConfig c;
        c.cliPath = settings_.cliPath;
        c.bunPath = settings_.bunPath;
        c.rulesDir = settings_.rulesDir;
        c.baseEnvironment = processEnvironmentSnapshot();  // main thread only
        return c;
    }

    // Read in on_init and again on every settings notification (main
    // thread); never on the decorate path.
    IntakeSettings settings_;
    std::shared_ptr<IntakeWatcher> watcher_;
    std::unique_ptr<IntakeLoader> loader_;
    IntakeLoader *loaderForWatcher_ = nullptr;  // read by the watcher's handler
    id mountObserver_ = nil;
    id unmountObserver_ = nil;
    id settingsObserver_ = nil;
    // Test CLI only; its read lane closes in stop(). Shared with the blocks
    // on testQueue_, which may still run after the service is deleted.
    std::shared_ptr<ProcessRunner> testRunner_ = std::make_shared<ProcessRunner>();
    dispatch_queue_t testQueue_ = nil;
};

Service *g_service = nullptr;  // main thread only

void Service::volumesChanged() {
    // Rows of a volume the guard marked were answered empty and the host
    // cached that; a reload that finds nothing changed would not repaint
    // them.
    if (resetSlowVolumes("mount change")) providerInvalidateAll();
    if (g_service == nullptr || !g_service->loader_) return;
    g_service->loader_->remount();
    g_service->loader_->reload(false);
    // A stream created while a watched share was absent (or present) is
    // replaced (the remount may also hand over a new set), from the event id
    // of that reload's `status` call when it already started, else from now;
    // the reload is the only `status` this costs.
    g_service->loader_->restartWatch();
}

class intake_initquit : public initquit {
public:
    void on_init() override {
        const IntakeSettings settings = config::load();
        g_logToFile = settings.logFile;
        setLogBackend(consoleBackend);
        setLogLevel(settings.logLevel);
        providerSetStatsEnabled(settings.decorStats);
        if (settings.decorStats) logUnfiltered(LogLevel::Info, "decor_stats on: one line per decorate batch");
        g_service = new Service(settings);
        g_service->start();
        // B8: adopt or finish execute runs an earlier session left behind
        // (on the mutation queue; no mutating call starts until it is done).
        actionsStartRunScan();
    }

    void on_quit() override {
        actionsShutdown();  // results of running mutating calls are dropped from here on
        if (g_service != nullptr) {
            g_service->stop();
            delete g_service;
            g_service = nullptr;
        }
        providerSetStatsEnabled(false);
        setLogBackend(nullptr);
    }
};

FB2K_SERVICE_FACTORY(intake_initquit);

} // anonymous namespace

void serviceReload(bool recheckVersion, std::function<void(const LoaderStatus &status)> finished) {
    if (g_service != nullptr) {
        g_service->reload(recheckVersion, std::move(finished));
    } else if (finished) {
        finished(serviceStatus());
    }
}

void serviceRefreshAfterCommand(std::function<void(const LoaderStatus &status)> finished) {
    if (g_service != nullptr) {
        g_service->refreshAfterCommand(std::move(finished));
    } else if (finished) {
        finished(serviceStatus());
    }
}

std::string serviceStatusLine() {
    return g_service != nullptr ? g_service->statusLine() : std::string("Stopped");
}

LoaderStatus serviceStatus() {
    if (g_service != nullptr) return g_service->status();
    LoaderStatus stopped;
    stopped.state = LoaderState::Stopped;
    return stopped;
}

ServiceActionInfo serviceActionInfo() {
    if (g_service != nullptr) return g_service->actionInfo();
    return ServiceActionInfo();
}

bool serviceMutationConfig(CliConfig &out) {
    return g_service != nullptr && g_service->mutationConfig(out);
}

void serviceTestCli(std::function<void(bool ok, const std::string &text)> completion) {
    if (!completion) return;
    if (g_service == nullptr) {
        completion(false, "not running");
        return;
    }
    g_service->testCli(std::move(completion));
}

} // namespace intake
