//
//  PlorgVolumeSyncLogic.h
//  foo_plorg_mac
//
//  Pure parsing and planning logic for volume UUID sync: mount-source and
//  config-key parsing, .fplite content scanning, BOM-preserving UUID
//  remapping, repair planning, orphan cache migration decisions, and metadb
//  migration SQL generation.
//  Foundation-only (no SDK, no filesystem, no sqlite) so it is unit-testable
//  standalone. Filesystem probes are injected as blocks.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// "mac-volume://" - prefix of volume-relative playlist entries
extern NSString * const PlorgMacVolumePrefix;

typedef NS_ENUM(NSInteger, FpliteLineResult) {
    FpliteLineNotVolume,   // empty or does not start with mac-volume://
    FpliteLineMalformed,   // has the prefix but no plausible UUID segment
    FpliteLineParsed,
};

@interface PlorgVolumeSyncLogic : NSObject

// --- Validation ---

// Strict volume-UUID grammar: 36 chars, 8-4-4-4-12 hex groups separated by '-'.
// Values reaching SQL, shell, or filesystem paths must pass this. macOS volume
// UUIDs always have this shape; anything else is malformed or hostile input.
+ (BOOL)isValidVolumeUUID:(nullable NSString *)uuid;

// --- Mount / config-key parsing ---

// Extract share name from statfs f_mntfromname:
// "//user@192.168.1.10/music.hq" -> "music.hq", "host:/export/path" -> "path"
+ (nullable NSString *)shareNameFromMountSource:(nullable const char *)mntfromname;

// "mac.volume.<UUID>.originalPath" / "mac.volume.<UUID>.bookmark" -> UUID (uppercase)
+ (nullable NSString *)volumeUUIDFromConfigKey:(NSString *)key;

// --- fplite content scanning ---

// Parse one .fplite line. On FpliteLineParsed, outUUID is the uppercase UUID
// and outSamplePath the path portion after "mac-volume://UUID/".
+ (FpliteLineResult)parseFpliteLine:(NSString *)line
                               uuid:(NSString * _Nullable * _Nullable)outUUID
                         samplePath:(NSString * _Nullable * _Nullable)outSamplePath;

// Scan .fplite content for mac-volume:// UUIDs: UUID (uppercase) -> entry count
+ (NSDictionary<NSString *, NSNumber *> *)scanFpliteContentForUUIDs:(nullable NSString *)content;

// Merge .fplite content into an index: UUID -> { @"count": NSNumber,
// @"samplePath": NSString } (samplePath is from the first entry seen)
+ (void)indexFpliteContent:(nullable NSString *)content
                      into:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)index;

// --- UUID remapping (content-level) ---

// Replace mac-volume:// UUIDs in raw .fplite data, preserving a UTF-8 BOM.
// Returns the new data, or nil when nothing changed or the data is not UTF-8.
+ (nullable NSData *)remappedFpliteData:(NSData *)rawData
                              fromUUIDs:(NSSet<NSString *> *)sourceUUIDs
                                 toUUID:(NSString *)targetUUID;

// --- Repair planning ---

// Group live UUIDs by canonical path (resolvedPath, falling back to
// originalPath). Registry format per UUID: { @"originalPath": NSString,
// @"resolvedPath": NSString?, @"isLive": NSNumber(BOOL) }
+ (NSDictionary<NSString *, NSArray<NSString *> *> *)liveUUIDsByPathFromRegistry:
    (NSDictionary<NSString *, NSDictionary *> *)foobarVolumes;

// Decide which stale .fplite UUIDs get remapped to which live UUID.
// fileExists abstracts the sample-path existence probe; log receives
// human-readable decisions (may be nil).
+ (NSDictionary<NSString *, NSString *> *)planRemapActionsWithRegistry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                           fpliteIndex:(NSDictionary<NSString *, NSDictionary *> *)fpliteIndex
                                                       liveUUIDsByPath:(NSDictionary<NSString *, NSArray<NSString *> *> *)liveUUIDsByPath
                                                            fileExists:(BOOL (^)(NSString *path))fileExists
                                                                   log:(void (^ _Nullable)(NSString *message))log;

// The .fplite UUIDs that are neither live in the registry nor scheduled for
// remap — i.e. stale references this pass could not fix. Lets the caller log
// an accurate outcome instead of falsely claiming "all .fplite UUIDs are live"
// when a stale UUID simply had no live replacement.
+ (NSArray<NSString *> *)unresolvedFpliteUUIDsInIndex:(NSDictionary<NSString *, NSDictionary *> *)fpliteIndex
                                             registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                         remapActions:(NSDictionary<NSString *, NSString *> *)remapActions;

// Of the unresolved stale UUIDs, the distinct registry originalPaths that ARE
// currently mounted (per the injected probe), sorted. A non-empty result means
// the user's volume is fine — foobar2000 just has no working bookmark for this
// mount session, so the fix is registration (play/add a file from the volume
// in fb2k), NOT mounting. Lets the caller stop advising "mount the volume"
// when it already is.
+ (NSArray<NSString *> *)mountedRegistryPathsForUnresolvedUUIDs:(NSArray<NSString *> *)unresolvedUUIDs
                                                       registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                      isMounted:(BOOL (^)(NSString *path))isMounted;

// Decide which dead UUIDs' metadb cache rows to migrate to a live UUID for
// the same originalPath. rowCounts: UUID -> cached row count in metadb.
// Only migrates when the dead UUID has more rows than the live target.
+ (NSDictionary<NSString *, NSString *> *)orphanCacheMigrationsWithRowCounts:(NSDictionary<NSString *, NSNumber *> *)rowCounts
                                                                    registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                             liveUUIDsByPath:(NSDictionary<NSString *, NSArray<NSString *> *> *)liveUUIDsByPath
                                                                         log:(void (^ _Nullable)(NSString *message))log;

// --- Metadb migration SQL ---

// Build the SQL script that copies cached rows from each dead UUID to its
// live target across the main metadb table and all metadb_index_* tables.
+ (NSString *)metadbMigrationSQLForRemapActions:(NSDictionary<NSString *, NSString *> *)remapActions
                                    indexTables:(NSArray<NSString *> *)indexTables;

@end

NS_ASSUME_NONNULL_END
