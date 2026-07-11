//
//  VolumeSyncService.mm
//  foo_plorg_mac
//
//  Automatic volume UUID sync for network shares.
//

#import "VolumeSyncService.h"
#import "VolumeSyncLogic.h"
#include "../fb2k_sdk.h"
#import "ConfigHelper.h"
#import <DiskArbitration/DiskArbitration.h>
#import <AppKit/AppKit.h>
#import <sys/mount.h>
#import <fcntl.h>
#import <unistd.h>
#import <sqlite3.h>

NSString * const kVolumeSyncBackupPrefix = @"backup_volume_sync_";
NSInteger const kVolumeSyncMaxBackups = 5;

@interface VolumeSyncService ()
@property (nonatomic, strong, readwrite) NSMutableArray<NSString *> *deferredLogMessages;
@property (nonatomic, strong) dispatch_source_t volumeMonitorSource;
@property (nonatomic, strong) NSString *playlistsDir; // cached for runtime monitor
@property (nonatomic, copy) dispatch_block_t pendingVolumeCheck; // coalesces monitor bursts
@end

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
    }
    return self;
}

#pragma mark - Volume Discovery

- (NSDictionary<NSString *, NSString *> *)discoverShareToUUIDMapping {
    NSDictionary *info = [self discoverShareInfo];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *shareName in info) {
        result[shareName] = info[shareName][@"uuid"];
    }
    return result;
}

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
        NSString *shareName = [VolumeSyncService shareNameFromMountSource:mounts[i].f_mntfromname];
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

+ (NSString *)shareNameFromMountSource:(const char *)mntfromname {
    return [VolumeSyncLogic shareNameFromMountSource:mntfromname];
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
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [VolumeSyncLogic scanFpliteContentForUUIDs:content];
}

#pragma mark - UUID Remapping

- (BOOL)remapUUIDsInFile:(NSString *)path
               fromUUIDs:(NSSet<NSString *> *)sourceUUIDs
                  toUUID:(NSString *)targetUUID
                   error:(NSError **)error {
    // Read raw data to detect and preserve BOM
    NSData *rawData = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!rawData) return NO;

    NSData *newData = [VolumeSyncLogic remappedFpliteData:rawData fromUUIDs:sourceUUIDs toUUID:targetUUID];
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
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:nil];
    if (!contents) return;

    NSMutableArray<NSString *> *backupDirs = [NSMutableArray array];
    for (NSString *item in contents) {
        if ([item hasPrefix:kVolumeSyncBackupPrefix]) {
            [backupDirs addObject:[playlistsDir stringByAppendingPathComponent:item]];
        }
    }

    if ((NSInteger)backupDirs.count <= kVolumeSyncMaxBackups) return;

    [backupDirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDictionary *aAttrs = [fm attributesOfItemAtPath:a error:nil];
        NSDictionary *bAttrs = [fm attributesOfItemAtPath:b error:nil];
        NSDate *aDate = aAttrs[NSFileModificationDate] ?: [NSDate distantPast];
        NSDate *bDate = bAttrs[NSFileModificationDate] ?: [NSDate distantPast];
        return [aDate compare:bDate];
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
        [VolumeSyncLogic liveUUIDsByPathFromRegistry:foobarVolumes];

    // 3. Scan .fplite files for UUIDs in active use.
    NSDictionary *fpliteIndex = [self buildFpliteUUIDIndexInDirectory:playlistsDir];
    if (fpliteIndex.count == 0) {
        [self deferLog:@"[Plorg VolumeSync] No mac-volume:// references in .fplite files"];
        return @{};
    }

    // 4. For each UUID found in .fplite, decide whether it needs remapping.
    __weak typeof(self) weakSelf = self;
    NSDictionary *remapActions = [VolumeSyncLogic planRemapActionsWithRegistry:foobarVolumes
        fpliteIndex:fpliteIndex
        liveUUIDsByPath:liveUUIDsByPath
        fileExists:^BOOL(NSString *path) {
            return [[NSFileManager defaultManager] fileExistsAtPath:path];
        }
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
        NSArray<NSString *> *unresolved = [VolumeSyncLogic unresolvedFpliteUUIDsInIndex:fpliteIndex
                                                                              registry:foobarVolumes
                                                                          remapActions:remapActions];
        if (unresolved.count > 0) {
            // Distinguish "not mounted" from "mounted but foobar has no working
            // bookmark for this session" — advising the user to mount an
            // already-mounted volume is a dead end (observed 2026-07-11).
            NSArray<NSString *> *mountedPaths =
                [VolumeSyncLogic mountedRegistryPathsForUnresolvedUUIDs:unresolved
                                                               registry:foobarVolumes
                                                              isMounted:^BOOL(NSString *path) {
                    return [self isCurrentlyMountedPath:path];
                }];
            if (mountedPaths.count > 0) {
                [self deferLog:[NSString stringWithFormat:
                    @"[Plorg VolumeSync] %lu stale .fplite UUID(s); %@ IS mounted but "
                    @"foobar2000 has no working bookmark for this mount session (no registry "
                    @"entry resolves). Nothing to remap onto. To register it, play or add any "
                    @"file from that volume in foobar2000, then rescan.",
                    (unsigned long)unresolved.count,
                    [mountedPaths componentsJoinedByString:@", "]]];
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
    sqlite3_busy_timeout(db, 1000);

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
        [VolumeSyncLogic orphanCacheMigrationsWithRowCounts:counts
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
    sqlite3_busy_timeout(db, 1000); // play nicely with running foobar

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
    return [VolumeSyncLogic volumeUUIDFromConfigKey:key];
}

// Write a snapshot to plorg_volume_uuids.json — purely diagnostic. We preserve
// __auto_sync_enabled (used for early opt-out) and overwrite share entries with
// the current registry summary.
- (void)persistDiagnosticSnapshot:(NSDictionary *)foobarVolumes
                     remapActions:(NSDictionary *)remapActions
                  liveUUIDsByPath:(NSDictionary *)liveUUIDsByPath {
    NSMutableDictionary *snapshot = [[self loadPersistedMapping] mutableCopy] ?: [NSMutableDictionary dictionary];

    // Strip any old per-share keys (everything not starting with __)
    NSArray *keys = [snapshot.allKeys copy];
    for (NSString *k in keys) {
        if (![k hasPrefix:@"__"]) [snapshot removeObjectForKey:k];
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
    fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    snapshot[@"last_run"] = [fmt stringFromDate:[NSDate date]];

    [self persistMapping:snapshot];
}

// Returns UUID(uppercase) -> @{ @"count": NSNumber, @"samplePath": NSString }
// samplePath is the path portion after the UUID from one of the .fplite entries.
- (NSDictionary<NSString *, NSDictionary *> *)buildFpliteUUIDIndexInDirectory:(NSString *)playlistsDir {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *index = [NSMutableDictionary dictionary];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:nil];
    if (!contents) return index;

    for (NSString *item in contents) {
        if (![item hasSuffix:@".fplite"]) continue;
        NSString *fullPath = [playlistsDir stringByAppendingPathComponent:item];

        NSString *content = [NSString stringWithContentsOfFile:fullPath
                                                      encoding:NSUTF8StringEncoding error:nil];
        [VolumeSyncLogic indexFpliteContent:content into:index];
    }

    return index;
}

- (void)scanForStaleUUIDsInDirectory:(NSString *)playlistsDir
                         withMapping:(NSDictionary *)mapping
                       currentMounts:(NSDictionary *)currentMounts
                        remapActions:(NSMutableDictionary *)remapActions {
    // Collect all fplite files
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:nil];
    if (!contents) return;

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
    NSArray *contents = [fm contentsOfDirectoryAtPath:playlistsDir error:nil];
    if (!contents) return @{};

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

        // Wait 3 seconds for the mount to fully settle before scanning.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
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

    // Discover all metadb_index_<GUID> tables (skip the *_data sibling tables).
    NSMutableArray<NSString *> *indexTables = [NSMutableArray array];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([dbPath fileSystemRepresentation], &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(db, 1000);
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db,
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name LIKE 'metadb_index_%' AND name NOT LIKE '%_data'",
                -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *n = sqlite3_column_text(stmt, 0);
                if (n) [indexTables addObject:[NSString stringWithUTF8String:(const char *)n]];
            }
            sqlite3_finalize(stmt);
        }
        sqlite3_close(db);
    }

    // Build the migration SQL.
    NSString *sql = [VolumeSyncLogic metadbMigrationSQLForRemapActions:remapActions
                                                           indexTables:indexTables];

    // Stage the SQL in /tmp; the helper script feeds it to sqlite3 after foobar exits.
    pid_t pid = getpid();
    NSString *sqlPath = [NSString stringWithFormat:@"/tmp/plorg_metadb_migration_%d.sql", pid];
    NSError *writeErr = nil;
    if (![sql writeToFile:sqlPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Failed to stage migration SQL: %@",
            writeErr.localizedDescription]];
        return;
    }

    NSString *logPath = [NSString stringWithFormat:@"/tmp/plorg_metadb_migration_%d.log", pid];
    NSString *script = [NSString stringWithFormat:
        @"while kill -0 %d 2>/dev/null; do sleep 0.5; done; "
        @"sleep 1; "
        @"/usr/bin/sqlite3 '%@' < '%@' > '%@' 2>&1; "
        @"echo \"[Plorg VolumeSync] Metadb migration finished at $(date)\" >> '%@'; "
        @"rm -f '%@'",
        pid, dbPath, sqlPath, logPath, logPath, sqlPath];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", script];
    @try {
        [task launch];
        [self deferLog:[NSString stringWithFormat:
            @"[Plorg VolumeSync] Spawned metadb migrator (%lu UUID remap%@). "
            @"It runs after foobar quits; log: %@",
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
    NSString *script = [NSString stringWithFormat:
        @"while kill -0 %d 2>/dev/null; do sleep 0.1; done; sleep 0.3; /usr/bin/open '%@'",
        pid, appPath];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", script];

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
