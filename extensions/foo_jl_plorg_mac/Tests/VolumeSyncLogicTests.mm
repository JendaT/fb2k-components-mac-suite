//
//  VolumeSyncLogicTests.mm
//  foo_plorg_mac
//
//  Unit tests for PlorgVolumeSyncLogic (mount parsing, fplite scanning,
//  BOM-preserving remap, repair planning, orphan migration, SQL builder).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/PlorgVolumeSyncLogic.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

static BOOL objEq(id a, id b) {
    return (a == b) || [a isEqual:b];
}

#define CHECK_EQ(got, want, what)                                                \
    do {                                                                         \
        g_checks++;                                                             \
        if (!objEq((got), (want))) {                                            \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %s, expected %s\n", g_context.c_str(),    \
                   what, [(got) description].UTF8String ?: "(nil)",             \
                   [(want) description].UTF8String ?: "(nil)");                 \
        }                                                                        \
    } while (0)

static NSString * const kDead = @"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
static NSString * const kLive = @"11111111-2222-3333-4444-555555555555";
static NSString * const kOther = @"99999999-8888-7777-6666-555555555555";

int main(void) {
    @autoreleasepool {

    // --- isValidVolumeUUID (the gate protecting SQL/path interpolation) ---
    {
        g_context = "uuid-validation";
        CHECK([PlorgVolumeSyncLogic isValidVolumeUUID:kDead], "canonical uppercase UUID valid");
        CHECK(([PlorgVolumeSyncLogic isValidVolumeUUID:[kDead lowercaseString]]), "lowercase valid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:nil], "nil invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@""], "empty invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"NOTAUUID"], "short invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE"],
              "35 chars invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEEE"],
              "37 chars invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"GGGGGGGG-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
              "non-hex invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"AAAAAAAABBBB-CCCC-DDDD-EEEEEEEEEEEEE"],
              "wrong group shape invalid");
        // SQL-injection payloads must never validate
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"X'; DROP TABLE metadb;--"],
              "quote injection invalid");
        CHECK(![PlorgVolumeSyncLogic isValidVolumeUUID:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEE'E"],
              "embedded quote invalid");
    }

    // --- Malformed UUIDs are rejected at the parse boundary ---
    {
        g_context = "injection-rejected";
        // A crafted .fplite line whose "UUID" segment carries SQL
        NSString *evil = @"mac-volume://X'; DROP TABLE metadb;--/a.flac";
        CHECK([PlorgVolumeSyncLogic parseFpliteLine:evil uuid:NULL samplePath:NULL] == FpliteLineMalformed,
              "SQL payload in UUID segment rejected as malformed");
        CHECK([PlorgVolumeSyncLogic scanFpliteContentForUUIDs:evil].count == 0,
              "malformed line contributes no UUID");

        NSMutableDictionary *idx = [NSMutableDictionary dictionary];
        [PlorgVolumeSyncLogic indexFpliteContent:evil into:idx];
        CHECK(idx.count == 0, "malformed line not indexed");

        // Config keys carrying SQL are rejected too
        CHECK([PlorgVolumeSyncLogic volumeUUIDFromConfigKey:@"mac.volume.X'; DROP TABLE x;--.bookmark"] == nil,
              "SQL payload in config key rejected");

        // Even if a bad value somehow reaches the SQL builder, it is skipped
        NSString *sql = [PlorgVolumeSyncLogic metadbMigrationSQLForRemapActions:
                            @{ @"X'; DROP TABLE metadb;--": kLive } indexTables:@[]];
        CHECK(![sql containsString:@"DROP TABLE"], "SQL builder skips invalid dead UUID");
        CHECK_EQ(sql, @"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\nCOMMIT;\n",
                 "invalid action yields empty transaction");

        NSString *sql2 = [PlorgVolumeSyncLogic metadbMigrationSQLForRemapActions:
                            @{ kDead: @"bogus-target" } indexTables:@[]];
        CHECK(![sql2 containsString:@"bogus"], "SQL builder skips invalid live UUID");
    }

    // --- shareNameFromMountSource ---
    {
        g_context = "share-name";
        CHECK_EQ([PlorgVolumeSyncLogic shareNameFromMountSource:"//user@192.168.1.10/music.hq"],
                 @"music.hq", "SMB with user");
        CHECK_EQ([PlorgVolumeSyncLogic shareNameFromMountSource:"//host/share"],
                 @"share", "SMB without user");
        CHECK_EQ([PlorgVolumeSyncLogic shareNameFromMountSource:"//host/share/sub/dir"],
                 @"share", "SMB subpath ignored");
        CHECK_EQ([PlorgVolumeSyncLogic shareNameFromMountSource:"nas:/export/media"],
                 @"media", "NFS last component");
        CHECK([PlorgVolumeSyncLogic shareNameFromMountSource:"//hostonly"] == nil, "no share part -> nil");
        CHECK([PlorgVolumeSyncLogic shareNameFromMountSource:"/dev/disk1s1"] == nil, "local device -> nil");
        CHECK([PlorgVolumeSyncLogic shareNameFromMountSource:NULL] == nil, "NULL -> nil");
        CHECK([PlorgVolumeSyncLogic shareNameFromMountSource:""] == nil, "empty -> nil");
    }

    // --- volumeUUIDFromConfigKey ---
    {
        g_context = "config-key";
        NSString *key = [NSString stringWithFormat:@"mac.volume.%@.originalPath", [kDead lowercaseString]];
        CHECK_EQ([PlorgVolumeSyncLogic volumeUUIDFromConfigKey:key], kDead, "extracts and uppercases");
        CHECK([PlorgVolumeSyncLogic volumeUUIDFromConfigKey:@"other.key"] == nil, "wrong prefix -> nil");
        CHECK([PlorgVolumeSyncLogic volumeUUIDFromConfigKey:@"mac.volume.nodot"] == nil, "no dot -> nil");
        CHECK([PlorgVolumeSyncLogic volumeUUIDFromConfigKey:@"mac.volume.nodash.bookmark"] == nil,
              "no dash in UUID -> nil");
    }

    // --- parseFpliteLine ---
    {
        g_context = "parse-line";
        NSString *uuid = nil, *sample = nil;
        NSString *line = [NSString stringWithFormat:@"mac-volume://%@/Artist/Track.flac",
                          [kDead lowercaseString]];
        CHECK([PlorgVolumeSyncLogic parseFpliteLine:line uuid:&uuid samplePath:&sample] == FpliteLineParsed,
              "valid line parses");
        CHECK_EQ(uuid, kDead, "UUID uppercased");
        CHECK_EQ(sample, @"Artist/Track.flac", "sample path after UUID");

        CHECK([PlorgVolumeSyncLogic parseFpliteLine:@"" uuid:NULL samplePath:NULL] == FpliteLineNotVolume,
              "empty -> not volume");
        CHECK([PlorgVolumeSyncLogic parseFpliteLine:@"file:///local/track.mp3" uuid:NULL samplePath:NULL]
              == FpliteLineNotVolume, "other scheme -> not volume");
        CHECK([PlorgVolumeSyncLogic parseFpliteLine:@"mac-volume://short/x" uuid:NULL samplePath:NULL]
              == FpliteLineMalformed, "UUID segment too short -> malformed");
        CHECK([PlorgVolumeSyncLogic parseFpliteLine:@"mac-volume://NODASHNODASH/x" uuid:NULL samplePath:NULL]
              == FpliteLineMalformed, "no dash -> malformed");
        CHECK([PlorgVolumeSyncLogic parseFpliteLine:@"mac-volume://noslashatall" uuid:NULL samplePath:NULL]
              == FpliteLineMalformed, "no slash -> malformed");
    }

    // --- scanFpliteContentForUUIDs / indexFpliteContent ---
    {
        g_context = "scan-content";
        NSString *content = [NSString stringWithFormat:
            @"mac-volume://%@/a.flac\n"
            @"mac-volume://%@/b.flac\n"
            @"mac-volume://%@/c.flac\n"
            @"file:///local.mp3\n"
            @"mac-volume://bad/x\n",
            kDead, kDead, kLive];

        NSDictionary *counts = [PlorgVolumeSyncLogic scanFpliteContentForUUIDs:content];
        CHECK_EQ(counts[kDead], @2, "dead UUID counted twice");
        CHECK_EQ(counts[kLive], @1, "live UUID counted once");
        CHECK(counts.count == 2, "malformed and non-volume lines skipped");
        CHECK([PlorgVolumeSyncLogic scanFpliteContentForUUIDs:nil].count == 0, "nil content -> empty");

        NSMutableDictionary *index = [NSMutableDictionary dictionary];
        [PlorgVolumeSyncLogic indexFpliteContent:content into:index];
        CHECK_EQ(index[kDead][@"count"], @2, "index counts");
        CHECK_EQ(index[kDead][@"samplePath"], @"a.flac", "samplePath from first entry");
        // Merging a second file accumulates
        [PlorgVolumeSyncLogic indexFpliteContent:[NSString stringWithFormat:@"mac-volume://%@/z.flac\n", kDead]
                                       into:index];
        CHECK_EQ(index[kDead][@"count"], @3, "second file accumulates count");
        CHECK_EQ(index[kDead][@"samplePath"], @"a.flac", "samplePath kept from first sighting");
    }

    // --- remappedFpliteData ---
    {
        g_context = "remap-data";
        NSString *body = [NSString stringWithFormat:
            @"mac-volume://%@/a.flac\nmac-volume://%@/b.flac\n", [kDead lowercaseString], kLive];
        NSData *plain = [body dataUsingEncoding:NSUTF8StringEncoding];

        NSData *out = [PlorgVolumeSyncLogic remappedFpliteData:plain
                                                fromUUIDs:[NSSet setWithObject:kDead]
                                                   toUUID:kLive];
        CHECK(out != nil, "change detected (case-insensitive match)");
        NSString *outStr = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
        CHECK(([outStr containsString:[NSString stringWithFormat:@"mac-volume://%@/a.flac", kLive]]),
              "dead UUID replaced");
        CHECK(![outStr containsString:[kDead lowercaseString]], "no dead UUID remains");

        // BOM preserved
        const uint8_t bom[] = {0xEF, 0xBB, 0xBF};
        NSMutableData *withBOM = [NSMutableData dataWithBytes:bom length:3];
        [withBOM appendData:plain];
        NSData *outBOM = [PlorgVolumeSyncLogic remappedFpliteData:withBOM
                                                   fromUUIDs:[NSSet setWithObject:kDead]
                                                      toUUID:kLive];
        CHECK(outBOM.length >= 3 && memcmp(outBOM.bytes, bom, 3) == 0, "UTF-8 BOM preserved");

        // No match -> nil
        CHECK([PlorgVolumeSyncLogic remappedFpliteData:plain
                                        fromUUIDs:[NSSet setWithObject:kOther]
                                           toUUID:kLive] == nil, "no match -> nil");

        // Invalid UTF-8 -> nil
        const uint8_t junk[] = {0xFF, 0xFE, 0x00, 0xD8};
        CHECK([PlorgVolumeSyncLogic remappedFpliteData:[NSData dataWithBytes:junk length:4]
                                        fromUUIDs:[NSSet setWithObject:kDead]
                                           toUUID:kLive] == nil, "non-UTF-8 -> nil");
    }

    // --- liveUUIDsByPathFromRegistry ---
    {
        g_context = "live-by-path";
        NSDictionary *registry = @{
            kLive:  @{ @"originalPath": @"/Volumes/music", @"resolvedPath": @"/Volumes/music",
                       @"isLive": @YES },
            kOther: @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
            kDead:  @{ @"isLive": @YES },  // live but no path -> skipped
        };
        NSDictionary *byPath = [PlorgVolumeSyncLogic liveUUIDsByPathFromRegistry:registry];
        CHECK(byPath.count == 1, "only pathed live UUIDs grouped");
        CHECK_EQ(byPath[@"/Volumes/music"], @[kLive], "live UUID grouped under path");
    }

    // --- planRemapActions ---
    {
        g_context = "plan-remap";
        NSDictionary *registry = @{
            kLive: @{ @"originalPath": @"/Volumes/music", @"resolvedPath": @"/Volumes/music",
                      @"isLive": @YES },
            kDead: @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
        };
        NSDictionary *byPath = @{ @"/Volumes/music": @[kLive] };
        NSMutableArray<NSString *> *logs = [NSMutableArray array];
        void (^log)(NSString *) = ^(NSString *m) { [logs addObject:m]; };

        // Dead UUID with matching originalPath -> remapped
        NSDictionary *plan = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kDead: @{ @"count": @3, @"samplePath": @"a.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) { return NO; }
            log:log];
        CHECK_EQ(plan, @{ kDead: kLive }, "dead UUID remapped via originalPath");

        // Live UUID in fplite -> untouched
        plan = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kLive: @{ @"count": @1, @"samplePath": @"a.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) { return YES; }
            log:nil];
        CHECK(plan.count == 0, "live UUID left alone");

        // Unknown UUID, sample path found on a live volume -> remapped
        plan = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kOther: @{ @"count": @1, @"samplePath": @"x/y.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) {
                return [p isEqualToString:@"/Volumes/music/x/y.flac"];
            }
            log:nil];
        CHECK_EQ(plan, @{ kOther: kLive }, "unknown UUID resolved via sample-path probe");

        // Unknown UUID, sample path nowhere -> no action, logged
        [logs removeAllObjects];
        plan = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kOther: @{ @"count": @1, @"samplePath": @"x/y.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) { return NO; }
            log:log];
        CHECK(plan.count == 0, "no replacement -> no action");
        CHECK(logs.count == 1 && [logs[0] containsString:@"no live replacement"],
              "unresolvable UUID logged");
    }

    // --- unresolvedFpliteUUIDs: the reported "contradiction" (item 1) ---
    // Reproduces 2026-07-11: registry has 0 live entries; a playlist references
    // a stale UUID for /Volumes/music. planRemapActions returns empty (no live
    // replacement), and the outcome must NOT be classified as "all live".
    {
        g_context = "unresolved-outcome";
        NSString *stale = @"CFA535CA-9B1A-B84E-33C6-30D0FABC1BA7";
        // Whole registry dead — mirrors "18 volumes (0 live)".
        NSDictionary *deadRegistry = @{
            stale: @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
            kDead: @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
        };
        NSDictionary *noLivePaths = [PlorgVolumeSyncLogic liveUUIDsByPathFromRegistry:deadRegistry];
        CHECK(noLivePaths.count == 0, "0 live registry entries -> no live paths");

        NSDictionary *idx = @{ stale: @{ @"count": @9, @"samplePath": @"Album/track.flac" } };
        NSDictionary *plan = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:deadRegistry
            fpliteIndex:idx
            liveUUIDsByPath:noLivePaths
            fileExists:^BOOL(NSString *p) { return YES; }  // path IS mounted & readable
            log:nil];
        CHECK(plan.count == 0, "stale UUID unrepairable when whole registry is dead");

        // The core assertion: this is NOT "all .fplite UUIDs are live".
        NSArray<NSString *> *unresolved = [PlorgVolumeSyncLogic unresolvedFpliteUUIDsInIndex:idx
            registry:deadRegistry remapActions:plan];
        CHECK(unresolved.count == 1 && [unresolved[0] isEqualToString:stale],
              "stale referenced UUID reported unresolved, not 'all live'");

        // Contrast: a genuinely-live fplite UUID is NOT reported unresolved.
        NSDictionary *liveReg = @{ kLive: @{ @"originalPath": @"/Volumes/music",
                                             @"resolvedPath": @"/Volumes/music", @"isLive": @YES } };
        NSArray<NSString *> *none = [PlorgVolumeSyncLogic unresolvedFpliteUUIDsInIndex:
            @{ kLive: @{ @"count": @1, @"samplePath": @"a.flac" } }
            registry:liveReg remapActions:@{}];
        CHECK(none.count == 0, "genuinely live UUID -> nothing unresolved (real 'all live')");

        // A UUID scheduled for remap is resolved, not unresolved.
        NSArray<NSString *> *afterPlan = [PlorgVolumeSyncLogic unresolvedFpliteUUIDsInIndex:idx
            registry:deadRegistry remapActions:@{ stale: kLive }];
        CHECK(afterPlan.count == 0, "UUID in remapActions counts as resolved");

        // A UUID unknown to the registry (not live, not planned) is unresolved.
        NSArray<NSString *> *unknown = [PlorgVolumeSyncLogic unresolvedFpliteUUIDsInIndex:
            @{ kOther: @{ @"count": @1, @"samplePath": @"z.flac" } }
            registry:deadRegistry remapActions:@{}];
        CHECK(unknown.count == 1, "UUID absent from registry is unresolved");
    }

    // --- mounted-but-unregistered classification (2026-07-11 addendum item 4) ---
    // Ground truth from the field: every registry bookmark can be dead while
    // the stale UUID's originalPath IS a mounted, readable directory (SMB mount
    // exposes no volume UUID, so no remap target is derivable from the mount;
    // only fb2k minting a fresh bookmark can supply one). In that state the
    // outcome must be "mounted but unregistered" — never "all live", and never
    // advice to mount an already-mounted volume.
    {
        g_context = "mounted-unregistered";
        NSString *stale = @"CFA535CA-9B1A-B84E-33C6-30D0FABC1BA7";
        NSDictionary *deadRegistry = @{
            stale:  @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
            kDead:  @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },   // same share, 2nd dead entry
            kOther: @{ @"originalPath": @"/Volumes/music-1", @"isLive": @NO }, // dead, NOT mounted
        };
        NSDictionary *idx = @{
            stale:  @{ @"count": @9, @"samplePath": @"Album/track.flac" },
            kDead:  @{ @"count": @1, @"samplePath": @"b.flac" },
            kOther: @{ @"count": @1, @"samplePath": @"c.flac" },
        };
        NSDictionary *plan = [PlorgVolumeSyncLogic planRemapActionsWithRegistry:deadRegistry
            fpliteIndex:idx
            liveUUIDsByPath:[PlorgVolumeSyncLogic liveUUIDsByPathFromRegistry:deadRegistry]
            fileExists:^BOOL(NSString *p) { return YES; }
            log:nil];
        CHECK(plan.count == 0, "no live target exists anywhere -> nothing planned");

        NSArray<NSString *> *unresolved = [PlorgVolumeSyncLogic unresolvedFpliteUUIDsInIndex:idx
            registry:deadRegistry remapActions:plan];
        CHECK(unresolved.count == 3, "all three stale UUIDs unresolved (never 'all live')");

        // Only /Volumes/music is mounted; the probe is consulted once per path.
        NSMutableArray<NSString *> *probed = [NSMutableArray array];
        NSArray<NSString *> *mounted = [PlorgVolumeSyncLogic mountedRegistryPathsForUnresolvedUUIDs:unresolved
            registry:deadRegistry
            isMounted:^BOOL(NSString *path) {
                [probed addObject:path];
                return [path isEqualToString:@"/Volumes/music"];
            }];
        CHECK_EQ(mounted, @[@"/Volumes/music"],
                 "mounted originalPath classified as mounted-but-unregistered, deduped");
        CHECK(![mounted containsObject:@"/Volumes/music-1"], "unmounted path not classified mounted");

        // Nothing mounted -> empty (the 'mount the volume' advice is then correct)
        NSArray<NSString *> *none = [PlorgVolumeSyncLogic mountedRegistryPathsForUnresolvedUUIDs:unresolved
            registry:deadRegistry
            isMounted:^BOOL(NSString *path) { return NO; }];
        CHECK(none.count == 0, "no mounted paths -> empty classification");

        // Unresolved UUID with no registry entry (no originalPath) never probes
        NSArray<NSString *> *noInfo = [PlorgVolumeSyncLogic mountedRegistryPathsForUnresolvedUUIDs:@[@"11111111-2222-3333-4444-999999999999"]
            registry:@{}
            isMounted:^BOOL(NSString *path) { return YES; }];
        CHECK(noInfo.count == 0, "UUID without registry originalPath yields no path");
    }

    // --- orphanCacheMigrations ---
    {
        g_context = "orphan-cache";
        NSDictionary *registry = @{
            kLive: @{ @"originalPath": @"/Volumes/music", @"resolvedPath": @"/Volumes/music",
                      @"isLive": @YES },
            kDead: @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
        };
        NSDictionary *byPath = @{ @"/Volumes/music": @[kLive] };

        // Dead has more rows than live -> migrate
        NSDictionary *m = [PlorgVolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kDead: @500, kLive: @10 }
                                                                     registry:registry
                                                              liveUUIDsByPath:byPath
                                                                          log:nil];
        CHECK_EQ(m, @{ kDead: kLive }, "dead cache with more rows migrates");

        // Dead has fewer rows -> already migrated, skip
        m = [PlorgVolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kDead: @10, kLive: @500 }
                                                       registry:registry
                                                liveUUIDsByPath:byPath
                                                            log:nil];
        CHECK(m.count == 0, "dead cache with fewer rows skipped");

        // Unknown to foobar -> skip
        m = [PlorgVolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kOther: @500 }
                                                       registry:registry
                                                liveUUIDsByPath:byPath
                                                            log:nil];
        CHECK(m.count == 0, "UUID unknown to registry skipped");

        // Live UUID rows -> skip
        m = [PlorgVolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kLive: @500 }
                                                       registry:registry
                                                liveUUIDsByPath:byPath
                                                            log:nil];
        CHECK(m.count == 0, "live UUID skipped");
    }

    // --- isValidMetadbIndexTableName ---
    // Guards the migrator's table discovery. SQL LIKE treats '_' as a
    // single-char wildcard, so 'metadb_index_%' matched the metadb_indexes
    // metadata table (columns name/synced/retention) and generated an INSERT
    // with nonexistent columns (observed 2026-07-11).
    {
        g_context = "index-table-name";
        NSString *real = @"metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE";
        CHECK([PlorgVolumeSyncLogic isValidMetadbIndexTableName:real], "real fb2k index table valid");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:@"metadb_indexes"],
              "metadb_indexes metadata table rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:
              [real stringByAppendingString:@"_data"]], "_data blob sibling rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:@"metadb"], "main table rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:@"metadb_index_abc"],
              "non-GUID suffix rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:
              @"metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AG"], "non-hex GUID rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:nil], "nil rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:@""], "empty rejected");
        CHECK(![PlorgVolumeSyncLogic isValidMetadbIndexTableName:
              @"metadb_index_C653739F\"; DROP TABLE metadb;--"], "injection payload rejected");
    }

    // --- metadbMigrationSQL ---
    {
        g_context = "migration-sql";
        NSString *idxTable = @"metadb_index_C653739F_14B3_4EF2_819B_A3E2883230AE";
        NSString *sql = [PlorgVolumeSyncLogic metadbMigrationSQLForRemapActions:@{ kDead: kLive }
                                                               indexTables:@[idxTable]];
        CHECK([sql hasPrefix:@"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\n"], "transaction preamble");
        CHECK([sql hasSuffix:@"COMMIT;\n"], "commit suffix");
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"REPLACE(name, 'mac-volume://%@', 'mac-volume://%@')", kDead, kLive]]),
            "metadb REPLACE clause");
        CHECK([sql containsString:@"INSERT OR IGNORE INTO metadb "], "metadb insert");
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"INSERT OR IGNORE INTO \"%@\" (key, filename)", idxTable]]),
              "index table insert");
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"WHERE name LIKE '%%mac-volume://%@/%%'", kDead]]),
            "LIKE pattern scoped to dead UUID");

        // Move semantics: dead-UUID source rows are deleted in the same
        // transaction, so copies do not accumulate across remount generations.
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"DELETE FROM metadb WHERE name LIKE '%%mac-volume://%@/%%'", kDead]]),
            "metadb source rows deleted after copy");
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"DELETE FROM \"%@\" WHERE filename LIKE '%%mac-volume://%@/%%'",
                idxTable, kDead]]),
            "index table source rows deleted after copy");
        NSRange insertPos = [sql rangeOfString:@"INSERT OR IGNORE INTO metadb "];
        NSRange deletePos = [sql rangeOfString:@"DELETE FROM metadb "];
        CHECK(insertPos.location != NSNotFound && deletePos.location != NSNotFound &&
              insertPos.location < deletePos.location, "copy precedes delete");

        // Tables failing the shape validator must never be written to.
        NSString *guarded = [PlorgVolumeSyncLogic metadbMigrationSQLForRemapActions:@{ kDead: kLive }
            indexTables:@[@"metadb_indexes", [idxTable stringByAppendingString:@"_data"], idxTable]];
        CHECK(![guarded containsString:@"\"metadb_indexes\""], "metadb_indexes never written");
        CHECK(![guarded containsString:@"_data\""], "_data sibling never written");
        CHECK(([guarded containsString:
            [NSString stringWithFormat:@"INSERT OR IGNORE INTO \"%@\" (key, filename)", idxTable]]),
              "valid table still migrated alongside rejected ones");

        NSString *emptySql = [PlorgVolumeSyncLogic metadbMigrationSQLForRemapActions:@{} indexTables:@[]];
        CHECK_EQ(emptySql, @"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\nCOMMIT;\n",
                 "no actions -> empty transaction");
    }

    // --- selfHealCandidates ---
    // The remediation gap (investigation item 5): every registry bookmark is
    // dead but the stale UUID's originalPath IS mounted and readable. The
    // candidate list drives the mint attempt (feeding one real file through
    // fb2k's location machinery so the core registers the volume).
    {
        g_context = "self-heal-candidates";
        NSString *stale = @"CFA535CA-9B1A-B84E-33C6-30D0FABC1BA7";
        NSDictionary *deadRegistry = @{
            stale:  @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
            kDead:  @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
            kOther: @{ @"originalPath": @"/Volumes/other", @"isLive": @NO },
        };
        NSDictionary *idx = @{
            stale:  @{ @"count": @9, @"samplePath": @"Album/track.flac" },
            kDead:  @{ @"count": @1, @"samplePath": @"b.flac" },
            kOther: @{ @"count": @1, @"samplePath": @"c.flac" },
        };
        BOOL (^musicMounted)(NSString *) = ^BOOL(NSString *p) {
            return [p isEqualToString:@"/Volumes/music"];
        };

        // Mounted path + existing sample file -> exactly one candidate per path
        NSArray *cands = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:@[stale, kDead, kOther]
            registry:deadRegistry fpliteIndex:idx
            isMounted:musicMounted
            fileExists:^BOOL(NSString *p) { return YES; }];
        CHECK(cands.count == 1, "one candidate per distinct mounted path");
        CHECK_EQ(cands.firstObject[@"path"], @"/Volumes/music", "candidate path is the mounted path");
        CHECK_EQ(cands.firstObject[@"file"], @"/Volumes/music/Album/track.flac",
                 "candidate file = mounted path + samplePath");

        // Not mounted -> no candidate
        NSArray *none = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:@[stale]
            registry:deadRegistry fpliteIndex:idx
            isMounted:^BOOL(NSString *p) { return NO; }
            fileExists:^BOOL(NSString *p) { return YES; }];
        CHECK(none.count == 0, "unmounted path yields no candidate");

        // Mounted but sample file missing -> skipped; next UUID for the same
        // path can still supply a candidate
        NSArray *fallback = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:@[stale, kDead]
            registry:deadRegistry fpliteIndex:idx
            isMounted:musicMounted
            fileExists:^BOOL(NSString *p) {
                return [p isEqualToString:@"/Volumes/music/b.flac"];
            }];
        CHECK(fallback.count == 1, "second UUID supplies candidate when first sample is gone");
        CHECK_EQ(fallback.firstObject[@"file"], @"/Volumes/music/b.flac",
                 "verifiable sample file chosen");

        // No sample path in the index (UUID not from .fplite) -> no candidate
        NSArray *noSample = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:@[stale]
            registry:deadRegistry fpliteIndex:@{}
            isMounted:musicMounted
            fileExists:^BOOL(NSString *p) { return YES; }];
        CHECK(noSample.count == 0, "no samplePath -> no candidate");

        // UUID without a registry originalPath -> no candidate
        NSArray *noPath = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:@[kLive]
            registry:@{} fpliteIndex:@{ kLive: @{ @"count": @1, @"samplePath": @"a.flac" } }
            isMounted:^BOOL(NSString *p) { return YES; }
            fileExists:^BOOL(NSString *p) { return YES; }];
        CHECK(noPath.count == 0, "no registry originalPath -> no candidate");

        // Two distinct mounted paths -> one candidate each, sorted by path
        NSDictionary *twoReg = @{
            stale:  @{ @"originalPath": @"/Volumes/music", @"isLive": @NO },
            kOther: @{ @"originalPath": @"/Volumes/other", @"isLive": @NO },
        };
        NSArray *two = [PlorgVolumeSyncLogic selfHealCandidatesForUnresolvedUUIDs:@[kOther, stale]
            registry:twoReg fpliteIndex:idx
            isMounted:^BOOL(NSString *p) { return YES; }
            fileExists:^BOOL(NSString *p) { return YES; }];
        CHECK(two.count == 2, "one candidate per mounted path");
        CHECK_EQ(two[0][@"path"], @"/Volumes/music", "sorted by path (1st)");
        CHECK_EQ(two[1][@"path"], @"/Volumes/other", "sorted by path (2nd)");
    }

    }
    printf("VolumeSyncLogicTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
