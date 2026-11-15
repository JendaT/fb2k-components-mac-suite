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

#include "../Core/IntakeCommandArgs.h"
#include "../Core/IntakeLoader.h"
#include "../Core/IntakeLog.h"

#include <memory>

namespace intake {

namespace {

// IntakeLog messages arrive "[intake] "-prefixed, from any thread.
void consoleBackend(LogLevel level, const char *message) {
    if (level == LogLevel::Error) {
        console::error(message);
    } else {
        console::info(message);
    }
}

class Service {
public:
    explicit Service(const IntakeSettings &settings) : settings_(settings) {}

    void start() {
        LoaderSettings ls;
        ls.cli.cliPath = settings_.cliPath;
        ls.cli.bunPath = settings_.bunPath;
        ls.cli.rulesDir = settings_.rulesDir;
        ls.cli.baseEnvironment = processEnvironmentSnapshot();  // main thread only
        ls.readMounts = [] { return readMountTable(); };
        ls.publish = [](std::shared_ptr<const IntakeView> view, bool invalidateAll, PublishReason reason) {
            providerPublish(std::move(view), invalidateAll, reason == PublishReason::Load);
        };
        loader_ = std::make_unique<IntakeLoader>(std::move(ls));

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
        if (loader_) {
            loader_->shutdown();  // cancel flag, then the read lane is killed
            loader_.reset();
        }
    }

    void reload(bool recheckVersion) {
        if (loader_) loader_->reload(recheckVersion);
    }

    std::string statusLine() const { return loader_ ? loader_->statusLine() : std::string("Stopped"); }

    // A volume came or went: the share may have mounted after startup
    // (`status` skips missing income folders) or one alias may be gone.
    static void volumesChanged();

private:
    IntakeSettings settings_;  // read once in on_init; never on the decorate path
    std::unique_ptr<IntakeLoader> loader_;
    id mountObserver_ = nil;
    id unmountObserver_ = nil;
};

Service *g_service = nullptr;  // main thread only

void Service::volumesChanged() {
    if (g_service == nullptr || !g_service->loader_) return;
    g_service->loader_->remount();
    g_service->loader_->reload(false);
}

class intake_initquit : public initquit {
public:
    void on_init() override {
        setLogBackend(consoleBackend);
        const IntakeSettings settings = config::load();
        setLogLevel(settings.logLevel);
        providerSetStatsEnabled(settings.decorStats);
        if (settings.decorStats) logInfo("decor_stats on: one line per decorate batch");
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

std::string serviceStatusLine() {
    return g_service != nullptr ? g_service->statusLine() : std::string("Stopped");
}

} // namespace intake
