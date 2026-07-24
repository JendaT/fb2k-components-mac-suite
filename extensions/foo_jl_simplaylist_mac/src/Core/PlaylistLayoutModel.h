//
//  PlaylistLayoutModel.h
//  foo_simplaylist_mac
//
//  Pure geometry/index model for the sparse group layout.
//
//  Contains NO foobar2000 SDK dependency and NO drawing code: only the
//  arithmetic that maps between playlist indices, display rows, groups,
//  subgroups, padding rows and pixel offsets. Extracted from SimPlaylistView
//  so this logic can be unit-tested without instantiating an NSView or the host.
//
//  The owning view feeds the inputs (itemCount, group/subgroup arrays, header
//  style, row metrics) and queries the pure methods. Extracted in the 1.5.0
//  testability refactor (see CHANGELOG.md).
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PlaylistLayoutModel : NSObject

// --- Inputs (sparse group model) ---
@property (nonatomic, assign) NSInteger itemCount;                                  // Total playlist items
@property (nonatomic, copy) NSArray<NSNumber *> *groupStarts;                       // Playlist indices where groups start
@property (nonatomic, copy) NSArray<NSNumber *> *groupPaddingRows;                  // Extra padding rows per group
@property (nonatomic, assign) NSInteger totalPaddingRowsCached;                     // Sum of all padding rows (computed by rebuildPaddingCache)
@property (nonatomic, copy) NSArray<NSNumber *> *cumulativePaddingCache;            // Cumulative padding before each group (computed)
@property (nonatomic, copy) NSArray<NSNumber *> *subgroupStarts;                    // Playlist indices where subgroups start
@property (nonatomic, copy) NSArray<NSString *> *subgroupHeaders;                   // Header text per subgroup
@property (nonatomic, copy) NSArray<NSNumber *> *subgroupCountPerGroup;             // Subgroup count per group
@property (nonatomic, copy) NSIndexSet *subgroupRowSet;                             // Subgroup row numbers (computed by rebuildSubgroupRowCache)
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *subgroupRowToIndex; // row -> subgroup index (computed)
@property (nonatomic, assign) NSInteger headerDisplayStyle;                         // 0 = above, 1 = art aligned, 2 = inline, 3 = under art

// --- Pixel metrics (for offset/height queries) ---
@property (nonatomic, assign) CGFloat rowHeight;
@property (nonatomic, assign) CGFloat headerHeight;

// --- Cache rebuilds (compute the *Cached properties from the raw arrays) ---
- (void)rebuildPaddingCache;       // Computes totalPaddingRowsCached + cumulativePaddingCache from groupPaddingRows
- (void)rebuildSubgroupRowCache;   // Computes subgroupRowSet + subgroupRowToIndex from subgroupStarts (run AFTER rebuildPaddingCache)

// --- Row mapping (pure) ---
- (NSInteger)rowCount;
- (NSInteger)cumulativePaddingBeforeGroup:(NSInteger)groupIndex;
- (NSInteger)totalRowsInGroup:(NSInteger)groupIndex;
- (NSInteger)groupIndexForRow:(NSInteger)row;
- (NSInteger)rowForGroupHeader:(NSInteger)groupIndex;
- (BOOL)isRowGroupHeader:(NSInteger)row;
- (BOOL)isRowPaddingRow:(NSInteger)row;
- (NSInteger)playlistIndexForRow:(NSInteger)row;
- (NSInteger)rowForPlaylistIndex:(NSInteger)playlistIndex;
- (NSRange)playlistIndexRangeForGroup:(NSInteger)groupIndex;
- (NSInteger)subgroupCountBeforePlaylistIndex:(NSInteger)playlistIndex;
- (BOOL)hasSubgroupAtPlaylistIndex:(NSInteger)playlistIndex;
- (BOOL)isRowSubgroupHeader:(NSInteger)row;
- (nullable NSString *)subgroupHeaderForRow:(NSInteger)row;
- (NSInteger)rowForSubgroupAtPlaylistIndex:(NSInteger)subgroupPlaylistIndex;

// --- Pixel geometry (pure) ---
- (CGFloat)heightForRow:(NSInteger)row;
- (CGFloat)yOffsetForRow:(NSInteger)row;
- (CGFloat)totalContentHeightCached;
- (CGFloat)pixelHeightForGroup:(NSInteger)groupIndex;
- (NSInteger)rowAtPoint:(NSPoint)point;  // Binary-search row at a y-coordinate (uses point.y only)

@end

NS_ASSUME_NONNULL_END
