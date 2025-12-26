//
//  GroupPreset.h
//  foo_simplaylist_mac
//
//  Group configuration preset model
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Display type for group components
typedef NS_ENUM(NSInteger, GroupDisplayType) {
    GroupDisplayTypeText,    // Plain text
    GroupDisplayTypeFront,   // Album art (front cover)
    GroupDisplayTypeBack,    // Album art (back cover)
    GroupDisplayTypeDisc,    // Album art (disc)
    GroupDisplayTypeArtist   // Artist image
};

// Subgroup definition
@interface SubgroupDefinition : NSObject

@property (nonatomic, copy) NSString *pattern;
@property (nonatomic, assign) GroupDisplayType displayType;

+ (instancetype)subgroupWithPattern:(NSString *)pattern displayType:(GroupDisplayType)type;

@end

// Group preset configuration
@interface GroupPreset : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *sortingPattern;

// Header configuration
@property (nonatomic, copy) NSString *headerPattern;
@property (nonatomic, assign) GroupDisplayType headerDisplayType;

// Group column (album art area) configuration
@property (nonatomic, copy) NSString *groupColumnPattern;
@property (nonatomic, assign) GroupDisplayType groupColumnDisplayType;

// Subgroups (e.g., disc separators)
@property (nonatomic, strong) NSArray<SubgroupDefinition *> *subgroups;

// Factory methods
+ (instancetype)presetWithName:(NSString *)name;

// Parse presets from JSON string
+ (NSArray<GroupPreset *> *)presetsFromJSON:(NSString *)jsonString;
+ (nullable NSString *)presetsToJSON:(NSArray<GroupPreset *> *)presets activeIndex:(NSInteger)index;
+ (nullable NSString *)presetsToJSON:(NSArray<GroupPreset *> *)presets;  // Uses index 0

// Get subgroup pattern (first subgroup or empty)
- (NSString *)subgroupPattern;
- (void)setSubgroupPattern:(NSString *)pattern;

// Get currently active preset index from JSON
+ (NSInteger)activeIndexFromJSON:(NSString *)jsonString;

// Default presets
+ (NSArray<GroupPreset *> *)defaultPresets;

// Convert display type from/to string
+ (GroupDisplayType)displayTypeFromString:(NSString *)str;
+ (NSString *)stringFromDisplayType:(GroupDisplayType)type;

@end

NS_ASSUME_NONNULL_END
