//
//  ColumnDefinitionStore.h
//  foo_simplaylist_mac
//
//  The config-backed and SDK-backed half of ColumnDefinition.
//
//  ColumnDefinition itself is a pure model + JSON codec with no dependency on
//  the foobar2000 SDK, which is what lets Tests/ColumnDefinitionTests.mm
//  compile and run it standalone under clang. Everything that reads or writes
//  the config store, or enumerates SDK column providers, lives here instead.
//
//  The separation has to be at file scope — see the note in GroupPresetStore.h
//  for why a link-time stub or a fake SDK header on -I cannot substitute.
//
//  Two config keys are involved and they are not the same thing:
//    kCustomColumns — the user's *catalogue* of custom column definitions.
//    kColumns       — the *visible layout*: which columns a panel shows, in
//                     what order, at what width.
//  A name appearing in the layout but in no catalogue (and matching no built-in
//  template or SDK provider) is an orphan, and +defaultColumns drops it.
//

#pragma once

#import "ColumnDefinition.h"

NS_ASSUME_NONNULL_BEGIN

@interface ColumnDefinition (Store)

// Visible column layout, from persisted config with a fallback chain: stored
// JSON, then the compiled-in default JSON, then a hardcoded five-column set.
//
// Also applies two silent repairs to the stored layout and writes the result
// back: orphan removal, and the legacy Playing-pattern migration. Both are
// implemented by the pure helpers on ColumnDefinition, which is where they are
// tested; this method only supplies the config I/O around them.
+ (NSArray<ColumnDefinition *> *)defaultColumns;

// Read columns dynamically from SDK playlistColumnProvider services
// (playback statistics: Play Count, First/Last Played, Date Added, Rating).
+ (NSArray<ColumnDefinition *> *)columnsFromSDKProviders;

// User-defined custom columns (the catalogue, stored under kCustomColumns).
+ (NSArray<ColumnDefinition *> *)customColumns;
+ (void)saveCustomColumns:(NSArray<ColumnDefinition *> *)columns;
+ (void)addCustomColumn:(ColumnDefinition *)column;
+ (void)removeCustomColumnAtIndex:(NSUInteger)index;

// Drop visible columns whose name matches no built-in template, SDK provider
// or custom definition. Gathers the known-name set from config and the SDK,
// then defers to +[ColumnDefinition columns:filteredToKnownNames:].
+ (NSArray<ColumnDefinition *> *)removeOrphanedColumns:(NSArray<ColumnDefinition *> *)columns;

// Update the visible layout when a custom column is renamed in the catalogue,
// so the layout does not immediately contain an orphan.
+ (void)syncCustomColumnRenameFrom:(NSString *)oldName to:(NSString *)newName;

@end

NS_ASSUME_NONNULL_END
