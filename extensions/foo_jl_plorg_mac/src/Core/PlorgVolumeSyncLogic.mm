//
//  PlorgVolumeSyncLogic.mm
//  foo_plorg_mac
//

#import "PlorgVolumeSyncLogic.h"

NSString * const PlorgMacVolumePrefix = @"mac-volume://";

@implementation PlorgVolumeSyncLogic

#pragma mark - Validation

+ (BOOL)isValidVolumeUUID:(NSString *)uuid {
    static const NSUInteger groupLengths[] = {8, 4, 4, 4, 12};
    static const NSUInteger groupCount = sizeof(groupLengths) / sizeof(groupLengths[0]);

    if (uuid.length != 36) return NO;

    NSArray<NSString *> *groups = [uuid componentsSeparatedByString:@"-"];
    if (groups.count != groupCount) return NO;

    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefABCDEF"] invertedSet];

    for (NSUInteger i = 0; i < groupCount; i++) {
        if (groups[i].length != groupLengths[i]) return NO;
        if ([groups[i] rangeOfCharacterFromSet:nonHex].location != NSNotFound) return NO;
    }
    return YES;
}

+ (BOOL)isValidMetadbIndexTableName:(NSString *)name {
    static NSString * const prefix = @"metadb_index_";
    if (![name hasPrefix:prefix]) return NO;

    // GUID with '-' replaced by '_': 8_4_4_4_12 hex groups.
    static const NSUInteger groupLengths[] = {8, 4, 4, 4, 12};
    static const NSUInteger groupCount = sizeof(groupLengths) / sizeof(groupLengths[0]);

    NSString *guidPart = [name substringFromIndex:prefix.length];
    NSArray<NSString *> *groups = [guidPart componentsSeparatedByString:@"_"];
    if (groups.count != groupCount) return NO;

    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdefABCDEF"] invertedSet];

    for (NSUInteger i = 0; i < groupCount; i++) {
        if (groups[i].length != groupLengths[i]) return NO;
        if ([groups[i] rangeOfCharacterFromSet:nonHex].location != NSNotFound) return NO;
    }
    return YES;
}

// Double single quotes so a value cannot terminate a SQL string literal.
static NSString *sqlQuote(NSString *value) {
    return [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
}

// Double double-quotes so a value cannot terminate a SQL quoted identifier.
static NSString *sqlIdentifier(NSString *value) {
    return [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
}

#pragma mark - Mount / Config-Key Parsing

+ (NSString *)shareNameFromMountSource:(const char *)mntfromname {
    if (!mntfromname) return nil;

    NSString *source = [NSString stringWithUTF8String:mntfromname];
    if (!source || source.length == 0) return nil;

    // Format: "//user@host/share" or "//host/share" or "host:/share"
    // Extract the last path component after the host

    // Handle SMB format: //[user@]host/share[/subpath]
    if ([source hasPrefix:@"//"]) {
        NSString *afterSlashes = [source substringFromIndex:2];
        // Find the host part (everything up to the first /)
        NSRange hostSlash = [afterSlashes rangeOfString:@"/"];
        if (hostSlash.location == NSNotFound) return nil;

        NSString *sharePart = [afterSlashes substringFromIndex:hostSlash.location + 1];
        // Share name is the first component after the host
        NSRange nextSlash = [sharePart rangeOfString:@"/"];
        if (nextSlash.location != NSNotFound) {
            return [sharePart substringToIndex:nextSlash.location];
        }
        return sharePart;
    }

    // Handle NFS format: host:/export/path
    NSRange colonSlash = [source rangeOfString:@":/"];
    if (colonSlash.location != NSNotFound) {
        NSString *exportPath = [source substringFromIndex:colonSlash.location + 1];
        return [exportPath lastPathComponent];
    }

    return nil;
}

+ (NSString *)volumeUUIDFromConfigKey:(NSString *)key {
    static NSString * const prefix = @"mac.volume.";
    if (![key hasPrefix:prefix]) return nil;

    NSString *rest = [key substringFromIndex:prefix.length];
    NSRange dot = [rest rangeOfString:@"."];
    if (dot.location == NSNotFound) return nil;

    NSString *uuid = [rest substringToIndex:dot.location];
    if (![self isValidVolumeUUID:uuid]) return nil;
    return [uuid uppercaseString];
}

#pragma mark - fplite Content Scanning

+ (FpliteLineResult)parseFpliteLine:(NSString *)line
                               uuid:(NSString **)outUUID
                         samplePath:(NSString **)outSamplePath {
    if (line.length == 0 || ![line hasPrefix:PlorgMacVolumePrefix]) {
        return FpliteLineNotVolume;
    }

    NSString *afterPrefix = [line substringFromIndex:PlorgMacVolumePrefix.length];
    NSRange firstSlash = [afterPrefix rangeOfString:@"/"];
    if (firstSlash.location == NSNotFound) {
        return FpliteLineMalformed;
    }

    // Strict UUID grammar: these values flow into generated SQL and file paths.
    NSString *rawUUID = [afterPrefix substringToIndex:firstSlash.location];
    if (![self isValidVolumeUUID:rawUUID]) {
        return FpliteLineMalformed;
    }
    NSString *uuid = [rawUUID uppercaseString];

    // The sample path is later joined onto mounted volume roots and probed on
    // disk, so it must be a non-empty relative path with no ".." components.
    // Components are checked (not substrings) so a file named "..foo" passes.
    NSString *samplePath = [afterPrefix substringFromIndex:firstSlash.location + 1];
    if (samplePath.length == 0 || [samplePath hasPrefix:@"/"]) {
        return FpliteLineMalformed;
    }
    if ([samplePath rangeOfString:@".."].location != NSNotFound &&
        [samplePath.pathComponents containsObject:@".."]) {
        return FpliteLineMalformed;
    }

    if (outUUID) *outUUID = uuid;
    if (outSamplePath) *outSamplePath = samplePath;
    return FpliteLineParsed;
}

+ (NSDictionary<NSString *, NSNumber *> *)scanFpliteContentForUUIDs:(NSString *)content {
    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary dictionary];
    if (!content) return result;

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        NSString *uuid = nil;
        if ([self parseFpliteLine:line uuid:&uuid samplePath:NULL] != FpliteLineParsed) continue;

        NSNumber *count = result[uuid];
        result[uuid] = @(count ? count.unsignedIntegerValue + 1 : 1);
    }

    return result;
}

+ (void)indexFpliteContent:(NSString *)content
                      into:(NSMutableDictionary<NSString *, NSMutableDictionary *> *)index {
    if (!content) return;

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    for (NSString *line in lines) {
        NSString *uuid = nil;
        NSString *samplePath = nil;
        if ([self parseFpliteLine:line uuid:&uuid samplePath:&samplePath] != FpliteLineParsed) continue;

        NSMutableDictionary *entry = index[uuid];
        if (!entry) {
            entry = [NSMutableDictionary dictionary];
            entry[@"count"] = @0;
            entry[@"samplePath"] = samplePath;
            index[uuid] = entry;
        }
        entry[@"count"] = @([entry[@"count"] unsignedIntegerValue] + 1);
    }
}

#pragma mark - UUID Remapping

+ (NSData *)remappedFpliteData:(NSData *)rawData
                     fromUUIDs:(NSSet<NSString *> *)sourceUUIDs
                        toUUID:(NSString *)targetUUID {
    if (![self isValidVolumeUUID:targetUUID]) return nil;
    for (NSString *sourceUUID in sourceUUIDs) {
        if (![self isValidVolumeUUID:sourceUUID]) return nil;
    }

    // Check for UTF-8 BOM (EF BB BF)
    BOOL hasBOM = NO;
    const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
    if (rawData.length >= 3 && memcmp(rawData.bytes, bom, 3) == 0) {
        hasBOM = YES;
    }

    NSString *content = [[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding];
    if (!content) return nil;

    NSMutableString *newContent = [content mutableCopy];
    BOOL changed = NO;

    for (NSString *sourceUUID in sourceUUIDs) {
        NSString *search = [NSString stringWithFormat:@"%@%@/", PlorgMacVolumePrefix, sourceUUID];
        NSString *replace = [NSString stringWithFormat:@"%@%@/", PlorgMacVolumePrefix, targetUUID];

        NSUInteger count = [newContent replaceOccurrencesOfString:search
                                                       withString:replace
                                                          options:NSCaseInsensitiveSearch
                                                            range:NSMakeRange(0, newContent.length)];
        if (count > 0) changed = YES;
    }

    if (!changed) return nil;

    NSData *outputData = [newContent dataUsingEncoding:NSUTF8StringEncoding];
    if (!outputData) return nil;

    NSMutableData *finalData = [NSMutableData data];
    if (hasBOM) {
        [finalData appendBytes:bom length:3];
    }
    // NSString strips BOM on read, so outputData won't have it
    [finalData appendData:outputData];

    return finalData;
}

#pragma mark - Repair Planning

// Canonical form for volume-path dictionary keys: standardized, single
// trailing slash stripped (but "/" stays "/"), Unicode precomposed. Must be
// applied both when building liveUUIDsByPath and at every lookup of it.
static NSString *normalizeVolumePath(NSString *path) {
    return [PlorgVolumeSyncLogic normalizedVolumePath:path];
}

+ (NSString *)normalizedVolumePath:(NSString *)path {
    if (path.length == 0) return path;
    NSString *normalized = [[path stringByStandardizingPath] precomposedStringWithCanonicalMapping];
    if (normalized.length > 1 && [normalized hasSuffix:@"/"]) {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }
    return normalized;
}

+ (NSDictionary<NSString *, NSArray<NSString *> *> *)liveUUIDsByPathFromRegistry:
    (NSDictionary<NSString *, NSDictionary *> *)foobarVolumes {
    // A UUID is "live" iff its bookmark resolved to an existing path. Multiple
    // UUIDs typically map to the same path because foobar registers a fresh
    // UUID on each remount.
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *liveUUIDsByPath = [NSMutableDictionary dictionary];

    for (NSString *uuid in foobarVolumes) {
        NSDictionary *info = foobarVolumes[uuid];
        if (![info[@"isLive"] boolValue]) continue;

        NSString *key = normalizeVolumePath(info[@"resolvedPath"] ?: info[@"originalPath"]);
        if (!key) continue;

        NSMutableArray *list = liveUUIDsByPath[key];
        if (!list) {
            list = [NSMutableArray array];
            liveUUIDsByPath[key] = list;
        }
        [list addObject:uuid];
    }

    return liveUUIDsByPath;
}

+ (NSDictionary<NSString *, NSString *> *)planRemapActionsWithRegistry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                           fpliteIndex:(NSDictionary<NSString *, NSDictionary *> *)fpliteIndex
                                                       liveUUIDsByPath:(NSDictionary<NSString *, NSArray<NSString *> *> *)liveUUIDsByPath
                                                            fileExists:(BOOL (^)(NSString *))fileExists
                                                                   log:(void (^)(NSString *))log {
    NSMutableDictionary *remapActions = [NSMutableDictionary dictionary]; // oldUUID -> newUUID

    for (NSString *fpliteUUID in fpliteIndex) {
        NSDictionary *info = foobarVolumes[fpliteUUID];

        // Already live? Foobar can resolve it via its bookmark - leave alone.
        if (info && [info[@"isLive"] boolValue]) {
            continue;
        }

        // Find a live UUID for the same path. Try originalPath first; fall back
        // to sample-path verification against any live UUID's resolved path.
        NSString *targetUUID = nil;
        NSString *targetPath = nil;

        if (info && info[@"originalPath"]) {
            NSArray *candidates = liveUUIDsByPath[normalizeVolumePath(info[@"originalPath"])];
            if (candidates.count > 0) {
                targetUUID = candidates.firstObject;
                targetPath = info[@"originalPath"];
            }
        }

        if (!targetUUID) {
            NSString *samplePath = fpliteIndex[fpliteUUID][@"samplePath"];
            if (samplePath) {
                for (NSString *path in liveUUIDsByPath) {
                    NSString *full = [path stringByAppendingPathComponent:samplePath];
                    if (fileExists(full)) {
                        targetUUID = liveUUIDsByPath[path].firstObject;
                        targetPath = path;
                        break;
                    }
                }
            }
        }

        if (!targetUUID) {
            if (log) log([NSString stringWithFormat:
                @"[Plorg VolumeSync] Stale UUID %@ has no live replacement (originalPath: %@). "
                @"Mount the volume and retry.",
                fpliteUUID, info ? info[@"originalPath"] : @"unknown"]);
            continue;
        }

        remapActions[fpliteUUID] = targetUUID;
        if (log) log([NSString stringWithFormat:
            @"[Plorg VolumeSync] Remapping stale %@ -> live %@ for %@",
            fpliteUUID, targetUUID, targetPath]);
    }

    return remapActions;
}

+ (NSArray<NSString *> *)unresolvedFpliteUUIDsInIndex:(NSDictionary<NSString *, NSDictionary *> *)fpliteIndex
                                             registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                         remapActions:(NSDictionary<NSString *, NSString *> *)remapActions {
    NSMutableArray<NSString *> *unresolved = [NSMutableArray array];
    for (NSString *uuid in fpliteIndex) {
        if (remapActions[uuid]) continue;                        // will be repaired
        NSDictionary *info = foobarVolumes[uuid];
        if (info && [info[@"isLive"] boolValue]) continue;       // genuinely live
        [unresolved addObject:uuid];
    }
    return unresolved;
}

+ (NSArray<NSString *> *)mountedRegistryPathsForUnresolvedUUIDs:(NSArray<NSString *> *)unresolvedUUIDs
                                                       registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                      isMounted:(BOOL (^)(NSString *))isMounted {
    NSMutableSet<NSString *> *mounted = [NSMutableSet set];
    for (NSString *uuid in unresolvedUUIDs) {
        NSString *originalPath = foobarVolumes[uuid][@"originalPath"];
        if (!originalPath) continue;
        if ([mounted containsObject:originalPath]) continue;
        if (isMounted(originalPath)) {
            [mounted addObject:originalPath];
        }
    }
    return [mounted.allObjects sortedArrayUsingSelector:@selector(compare:)];
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)selfHealCandidatesForUnresolvedUUIDs:(NSArray<NSString *> *)unresolvedUUIDs
                                                                                 registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                                              fpliteIndex:(NSDictionary<NSString *, NSDictionary *> *)fpliteIndex
                                                                                isMounted:(BOOL (^)(NSString *))isMounted
                                                                               fileExists:(BOOL (^)(NSString *))fileExists {
    // path -> candidate; first UUID with a verifiable sample file wins per path.
    NSMutableDictionary<NSString *, NSDictionary *> *byPath = [NSMutableDictionary dictionary];

    for (NSString *uuid in unresolvedUUIDs) {
        NSString *originalPath = foobarVolumes[uuid][@"originalPath"];
        if (originalPath.length == 0) continue;
        if (byPath[originalPath]) continue;          // already have a candidate
        if (!isMounted(originalPath)) continue;

        NSString *samplePath = fpliteIndex[uuid][@"samplePath"];
        if (samplePath.length == 0) continue;

        NSString *fullFile = [originalPath stringByAppendingPathComponent:samplePath];
        if (!fileExists(fullFile)) continue;         // volume mounted but file gone

        byPath[originalPath] = @{ @"path": originalPath, @"file": fullFile };
    }

    NSArray *sortedPaths = [byPath.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:sortedPaths.count];
    for (NSString *path in sortedPaths) {
        [result addObject:byPath[path]];
    }
    return result;
}

+ (NSDictionary<NSString *, NSString *> *)orphanCacheMigrationsWithRowCounts:(NSDictionary<NSString *, NSNumber *> *)rowCounts
                                                                    registry:(NSDictionary<NSString *, NSDictionary *> *)foobarVolumes
                                                             liveUUIDsByPath:(NSDictionary<NSString *, NSArray<NSString *> *> *)liveUUIDsByPath
                                                                         log:(void (^)(NSString *))log {
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];

    for (NSString *uuid in rowCounts) {
        NSDictionary *info = foobarVolumes[uuid];
        if (!info) continue;                          // unknown to foobar
        if ([info[@"isLive"] boolValue]) continue;    // already live

        NSString *originalPath = info[@"originalPath"];
        if (!originalPath) continue;

        NSArray *liveCandidates = liveUUIDsByPath[normalizeVolumePath(originalPath)];
        if (liveCandidates.count == 0) {
            if (log) log([NSString stringWithFormat:
                @"[Plorg VolumeSync] Orphan cache: %@ has no live replacement (originalPath: %@); skipping.",
                uuid, originalPath]);
            continue;
        }

        NSString *target = liveCandidates.firstObject;
        NSUInteger deadRows = rowCounts[uuid].unsignedIntegerValue;
        NSUInteger liveRows = rowCounts[target] ? rowCounts[target].unsignedIntegerValue : 0;

        // Only migrate when the dead UUID has more cached rows than the live
        // target, otherwise the work was already done in a prior session.
        if (deadRows > liveRows) {
            result[uuid] = target;
            if (log) log([NSString stringWithFormat:
                @"[Plorg VolumeSync] Orphan cache: %@ (%lu rows) -> %@ (%lu rows) for %@",
                uuid, (unsigned long)deadRows, target, (unsigned long)liveRows, originalPath]);
        }
    }

    return result;
}

#pragma mark - Metadb Migration SQL

+ (NSString *)metadbMigrationSQLForRemapActions:(NSDictionary<NSString *, NSString *> *)remapActions
                                    indexTables:(NSArray<NSString *> *)indexTables {
    NSMutableString *sql = [NSMutableString string];
    [sql appendString:@"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\n"];

    // Only tables with the known (key, filename) shape may be written to.
    // Guards against SQL-wildcard discovery accidents (e.g. LIKE
    // 'metadb_index_%' matching the metadb_indexes metadata table, whose
    // columns are (name, synced, retention) - observed 2026-07-11).
    NSMutableArray<NSString *> *safeTables = [NSMutableArray array];
    for (NSString *table in indexTables) {
        if ([self isValidMetadbIndexTableName:table]) [safeTables addObject:table];
    }

    for (NSString *deadUUID in remapActions) {
        NSString *liveUUID = remapActions[deadUUID];

        // Defense in depth: these are interpolated into SQL string literals.
        // parseFpliteLine/volumeUUIDFromConfigKey already enforce this, but a
        // malformed value must never reach the migrator.
        if (![self isValidVolumeUUID:deadUUID] || ![self isValidVolumeUUID:liveUUID]) continue;

        NSString *fromTok = sqlQuote([NSString stringWithFormat:@"%@%@", PlorgMacVolumePrefix, deadUUID]);
        NSString *toTok = sqlQuote([NSString stringWithFormat:@"%@%@", PlorgMacVolumePrefix, liveUUID]);
        NSString *likePattern = sqlQuote([NSString stringWithFormat:@"%%%@%@/%%", PlorgMacVolumePrefix, deadUUID]);

        // Main metadb rows: copy under a new name with the UUID rewritten,
        // then delete the dead-UUID sources. metadb.name is a unique primary
        // key, so OR IGNORE preserves rows foobar already cached for the live
        // UUID; deleting the sources keeps one metadata copy per file instead
        // of accumulating one per remount generation (observed: 4 full
        // library copies, 8.7 GB).
        [sql appendFormat:
            @"INSERT OR IGNORE INTO metadb "
            @"(name, info, infoBrowse, size, lastModified, infoBrowseTime, lastseen, created, attribs, attribsValid, partial) "
            @"SELECT REPLACE(name, '%@', '%@'), info, infoBrowse, size, lastModified, infoBrowseTime, lastseen, created, attribs, attribsValid, partial "
            @"FROM metadb WHERE name LIKE '%@';\n",
            fromTok, toTok, likePattern];
        [sql appendFormat:
            @"DELETE FROM metadb WHERE name LIKE '%@' "
            @"AND REPLACE(name, '%@', '%@') <> name;\n",
            likePattern, fromTok, toTok];

        // Library / component index tables (key INTEGER, filename TEXT UNIQUE
        // PRIMARY KEY). The *_data blob siblings are keyed by `key`, which the
        // copy preserves, so they need no migration and no cleanup here.
        for (NSString *table in safeTables) {
            [sql appendFormat:
                @"INSERT OR IGNORE INTO \"%@\" (key, filename) "
                @"SELECT key, REPLACE(filename, '%@', '%@') "
                @"FROM \"%@\" WHERE filename LIKE '%@';\n",
                sqlIdentifier(table), fromTok, toTok, sqlIdentifier(table), likePattern];
            [sql appendFormat:
                @"DELETE FROM \"%@\" WHERE filename LIKE '%@' "
                @"AND REPLACE(filename, '%@', '%@') <> filename;\n",
                sqlIdentifier(table), likePattern, fromTok, toTok];
        }
    }
    [sql appendString:@"COMMIT;\n"];

    return sql;
}

@end
