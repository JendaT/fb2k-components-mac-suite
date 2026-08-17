//
//  VolumeSyncService.mm
//  foo_plorg_mac
//
//  Automatic volume UUID sync for network shares.
//

#import "VolumeSyncService.h"
#import "PlorgVolumeSyncLogic.h"
#include "../fb2k_sdk.h"
#import "ConfigHelper.h"
#import <DiskArbitration/DiskArbitration.h>
#import <AppKit/AppKit.h>
#import <sys/mount.h>
#import <fcntl.h>
#import <unistd.h>
#import <sqlite3.h>

#include <string>
#include <vector>

NSString * const kVolumeSyncBackupPrefix = @"backup_volume_sync_";
NSInteger const kVolumeSyncMaxBackups = 5;
NSString * const kVolumeSyncAutoSyncEnabledKey = @"__auto_sync_enabled";

static const int kSQLiteBusyTimeoutMillis = 1000;
static const int64_t kVolumeChangeDebounceSeconds = 3;
static const int64_t kSelfHealDeferralSeconds = 2;
static const int64_t kSelfHealVerifyDelaySeconds = 2;
static const int64_t kSelfHealVerifyRetryDelaySeconds = 5;
static const NSInteger kSelfHealVerifyRetries = 3;
static const int kMigratorRelaunchAbortWaitSeconds = 120;

// Staged migration SQL for a given fb2k pid: written before quit, consumed by
// the migrator after quit, removed when it is done.
static NSString *stagedMigrationSQLPathForPID(pid_t pid) {
    return [NSString stringWithFormat:@"/tmp/plorg_metadb_migration_%d.sql", pid];
}

// "Reopen foobar2000 when the migration is finished" request. Written by
// relaunchApp when a migration is staged; the migrator consumes it as its very
// last act. Ordering is guaranteed because one process does both - the app can
// never reopen while sqlite3 still holds metadb.
//
// This replaced a handshake where the relauncher polled for the staged SQL file
// to disappear. File existence is not a lock: the file also vanishes when the
// migrator aborts, when a second migrator finishes first (leaving the first
// still writing), and the poll had a 15-minute bound after which it reopened
// foobar2000 regardless - all of which surfaced as "metadb is corrupted" on
// restart, because fb2k opened the database mid-write.
static NSString *relaunchMarkerPathForPID(pid_t pid) {
    return [NSString stringWithFormat:@"/tmp/plorg_metadb_relaunch_%d.marker", pid];
}

@interface VolumeSyncService ()
@property (nonatomic, strong) NSMutableArray<NSString *> *deferredLogMessages;
@property (nonatomic, strong) dispatch_source_t volumeMonitorSource;
@property (nonatomic, strong) NSString *playlistsDir; // cached for runtime monitor
@property (nonatomic, copy) dispatch_block_t pendingVolumeCheck; // coalesces monitor bursts
@property (nonatomic, strong) NSMutableSet<NSString *> *selfHealAttemptedPaths; // once per path per session
@property (nonatomic, assign) BOOL migratorSpawned; // at most one migrator per fb2k process

// Get volume UUID via DiskArbitration framework
- (nullable NSString *)volumeUUIDForMountPath:(NSString *)path;

- (void)selfHealResolutionCompletedForPaths:(NSArray<NSString *> *)paths
                              resolvedCount:(NSUInteger)resolvedCount
                                    isFinal:(BOOL)isFinal;
@end

namespace {

// Receives the result of the self-heal location resolution. Resolving a real
// file on a mounted-but-unregistered volume is what makes the fb2k core
// register the volume and persist a fresh security-scoped bookmark; we never
// insert the resolved items anywhere.
class PlorgSelfHealNotify : public process_locations_notify {
public:
    std::vector<std::string> m_mountPaths; // volume mount points being healed
    std::vector<std::string> m_files;      // stable storage for the fed paths
    bool m_isFinal = false;                // user-driven fallback attempt?

    void on_completion(metadb_handle_list_cref items) override {
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (const auto &p : m_mountPaths) {
            [paths addObject:[NSString stringWithUTF8String:p.c_str()]];
        }
        [[VolumeSyncService shared] selfHealResolutionCompletedForPaths:paths
                                                          resolvedCount:items.get_count()
                                                                isFinal:m_isFinal];
    }

    void on_aborted() override {
        FB2K_console_formatter() << "[Plorg VolumeSync] Self-heal: location resolution aborted";
    }
};

} // anonymous namespace

@implementation VolumeSyncService

+ (instancetype)shared {
    static VolumeSyncService *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VolumeSyncService alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _deferredLogMessages = [NSMutableArray array];
        _selfHealAttemptedPaths = [NSMutableSet set];
    }
    return self;
}

#pragma mark - Volume Discovery

// Internal: returns share -> @{ @"uuid": NSString, @"mountPath": NSString }
- (NSDictionary<NSString *, NSDictionary *> *)discoverShareInfo {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    if (count <= 0 || !mounts) return result;

    for (int i = 0; i < count; i++) {
        NSString *fstype = [NSString stringWithUTF8String:mounts[i].f_fstypename];

        // Only network filesystems
        if (![fstype isEqualToString:@"smbfs"] &&
            ![fstype isEqualToString:@"nfs"] &&
            ![fstype isEqualToString:@"afpfs"]) {
            continue;
        }

        NSString *mountPath = [NSString stringWithUTF8String:mounts[i].f_mntonname];
        NSString *shareName = [PlorgVolumeSyncLogic shareNameFromMountSource:mounts[i].f_mntfromname];
        if (!shareName || shareName.length == 0) continue;

        NSString *uuid = [self volumeUUIDForMountPath:mountPath];
        if (uuid) {
            // If multiple mounts have the same share name, prefer the first (avoid collision)
            if (!result[shareName]) {
                result[shareName] = @{
                    @"uuid": [uuid uppercaseString],
                    @"mountPath": mountPath,
                };
            }
        }
    }

    return result;
}

- (NSString *)volumeUUIDForMountPath:(NSString *)path {
    if (!path) return nil;

    // First try NSURL resource key (works for local volumes)
    NSURL *volumeURL = [NSURL fileURLWithPath:path];
    NSString *uuidString = nil;
    [volumeURL getResourceValue:&uuidString forKey:NSURLVolumeUUIDStringKey error:nil];
    if (uuidString && uuidString.length > 0) {
        return [uuidString uppercaseString];
    }

    // Fall back to DiskArbitration (works for more volume types including some network)
    struct statfs stfs;
    if (statfs(path.fileSystemRepresentation, &stfs) != 0) {
        return nil;
    }

    DASessionRef session = DASessionCreate(NULL);
    if (!session) return nil;

    NSString *uuid = nil;
    DADiskRef disk = DADiskCreateFromBSDName(NULL, session, stfs.f_mntfromname);
    if (disk) {
        NSDictionary *diskInfo = CFBridgingRelease(DADiskCopyDescription(disk));
        id uuidValue = diskInfo[(__bridge NSString *)kDADiskDescriptionVolumeUUIDKey];
        if (uuidValue && CFGetTypeID((__bridge CFTypeRef)uuidValue) == CFUUIDGetTypeID()) {
            CFUUIDRef cfuuid = (__bridge CFUUIDRef)uuidValue;
            CFStringRef cfUuidString = CFUUIDCreateString(NULL, cfuuid);
            if (cfUuidString) {
                uuid = [(__bridge_transfer NSString *)cfUuidString uppercaseString];
            }
        }
        CFRelease(disk);
    }
    CFRelease(session);

    return uuid;
}

#pragma mark - fplite Scanning

- (NSDictionary<NSString *, NSNumber *> *)scanFpliteFileForUUIDs:(NSString *)path {
    NSError *readError = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!content) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to read %@: %@",
            path, readError.localizedDescription]];
    }
    return [PlorgVolumeSyncLogic scanFpliteContentForUUIDs:content];
}

#pragma mark - UUID Remapping

- (BOOL)remapUUIDsInFile:(NSString *)path
               fromUUIDs:(NSSet<NSString *> *)sourceUUIDs
                  toUUID:(NSString *)targetUUID
                   error:(NSError **)error {
    // Read raw data to detect and preserve BOM
    NSData *rawData = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!rawData) return NO;

    NSData *newData = [PlorgVolumeSyncLogic remappedFpliteData:rawData fromUUIDs:sourceUUIDs toUUID:targetUUID];
    if (!newData) return NO;  // nothing changed (or not UTF-8)

    if (![newData writeToFile:path options:NSDataWritingAtomic error:error]) {
        return NO;
    }

    return YES;
}

#pragma mark - Backup

- (NSString *)createBackupInDirectory:(NSString *)playlistsDir
                             forFiles:(NSSet<NSString *> *)filePaths
                                error:(NSError **)error {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd_HHmmss";
    NSString *timestamp = [formatter stringFromDate:[NSDate date]];

    NSString *backupDir = [playlistsDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@%@", kVolumeSyncBackupPrefix, timestamp]];

    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    for (NSString *filePath in filePaths) {
        NSString *filename = [filePath lastPathComponent];
        NSString *backupPath = [backupDir stringByAppendingPathComponent:filename];

        NSError *copyError = nil;
        if (![fm copyItemAtPath:filePath toPath:backupPath error:&copyError]) {
            [self deferLog:[NSString stringWithFormat:@"[Plorg VolumeSync] Failed to backup %@: %@",
                filename, copyError.localizedDescription]];
        }
    }

    return backupDir;
}

- (void)pruneOldBackupsInDirectory:(NSString *)playlistsDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listError = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:&listError];
    if (!contents) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to list %@ for backup pruning: %@",
            playlistsDir, listError.localizedDescription]];
        return;
    }

    NSMutableArray<NSString *> *backupDirs = [NSMutableArray array];
    for (NSString *item in contents) {
        if ([item hasPrefix:kVolumeSyncBackupPrefix]) {
            [backupDirs addObject:[playlistsDir stringByAppendingPathComponent:item]];
        }
    }

    if ((NSInteger)backupDirs.count <= kVolumeSyncMaxBackups) return;

    // Directory names embed a zero-padded yyyy-MM-dd_HHmmss timestamp, so
    // lexicographic order is chronological order.
    [backupDirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent compare:b.lastPathComponent];
    }];

    NSInteger toRemove = (NSInteger)backupDirs.count - kVolumeSyncMaxBackups;
    for (NSInteger i = 0; i < toRemove; i++) {
        [fm removeItemAtPath:backupDirs[i] error:nil];
    }
}

#pragma mark - Persistent Mapping

- (NSString *)mappingFilePath {
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/foobar2000-v2/plorg_volume_uuids.json"];
}

- (NSDictionary *)loadPersistedMapping {
    NSData *data = [NSData dataWithContentsOfFile:[self mappingFilePath]];
    if (!data) return @{};

    NSError *error = nil;
    id result = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![result isKindOfClass:[NSDictionary class]]) return @{};

    return result;
}

- (void)persistMapping:(NSDictionary *)mapping {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:mapping
                                                  options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                    error:&error];
    if (error || !data) {
        [self deferLog:[NSString stringWithFormat:@"[Plorg VolumeSync] Failed to persist mapping: %@",
            error.localizedDescription]];
        return;
    }

    NSString *dir = [[self mappingFilePath] stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:&dirError]) {
        [self deferLog:[NSString stringWithFormat:@"[Plorg VolumeSync] Failed to create mapping dir: %@",
            dirError.localizedDescription]];
        return;
    }

    // Cocoa only guarantees `error` is populated when the call returns NO.
    NSError *writeError = nil;
    if (![data writeToFile:[self mappingFilePath] options:NSDataWritingAtomic error:&writeError]) {
        [self deferLog:[NSString stringWithFormat:@"[Plorg VolumeSync] Failed to write mapping file: %@",
            writeError.localizedDescription]];
    }
}

#pragma mark - Core Repair

- (NSDictionary *)performRepairInDirectory:(NSString *)playlistsDir {
    self.playlistsDir = playlistsDir;

    // 1. Read foobar's volume registry from config.sqlite. Each UUID has an
    //    originalPath (e.g., "/Volumes/music") and a security-scoped bookmark
    //    that may or may not currently resolve.
    NSDictionary<NSString *, NSDictionary *> *foobarVolumes = [self readFoobarVolumeRegistry];
    if (foobarVolumes.count == 0) {
        [self deferLog:@"[Plorg VolumeSync] foobar volume registry empty or unreadable; skipping"];
        return @{};
    }

    // 2. Group UUIDs by their canonical path. A UUID is "live" iff its bookmark
    //    resolved to an existing path. Multiple UUIDs typically map to the same
    //    path because foobar registers a fresh UUID on each remount.
    NSDictionary<NSString *, NSArray<NSString *> *> *liveUUIDsByPath =
        [PlorgVolumeSyncLogic liveUUIDsByPathFromRegistry:foobarVolumes];

    // 3. Scan .fplite files for UUIDs in active use.
    NSDictionary *fpliteIndex = [self buildFpliteUUIDIndexInDirectory:playlistsDir];
    if (fpliteIndex.count == 0) {
        [self deferLog:@"[Plorg VolumeSync] No mac-volume:// references in .fplite files"];
        return @{};
    }

    // 4. For each UUID found in .fplite, decide whether it needs remapping.
    __weak typeof(self) weakSelf = self;
    BOOL (^fileExists)(NSString *) = ^BOOL(NSString *path) {
        return [[NSFileManager defaultManager] fileExistsAtPath:path];
    };
    BOOL (^isMounted)(NSString *) = ^BOOL(NSString *path) {
        return [self isCurrentlyMountedPath:path];
    };
    NSDictionary *remapActions = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:foobarVolumes
        fpliteIndex:fpliteIndex
        liveUUIDsByPath:liveUUIDsByPath
        fileExists:fileExists
        log:^(NSString *message) {
            [weakSelf deferLog:message];
        }];

    // 5. Apply .fplite remapping if needed.
    NSDictionary *result = @{};
    if (remapActions.count > 0) {
        result = [self applyRemapping:remapActions inDirectory:playlistsDir];
    } else {
        // remapActions can be empty for two very different reasons: everything
        // really is live, OR a stale UUID was found with no live replacement
        // (already logged per-UUID above). Report which, so the log does not
        // falsely claim liveness when playback is actually broken.
        NSArray<NSString *> *unresolved = [PlorgVolumeSyncLogic unresolvedFpliteUUIDsInIndex:fpliteIndex
                                                                              registry:foobarVolumes
                                                                          remapActions:remapActions];
        if (unresolved.count > 0) {
            // Distinguish "not mounted" from "mounted but foobar has no working
            // bookmark for this session" — advising the user to mount an
            // already-mounted volume is a dead end (observed 2026-07-11).
            NSArray<NSString *> *mountedPaths =
                [PlorgVolumeSyncLogic mountedRegistryPathsForUnresolvedUUIDs:unresolved
                                                               registry:foobarVolumes
                                                              isMounted:isMounted];
            if (mountedPaths.count > 0) {
                [self deferLog:[NSString stringWithFormat:
                    @"[Plorg VolumeSync] %lu stale .fplite UUID(s); %@ IS mounted but "
                    @"foobar2000 has no working bookmark for this mount session (no registry "
                    @"entry resolves). Nothing to remap onto.",
                    (unsigned long)unresolved.count,
                    [mountedPaths componentsJoinedByString:@", "]]];

                // Self-heal: make the core mint a fresh bookmark by resolving
                // one real file from the mounted volume, then re-run repair.
                NSArray *candidates = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:unresolved
                    registry:foobarVolumes
                    fpliteIndex:fpliteIndex
                    isMounted:isMounted
                    fileExists:fileExists];
                [self scheduleSelfHealForCandidates:candidates];
            } else {
                [self deferLog:[NSString stringWithFormat:
                    @"[Plorg VolumeSync] %lu .fplite UUID(s) are stale with no live replacement "
                    @"in foobar's volume registry and the volume is not mounted; nothing patched. "
                    @"Mount the volume, open it in foobar2000, then rescan.",
                    (unsigned long)unresolved.count]];
            }
        } else {
            [self deferLog:@"[Plorg VolumeSync] All .fplite UUIDs are live; nothing to patch"];
        }
    }

    // 5b. Orphan cache migrations — dead UUIDs that aren't in .fplite (so no
    //     remap is required) but DO have cached metadb rows that we can copy
    //     onto an equivalent live UUID. Catches the case where a previous
    //     repair patched .fplite before the metadb migrator existed.
    NSDictionary *orphanMigrations = [self discoverOrphanCacheMigrationsWithFoobarVolumes:foobarVolumes
                                                                          liveUUIDsByPath:liveUUIDsByPath];

    NSMutableDictionary *allMigrations = [(result ?: @{}) mutableCopy] ?: [NSMutableDictionary dictionary];
    for (NSString *u in orphanMigrations) {
        if (!allMigrations[u]) allMigrations[u] = orphanMigrations[u];
    }

    // Spawn the metadb migrator if either kind of work was found.
    if (allMigrations.count > 0) {
        if (orphanMigrations.count > 0 && result.count == 0) {
            [self deferLog:[NSString stringWithFormat:
                @"[Plorg VolumeSync] No .fplite changes needed but found %lu orphan UUID(s) "
                @"with cached metadata that can be migrated to live UUIDs.",
                (unsigned long)orphanMigrations.count]];
        }
        [self spawnMetadbMigratorForRemapActions:allMigrations];
    }

    // 6. Persist a small diagnostic snapshot for the user / next run.
    [self persistDiagnosticSnapshot:foobarVolumes
                       remapActions:allMigrations
                  liveUUIDsByPath:liveUUIDsByPath];

    return result;
}

// Find dead UUIDs whose metadb cache could be migrated to a live UUID for the
// same originalPath. Heuristic: only schedule a migration when the dead UUID
// has more cached rows than the live target, otherwise the work was already
// done in a prior session.
- (NSDictionary<NSString *, NSString *> *)discoverOrphanCacheMigrationsWithFoobarVolumes:(NSDictionary *)foobarVolumes
                                                                          liveUUIDsByPath:(NSDictionary *)liveUUIDsByPath {
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];

    NSString *dbPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/foobar2000-v2/metadb.sqlite"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) return result;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2([dbPath fileSystemRepresentation], &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return result;
    }
    sqlite3_busy_timeout(db, kSQLiteBusyTimeoutMillis);

    // UUID -> row count in metadb.
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT substr(name, instr(name, 'mac-volume://')+13, 36) AS uuid, COUNT(*) "
            "FROM metadb WHERE name LIKE '%mac-volume://%' GROUP BY uuid",
            -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *u = sqlite3_column_text(stmt, 0);
            if (!u) continue;
            NSString *uuid = [[NSString stringWithUTF8String:(const char *)u] uppercaseString];
            if (uuid.length != 36 || ![uuid containsString:@"-"]) continue;
            counts[uuid] = @(sqlite3_column_int(stmt, 1));
        }
        sqlite3_finalize(stmt);
    }
    sqlite3_close(db);

    __weak typeof(self) weakSelf = self;
    [result addEntriesFromDictionary:
        [PlorgVolumeSyncLogic orphanCacheMigrationsWithRowCounts:counts
                                                   registry:foobarVolumes
                                            liveUUIDsByPath:liveUUIDsByPath
                                                        log:^(NSString *message) {
            [weakSelf deferLog:message];
        }]];

    return result;
}

// YES iff `path` is itself a current mount point (statfs f_mntonname == path).
// Deliberately NOT fileExistsAtPath: — a leftover empty /Volumes/<name> dir
// from a dead mount must not count as "mounted".
- (BOOL)isCurrentlyMountedPath:(NSString *)path {
    if (path.length == 0) return NO;
    struct statfs stfs;
    if (statfs(path.fileSystemRepresentation, &stfs) != 0) return NO;
    return strcmp(stfs.f_mntonname, path.fileSystemRepresentation) == 0;
}

// Reads ~/Library/foobar2000-v2/config.sqlite read-only and returns
// uuid (uppercase) -> @{ @"originalPath": NSString,
//                        @"resolvedPath": NSString | nil,
//                        @"isLive": @YES/@NO }
- (NSDictionary<NSString *, NSDictionary *> *)readFoobarVolumeRegistry {
    NSString *dbPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/foobar2000-v2/config.sqlite"];

    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2([dbPath fileSystemRepresentation], &db,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL);
    if (rc != SQLITE_OK) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to open config.sqlite: %d", rc]];
        if (db) sqlite3_close(db);
        return @{};
    }
    sqlite3_busy_timeout(db, kSQLiteBusyTimeoutMillis); // play nicely with running foobar

    NSMutableDictionary<NSString *, NSMutableDictionary *> *registry = [NSMutableDictionary dictionary];

    // Pass 1: originalPath strings.
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db,
            "SELECT name, value FROM configStrings WHERE name LIKE 'mac.volume.%.originalPath'",
            -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *nameBytes = sqlite3_column_text(stmt, 0);
            const unsigned char *valBytes = sqlite3_column_text(stmt, 1);
            if (!nameBytes || !valBytes) continue;

            NSString *name = [NSString stringWithUTF8String:(const char *)nameBytes];
            NSString *value = [NSString stringWithUTF8String:(const char *)valBytes];
            NSString *uuid = [self extractVolumeUUIDFromConfigKey:name];
            if (!uuid) continue;

            NSMutableDictionary *entry = registry[uuid] ?: [NSMutableDictionary dictionary];
            entry[@"originalPath"] = value;
            entry[@"isLive"] = @NO;
            registry[uuid] = entry;
        }
        sqlite3_finalize(stmt);
        stmt = NULL;
    }

    // Pass 2: bookmark blobs — try to resolve each.
    if (sqlite3_prepare_v2(db,
            "SELECT name, value FROM configBlobs WHERE name LIKE 'mac.volume.%.bookmark'",
            -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *nameBytes = sqlite3_column_text(stmt, 0);
            const void *blobBytes = sqlite3_column_blob(stmt, 1);
            int blobLen = sqlite3_column_bytes(stmt, 1);
            if (!nameBytes || !blobBytes || blobLen <= 0) continue;

            NSString *name = [NSString stringWithUTF8String:(const char *)nameBytes];
            NSString *uuid = [self extractVolumeUUIDFromConfigKey:name];
            if (!uuid) continue;

            NSMutableDictionary *entry = registry[uuid] ?: [NSMutableDictionary dictionary];

            NSData *bookmark = [NSData dataWithBytes:blobBytes length:blobLen];
            BOOL stale = NO;
            NSError *err = nil;
            NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark
                options:NSURLBookmarkResolutionWithoutUI |
                        NSURLBookmarkResolutionWithoutMounting
                relativeToURL:nil
                bookmarkDataIsStale:&stale
                error:&err];

            if (url && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                entry[@"resolvedPath"] = url.path;
                entry[@"isLive"] = @YES;
            } else {
                entry[@"isLive"] = @NO;
            }
            registry[uuid] = entry;
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);

    NSUInteger live = 0;
    for (NSString *u in registry) {
        if ([registry[u][@"isLive"] boolValue]) live++;
    }
    [self deferLog:[NSString stringWithFormat:
        @"[Plorg VolumeSync] foobar registry: %lu volumes (%lu live)",
        (unsigned long)registry.count, (unsigned long)live]];

    return registry;
}

// "mac.volume.<UUID>.originalPath" / "mac.volume.<UUID>.bookmark" -> UUID (uppercase)
- (NSString *)extractVolumeUUIDFromConfigKey:(NSString *)key {
    return [PlorgVolumeSyncLogic volumeUUIDFromConfigKey:key];
}

// Write a snapshot to plorg_volume_uuids.json — purely diagnostic. We preserve
// __auto_sync_enabled (used for early opt-out) and overwrite share entries with
// the current registry summary.
- (void)persistDiagnosticSnapshot:(NSDictionary *)foobarVolumes
                     remapActions:(NSDictionary *)remapActions
                  liveUUIDsByPath:(NSDictionary *)liveUUIDsByPath {
    NSDictionary *previous = [self loadPersistedMapping];
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];

    id autoSyncEnabled = previous[kVolumeSyncAutoSyncEnabledKey];
    if ([autoSyncEnabled isKindOfClass:[NSNumber class]]) {
        snapshot[kVolumeSyncAutoSyncEnabledKey] = autoSyncEnabled;
    }

    NSMutableDictionary *paths = [NSMutableDictionary dictionary];
    for (NSString *path in liveUUIDsByPath) {
        paths[path] = @{ @"live_uuids": [liveUUIDsByPath[path] copy] };
    }
    snapshot[@"paths"] = paths;

    NSMutableArray *deadList = [NSMutableArray array];
    for (NSString *uuid in foobarVolumes) {
        if (![foobarVolumes[uuid][@"isLive"] boolValue]) {
            [deadList addObject:@{
                @"uuid": uuid,
                @"originalPath": foobarVolumes[uuid][@"originalPath"] ?: @"",
            }];
        }
    }
    snapshot[@"dead_uuids"] = deadList;
    snapshot[@"last_remap_actions"] = remapActions ?: @{};

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    snapshot[@"last_run"] = [fmt stringFromDate:[NSDate date]];

    [self persistMapping:snapshot];
}

// Returns UUID(uppercase) -> @{ @"count": NSNumber, @"samplePath": NSString }
// samplePath is the path portion after the UUID from one of the .fplite entries.
- (NSDictionary<NSString *, NSDictionary *> *)buildFpliteUUIDIndexInDirectory:(NSString *)playlistsDir {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *index = [NSMutableDictionary dictionary];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listError = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:&listError];
    if (!contents) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to list %@ for .fplite indexing: %@",
            playlistsDir, listError.localizedDescription]];
        return index;
    }

    for (NSString *item in contents) {
        if (![item hasSuffix:@".fplite"]) continue;
        NSString *fullPath = [playlistsDir stringByAppendingPathComponent:item];

        NSError *readError = nil;
        NSString *content = [NSString stringWithContentsOfFile:fullPath
                                                      encoding:NSUTF8StringEncoding error:&readError];
        if (!content) {
            [self deferLog:[NSString stringWithFormat:
                @"[Plorg VolumeSync] Failed to read %@: %@",
                fullPath, readError.localizedDescription]];
        }
        [PlorgVolumeSyncLogic indexFpliteContent:content into:index];
    }

    return index;
}

- (void)scanForStaleUUIDsInDirectory:(NSString *)playlistsDir
                         withMapping:(NSDictionary *)mapping
                       currentMounts:(NSDictionary *)currentMounts
                        remapActions:(NSMutableDictionary *)remapActions {
    // Collect all fplite files
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listError = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:&listError];
    if (!contents) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to list %@ for stale UUID scan: %@",
            playlistsDir, listError.localizedDescription]];
        return;
    }

    NSMutableDictionary *allFpliteUUIDs = [NSMutableDictionary dictionary]; // UUID -> total count

    for (NSString *item in contents) {
        if (![item hasSuffix:@".fplite"]) continue;
        NSString *fullPath = [playlistsDir stringByAppendingPathComponent:item];
        NSDictionary *fileUUIDs = [self scanFpliteFileForUUIDs:fullPath];
        for (NSString *uuid in fileUUIDs) {
            NSNumber *existing = allFpliteUUIDs[uuid];
            allFpliteUUIDs[uuid] = @((existing ? existing.unsignedIntegerValue : 0) +
                                     [fileUUIDs[uuid] unsignedIntegerValue]);
        }
    }

    // For each share with a known mapping, check if any known_uuid is in the fplite files
    for (NSString *shareName in mapping) {
        if ([shareName hasPrefix:@"__"]) continue; // skip metadata keys

        NSDictionary *shareEntry = mapping[shareName];
        NSString *currentUUID = shareEntry[@"current_uuid"];
        NSArray *knownUUIDs = shareEntry[@"known_uuids"];

        if (!currentUUID || !knownUUIDs) continue;

        // Only remap if we have a currently mounted volume for this share
        if (!currentMounts[shareName]) continue;

        for (NSString *knownUUID in knownUUIDs) {
            if ([knownUUID isEqualToString:currentUUID]) continue;
            if (allFpliteUUIDs[knownUUID]) {
                remapActions[knownUUID] = currentUUID;
                [self deferLog:[NSString stringWithFormat:
                    @"[Plorg VolumeSync] Found stale UUID %@ for share '%@', remapping to %@",
                    knownUUID, shareName, currentUUID]];
            }
        }
    }
}

- (NSDictionary *)applyRemapping:(NSDictionary *)remapActions
                     inDirectory:(NSString *)playlistsDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *listError = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:&listError];
    if (!contents) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to list %@ for remapping: %@",
            playlistsDir, listError.localizedDescription]];
        return @{};
    }

    // Collect affected files
    NSMutableSet<NSString *> *affectedFiles = [NSMutableSet set];
    NSSet<NSString *> *staleUUIDs = [NSSet setWithArray:remapActions.allKeys];

    for (NSString *item in contents) {
        if (![item hasSuffix:@".fplite"]) continue;
        NSString *fullPath = [playlistsDir stringByAppendingPathComponent:item];
        NSDictionary *fileUUIDs = [self scanFpliteFileForUUIDs:fullPath];

        for (NSString *uuid in fileUUIDs) {
            if ([staleUUIDs containsObject:uuid]) {
                [affectedFiles addObject:fullPath];
                break;
            }
        }
    }

    if (affectedFiles.count == 0) return @{};

    // Group source UUIDs by target UUID
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *byTarget = [NSMutableDictionary dictionary];
    for (NSString *oldUUID in remapActions) {
        NSString *newUUID = remapActions[oldUUID];
        if (!byTarget[newUUID]) byTarget[newUUID] = [NSMutableSet set];
        [byTarget[newUUID] addObject:oldUUID];
    }

    // Create backup
    NSError *backupError = nil;
    NSString *backupDir = [self createBackupInDirectory:playlistsDir forFiles:affectedFiles error:&backupError];
    if (!backupDir) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Backup failed, aborting repair: %@",
            backupError.localizedDescription]];
        return @{};
    }
    [self deferLog:[NSString stringWithFormat:@"[Plorg VolumeSync] Backup created: %@",
        [backupDir lastPathComponent]]];

    // Apply remapping. A file touched by several target groups must only be
    // counted once, so track distinct paths rather than incrementing per pass.
    NSMutableSet<NSString *> *modifiedFiles = [NSMutableSet set];
    for (NSString *filePath in affectedFiles) {
        for (NSString *targetUUID in byTarget) {
            NSSet *sources = byTarget[targetUUID];
            NSError *error = nil;
            BOOL modified = [self remapUUIDsInFile:filePath fromUUIDs:sources toUUID:targetUUID error:&error];
            if (modified) [modifiedFiles addObject:filePath];
            if (error) {
                [self deferLog:[NSString stringWithFormat:
                    @"[Plorg VolumeSync] Error remapping %@: %@",
                    [filePath lastPathComponent], error.localizedDescription]];
            }
        }
    }

    [self pruneOldBackupsInDirectory:playlistsDir];

    [self deferLog:[NSString stringWithFormat:
        @"[Plorg VolumeSync] Repaired %ld playlist files (%ld UUID(s) remapped)",
        (long)modifiedFiles.count, (long)remapActions.count]];

    return remapActions;
}

#pragma mark - Runtime Volume Monitor

- (void)startVolumeMonitor {
    if (self.volumeMonitorSource) return; // Already running

    int fd = open("/Volumes", O_EVTONLY);
    if (fd < 0) {
        [self deferLog:@"[Plorg VolumeSync] Failed to open /Volumes for monitoring"];
        return;
    }

    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_LINK,
        dispatch_get_main_queue());

    __weak typeof(self) weakSelf = self;

    dispatch_source_set_event_handler(source, ^{
        // A single mount emits several /Volumes events; without coalescing each
        // one scheduled an independent repair, so a burst produced N registry
        // scans ~3s later. Cancel any pending check and (re)arm one 3s block so
        // only the last event in a burst triggers a repair.
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (strongSelf.pendingVolumeCheck) {
            dispatch_block_cancel(strongSelf.pendingVolumeCheck);
        }

        dispatch_block_t check = dispatch_block_create((dispatch_block_flags_t)0, ^{
            typeof(self) s = weakSelf;
            if (!s) return;
            s.pendingVolumeCheck = nil;
            [s handleVolumeChange];
        });
        strongSelf.pendingVolumeCheck = check;

        // Wait kVolumeChangeDebounceSeconds for the mount to fully settle before scanning.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kVolumeChangeDebounceSeconds * NSEC_PER_SEC),
            dispatch_get_main_queue(), check);
    });

    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });

    dispatch_resume(source);
    self.volumeMonitorSource = source;
}

- (void)stopVolumeMonitor {
    if (self.pendingVolumeCheck) {
        dispatch_block_cancel(self.pendingVolumeCheck);
        self.pendingVolumeCheck = nil;
    }
    if (self.volumeMonitorSource) {
        dispatch_source_cancel(self.volumeMonitorSource);
        self.volumeMonitorSource = nil;
    }
}

- (void)handleVolumeChange {
    if (!self.playlistsDir) return;

    NSDictionary *result = [self performRepairInDirectory:self.playlistsDir];
    [self flushDeferredLogsToConsole];
    [self maybePromptForRestartAfterRepair:result];
}

#pragma mark - Self-Heal

// Filter candidates against the once-per-session guard and the preference,
// then schedule the mint attempt. Called from within performRepairInDirectory:
// (which may run during on_init), so the actual SDK call is deferred to give
// the core time to finish starting up.
- (void)scheduleSelfHealForCandidates:(NSArray<NSDictionary *> *)candidates {
    if (candidates.count == 0) {
        [self deferLog:@"[Plorg VolumeSync] Self-heal: no readable sample file found on the "
            @"mounted volume. To register it, play or add any file from that volume in "
            @"foobar2000, then rescan."];
        return;
    }

    if (!plorg_config::getConfigBool(plorg_config::kVolumeSelfHeal,
                                     plorg_config::kDefaultVolumeSelfHeal)) {
        [self deferLog:@"[Plorg VolumeSync] Self-heal disabled in preferences. To register the "
            @"volume, play or add any file from it in foobar2000, then rescan."];
        return;
    }

    NSMutableArray<NSDictionary *> *fresh = [NSMutableArray array];
    for (NSDictionary *c in candidates) {
        if ([self.selfHealAttemptedPaths containsObject:c[@"path"]]) continue;
        [self.selfHealAttemptedPaths addObject:c[@"path"]];
        [fresh addObject:c];
    }
    if (fresh.count == 0) return; // already attempted this session

    NSMutableArray *paths = [NSMutableArray array];
    for (NSDictionary *c in fresh) [paths addObject:c[@"path"]];
    [self deferLog:[NSString stringWithFormat:
        @"[Plorg VolumeSync] Self-heal: asking foobar2000 to register %@ by resolving a "
        @"file from the volume...",
        [paths componentsJoinedByString:@", "]]];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kSelfHealDeferralSeconds * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        [weakSelf attemptSelfHealForCandidates:fresh];
    });
}

- (void)attemptSelfHealForCandidates:(NSArray<NSDictionary<NSString *, NSString *> *> *)candidates {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSDictionary *c in candidates) {
        NSString *path = c[@"path"];
        NSString *file = c[@"file"];
        if (path.length == 0 || file.length == 0) continue;
        [paths addObject:path];
        [files addObject:file];
    }
    if (files.count == 0) return;
    [self mintBookmarkForFiles:files mountPaths:paths isFinal:NO];
}

// Feed real file paths through the core's location machinery. Bookmark
// creation goes through foobar2000 itself, which owns config.sqlite; plorg
// stays read-only on that database (hard rule).
// Lifetimes: filePtrs holds raw const char* into notify->m_files, so the fed
// strings must live in the notify object, not in locals. The notify (and thus
// m_files) is kept alive by the service reference process_locations_async
// holds until on_completion/on_aborted, which arrive on the main thread.
- (void)mintBookmarkForFiles:(NSArray<NSString *> *)files
                  mountPaths:(NSArray<NSString *> *)mountPaths
                     isFinal:(BOOL)isFinal {
    try {
        auto notify = fb2k::service_new<PlorgSelfHealNotify>();
        notify->m_isFinal = isFinal;
        for (NSString *p in mountPaths) notify->m_mountPaths.push_back(p.UTF8String);
        for (NSString *f in files) notify->m_files.push_back(f.UTF8String);

        pfc::list_t<const char *> filePtrs;
        for (const auto &f : notify->m_files) filePtrs.add_item(f.c_str());

        playlist_incoming_item_filter_v2::get()->process_locations_async(
            filePtrs,
            playlist_incoming_item_filter_v2::op_flag_no_filter |
            playlist_incoming_item_filter_v2::op_flag_delay_ui,
            nullptr, nullptr, nullptr,
            notify);
    } catch (const std::exception &e) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Self-heal mint failed: %s", e.what()]];
    } catch (...) {
        [self deferLog:@"[Plorg VolumeSync] Self-heal mint failed: core services unavailable."];
    }
}

- (void)selfHealResolutionCompletedForPaths:(NSArray<NSString *> *)paths
                              resolvedCount:(NSUInteger)resolvedCount
                                    isFinal:(BOOL)isFinal {
    FB2K_console_formatter() << "[Plorg VolumeSync] Self-heal: resolved "
        << (unsigned)resolvedCount << " item(s); verifying foobar's volume registry...";

    // The core may persist the new volume bookmark to config.sqlite with a
    // small lag after resolution; verify with retries before concluding.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kSelfHealVerifyDelaySeconds * NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        [weakSelf verifySelfHealForPaths:paths remainingRetries:kSelfHealVerifyRetries isFinal:isFinal];
    });
}

- (void)verifySelfHealForPaths:(NSArray<NSString *> *)paths
              remainingRetries:(NSInteger)retries
                       isFinal:(BOOL)isFinal {
    NSDictionary *registry = [self readFoobarVolumeRegistry];
    NSDictionary *liveByPath = [PlorgVolumeSyncLogic liveUUIDsByPathFromRegistry:registry];

    NSMutableArray<NSString *> *healed = [NSMutableArray array];
    NSMutableArray<NSString *> *pending = [NSMutableArray array];
    for (NSString *path in paths) {
        NSString *key = [PlorgVolumeSyncLogic normalizedVolumePath:path];
        if ([liveByPath[key] count] > 0) [healed addObject:path];
        else [pending addObject:path];
    }

    if (pending.count > 0 && retries > 0) {
        [self flushDeferredLogsToConsole];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kSelfHealVerifyRetryDelaySeconds * NSEC_PER_SEC),
            dispatch_get_main_queue(), ^{
            [weakSelf verifySelfHealForPaths:paths remainingRetries:retries - 1 isFinal:isFinal];
        });
        return;
    }

    if (healed.count > 0) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Self-heal succeeded: foobar2000 minted a live bookmark for "
            @"%@. Re-running repair to remap stale playlists.",
            [healed componentsJoinedByString:@", "]]];
        NSDictionary *result = [self performRepairInDirectory:self.playlistsDir];
        [self flushDeferredLogsToConsole];
        [self maybePromptForRestartAfterRepair:result];
    }

    if (pending.count > 0) {
        if (isFinal) {
            [self deferLog:[NSString stringWithFormat:
                @"[Plorg VolumeSync] Self-heal: foobar2000 did not register %@ even after "
                @"resolving a file from it. Play or add any file from that volume in "
                @"foobar2000 (e.g. drag it into a playlist), then rescan.",
                [pending componentsJoinedByString:@", "]]];
        } else {
            [self deferLog:[NSString stringWithFormat:
                @"[Plorg VolumeSync] Self-heal: resolving a file did not make foobar2000 "
                @"persist a bookmark for %@. Falling back to manual registration.",
                [pending componentsJoinedByString:@", "]]];
            [self promptToRegisterMountedPaths:pending];
        }
    }

    [self flushDeferredLogsToConsole];
}

// One-click fallback: the volume is mounted and readable, foobar2000 just has
// no working bookmark for it. A user-initiated file choice fed through the
// core is the reliable way to make it register the volume. Gated by the same
// opt-in preference as the restart prompt; when off, log instructions only.
- (void)promptToRegisterMountedPaths:(NSArray<NSString *> *)paths {
    if (paths.count == 0) return;

    BOOL autoPrompt = plorg_config::getConfigBool(
        plorg_config::kAutoRestartAfterVolumeSync,
        plorg_config::kDefaultAutoRestartAfterVolumeSync);
    if (!autoPrompt) {
        FB2K_console_formatter() << "[Plorg VolumeSync] To register the volume with "
            "foobar2000, play or add any file from it (e.g. drag it into a playlist), "
            "then rescan.";
        return;
    }

    NSString *joined = [paths componentsJoinedByString:@", "];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Register volume with foobar2000?";
        alert.informativeText = [NSString stringWithFormat:
            @"Playlists reference %@, which is mounted but not registered with "
            @"foobar2000 in this session (no working bookmark).\n\n"
            @"Choose any audio file from the volume to register it; stale playlists "
            @"will then be repaired automatically.", joined];
        [alert addButtonWithTitle:@"Choose File..."];
        [alert addButtonWithTitle:@"Later"];
        alert.alertStyle = NSAlertStyleInformational;

        if ([alert runModal] != NSAlertFirstButtonReturn) {
            FB2K_console_formatter() << "[Plorg VolumeSync] Registration deferred. Play or "
                "add any file from the volume in foobar2000 to register it, then rescan.";
            return;
        }

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.directoryURL = [NSURL fileURLWithPath:paths.firstObject];
        panel.message = @"Choose any audio file on the volume to register it with foobar2000";
        panel.prompt = @"Register";

        if ([panel runModal] == NSModalResponseOK && panel.URL.path.length > 0) {
            [weakSelf mintBookmarkForFiles:@[panel.URL.path]
                                mountPaths:paths
                                   isFinal:YES];
        } else {
            FB2K_console_formatter() << "[Plorg VolumeSync] Registration cancelled.";
        }
    });
}

#pragma mark - Restart Prompt

- (void)maybePromptForRestartAfterRepair:(NSDictionary *)repairResult {
    if (repairResult.count == 0) return;

    // Note: the metadb cache migrator is spawned inside performRepairInDirectory:
    // because it also covers orphan UUIDs that have no .fplite changes.

    BOOL autoPrompt = plorg_config::getConfigBool(
        plorg_config::kAutoRestartAfterVolumeSync,
        plorg_config::kDefaultAutoRestartAfterVolumeSync);

    if (!autoPrompt) {
        FB2K_console_formatter() << "[Plorg VolumeSync] Playlist files repaired on disk. "
            "Restart foobar2000 to load the fixed playlists. Cached metadata will be "
            "migrated automatically when foobar quits.";
        return;
    }

    NSUInteger count = repairResult.count;
    __weak typeof(self) weakSelf = self;

    // Defer past current call stack so on_init / dispatch handler can return first
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Volume UUIDs repaired";
        alert.informativeText = [NSString stringWithFormat:
            @"foobar2000 needs to restart to load the fixed playlists.\n\n"
            @"%lu stale volume UUID%@ remapped. Cached metadata will be migrated "
            @"during shutdown so tracks stay indexed after relaunch.",
            (unsigned long)count, count == 1 ? @"" : @"s"];
        [alert addButtonWithTitle:@"Restart Now"];
        [alert addButtonWithTitle:@"Later"];
        alert.alertStyle = NSAlertStyleInformational;

        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            [weakSelf relaunchApp];
        } else {
            FB2K_console_formatter() << "[Plorg VolumeSync] Restart deferred. "
                "Playlists will use stale references until next launch.";
        }
    });
}

- (void)spawnMetadbMigratorForRemapActions:(NSDictionary *)remapActions {
    if (remapActions.count == 0) return;

    NSString *dbPath = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/foobar2000-v2/metadb.sqlite"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        [self deferLog:@"[Plorg VolumeSync] metadb.sqlite not found; skipping cache migration"];
        return;
    }

    // Discover all metadb_index_<GUID> tables. GLOB (unlike LIKE) treats '_'
    // literally, so 'metadb_index_*' cannot match the metadb_indexes metadata
    // table; the SQL builder additionally shape-validates every name before
    // writing to it.
    NSMutableArray<NSString *> *indexTables = [NSMutableArray array];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([dbPath fileSystemRepresentation], &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(db, kSQLiteBusyTimeoutMillis);
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db,
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name GLOB 'metadb_index_*' AND NOT name GLOB '*_data'",
                -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *n = sqlite3_column_text(stmt, 0);
                if (!n) continue;
                NSString *name = [NSString stringWithUTF8String:(const char *)n];
                if ([PlorgVolumeSyncLogic isValidMetadbIndexTableName:name]) {
                    [indexTables addObject:name];
                }
            }
            sqlite3_finalize(stmt);
        }
        sqlite3_close(db);
    }

    // Build the migration SQL. ".bail on" makes sqlite3 abort on the first
    // error instead of continuing to COMMIT; exiting with the transaction
    // open rolls everything back, so the migration is all-or-nothing.
    NSString *sql = [PlorgVolumeSyncLogic metadbMigrationSQLForRemapActions:remapActions
                                                           indexTables:indexTables];
    sql = [@".bail on\n" stringByAppendingString:sql];

    // Stage the SQL in /tmp; the helper script feeds it to sqlite3 after foobar
    // exits and deletes it when done.
    pid_t pid = getpid();
    NSString *sqlPath = stagedMigrationSQLPathForPID(pid);
    NSError *writeErr = nil;
    if (![sql writeToFile:sqlPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to stage migration SQL: %@",
            writeErr.localizedDescription]];
        return;
    }

    // At most one migrator per fb2k process. Repair runs on every startup and
    // every /Volumes event, and the orphan-cache heuristic re-detects the same
    // dead UUIDs until the migration actually runs - so without this guard each
    // pass spawned another migrator, all sharing this one staged SQL path. Two
    // were observed live on 2026-08-05, concurrently copying the same backup
    // file. Later passes only refresh the staged SQL, which the waiting script
    // reads after quit, so the newest plan still wins.
    if (self.migratorSpawned) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Migration plan updated (%lu UUID remap%@); "
            "the already-scheduled migrator will pick it up at quit.",
            (unsigned long)remapActions.count, remapActions.count == 1 ? @"" : @"s"]];
        return;
    }

    NSString *logPath = [NSString stringWithFormat:@"/tmp/plorg_metadb_migration_%d.log", pid];
    NSString *markerPath = relaunchMarkerPathForPID(pid);
    NSString *appPath = [[NSBundle mainBundle] bundlePath] ?: @"";
    // This script owns the entire post-quit sequence, in order:
    //  1. waits for this fb2k process to exit;
    //  2. aborts if another foobar2000 is already running (user relaunched
    //     manually before the migration could start) - never write to metadb
    //     while any fb2k session may hold it;
    //  3. best-effort backup: one rotating copy next to the DB when disk
    //     space allows (DB + WAL/SHM siblings);
    //  4. feeds the staged SQL to sqlite3 (transactional, .bail on);
    //  5. verifies with quick_check, restoring the backup if it fails;
    //  6. VACUUMs, because the copy-then-delete migration frees pages inside
    //     the file that SQLite never returns to the filesystem - without this
    //     the DB parks at ~2.7x the size it needs, forever;
    //  7. drops the now-redundant backup (the DB has been verified good);
    //  8. reopens foobar2000 if relaunchApp asked for it.
    // Steps 4-8 in one process is what guarantees fb2k cannot reopen while
    // sqlite3 still holds metadb - see relaunchMarkerPathForPID.
    NSString *script = [NSString stringWithFormat:
        @"export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"
        @"DB='%@'; SQL='%@'; LOG='%@'; MARK='%@'; BK=\"$DB.plorg-pre-migration\"\n"
        @"relaunch() { [ -e \"$MARK\" ] || return 0; rm -f \"$MARK\"; if [ -n '%@' ]; then /usr/bin/open '%@'; fi; return 0; }\n"
        @"while kill -0 %d 2>/dev/null; do sleep 0.5; done\n"
        @"sleep 1\n"
        @"t=0\n"
        @"while /usr/bin/pgrep -x foobar2000 >/dev/null 2>&1; do\n"
        @"  t=$((t+1))\n"
        @"  if [ \"$t\" -ge %d ]; then\n"
        @"    echo \"[Plorg VolumeSync] Migration SKIPPED: foobar2000 was relaunched before it could run. It will be rescheduled on next repair.\" > \"$LOG\"\n"
        @"    rm -f \"$SQL\" \"$MARK\"\n"
        @"    exit 0\n"
        @"  fi\n"
        @"  sleep 1\n"
        @"done\n"
        @"dbsize=$(/usr/bin/stat -f%%z \"$DB\" 2>/dev/null || echo 0)\n"
        @"avail=$(( $(/bin/df -k \"$(dirname \"$DB\")\" | /usr/bin/awk 'NR==2 {print $4}') * 1024 ))\n"
        @"if [ \"$avail\" -gt \"$((dbsize + dbsize / 10))\" ]; then\n"
        @"  /bin/cp -f \"$DB\" \"$BK\" && echo \"[Plorg VolumeSync] metadb backed up to $BK\" > \"$LOG\"\n"
        @"  for ext in -wal -shm; do\n"
        @"    if [ -f \"$DB$ext\" ]; then /bin/cp -f \"$DB$ext\" \"$BK$ext\"; else rm -f \"$BK$ext\"; fi\n"
        @"  done\n"
        @"else\n"
        @"  echo \"[Plorg VolumeSync] WARNING: not enough disk space for a metadb backup; proceeding (migration is transactional)\" > \"$LOG\"\n"
        @"fi\n"
        @"/usr/bin/sqlite3 \"$DB\" < \"$SQL\" >> \"$LOG\" 2>&1\n"
        @"rc=$?\n"
        @"echo \"[Plorg VolumeSync] Metadb migration finished (exit $rc) at $(date)\" >> \"$LOG\"\n"
        @"if [ \"$rc\" -eq 0 ]; then\n"
        @"  chk=$(/usr/bin/sqlite3 \"$DB\" 'PRAGMA quick_check;' 2>&1 | /usr/bin/head -1)\n"
        @"  echo \"[Plorg VolumeSync] Integrity after migration: $chk\" >> \"$LOG\"\n"
        @"  if [ \"$chk\" = \"ok\" ]; then\n"
        @"    before=$(/usr/bin/stat -f%%z \"$DB\" 2>/dev/null || echo 0)\n"
        @"    avail=$(( $(/bin/df -k \"$(dirname \"$DB\")\" | /usr/bin/awk 'NR==2 {print $4}') * 1024 ))\n"
        @"    if [ \"$avail\" -gt \"$before\" ]; then\n"
        @"      if /usr/bin/sqlite3 \"$DB\" 'VACUUM;' >> \"$LOG\" 2>&1; then\n"
        @"        after=$(/usr/bin/stat -f%%z \"$DB\" 2>/dev/null || echo 0)\n"
        @"        echo \"[Plorg VolumeSync] VACUUM reclaimed $(( (before - after) / 1048576 )) MB\" >> \"$LOG\"\n"
        @"      fi\n"
        @"    else\n"
        @"      echo \"[Plorg VolumeSync] VACUUM skipped: not enough free disk space\" >> \"$LOG\"\n"
        @"    fi\n"
        @"    rm -f \"$BK\" \"$BK-wal\" \"$BK-shm\"\n"
        @"  elif [ -f \"$BK\" ]; then\n"
        @"    /bin/cp -f \"$BK\" \"$DB\" && echo \"[Plorg VolumeSync] Integrity check FAILED - restored the pre-migration backup; it is kept at $BK\" >> \"$LOG\"\n"
        @"  else\n"
        @"    echo \"[Plorg VolumeSync] Integrity check FAILED and no backup was made (disk space)\" >> \"$LOG\"\n"
        @"  fi\n"
        @"fi\n"
        @"rm -f \"$SQL\"\n"
        @"relaunch\n",
        dbPath, sqlPath, logPath, markerPath, appPath, appPath,
        pid, kMigratorRelaunchAbortWaitSeconds];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", script];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    @try {
        [task launch];
        self.migratorSpawned = YES;
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Spawned metadb migrator (%lu UUID remap%@). "
            @"It runs after foobar quits: backup, transactional migration, "
            @"integrity check, VACUUM, then reopens foobar2000 if the repair "
            @"prompt asked for a restart. Log: %@",
            (unsigned long)remapActions.count,
            remapActions.count == 1 ? @"" : @"s",
            logPath]];
    } @catch (NSException *e) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to spawn migrator: %@", e.reason]];
    }
}

- (void)relaunchApp {
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    if (!appPath) {
        FB2K_console_formatter() << "[Plorg VolumeSync] Cannot determine app path for relaunch.";
        return;
    }

    pid_t pid = getpid();

    // If a migration is staged, the migrator reopens foobar2000 itself as its
    // last act - we only leave the request. One process doing migrate-then-open
    // is what makes the ordering airtight; the previous design had this process
    // poll for the staged SQL file to disappear and then open the app, which
    // reopened fb2k mid-write whenever the file vanished for any reason other
    // than "migration completed" (abort path, a second migrator finishing
    // first, or the 15-minute bound elapsing). That is what surfaced as
    // "metadb is corrupted" on restart.
    if (self.migratorSpawned) {
        NSString *markerPath = relaunchMarkerPathForPID(pid);
        if ([[NSFileManager defaultManager] createFileAtPath:markerPath
                                                    contents:[NSData data]
                                                  attributes:nil]) {
            FB2K_console_formatter() << "[Plorg VolumeSync] Restart requested; foobar2000 "
                "will reopen automatically once the metadb migration finishes.";
            [self flushDeferredLogsToConsole];
            [[NSApplication sharedApplication] terminate:nil];
            return;
        }
        // Could not leave the request - fall through to the simple relauncher
        // rather than quitting with no way back. It waits for this process to
        // exit; the migrator's own abort guard keeps it from writing metadb
        // while the new session is alive.
        FB2K_console_formatter() << "[Plorg VolumeSync] Could not stage the restart request; "
            "reopening directly (the migration will be rescheduled if it is skipped).";
    }

    // No migration staged: nothing to order against, just wait for exit.
    NSString *script = [NSString stringWithFormat:
        @"export PATH=/usr/bin:/bin:/usr/sbin:/sbin\n"
        @"while kill -0 %d 2>/dev/null; do sleep 0.1; done\n"
        @"sleep 0.3\n"
        @"/usr/bin/open '%@'\n",
        pid, appPath];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", script];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [task launch];
    } @catch (NSException *e) {
        FB2K_console_formatter() << "[Plorg VolumeSync] Failed to spawn relauncher: "
            << [e.reason UTF8String];
        return;
    }

    [[NSApplication sharedApplication] terminate:nil];
}

#pragma mark - Deferred Logging

- (void)deferLog:(NSString *)message {
    @synchronized(self.deferredLogMessages) {
        [self.deferredLogMessages addObject:message];
    }
    NSLog(@"%@", message);
}

- (void)flushDeferredLogsToConsole {
    @synchronized(self.deferredLogMessages) {
        for (NSString *msg in self.deferredLogMessages) {
            FB2K_console_formatter() << [msg UTF8String];
        }
        [self.deferredLogMessages removeAllObjects];
    }
}

@end
