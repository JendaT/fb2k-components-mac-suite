//
//  ColumnDefinition.mm
//  foo_simplaylist_mac
//

#import "ColumnDefinition.h"
#import "ConfigHelper.h"
#import "../fb2k_sdk.h"
#import <foobar2000/SDK/playlistColumnProvider.h>

// Guarded funnel for every persisted column-layout write.
// columnsToJSON: returns @"" when serialisation fails, and ConfigHelper
// documents that storing "" is the DELETE idiom - an unguarded write would
// silently wipe the user's column layout. A nil string would additionally
// hand UTF8String == NULL to the SDK.
static void persistColumnsJSON(const char *key, NSString *json, const char *what) {
    if (json.length == 0) {
        FB2K_console_formatter() << "[SimPlaylist] Refusing to persist empty column JSON ("
                                 << what << "); keeping the stored layout";
        return;
    }
    simplaylist_config::setConfigString(key, json.UTF8String);
}

@implementation ColumnDefinition

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"";
        _pattern = @"";
        _width = 100;
        _minWidth = 30;
        _alignment = ColumnAlignmentLeft;
        _autoResize = NO;
        _clickable = NO;
    }
    return self;
}

- (id)copyWithZone:(nullable NSZone *)zone {
    ColumnDefinition *copy = [[ColumnDefinition allocWithZone:zone] init];
    copy.name = self.name;
    copy.pattern = self.pattern;
    copy.width = self.width;
    copy.minWidth = self.minWidth;
    copy.alignment = self.alignment;
    copy.autoResize = self.autoResize;
    copy.clickable = self.clickable;
    return copy;
}

+ (instancetype)columnWithName:(NSString *)name
                       pattern:(NSString *)pattern
                         width:(CGFloat)width
                     alignment:(ColumnAlignment)alignment {
    return [self columnWithName:name pattern:pattern width:width alignment:alignment autoResize:NO];
}

+ (instancetype)columnWithName:(NSString *)name
                       pattern:(NSString *)pattern
                         width:(CGFloat)width
                     alignment:(ColumnAlignment)alignment
                    autoResize:(BOOL)autoResize {
    ColumnDefinition *col = [[ColumnDefinition alloc] init];
    col.name = name;
    col.pattern = pattern;
    col.width = width;
    col.alignment = alignment;
    col.autoResize = autoResize;
    return col;
}

+ (ColumnAlignment)alignmentFromString:(NSString *)str {
    NSString *lower = [str lowercaseString];
    if ([lower isEqualToString:@"center"]) {
        return ColumnAlignmentCenter;
    } else if ([lower isEqualToString:@"right"]) {
        return ColumnAlignmentRight;
    }
    return ColumnAlignmentLeft;
}

+ (NSString *)stringFromAlignment:(ColumnAlignment)alignment {
    switch (alignment) {
        case ColumnAlignmentCenter:
            return @"center";
        case ColumnAlignmentRight:
            return @"right";
        default:
            return @"left";
    }
}

+ (NSArray<ColumnDefinition *> *)defaultColumns {
    // First try to load from saved config
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kColumns, "");

    if (!savedJSON.empty()) {
        NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
        NSArray<ColumnDefinition *> *columns = [self columnsFromJSON:jsonString];
        if (columns.count > 0) {
            // Clean up any orphaned custom columns. Cleanup must fall through to
            // the migration below: returning early left a config that needed both
            // migrating only on the next launch.
            NSArray<ColumnDefinition *> *cleaned = [self removeOrphanedColumns:columns];
            NSUInteger orphansRemoved = columns.count - cleaned.count;

            // Migration: remove legacy ">" pattern from Playing columns now that the
            // native ▶ drawing in SimPlaylistView handles the indicator.
            // TODO: This migration for Playing column can be removed in future. Let's keep it until end of 2026.
            BOOL migrated = NO;
            NSMutableArray<ColumnDefinition *> *migrating = [cleaned mutableCopy];
            for (ColumnDefinition *col in migrating) {
                if ([col.name isEqualToString:@"Playing"] &&
                    [col.pattern isEqualToString:@"$if(%isplaying%,>,)"]) {
                    col.pattern = @"";
                    migrated = YES;
                }
            }

            if (orphansRemoved > 0 || migrated) {
                persistColumnsJSON(simplaylist_config::kColumns,
                                   [self columnsToJSON:migrating],
                                   "orphan cleanup / Playing migration");
                if (orphansRemoved > 0) {
                    FB2K_console_formatter() << "[SimPlaylist] Removed "
                        << orphansRemoved << " orphaned custom column(s)";
                }
                if (migrated) {
                    FB2K_console_formatter() << "[SimPlaylist] Migrated Playing column: removed legacy > pattern";
                }
            }

            return migrating;
        }
    }

    // Fall back to hardcoded default JSON
    const char* jsonCStr = simplaylist_config::getDefaultColumnsJSON();
    NSString *jsonString = [NSString stringWithUTF8String:jsonCStr];

    NSArray<ColumnDefinition *> *columns = [self columnsFromJSON:jsonString];
    if (columns.count > 0) {
        return columns;
    }

    // Final fallback to hardcoded defaults
    return @[
        [ColumnDefinition columnWithName:@"Playing"
                                 pattern:@""
                                   width:24
                               alignment:ColumnAlignmentCenter],

        [ColumnDefinition columnWithName:@"#"
                                 pattern:@"%tracknumber%"
                                   width:32
                               alignment:ColumnAlignmentRight],

        [ColumnDefinition columnWithName:@"Title"
                                 pattern:@"%title%"
                                   width:250
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],

        [ColumnDefinition columnWithName:@"Artist"
                                 pattern:@"%artist%"
                                   width:150
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],

        [ColumnDefinition columnWithName:@"Duration"
                                 pattern:@"%length%"
                                   width:50
                               alignment:ColumnAlignmentRight]
    ];
}

+ (NSArray<ColumnDefinition *> *)availableColumnTemplates {
    // Return all available column types for the column chooser menu
    // Organized in same order as default playlist UI
    return @[
        // Standard columns (first group)
        [ColumnDefinition columnWithName:@"#"
                                 pattern:@"%tracknumber%"
                                   width:32
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Item index"
                                 pattern:@"%list_index%"
                                   width:50
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Artist"
                                 pattern:@"%artist%"
                                   width:150
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Album"
                                 pattern:@"%album%"
                                   width:150
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Artist/album"
                                 pattern:@"$if2(%album artist%,%artist%)[ / %album%]"
                                   width:200
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Title"
                                 pattern:@"%title%"
                                   width:250
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Title / track artist"
                                 pattern:@"%title%[ / %track artist%]"
                                   width:250
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"Date"
                                 pattern:@"%date%"
                                   width:60
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Duration"
                                 pattern:@"%length%"
                                   width:50
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Codec"
                                 pattern:@"%codec%"
                                   width:60
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Bitrate"
                                 pattern:@"%bitrate%"
                                   width:60
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Sample Rate"
                                 pattern:@"[%samplerate% Hz][, %__bitspersample%-bit]"
                                   width:100
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"BPM"
                                 pattern:@"%BPM%"
                                   width:50
                               alignment:ColumnAlignmentRight],
        [ColumnDefinition columnWithName:@"Key"
                                 pattern:@"%INITIALKEY%"
                                   width:50
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"Queue #"
                                 pattern:@"__queue_position__"
                                   width:40
                               alignment:ColumnAlignmentCenter],
        [ColumnDefinition columnWithName:@"Playing"
                                 pattern:@""
                                   width:24
                               alignment:ColumnAlignmentCenter],
        [ColumnDefinition columnWithName:@"File name"
                                 pattern:@"%filename%"
                                   width:200
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"File extension"
                                 pattern:@"%filename_ext%"
                                   width:50
                               alignment:ColumnAlignmentLeft],
        [ColumnDefinition columnWithName:@"File path"
                                 pattern:@"%path%"
                                   width:300
                               alignment:ColumnAlignmentLeft
                              autoResize:YES],
        [ColumnDefinition columnWithName:@"File size"
                                 pattern:@"%filesize%"
                                   width:60
                               alignment:ColumnAlignmentRight],
        // Note: Play Count, First Played, Last Played, Date Added, Rating
        // are provided by SDK playlistColumnProvider, not hardcoded here
    ];
}

+ (NSArray<ColumnDefinition *> *)columnsFromSDKProviders {
    // Returns columns from SDK playlistColumnProvider services
    // (e.g., playback statistics: Play Count, First/Last Played, Date Added, Rating)
    // Note: foobar's Custom Playlist Columns are stored in binary cfg_var blob - not accessible

    NSMutableArray<ColumnDefinition *> *columns = [NSMutableArray array];
    NSMutableSet<NSString *> *seenNames = [NSMutableSet set];

    // The SDK raises C++ exceptions (pfc::exception), which @catch (NSException *)
    // cannot intercept; the outer C++ handlers mirror runGuardedSDKAction in
    // SimPlaylistView.mm and ConfigHelper's accessors.
    try {
    @try {

        // Enumerate all playlistColumnProvider services
        for (auto provider : fb2k::playlistColumnProvider::enumerate()) {
            size_t numCols = provider->numColumns();

            for (size_t i = 0; i < numCols; i++) {
                fb2k::stringRef nameRef = provider->columnName(i);
                fb2k::stringRef patternRef = provider->columnFormatSpec(i);
                unsigned flags = provider->columnFlags(i);

                if (!nameRef.is_valid() || !patternRef.is_valid()) continue;

                NSString *name = [NSString stringWithUTF8String:nameRef->c_str()];
                NSString *pattern = [NSString stringWithUTF8String:patternRef->c_str()];

                // Skip if empty or already seen
                if (!name || name.length == 0 || !pattern || pattern.length == 0) continue;
                if ([seenNames containsObject:name]) continue;
                [seenNames addObject:name];

                // Determine alignment from flags
                ColumnAlignment alignment = ColumnAlignmentLeft;
                if (flags & fb2k::playlistColumnProvider::flag_alignRight) {
                    alignment = ColumnAlignmentRight;
                } else if (flags & fb2k::playlistColumnProvider::flag_alignCenter) {
                    alignment = ColumnAlignmentCenter;
                }

                ColumnDefinition *col = [ColumnDefinition columnWithName:name
                                                                  pattern:pattern
                                                                    width:100
                                                                alignment:alignment];
                [columns addObject:col];
            }
        }
    } @catch (NSException *exception) {
        FB2K_console_formatter() << "[SimPlaylist] Column provider enumeration failed: "
                                 << (exception.reason.UTF8String ?: "unknown");
    }
    } catch (const std::exception &e) {
        FB2K_console_formatter() << "[SimPlaylist] Column provider enumeration failed: " << e.what();
    } catch (...) {
        FB2K_console_formatter() << "[SimPlaylist] Column provider enumeration failed: unknown exception";
    }

    return columns;
}

#pragma mark - Custom Columns

+ (NSArray<ColumnDefinition *> *)customColumns {
    std::string jsonStr = simplaylist_config::getConfigString(
        simplaylist_config::kCustomColumns,
        simplaylist_config::getDefaultCustomColumnsJSON()
    );

    if (jsonStr.empty()) {
        return @[];
    }

    NSString *json = [NSString stringWithUTF8String:jsonStr.c_str()];
    return [self columnsFromJSON:json];
}

+ (void)saveCustomColumns:(NSArray<ColumnDefinition *> *)columns {
    // An empty custom-column list legitimately serialises to a non-empty JSON
    // document ({"columns": []}), so an empty string here is always a failure.
    persistColumnsJSON(simplaylist_config::kCustomColumns,
                       [self columnsToJSON:columns],
                       "custom columns");
}

+ (void)addCustomColumn:(ColumnDefinition *)column {
    NSMutableArray *columns = [[self customColumns] mutableCopy];
    [columns addObject:column];
    [self saveCustomColumns:columns];
}

+ (void)removeCustomColumnAtIndex:(NSUInteger)index {
    NSMutableArray *columns = [[self customColumns] mutableCopy];
    if (index < columns.count) {
        [columns removeObjectAtIndex:index];
        [self saveCustomColumns:columns];
    }
}

+ (NSArray<ColumnDefinition *> *)removeOrphanedColumns:(NSArray<ColumnDefinition *> *)columns {
    // Build set of all known column names (templates + SDK providers + custom definitions)
    NSMutableSet<NSString *> *knownNames = [NSMutableSet set];

    // Add built-in template names
    for (ColumnDefinition *col in [self availableColumnTemplates]) {
        [knownNames addObject:col.name];
    }

    // Add SDK provider column names
    for (ColumnDefinition *col in [self columnsFromSDKProviders]) {
        [knownNames addObject:col.name];
    }

    // Add user-defined custom column names
    for (ColumnDefinition *col in [self customColumns]) {
        [knownNames addObject:col.name];
    }

    // Filter to only columns with known names
    NSMutableArray<ColumnDefinition *> *result = [NSMutableArray array];
    for (ColumnDefinition *col in columns) {
        if ([knownNames containsObject:col.name]) {
            [result addObject:col];
        }
    }

    return result;
}

+ (void)syncCustomColumnRenameFrom:(NSString *)oldName to:(NSString *)newName {
    if (!oldName || !newName || [oldName isEqualToString:newName]) {
        return;
    }

    // Load current visible columns
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kColumns, "");
    if (savedJSON.empty()) {
        return;
    }

    NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
    NSArray<ColumnDefinition *> *columns = [self columnsFromJSON:jsonString];
    if (columns.count == 0) {
        return;
    }

    // Find and update any column with the old name
    BOOL changed = NO;
    NSMutableArray<ColumnDefinition *> *updated = [NSMutableArray array];
    for (ColumnDefinition *col in columns) {
        if ([col.name isEqualToString:oldName]) {
            ColumnDefinition *renamed = [col copy];
            renamed.name = newName;
            [updated addObject:renamed];
            changed = YES;
        } else {
            [updated addObject:col];
        }
    }

    // Save if any columns were renamed
    if (changed) {
        persistColumnsJSON(simplaylist_config::kColumns,
                           [self columnsToJSON:updated],
                           "custom column rename");
    }
}

+ (NSArray<ColumnDefinition *> *)columnsFromJSON:(NSString *)jsonString {
    if (!jsonString || jsonString.length == 0) {
        return @[];
    }

    NSError *error = nil;
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) {
        // Unencodable string (e.g. unpaired surrogates); JSONObjectWithData:
        // would throw on nil data.
        return @[];
    }
    // A top-level JSON array parses fine and is NOT a dictionary; subscripting
    // it would raise NSInvalidArgumentException on every panel construction.
    id root = [NSJSONSerialization JSONObjectWithData:jsonData
                                              options:0
                                                error:&error];
    if (error || ![root isKindOfClass:[NSDictionary class]]) {
        return @[];
    }
    NSDictionary *json = root;

    NSArray *columnsArray = json[@"columns"];
    if (![columnsArray isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ColumnDefinition *> *result = [NSMutableArray array];

    for (NSDictionary *colDict in columnsArray) {
        if (![colDict isKindOfClass:[NSDictionary class]]) continue;

        NSString *name = colDict[@"name"];
        NSString *pattern = colDict[@"pattern"];
        NSNumber *widthNum = colDict[@"width"];
        NSString *alignmentStr = colDict[@"alignment"];
        NSNumber *autoResizeNum = colDict[@"auto_resize"];
        NSNumber *clickableNum = colDict[@"clickable"];

        // Corrupted config can put non-strings/non-numbers here; wrong types
        // crash later on isEqualToString:/doubleValue sends.
        if (![name isKindOfClass:[NSString class]] ||
            ![pattern isKindOfClass:[NSString class]]) continue;
        if (widthNum && ![widthNum isKindOfClass:[NSNumber class]]) widthNum = nil;
        if (alignmentStr && ![alignmentStr isKindOfClass:[NSString class]]) alignmentStr = nil;
        if (autoResizeNum && ![autoResizeNum isKindOfClass:[NSNumber class]]) autoResizeNum = nil;
        if (clickableNum && ![clickableNum isKindOfClass:[NSNumber class]]) clickableNum = nil;

        // Migration: "Track no" removed - use "#" instead (v1.1.7+)
        if ([name isEqualToString:@"Track no"]) {
            continue;  // Skip - duplicate of "#"
        }

        ColumnDefinition *col = [[ColumnDefinition alloc] init];
        col.name = name;
        col.pattern = pattern;
        // Persisted width may be NaN/Inf/non-positive; that would flow into
        // NSRect math and hit-testing. Fall back to the default and cap.
        // (No higher floor: stock columns legitimately persist widths of 24.)
        double width = widthNum ? [widthNum doubleValue] : 100;
        if (!isfinite(width) || width <= 0) width = 100;
        col.width = MIN(10000.0, width);
        col.alignment = alignmentStr ? [self alignmentFromString:alignmentStr] : ColumnAlignmentLeft;
        col.autoResize = autoResizeNum ? [autoResizeNum boolValue] : NO;
        col.clickable = clickableNum ? [clickableNum boolValue] : NO;

        [result addObject:col];
    }

    return result;
}

+ (NSString *)columnsToJSON:(NSArray<ColumnDefinition *> *)columns {
    NSMutableArray *columnsArray = [NSMutableArray array];

    for (ColumnDefinition *col in columns) {
        NSMutableDictionary *colDict = [NSMutableDictionary dictionary];
        // nil field would crash the dictionary literal-style assignment
        colDict[@"name"] = col.name ?: @"";
        colDict[@"pattern"] = col.pattern ?: @"";
        colDict[@"width"] = @(col.width);
        colDict[@"alignment"] = [self stringFromAlignment:col.alignment];
        if (col.autoResize) {
            colDict[@"auto_resize"] = @YES;
        }
        if (col.clickable) {
            colDict[@"clickable"] = @YES;
        }
        [columnsArray addObject:colDict];
    }

    NSDictionary *json = @{@"columns": columnsArray};
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:json
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&error];
    if (error || !jsonData) {
        return @"";
    }

    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<Column: %@ pattern='%@' width=%.0f>",
            self.name, self.pattern, self.width];
}

@end
