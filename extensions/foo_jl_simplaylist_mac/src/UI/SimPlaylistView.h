//
//  SimPlaylistView.h
//  foo_simplaylist_mac
//
//  Main playlist view with virtual scrolling
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class GroupNode;
@class GroupBoundary;
@class ColumnDefinition;
@protocol SimPlaylistViewDelegate;

// Settings changed notification
extern NSString *const SimPlaylistSettingsChangedNotification;

// Pasteboard type for internal drag & drop
extern NSPasteboardType const SimPlaylistPasteboardType;

@interface SimPlaylistView : NSView <NSDraggingSource, NSDraggingDestination>

// Delegate for view events
@property (nonatomic, weak, nullable) id<SimPlaylistViewDelegate> delegate;

// Column definitions
@property (nonatomic, strong) NSArray<ColumnDefinition *> *columns;

// SPARSE GROUP MODEL - O(G) storage for G groups instead of O(N) for N tracks
@property (nonatomic, assign) NSInteger itemCount;  // Total playlist items
@property (nonatomic, strong) NSArray<NSNumber *> *groupStarts;  // Playlist indices where groups start
@property (nonatomic, strong) NSArray<NSString *> *groupHeaders;  // Header text per group
@property (nonatomic, strong) NSArray<NSString *> *groupArtKeys;  // Album art cache key per group
@property (nonatomic, strong) NSArray<NSNumber *> *groupPaddingRows;  // Extra padding rows per group for min height
@property (nonatomic, assign) NSInteger totalPaddingRowsCached;  // Pre-computed sum of all padding rows
@property (nonatomic, strong) NSArray<NSNumber *> *cumulativePaddingCache;  // Pre-computed cumulative padding before each group

// SUBGROUPS - playlist indices where subgroups start, header text per subgroup
@property (nonatomic, strong) NSArray<NSNumber *> *subgroupStarts;  // Playlist indices where subgroups start
@property (nonatomic, strong) NSArray<NSString *> *subgroupHeaders;  // Header text per subgroup
@property (nonatomic, strong) NSArray<NSNumber *> *subgroupCountPerGroup;  // Pre-computed subgroup count per group
@property (nonatomic, strong) NSSet<NSNumber *> *subgroupRowSet;  // Pre-computed set of subgroup row numbers for O(1) lookup
@property (nonatomic, strong) NSDictionary<NSNumber *, NSNumber *> *subgroupRowToIndex;  // Map row -> subgroup index

// Formatted column values cache (lazily populated during draw)
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<NSString *> *> *formattedValuesCache;

// Legacy properties (for compatibility)
@property (nonatomic, strong) NSArray<GroupNode *> *nodes;  // Deprecated
@property (nonatomic, strong) NSMutableArray<GroupBoundary *> *groupBoundaries;  // Deprecated
@property (nonatomic, assign) NSInteger totalItemCount;
@property (nonatomic, assign) BOOL groupsComplete;
@property (nonatomic, assign) NSInteger groupsCalculatedUpTo;
@property (nonatomic, assign) BOOL flatModeEnabled;
@property (nonatomic, assign) NSInteger flatModeTrackCount;

// Layout metrics
@property (nonatomic, assign) CGFloat rowHeight;
@property (nonatomic, assign) CGFloat headerHeight;
@property (nonatomic, assign) CGFloat subgroupHeight;
@property (nonatomic, assign) CGFloat groupColumnWidth;
@property (nonatomic, assign) CGFloat albumArtSize;  // Preferred album art size (actual may be smaller)

// State
@property (nonatomic, strong) NSMutableIndexSet *selectedIndices;
@property (nonatomic, assign) NSInteger focusIndex;
@property (nonatomic, assign) NSInteger playingIndex;  // -1 if not playing
@property (nonatomic, assign) NSInteger sourcePlaylistIndex;  // For drag validation

// Appearance settings
@property (nonatomic, assign) BOOL showNowPlayingShading;  // Yellow background for playing row
@property (nonatomic, assign) NSInteger headerDisplayStyle;  // 0 = above tracks, 1 = album art aligned, 2 = inline
@property (nonatomic, assign) BOOL dimParentheses;  // Dim text inside () and []

// Reload data and redraw
- (void)reloadData;

// Selection management
- (void)selectRowAtIndex:(NSInteger)index;
- (void)selectRowAtIndex:(NSInteger)index extendSelection:(BOOL)extend;
- (void)selectRowsInRange:(NSRange)range;
- (void)selectAll;
- (void)deselectAll;
- (void)toggleSelectionAtIndex:(NSInteger)index;

// Focus management
- (void)setFocusIndex:(NSInteger)index;
- (void)moveFocusBy:(NSInteger)delta extendSelection:(BOOL)extend;
- (void)scrollRowToVisible:(NSInteger)row;

// Coordinate conversion
- (NSInteger)rowAtPoint:(NSPoint)point;
- (NSRect)rectForRow:(NSInteger)row;
- (CGFloat)yOffsetForRow:(NSInteger)row;

// Row mapping for sparse groups (O(log g) operations)
- (NSInteger)rowCount;  // Total display rows = itemCount + groupCount
- (NSInteger)playlistIndexForRow:(NSInteger)row;  // -1 for header rows
- (BOOL)isRowGroupHeader:(NSInteger)row;
- (NSInteger)groupIndexForRow:(NSInteger)row;  // Which group does row belong to
- (NSInteger)rowForGroupHeader:(NSInteger)groupIndex;  // Row number for group header
- (NSInteger)rowForPlaylistIndex:(NSInteger)playlistIndex;  // Convert playlist index to row

// Clear cached data (call when playlist changes)
- (void)clearFormattedValuesCache;
- (void)rebuildSubgroupRowCache;  // Call after subgroups or layout changes
- (void)rebuildPaddingCache;  // Call after groupPaddingRows changes

// Update playing state
- (void)setPlayingIndex:(NSInteger)index;

// Settings reload
- (void)reloadSettings;

// Rebuild row offset cache for grouped mode
- (void)rebuildRowOffsetCache;

// Total content height (for frame sizing)
- (CGFloat)totalContentHeightCached;

@end

@protocol SimPlaylistViewDelegate <NSObject>

@optional
// Called when selection changes
- (void)playlistView:(SimPlaylistView *)view selectionDidChange:(NSIndexSet *)selectedIndices;

// Called when user double-clicks a row
- (void)playlistView:(SimPlaylistView *)view didDoubleClickRow:(NSInteger)row;

// Called when user right-clicks for context menu
- (void)playlistView:(SimPlaylistView *)view requestContextMenuForRows:(NSIndexSet *)rows atPoint:(NSPoint)point;

// Called when user presses delete key
- (void)playlistViewDidRequestRemoveSelection:(SimPlaylistView *)view;

// Called to request album art for a group (returns cached image or nil, triggers async load)
- (nullable NSImage *)playlistView:(SimPlaylistView *)view albumArtForGroupAtPlaylistIndex:(NSInteger)playlistIndex;

// Called when group column width changes (Ctrl+scroll resize)
- (void)playlistView:(SimPlaylistView *)view didChangeGroupColumnWidth:(CGFloat)newWidth;

// Drag & drop - reorder/duplicate within playlist
// operation: NSDragOperationMove reorders, NSDragOperationCopy duplicates
- (void)playlistView:(SimPlaylistView *)view didReorderRows:(NSIndexSet *)sourceRows toRow:(NSInteger)destinationRow operation:(NSDragOperation)operation;

// Drag & drop - move/copy items from different playlist (cross-playlist drop)
// operation: NSDragOperationMove removes from source, NSDragOperationCopy leaves source unchanged
- (void)playlistView:(SimPlaylistView *)view didReceiveDroppedPaths:(NSArray<NSString *> *)paths fromPlaylist:(NSInteger)sourcePlaylist sourceIndices:(NSIndexSet *)sourceIndices atRow:(NSInteger)row operation:(NSDragOperation)operation;

// Drag & drop - import files from Finder
- (void)playlistView:(SimPlaylistView *)view didReceiveDroppedURLs:(NSArray<NSURL *> *)urls atRow:(NSInteger)row;

// Get file paths for playlist indices (for drag data capture)
- (nullable NSArray<NSString *> *)playlistView:(SimPlaylistView *)view filePathsForPlaylistIndices:(NSIndexSet *)indices;

// Lazy column value formatting - called when drawing track rows with nil columnValues
- (nullable NSArray<NSString *> *)playlistView:(SimPlaylistView *)view columnValuesForPlaylistIndex:(NSInteger)playlistIndex;

@end

NS_ASSUME_NONNULL_END
