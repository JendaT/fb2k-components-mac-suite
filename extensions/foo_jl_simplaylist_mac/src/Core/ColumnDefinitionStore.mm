//
//  ColumnDefinitionStore.mm
//  foo_simplaylist_mac
//

#import "ColumnDefinitionStore.h"
#import "ConfigHelper.h"
#import "../fb2k_sdk.h"
#import <foobar2000/SDK/playlistColumnProvider.h>

// Guarded funnel for every persisted column write, for both keys.
//
// columnsToJSON: returns nil when serialisation fails, and ConfigHelper
// documents that storing "" is the config store's DELETE idiom — so an
// unguarded write of a failure value would silently wipe the user's columns and
// let the compiled-in defaults quietly take over. A nil string would additionally hand
// UTF8String == NULL to the SDK. An empty custom-column list legitimately
// serialises to a non-empty document ({"columns": []}), so an empty or nil
// string here always means failure, never "nothing to save".
static void persistColumnsJSON(const char *key, NSString *json, const char *what) {
    if (json.length == 0) {
        FB2K_console_formatter() << "[SimPlaylist] Refusing to persist empty column JSON ("
                                 << what << "); keeping the stored layout";
        return;
    }
    simplaylist_config::setConfigString(key, json.UTF8String);
}

@implementation ColumnDefinition (Store)

#pragma mark - Visible layout

+ (void)persistVisibleColumns:(NSArray<ColumnDefinition *> *)columns
                       reason:(const char *)reason {
    persistColumnsJSON(simplaylist_config::kColumns,
                       [self columnsToJSON:columns],
                       reason);
}

+ (NSArray<ColumnDefinition *> *)loadVisibleColumnsNeedingPersist:(nullable BOOL *)outNeedsPersist {
    if (outNeedsPersist) *outNeedsPersist = NO;

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
            NSArray<ColumnDefinition *> *repaired = [self removeOrphanedColumns:columns];
            NSUInteger orphansRemoved = columns.count - repaired.count;

            // Migration: remove legacy ">" pattern from Playing columns now that
            // the native indicator drawing in SimPlaylistView handles it.
            NSArray<ColumnDefinition *> *migrated =
                [self columnsByMigratingLegacyPlayingPattern:repaired];
            if (migrated) repaired = migrated;

            if (orphansRemoved > 0) {
                FB2K_console_formatter() << "[SimPlaylist] Removed "
                    << orphansRemoved << " orphaned custom column(s)";
            }
            if (migrated) {
                FB2K_console_formatter() << "[SimPlaylist] Migrated Playing column: removed legacy > pattern";
            }
            if (outNeedsPersist) *outNeedsPersist = (orphansRemoved > 0 || migrated != nil);

            return repaired;
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

#pragma mark - SDK providers

+ (NSArray<ColumnDefinition *> *)columnsFromSDKProviders {
    return [self columnsFromSDKProvidersComplete:NULL];
}

+ (NSArray<ColumnDefinition *> *)columnsFromSDKProvidersComplete:(nullable BOOL *)outComplete {
    // Returns columns from SDK playlistColumnProvider services
    // (e.g., playback statistics: Play Count, First/Last Played, Date Added, Rating)
    // Note: foobar's Custom Playlist Columns are stored in binary cfg_var blob - not accessible

    if (outComplete) *outComplete = YES;

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
        if (outComplete) *outComplete = NO;
        FB2K_console_formatter() << "[SimPlaylist] Column provider enumeration failed: "
                                 << (exception.reason.UTF8String ?: "unknown");
    }
    } catch (const std::exception &e) {
        if (outComplete) *outComplete = NO;
        FB2K_console_formatter() << "[SimPlaylist] Column provider enumeration failed: " << e.what();
    } catch (...) {
        if (outComplete) *outComplete = NO;
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

#pragma mark - Layout repair

+ (NSArray<ColumnDefinition *> *)removeOrphanedColumns:(NSArray<ColumnDefinition *> *)columns {
    // Build set of all known column names (templates + SDK providers + custom definitions)
    BOOL sdkComplete = YES;
    NSArray<ColumnDefinition *> *sdkColumns = [self columnsFromSDKProvidersComplete:&sdkComplete];

    // A throw partway through provider enumeration yields a partial list, and
    // every column belonging to a provider past the throw would then look like
    // an orphan. Orphan removal is permanent, so bail out entirely rather than
    // delete a user's columns on the strength of an incomplete answer.
    if (!sdkComplete) {
        FB2K_console_formatter()
            << "[SimPlaylist] Skipping orphaned-column cleanup: provider enumeration was incomplete";
        return columns;
    }

    NSMutableSet<NSString *> *knownNames = [NSMutableSet set];
    for (ColumnDefinition *col in [self availableColumnTemplates]) {
        [knownNames addObject:col.name];
    }
    for (ColumnDefinition *col in sdkColumns) {
        [knownNames addObject:col.name];
    }
    for (ColumnDefinition *col in [self customColumns]) {
        [knownNames addObject:col.name];
    }

    return [self columns:columns filteredToKnownNames:knownNames];
}

+ (void)syncCustomColumnRenameFrom:(NSString *)oldName to:(NSString *)newName {
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

    // nil when no visible column carried the old name — nothing to write.
    NSArray<ColumnDefinition *> *updated = [self columns:columns
                                            renamedFrom:oldName
                                                     to:newName];
    if (!updated) {
        return;
    }

    [self persistVisibleColumns:updated reason:"custom column rename"];
}

@end
