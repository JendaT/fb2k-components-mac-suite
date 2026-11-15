//
//  IntakeService.mm
//  foo_jl_intake
//

#import "../fb2k_sdk.h"

#import <AppKit/AppKit.h>

#include "IntakeService.h"

#include "IntakeConfig.h"
#include "IntakeDecoratorProvider.h"
#include "IntakeMounts.h"
#include "IntakeNativePath.h"

#include "../Core/IntakeCommandArgs.h"
#include "../Core/IntakeLoader.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeWatcher.h"

#include <atomic>
#include <ctime>
#include <memory>
#include <mutex>
#include <string>
#include <sys/time.h>

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

class Service {
public:
    explicit Service(const IntakeSettings &settings) : settings_(settings) {}

    void start() {
        for (const std::string &line : settings_.ignoredWatchFolders) {
            logInfo("watch_folders: ignoring \"" + line + "\" (not an absolute path)");
        }
        // The handler runs on the watcher's queue; stop() in on_quit clears
        // it (waiting out a running call) before the loader goes, so the raw
        // pointer never outlives the loader.
        IntakeLoader **loaderSlot = &loaderForWatcher_;
        watcher_ = std::make_shared<IntakeWatcher>([loaderSlot](WatchBatch batch) {
            if (IntakeLoader *loader = *loaderSlot) loader->reloadForChanges(std::move(batch.directories), batch.rescan);
        });

        LoaderSettings ls;
        ls.cli.cliPath = settings_.cliPath;
        ls.cli.bunPath = settings_.bunPath;
        ls.cli.rulesDir = settings_.rulesDir;
        ls.cli.baseEnvironment = processEnvironmentSnapshot();  // main thread only
        ls.readMounts = [] { return readMountTable(); };
        ls.publish = [](std::shared_ptr<const IntakeView> view, bool invalidateAll, PublishReason reason) {
            providerPublish(std::move(view), invalidateAll, reason == PublishReason::Load);
        };
        ls.watchFolders = settings_.watchFolders;
        // Runs on the loader queue; a weak reference, so a watch set handed
        // over while on_quit runs finds the watcher gone (or stopped).
        std::weak_ptr<IntakeWatcher> weakWatcher = watcher_;
        ls.onWatchSet = [weakWatcher](const std::vector<std::string> &paths) {
            if (std::shared_ptr<IntakeWatcher> watcher = weakWatcher.lock()) watcher->setPaths(paths);
        };
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

        loader_->reload(true);
    }

    void stop() {
        NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
        if (mountObserver_) [center removeObserver:mountObserver_];
        if (unmountObserver_) [center removeObserver:unmountObserver_];
        mountObserver_ = nil;
        unmountObserver_ = nil;
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

    void reload(bool recheckVersion) {
        if (loader_) loader_->reload(recheckVersion);
    }

    void refreshAfterCommand() {
        if (loader_) loader_->reload(false);
    }

    std::string statusLine() const { return loader_ ? loader_->statusLine() : std::string("Stopped"); }

    // A volume came or went: the share may have mounted after startup
    // (`status` skips missing income folders) or one alias may be gone.
    static void volumesChanged();

private:
    IntakeSettings settings_;  // read once in on_init; never on the decorate path
    std::shared_ptr<IntakeWatcher> watcher_;
    std::unique_ptr<IntakeLoader> loader_;
    IntakeLoader *loaderForWatcher_ = nullptr;  // read by the watcher's handler
    id mountObserver_ = nil;
    id unmountObserver_ = nil;
};

Service *g_service = nullptr;  // main thread only

void Service::volumesChanged() {
    resetSlowVolumes();
    if (g_service == nullptr || !g_service->loader_) return;
    g_service->loader_->remount();
    g_service->loader_->reload(false);
    // A stream created while a watched share was absent (or present) is
    // replaced; the remount may also hand over a new set.
    if (g_service->watcher_) g_service->watcher_->restart();
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
    }

    void on_quit() override {
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

void serviceReload(bool recheckVersion) {
    if (g_service != nullptr) g_service->reload(recheckVersion);
}

void serviceRefreshAfterCommand() {
    if (g_service != nullptr) g_service->refreshAfterCommand();
}

std::string serviceStatusLine() {
    return g_service != nullptr ? g_service->statusLine() : std::string("Stopped");
}

} // namespace intake
