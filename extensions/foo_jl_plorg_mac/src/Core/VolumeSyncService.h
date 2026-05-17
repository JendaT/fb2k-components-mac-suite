//
//  VolumeSyncService.h
//  foo_plorg_mac
//
//  Automatic volume UUID sync for network shares.
//  Detects when macOS assigns a new UUID to a remounted SMB/NFS/AFP share
//  and repairs .fplite playlist files to use the current UUID.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Backup directory prefix (timestamped: backup_volume_sync_YYYY-MM-DD_HHmmss)
extern NSString * const kVolumeSyncBackupPrefix;

// Maximum backup directories to retain
extern NSInteger const kVolumeSyncMaxBackups;

@interface VolumeSyncService : NSObject

+ (instancetype)shared;

// --- Volume Discovery ---

// Enumerate mounted network volumes, return share_name -> current_UUID
// Uses getmntinfo() filtered to smbfs/nfs/afpfs, then DiskArbitration for UUID
- (NSDictionary<NSString *, NSString *> *)discoverShareToUUIDMapping;

// Extract share name from statfs f_mntfromname
// e.g., "//user@192.168.1.10/music.hq" -> "music.hq"
+ (nullable NSString *)shareNameFromMountSource:(const char *)mntfromname;

// Get volume UUID via DiskArbitration framework
- (nullable NSString *)volumeUUIDForMountPath:(NSString *)path;

// --- fplite Scanning ---

// Scan a single .fplite file for mac-volume:// UUIDs
// Returns dict: UUID (uppercase) -> entry count (NSNumber)
- (NSDictionary<NSString *, NSNumber *> *)scanFpliteFileForUUIDs:(NSString *)path;

// --- UUID Remapping (file-level) ---

// Replace UUIDs in a .fplite file. Preserves UTF-8 BOM.
// Returns YES if file was modified.
- (BOOL)remapUUIDsInFile:(NSString *)path
               fromUUIDs:(NSSet<NSString *> *)sourceUUIDs
                  toUUID:(NSString *)targetUUID
                   error:(NSError **)error;

// --- Backup ---

// Create timestamped backup of files before modification.
// Returns backup directory path, or nil on failure.
- (nullable NSString *)createBackupInDirectory:(NSString *)playlistsDir
                                      forFiles:(NSSet<NSString *> *)filePaths
                                         error:(NSError **)error;

// Remove old backup directories, keeping the most recent kVolumeSyncMaxBackups
- (void)pruneOldBackupsInDirectory:(NSString *)playlistsDir;

// --- Persistent UUID Mapping ---

// File: ~/Library/foobar2000-v2/plorg_volume_uuids.json
// Format:
// {
//   "__auto_sync_enabled": true,
//   "share_name": {
//     "current_uuid": "CEF335FD-...",
//     "known_uuids": ["CEF335FD-...", "CFA535CA-..."],
//     "last_seen": "2026-04-11T10:30:00Z"
//   }
// }

- (NSDictionary *)loadPersistedMapping;
- (void)persistMapping:(NSDictionary *)mapping;

// --- Core Repair ---

// Detect UUID changes and repair .fplite files.
// Returns dict of actions taken: { shareName: { @"from": [old UUIDs], @"to": newUUID } }
// Empty dict means nothing needed repair.
- (NSDictionary *)performRepairInDirectory:(NSString *)playlistsDir;

// --- Runtime Volume Monitor ---

// Watch /Volumes for mount/unmount events, auto-repair on UUID change
- (void)startVolumeMonitor;
- (void)stopVolumeMonitor;

// --- Restart Prompt ---

// If the repair result indicates files were patched and the
// kAutoRestartAfterVolumeSync preference is enabled, show a confirmation
// dialog and relaunch foobar2000 if the user accepts. Otherwise just log a
// "restart recommended" message to the console. The alert is dispatched to
// the main queue, so this is safe to call from any context.
- (void)maybePromptForRestartAfterRepair:(NSDictionary *)repairResult;

// --- Deferred Logging ---

// Buffer log messages when FB2K_console_formatter may not be available
@property (nonatomic, strong, readonly) NSMutableArray<NSString *> *deferredLogMessages;
- (void)flushDeferredLogsToConsole;

@end

NS_ASSUME_NONNULL_END
