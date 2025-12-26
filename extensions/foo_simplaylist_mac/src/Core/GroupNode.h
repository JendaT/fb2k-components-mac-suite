//
//  GroupNode.h
//  foo_simplaylist_mac
//
//  Data model for playlist display nodes (headers, subgroups, tracks)
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GroupNodeType) {
    GroupNodeTypeHeader,      // Group header row
    GroupNodeTypeSubgroup,    // Subgroup separator
    GroupNodeTypeTrack        // Individual track
};

@interface GroupNode : NSObject

// Node type
@property (nonatomic, assign) GroupNodeType type;

// Display text (formatted via titleformat)
@property (nonatomic, copy, nullable) NSString *displayText;

// For tracks: playlist index; for headers/subgroups: -1
@property (nonatomic, assign) NSInteger playlistIndex;

// Nesting depth (0 for headers, 1+ for subgroups/tracks)
@property (nonatomic, assign) NSInteger indentLevel;

// State flags
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, assign) BOOL isFocused;

// For headers: group boundaries
@property (nonatomic, assign) NSInteger groupStartIndex;  // First track index in playlist
@property (nonatomic, assign) NSInteger groupEndIndex;    // Last track index in playlist
@property (nonatomic, assign) NSInteger groupFirstRow;    // First row in display
@property (nonatomic, assign) NSInteger groupLastRow;     // Last row in display

// Album art cache key (for headers)
@property (nonatomic, copy, nullable) NSString *albumArtKey;

// Column values for track rows (formatted strings for each column)
@property (nonatomic, strong, nullable) NSArray<NSString *> *columnValues;

// Factory methods
+ (instancetype)headerWithText:(NSString *)text
                    startIndex:(NSInteger)start
                      endIndex:(NSInteger)end
                   albumArtKey:(nullable NSString *)artKey;

+ (instancetype)subgroupWithText:(NSString *)text
                     indentLevel:(NSInteger)level;

+ (instancetype)trackWithPlaylistIndex:(NSInteger)index
                          columnValues:(NSArray<NSString *> *)values
                           indentLevel:(NSInteger)level;

// Lazy version - column values loaded on demand
+ (instancetype)trackWithPlaylistIndex:(NSInteger)index
                           indentLevel:(NSInteger)level;

@end

NS_ASSUME_NONNULL_END
