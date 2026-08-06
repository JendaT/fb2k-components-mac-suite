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
//  template or SDK provider) is an orphan, and the loader below drops it.
//

#pragma once

#import "ColumnDefinition.h"

NS_ASSUME_NONNULL_BEGIN

@interface ColumnDefinition (Store)

// Visible column layout, from persisted config with a fallback chain: stored
// JSON, then the compiled-in default JSON, then a hardcoded five-column set.
//
// Also applies two silent repairs to the stored layout — orphan removal and the
// legacy Playing-pattern migration — but does NOT write them back. On return
// *outNeedsPersist says whether a repair changed anything, leaving the decision
// to save with the owner of the live layout.
//
// This used to be a getter that wrote config as a side effect, which is how
// kColumns ended up with four writers and no owner. The concrete failure was a
// rename that a live panel never saw, overwritten by the next column resize,
// then deleted at the following launch by the orphan cleanup inside this very
// method. Pass NULL for outNeedsPersist if the caller genuinely cannot persist.
+ (NSArray<ColumnDefinition *> *)loadVisibleColumnsNeedingPersist:(nullable BOOL *)outNeedsPersist;

// The single entry point for writing kColumns. Refuses to store a failed
// serialisation, since an empty string is the config store's DELETE idiom.
+ (void)persistVisibleColumns:(NSArray<ColumnDefinition *> *)columns
                       reason:(const char *)reason;

// Read columns dynamically from SDK playlistColumnProvider services
// (playback statistics: Play Count, First/Last Played, Date Added, Rating).
//
// *outComplete reports whether the enumeration finished without an exception.
// It matters because a partial list makes columns belonging to a provider that
// had not loaded yet look like orphans — and orphans get deleted permanently.
// Pass NULL if the answer is not needed.
+ (NSArray<ColumnDefinition *> *)columnsFromSDKProvidersComplete:(nullable BOOL *)outComplete;
+ (NSArray<ColumnDefinition *> *)columnsFromSDKProviders;

// User-defined custom columns (the catalogue, stored under kCustomColumns).
+ (NSArray<ColumnDefinition *> *)customColumns;
+ (void)saveCustomColumns:(NSArray<ColumnDefinition *> *)columns;
+ (void)addCustomColumn:(ColumnDefinition *)column;
+ (void)removeCustomColumnAtIndex:(NSUInteger)index;

// Drop visible columns whose name matches no built-in template, SDK provider
// or custom definition. Gathers the known-name set from config and the SDK,
// then defers to +[ColumnDefinition columns:filteredToKnownNames:].
//
// Returns the input unchanged when the SDK provider enumeration is incomplete:
// filtering against a partial known-name set would classify live columns as
// orphans, and an orphan is deleted for good.
+ (NSArray<ColumnDefinition *> *)removeOrphanedColumns:(NSArray<ColumnDefinition *> *)columns;

// Update the visible layout when a custom column is renamed in the catalogue,
// so the layout does not immediately contain an orphan.
+ (void)syncCustomColumnRenameFrom:(NSString *)oldName to:(NSString *)newName;

@end

NS_ASSUME_NONNULL_END
