//
//  VolumeSyncStartup.mm
//  foo_plorg_mac
//
//  Startup hook for automatic volume UUID sync.
//  Detects UUID changes on network volumes and repairs .fplite playlist files.
//

#include "../fb2k_sdk.h"
#import "../Core/VolumeSyncService.h"
#import "../Core/ConfigHelper.h"

namespace {

class volume_sync_init : public initquit {
public:
    void on_init() override {
        @autoreleasepool {
            NSString *playlistsDir = [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/foobar2000-v2/playlists-v2.0"];

            if (![[NSFileManager defaultManager] fileExistsAtPath:playlistsDir]) {
                return;
            }

            VolumeSyncService *svc = [VolumeSyncService shared];

            // Check enabled state from JSON mapping file
            NSDictionary *mapping = [svc loadPersistedMapping];
            if (mapping[@"__auto_sync_enabled"] &&
                ![mapping[@"__auto_sync_enabled"] boolValue]) {
                return;
            }

            // Perform repair (patches .fplite files on disk)
            NSDictionary *result = [svc performRepairInDirectory:playlistsDir];

            // Flush buffered log messages to foobar console
            [svc flushDeferredLogsToConsole];

            // foobar has already loaded the (stale) playlists into memory; a
            // restart picks up the patched files. If the auto-restart pref is
            // on, prompt the user; otherwise just log "restart recommended".
            [svc maybePromptForRestartAfterRepair:result];

            // Sync configStore preference to JSON for next startup
            // (configStore is available by the time on_init runs)
            bool enabled = plorg_config::getConfigBool(
                plorg_config::kAutoVolumeSync, plorg_config::kDefaultAutoVolumeSync);
            NSMutableDictionary *m = [[svc loadPersistedMapping] mutableCopy]
                ?: [NSMutableDictionary dictionary];
            m[@"__auto_sync_enabled"] = @(enabled);
            [svc persistMapping:m];

            // Start runtime /Volumes monitor
            if (enabled) {
                [svc startVolumeMonitor];
            }
        }
    }

    void on_quit() override {
        [[VolumeSyncService shared] stopVolumeMonitor];
    }
};

FB2K_SERVICE_FACTORY(volume_sync_init);

} // anonymous namespace
