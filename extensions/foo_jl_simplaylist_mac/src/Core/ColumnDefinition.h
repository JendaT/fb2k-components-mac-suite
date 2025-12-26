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

// Default columns (loads from config or returns hardcoded defaults)
+ (NSArray<ColumnDefinition *> *)defaultColumns;

// All available column templates (for column chooser menu)
// Combines hardcoded defaults + columns from SDK playlistColumnProvider services
+ (NSArray<ColumnDefinition *> *)availableColumnTemplates;

// Read columns dynamically from SDK playlistColumnProvider services
+ (NSArray<ColumnDefinition *> *)columnsFromSDKProviders;

// Parse columns from JSON string
+ (NSArray<ColumnDefinition *> *)columnsFromJSON:(NSString *)jsonString;

// Serialize columns to JSON string
+ (NSString *)columnsToJSON:(NSArray<ColumnDefinition *> *)columns;

@end

NS_ASSUME_NONNULL_END
