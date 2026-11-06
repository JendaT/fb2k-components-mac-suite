//
//  ColumnDefinition.h
//  foo_simplaylist_mac
//
//  Column configuration model
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ColumnAlignment) {
    ColumnAlignmentLeft,
    ColumnAlignmentCenter,
    ColumnAlignmentRight
};

@interface ColumnDefinition : NSObject <NSCopying>

// Column name (displayed in header)
@property (nonatomic, copy) NSString *name;

// Title formatting pattern
@property (nonatomic, copy) NSString *pattern;

// Current width in points
@property (nonatomic, assign) CGFloat width;

// Minimum width
@property (nonatomic, assign) CGFloat minWidth;

// Text alignment
@property (nonatomic, assign) ColumnAlignment alignment;

// Whether this column should expand to fill available space
@property (nonatomic, assign) BOOL autoResize;

// Whether clicking this column performs an action (e.g., rating)
@property (nonatomic, assign) BOOL clickable;

// Factory methods
+ (instancetype)columnWithName:(NSString *)name
                       pattern:(NSString *)pattern
                         width:(CGFloat)width
                     alignment:(ColumnAlignment)alignment;

+ (instancetype)columnWithName:(NSString *)name
                       pattern:(NSString *)pattern
                         width:(CGFloat)width
                     alignment:(ColumnAlignment)alignment
                    autoResize:(BOOL)autoResize;

// Parse alignment from string
+ (ColumnAlignment)alignmentFromString:(NSString *)str;
+ (NSString *)stringFromAlignment:(ColumnAlignment)alignment;

// Built-in column templates offered by the column chooser menu. Hardcoded and
// config-free; the SDK-provided columns are appended by the Store category.
+ (NSArray<ColumnDefinition *> *)availableColumnTemplates;

// Config-backed and SDK-backed accessors (the layout loader, +customColumns,
// +columnsFromSDKProviders, +removeOrphanedColumns:, the rename sync and the
// custom-column mutators) live in ColumnDefinitionStore.h, so this file stays
// free of the foobar2000 SDK and can be unit-tested standalone.

#pragma mark - Pure transforms

// Keep only the columns whose name appears in knownNames. The Store category
// assembles that set from the built-in templates, the SDK providers and the
// user's custom-column catalogue; the filtering itself is here so it can be
// tested without any of them.
+ (NSArray<ColumnDefinition *> *)columns:(NSArray<ColumnDefinition *> *)columns
                    filteredToKnownNames:(NSSet<NSString *> *)knownNames;

// Rename every column called oldName. Returns nil when nothing matched, so the
// caller can skip persisting entirely rather than rewriting an identical layout.
+ (nullable NSArray<ColumnDefinition *> *)columns:(NSArray<ColumnDefinition *> *)columns
                                      renamedFrom:(NSString *)oldName
                                               to:(NSString *)newName;

// Strip the legacy "$if(%isplaying%,>,)" pattern from Playing columns, now that
// SimPlaylistView draws the indicator natively. Returns nil when no column
// needed migrating.
// TODO: This migration for Playing column can be removed in future. Let's keep it until end of 2026.
+ (nullable NSArray<ColumnDefinition *> *)columnsByMigratingLegacyPlayingPattern:
    (NSArray<ColumnDefinition *> *)columns;

#pragma mark - JSON codec

// Parse columns from JSON string. Returns an empty array for anything
// unparseable; individual entries with wrong types are skipped.
+ (NSArray<ColumnDefinition *> *)columnsFromJSON:(NSString *)jsonString;

// Serialize columns to JSON string, or nil on failure.
//
// Nil rather than @"" deliberately: ConfigHelper documents that storing an
// empty string is the config store's DELETE idiom, so a caller that wrote the
// empty-string failure value straight through would erase the user's saved
// layout. This now matches +[GroupPreset presetsToJSON:activeIndex:], which
// the two functions previously disagreed about despite being mirror images.
+ (nullable NSString *)columnsToJSON:(NSArray<ColumnDefinition *> *)columns;

@end

NS_ASSUME_NONNULL_END
