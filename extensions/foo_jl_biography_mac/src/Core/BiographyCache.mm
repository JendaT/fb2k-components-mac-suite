//
//  BiographyCache.mm
//  foo_jl_biography_mac
//
//  SQLite-based cache implementation
//

#import "BiographyCache.h"
#import "BiographyData.h"
#import "../API/BiographyAPIConstants.h"
#import <sqlite3.h>

@interface BiographyCache ()

@property (nonatomic) sqlite3 *db;
@property (nonatomic, strong) dispatch_queue_t dbQueue;
@property (nonatomic, copy) NSString *dbPath;

@end

@implementation BiographyCache

- (instancetype)init {
    self = [super init];
    if (self) {
        _dbQueue = dispatch_queue_create("com.foobar2000.biography.cache", DISPATCH_QUEUE_SERIAL);
        [self setupDatabase];
    }
    return self;
}

- (void)dealloc {
    if (_db) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

#pragma mark - Database Setup

- (void)setupDatabase {
    // Create cache directory
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                                NSUserDomainMask, YES).firstObject;
    NSString *cacheDir = [appSupport stringByAppendingPathComponent:@"foobar2000-v2/biography_cache"];

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
    if (error) {
        NSLog(@"[Biography] Failed to create cache directory: %@", error);
        return;
    }

    self.dbPath = [cacheDir stringByAppendingPathComponent:@"biography.db"];

    dispatch_sync(self.dbQueue, ^{
        int result = sqlite3_open([self.dbPath UTF8String], &self->_db);
        if (result != SQLITE_OK) {
            NSLog(@"[Biography] Failed to open database: %d", result);
            return;
        }

        // Create tables
        const char *createSQL = R"SQL(
            CREATE TABLE IF NOT EXISTS artists (
                artist_name TEXT PRIMARY KEY COLLATE NOCASE,
                display_name TEXT,
                mbid TEXT,
                biography TEXT,
                biography_summary TEXT,
                biography_source INTEGER,
                language TEXT,
                image_url TEXT,
                image_source INTEGER,
                image_type INTEGER,
                tags TEXT,
                similar_artists TEXT,
                genre TEXT,
                country TEXT,
                listeners INTEGER,
                playcount INTEGER,
                cached_at REAL,
                last_accessed REAL
            );

            CREATE INDEX IF NOT EXISTS idx_artists_cached_at ON artists(cached_at);
            CREATE INDEX IF NOT EXISTS idx_artists_last_accessed ON artists(last_accessed);
        )SQL";

        char *errMsg = NULL;
        result = sqlite3_exec(self->_db, createSQL, NULL, NULL, &errMsg);
        if (result != SQLITE_OK) {
            NSLog(@"[Biography] Failed to create tables: %s", errMsg);
            sqlite3_free(errMsg);
        }
    });
}

#pragma mark - Cache Operations

- (void)cacheBiography:(BiographyData *)data forArtist:(NSString *)artistName {
    if (!data || !artistName) return;

    dispatch_async(self.dbQueue, ^{
        if (!self.db) return;

        const char *sql = R"SQL(
            INSERT OR REPLACE INTO artists
            (artist_name, display_name, mbid, biography, biography_summary,
             biography_source, language, image_url, image_source, image_type,
             tags, similar_artists, genre, country, listeners, playcount,
             cached_at, last_accessed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        )SQL";

        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            NSLog(@"[Biography] Failed to prepare cache statement");
            return;
        }

        // Bind values
        sqlite3_bind_text(stmt, 1, [artistName.lowercaseString UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [data.artistName UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [data.musicBrainzId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [data.biography UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 5, [data.biographySummary UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 6, (int)data.biographySource);
        sqlite3_bind_text(stmt, 7, [data.language UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 8, [data.artistImageURL.absoluteString UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 9, (int)data.imageSource);
        sqlite3_bind_int(stmt, 10, (int)data.imageType);

        // Serialize arrays as JSON
        NSString *tagsJson = [self jsonStringFromArray:data.tags];
        sqlite3_bind_text(stmt, 11, [tagsJson UTF8String], -1, SQLITE_TRANSIENT);

        NSString *similarJson = [self serializeSimilarArtists:data.similarArtists];
        sqlite3_bind_text(stmt, 12, [similarJson UTF8String], -1, SQLITE_TRANSIENT);

        sqlite3_bind_text(stmt, 13, [data.genre UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 14, [data.country UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 15, data.listeners);
        sqlite3_bind_int64(stmt, 16, data.playcount);

        double now = [[NSDate date] timeIntervalSince1970];
        sqlite3_bind_double(stmt, 17, now);
        sqlite3_bind_double(stmt, 18, now);

        if (sqlite3_step(stmt) != SQLITE_DONE) {
            NSLog(@"[Biography] Failed to cache biography: %s", sqlite3_errmsg(self.db));
        }

        sqlite3_finalize(stmt);
    });

    // PERF-6: Enforce cache size after writes
    [self enforceMaxSize];
}

- (BiographyData *)fetchCachedBiographyForArtist:(NSString *)artistName {
    if (!artistName) return nil;

    __block BiographyData *result = nil;

    dispatch_sync(self.dbQueue, ^{
        if (!self.db) return;

        const char *sql = R"SQL(
            SELECT display_name, mbid, biography, biography_summary,
                   biography_source, language, image_url, image_source, image_type,
                   tags, similar_artists, genre, country, listeners, playcount,
                   cached_at, last_accessed
            FROM artists
            WHERE artist_name = ?
        )SQL";

        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            return;
        }

        sqlite3_bind_text(stmt, 1, [artistName.lowercaseString UTF8String], -1, SQLITE_TRANSIENT);

        if (sqlite3_step(stmt) == SQLITE_ROW) {
            BiographyDataBuilder *builder = [[BiographyDataBuilder alloc] init];

            builder.artistName = [self stringFromColumn:0 stmt:stmt] ?: artistName;
            builder.musicBrainzId = [self stringFromColumn:1 stmt:stmt];
            builder.biography = [self stringFromColumn:2 stmt:stmt];
            builder.biographySummary = [self stringFromColumn:3 stmt:stmt];
            builder.biographySource = (BiographySource)sqlite3_column_int(stmt, 4);
            builder.language = [self stringFromColumn:5 stmt:stmt];

            NSString *imageUrlStr = [self stringFromColumn:6 stmt:stmt];
            if (imageUrlStr) {
                builder.artistImageURL = [NSURL URLWithString:imageUrlStr];
            }

            builder.imageSource = (BiographySource)sqlite3_column_int(stmt, 7);
            builder.imageType = (BiographyImageType)sqlite3_column_int(stmt, 8);

            NSString *tagsJson = [self stringFromColumn:9 stmt:stmt];
            builder.tags = [self arrayFromJsonString:tagsJson];

            NSString *similarJson = [self stringFromColumn:10 stmt:stmt];
            builder.similarArtists = [self deserializeSimilarArtists:similarJson];

            builder.genre = [self stringFromColumn:11 stmt:stmt];
            builder.country = [self stringFromColumn:12 stmt:stmt];
            builder.listeners = sqlite3_column_int64(stmt, 13);
            builder.playcount = sqlite3_column_int64(stmt, 14);

            double cachedAt = sqlite3_column_double(stmt, 15);
            builder.fetchedAt = [NSDate dateWithTimeIntervalSince1970:cachedAt];
            builder.isFromCache = YES;

            // Check if stale
            NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - cachedAt;
            builder.isStale = age > kBiographyCacheTTL;

            result = [builder build];

            // ARCH-6: Inline touch SQL within existing dispatch_sync block
            // PERF-10: Only update last_accessed if more than 1 hour stale
            double lastAccessed = sqlite3_column_double(stmt, 16);
            double now = [[NSDate date] timeIntervalSince1970];
            if (now - lastAccessed > 3600) {
                sqlite3_finalize(stmt);
                stmt = NULL;

                const char *touchSql = "UPDATE artists SET last_accessed = ? WHERE artist_name = ?";
                sqlite3_stmt *touchStmt = NULL;
                if (sqlite3_prepare_v2(self.db, touchSql, -1, &touchStmt, NULL) == SQLITE_OK) {
                    sqlite3_bind_double(touchStmt, 1, now);
                    sqlite3_bind_text(touchStmt, 2, [artistName.lowercaseString UTF8String], -1, SQLITE_TRANSIENT);
                    sqlite3_step(touchStmt);
                    sqlite3_finalize(touchStmt);
                }
            }
        }

        if (stmt) sqlite3_finalize(stmt);
    });

    return result;
}

- (BOOL)hasFreshCacheForArtist:(NSString *)artistName {
    if (!artistName) return NO;

    __block BOOL isFresh = NO;

    dispatch_sync(self.dbQueue, ^{
        if (!self.db) return;

        // PERF-5: Only read cached_at instead of full row
        const char *sql = "SELECT cached_at FROM artists WHERE artist_name = ? LIMIT 1";
        sqlite3_stmt *stmt = NULL;

        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            return;
        }

        sqlite3_bind_text(stmt, 1, [artistName.lowercaseString UTF8String], -1, SQLITE_TRANSIENT);

        if (sqlite3_step(stmt) == SQLITE_ROW) {
            double cachedAt = sqlite3_column_double(stmt, 0);
            NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - cachedAt;
            isFresh = age <= kBiographyCacheTTL;
        }

        sqlite3_finalize(stmt);
    });

    return isFresh;
}

- (void)clearCacheForArtist:(NSString *)artistName {
    if (!artistName) return;

    dispatch_async(self.dbQueue, ^{
        if (!self.db) return;

        const char *sql = "DELETE FROM artists WHERE artist_name = ?";
        sqlite3_stmt *stmt = NULL;

        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [artistName.lowercaseString UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    });
}

- (void)clearAllCache {
    dispatch_async(self.dbQueue, ^{
        if (!self.db) return;

        sqlite3_exec(self.db, "DELETE FROM artists", NULL, NULL, NULL);
    });
}

- (NSUInteger)totalCacheSize {
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:self.dbPath error:&error];
    return [attrs[NSFileSize] unsignedIntegerValue];
}

- (void)enforceMaxSize {
    dispatch_async(self.dbQueue, ^{
        if (!self.db) return;

        // PERF-6/SEC-11: Use SQLite page_count * page_size for size check (no syscall),
        // cap iterations, and VACUUM after deletions
        NSUInteger iterations = 0;
        static const NSUInteger kMaxIterations = 50;

        while (iterations < kMaxIterations) {
            // Get database size via SQLite internals
            sqlite3_stmt *sizeStmt = NULL;
            if (sqlite3_prepare_v2(self.db, "SELECT page_count * page_size FROM pragma_page_count, pragma_page_size", -1, &sizeStmt, NULL) != SQLITE_OK) {
                break;
            }

            NSUInteger dbSize = 0;
            if (sqlite3_step(sizeStmt) == SQLITE_ROW) {
                dbSize = (NSUInteger)sqlite3_column_int64(sizeStmt, 0);
            }
            sqlite3_finalize(sizeStmt);

            if (dbSize <= kMaxCacheSizeBytes) break;

            const char *sql = R"SQL(
                DELETE FROM artists WHERE artist_name IN
                (SELECT artist_name FROM artists ORDER BY last_accessed ASC LIMIT 10)
            )SQL";

            if (sqlite3_exec(self.db, sql, NULL, NULL, NULL) != SQLITE_OK) {
                break;
            }

            iterations++;
        }

        if (iterations > 0) {
            sqlite3_exec(self.db, "VACUUM", NULL, NULL, NULL);
        }
    });
}

#pragma mark - Helpers

- (NSString *)stringFromColumn:(int)col stmt:(sqlite3_stmt *)stmt {
    const char *text = (const char *)sqlite3_column_text(stmt, col);
    return text ? [NSString stringWithUTF8String:text] : nil;
}

- (NSString *)jsonStringFromArray:(NSArray<NSString *> *)array {
    if (!array.count) return nil;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:array options:0 error:&error];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (NSArray<NSString *> *)arrayFromJsonString:(NSString *)json {
    if (!json) return nil;

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    // SEC-7: Validate type from cached JSON
    if (![parsed isKindOfClass:[NSArray class]]) return nil;
    return (NSArray *)parsed;
}

- (NSString *)serializeSimilarArtists:(NSArray<SimilarArtistRef *> *)artists {
    if (!artists.count) return nil;

    NSMutableArray *dicts = [NSMutableArray array];
    for (SimilarArtistRef *ref in artists) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"name"] = ref.name;
        if (ref.thumbnailURL) d[@"thumbnailURL"] = ref.thumbnailURL.absoluteString;
        if (ref.musicBrainzId) d[@"mbid"] = ref.musicBrainzId;
        [dicts addObject:d];
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dicts options:0 error:&error];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (NSArray<SimilarArtistRef *> *)deserializeSimilarArtists:(NSString *)json {
    if (!json) return nil;

    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

    // SEC-7: Validate types from cached JSON
    if (![parsed isKindOfClass:[NSArray class]]) return nil;
    NSArray *dicts = (NSArray *)parsed;

    NSMutableArray *result = [NSMutableArray array];
    for (id element in dicts) {
        if (![element isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *d = (NSDictionary *)element;

        NSString *name = d[@"name"];
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;

        NSURL *thumbURL = nil;
        NSString *thumbStr = d[@"thumbnailURL"];
        if ([thumbStr isKindOfClass:[NSString class]] && thumbStr.length > 0) {
            thumbURL = [NSURL URLWithString:thumbStr];
        }

        NSString *mbid = d[@"mbid"];
        if (![mbid isKindOfClass:[NSString class]]) mbid = nil;

        SimilarArtistRef *ref = [[SimilarArtistRef alloc] initWithName:name
                                                          thumbnailURL:thumbURL
                                                         musicBrainzId:mbid];
        [result addObject:ref];
    }
    return [result copy];
}

@end
