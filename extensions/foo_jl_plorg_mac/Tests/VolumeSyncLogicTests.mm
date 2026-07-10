//
//  VolumeSyncLogicTests.mm
//  foo_plorg_mac
//
//  Unit tests for VolumeSyncLogic (mount parsing, fplite scanning,
//  BOM-preserving remap, repair planning, orphan migration, SQL builder).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/VolumeSyncLogic.h"

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
        CHECK([VolumeSyncLogic isValidVolumeUUID:kDead], "canonical uppercase UUID valid");
        CHECK(([VolumeSyncLogic isValidVolumeUUID:[kDead lowercaseString]]), "lowercase valid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:nil], "nil invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@""], "empty invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"NOTAUUID"], "short invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEE"],
              "35 chars invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEEE"],
              "37 chars invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"GGGGGGGG-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
              "non-hex invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"AAAAAAAABBBB-CCCC-DDDD-EEEEEEEEEEEEE"],
              "wrong group shape invalid");
        // SQL-injection payloads must never validate
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"X'; DROP TABLE metadb;--"],
              "quote injection invalid");
        CHECK(![VolumeSyncLogic isValidVolumeUUID:@"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEE'E"],
              "embedded quote invalid");
    }

    // --- Malformed UUIDs are rejected at the parse boundary ---
    {
        g_context = "injection-rejected";
        // A crafted .fplite line whose "UUID" segment carries SQL
        NSString *evil = @"mac-volume://X'; DROP TABLE metadb;--/a.flac";
        CHECK([VolumeSyncLogic parseFpliteLine:evil uuid:NULL samplePath:NULL] == FpliteLineMalformed,
              "SQL payload in UUID segment rejected as malformed");
        CHECK([VolumeSyncLogic scanFpliteContentForUUIDs:evil].count == 0,
              "malformed line contributes no UUID");

        NSMutableDictionary *idx = [NSMutableDictionary dictionary];
        [VolumeSyncLogic indexFpliteContent:evil into:idx];
        CHECK(idx.count == 0, "malformed line not indexed");

        // Config keys carrying SQL are rejected too
        CHECK([VolumeSyncLogic volumeUUIDFromConfigKey:@"mac.volume.X'; DROP TABLE x;--.bookmark"] == nil,
              "SQL payload in config key rejected");

        // Even if a bad value somehow reaches the SQL builder, it is skipped
        NSString *sql = [VolumeSyncLogic metadbMigrationSQLForRemapActions:
                            @{ @"X'; DROP TABLE metadb;--": kLive } indexTables:@[]];
        CHECK(![sql containsString:@"DROP TABLE"], "SQL builder skips invalid dead UUID");
        CHECK_EQ(sql, @"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\nCOMMIT;\n",
                 "invalid action yields empty transaction");

        NSString *sql2 = [VolumeSyncLogic metadbMigrationSQLForRemapActions:
                            @{ kDead: @"bogus-target" } indexTables:@[]];
        CHECK(![sql2 containsString:@"bogus"], "SQL builder skips invalid live UUID");
    }

    // --- shareNameFromMountSource ---
    {
        g_context = "share-name";
        CHECK_EQ([VolumeSyncLogic shareNameFromMountSource:"//user@192.168.1.10/music.hq"],
                 @"music.hq", "SMB with user");
        CHECK_EQ([VolumeSyncLogic shareNameFromMountSource:"//host/share"],
                 @"share", "SMB without user");
        CHECK_EQ([VolumeSyncLogic shareNameFromMountSource:"//host/share/sub/dir"],
                 @"share", "SMB subpath ignored");
        CHECK_EQ([VolumeSyncLogic shareNameFromMountSource:"nas:/export/media"],
                 @"media", "NFS last component");
        CHECK([VolumeSyncLogic shareNameFromMountSource:"//hostonly"] == nil, "no share part -> nil");
        CHECK([VolumeSyncLogic shareNameFromMountSource:"/dev/disk1s1"] == nil, "local device -> nil");
        CHECK([VolumeSyncLogic shareNameFromMountSource:NULL] == nil, "NULL -> nil");
        CHECK([VolumeSyncLogic shareNameFromMountSource:""] == nil, "empty -> nil");
    }

    // --- volumeUUIDFromConfigKey ---
    {
        g_context = "config-key";
        NSString *key = [NSString stringWithFormat:@"mac.volume.%@.originalPath", [kDead lowercaseString]];
        CHECK_EQ([VolumeSyncLogic volumeUUIDFromConfigKey:key], kDead, "extracts and uppercases");
        CHECK([VolumeSyncLogic volumeUUIDFromConfigKey:@"other.key"] == nil, "wrong prefix -> nil");
        CHECK([VolumeSyncLogic volumeUUIDFromConfigKey:@"mac.volume.nodot"] == nil, "no dot -> nil");
        CHECK([VolumeSyncLogic volumeUUIDFromConfigKey:@"mac.volume.nodash.bookmark"] == nil,
              "no dash in UUID -> nil");
    }

    // --- parseFpliteLine ---
    {
        g_context = "parse-line";
        NSString *uuid = nil, *sample = nil;
        NSString *line = [NSString stringWithFormat:@"mac-volume://%@/Artist/Track.flac",
                          [kDead lowercaseString]];
        CHECK([VolumeSyncLogic parseFpliteLine:line uuid:&uuid samplePath:&sample] == FpliteLineParsed,
              "valid line parses");
        CHECK_EQ(uuid, kDead, "UUID uppercased");
        CHECK_EQ(sample, @"Artist/Track.flac", "sample path after UUID");

        CHECK([VolumeSyncLogic parseFpliteLine:@"" uuid:NULL samplePath:NULL] == FpliteLineNotVolume,
              "empty -> not volume");
        CHECK([VolumeSyncLogic parseFpliteLine:@"file:///local/track.mp3" uuid:NULL samplePath:NULL]
              == FpliteLineNotVolume, "other scheme -> not volume");
        CHECK([VolumeSyncLogic parseFpliteLine:@"mac-volume://short/x" uuid:NULL samplePath:NULL]
              == FpliteLineMalformed, "UUID segment too short -> malformed");
        CHECK([VolumeSyncLogic parseFpliteLine:@"mac-volume://NODASHNODASH/x" uuid:NULL samplePath:NULL]
              == FpliteLineMalformed, "no dash -> malformed");
        CHECK([VolumeSyncLogic parseFpliteLine:@"mac-volume://noslashatall" uuid:NULL samplePath:NULL]
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

        NSDictionary *counts = [VolumeSyncLogic scanFpliteContentForUUIDs:content];
        CHECK_EQ(counts[kDead], @2, "dead UUID counted twice");
        CHECK_EQ(counts[kLive], @1, "live UUID counted once");
        CHECK(counts.count == 2, "malformed and non-volume lines skipped");
        CHECK([VolumeSyncLogic scanFpliteContentForUUIDs:nil].count == 0, "nil content -> empty");

        NSMutableDictionary *index = [NSMutableDictionary dictionary];
        [VolumeSyncLogic indexFpliteContent:content into:index];
        CHECK_EQ(index[kDead][@"count"], @2, "index counts");
        CHECK_EQ(index[kDead][@"samplePath"], @"a.flac", "samplePath from first entry");
        // Merging a second file accumulates
        [VolumeSyncLogic indexFpliteContent:[NSString stringWithFormat:@"mac-volume://%@/z.flac\n", kDead]
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

        NSData *out = [VolumeSyncLogic remappedFpliteData:plain
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
        NSData *outBOM = [VolumeSyncLogic remappedFpliteData:withBOM
                                                   fromUUIDs:[NSSet setWithObject:kDead]
                                                      toUUID:kLive];
        CHECK(outBOM.length >= 3 && memcmp(outBOM.bytes, bom, 3) == 0, "UTF-8 BOM preserved");

        // No match -> nil
        CHECK([VolumeSyncLogic remappedFpliteData:plain
                                        fromUUIDs:[NSSet setWithObject:kOther]
                                           toUUID:kLive] == nil, "no match -> nil");

        // Invalid UTF-8 -> nil
        const uint8_t junk[] = {0xFF, 0xFE, 0x00, 0xD8};
        CHECK([VolumeSyncLogic remappedFpliteData:[NSData dataWithBytes:junk length:4]
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
        NSDictionary *byPath = [VolumeSyncLogic liveUUIDsByPathFromRegistry:registry];
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
        NSDictionary *plan = [VolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kDead: @{ @"count": @3, @"samplePath": @"a.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) { return NO; }
            log:log];
        CHECK_EQ(plan, @{ kDead: kLive }, "dead UUID remapped via originalPath");

        // Live UUID in fplite -> untouched
        plan = [VolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kLive: @{ @"count": @1, @"samplePath": @"a.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) { return YES; }
            log:nil];
        CHECK(plan.count == 0, "live UUID left alone");

        // Unknown UUID, sample path found on a live volume -> remapped
        plan = [VolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kOther: @{ @"count": @1, @"samplePath": @"x/y.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) {
                return [p isEqualToString:@"/Volumes/music/x/y.flac"];
            }
            log:nil];
        CHECK_EQ(plan, @{ kOther: kLive }, "unknown UUID resolved via sample-path probe");

        // Unknown UUID, sample path nowhere -> no action, logged
        [logs removeAllObjects];
        plan = [VolumeSyncLogic planRemapActionsWithRegistry:registry
            fpliteIndex:@{ kOther: @{ @"count": @1, @"samplePath": @"x/y.flac" } }
            liveUUIDsByPath:byPath
            fileExists:^BOOL(NSString *p) { return NO; }
            log:log];
        CHECK(plan.count == 0, "no replacement -> no action");
        CHECK(logs.count == 1 && [logs[0] containsString:@"no live replacement"],
              "unresolvable UUID logged");
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
        NSDictionary *m = [VolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kDead: @500, kLive: @10 }
                                                                     registry:registry
                                                              liveUUIDsByPath:byPath
                                                                          log:nil];
        CHECK_EQ(m, @{ kDead: kLive }, "dead cache with more rows migrates");

        // Dead has fewer rows -> already migrated, skip
        m = [VolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kDead: @10, kLive: @500 }
                                                       registry:registry
                                                liveUUIDsByPath:byPath
                                                            log:nil];
        CHECK(m.count == 0, "dead cache with fewer rows skipped");

        // Unknown to foobar -> skip
        m = [VolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kOther: @500 }
                                                       registry:registry
                                                liveUUIDsByPath:byPath
                                                            log:nil];
        CHECK(m.count == 0, "UUID unknown to registry skipped");

        // Live UUID rows -> skip
        m = [VolumeSyncLogic orphanCacheMigrationsWithRowCounts:@{ kLive: @500 }
                                                       registry:registry
                                                liveUUIDsByPath:byPath
                                                            log:nil];
        CHECK(m.count == 0, "live UUID skipped");
    }

    // --- metadbMigrationSQL ---
    {
        g_context = "migration-sql";
        NSString *sql = [VolumeSyncLogic metadbMigrationSQLForRemapActions:@{ kDead: kLive }
                                                               indexTables:@[@"metadb_index_abc"]];
        CHECK([sql hasPrefix:@"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\n"], "transaction preamble");
        CHECK([sql hasSuffix:@"COMMIT;\n"], "commit suffix");
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"REPLACE(name, 'mac-volume://%@', 'mac-volume://%@')", kDead, kLive]]),
            "metadb REPLACE clause");
        CHECK([sql containsString:@"INSERT OR IGNORE INTO metadb "], "metadb insert");
        CHECK([sql containsString:@"INSERT OR IGNORE INTO \"metadb_index_abc\" (key, filename)"],
              "index table insert");
        CHECK(([sql containsString:
            [NSString stringWithFormat:@"WHERE name LIKE '%%mac-volume://%@/%%'", kDead]]),
            "LIKE pattern scoped to dead UUID");

        NSString *emptySql = [VolumeSyncLogic metadbMigrationSQLForRemapActions:@{} indexTables:@[]];
        CHECK_EQ(emptySql, @"PRAGMA busy_timeout=10000;\nBEGIN IMMEDIATE;\nCOMMIT;\n",
                 "no actions -> empty transaction");
    }

    }
    printf("VolumeSyncLogicTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
