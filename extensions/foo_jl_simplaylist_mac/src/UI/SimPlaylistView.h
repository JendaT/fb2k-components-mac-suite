//
//  SimPlaylistView.h
//  foo_simplaylist_mac
//
//  Main playlist view with virtual scrolling
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ColumnDefinition;
@class RowDecoration;
@class GroupDecoration;
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
@property (nonatomic, copy) NSArray<NSNumber *> *groupStarts;  // Playlist indices where groups start
@property (nonatomic, copy) NSArray<NSString *> *groupHeaders;  // Header text per group
@property (nonatomic, copy) NSArray<NSString *> *groupArtKeys;  // Album art cache key per group
@property (nonatomic, copy, nullable) NSArray<NSNumber *> *groupDurations;  // Total seconds per group, or nil if disabled
@property (nonatomic, copy) NSArray<NSNumber *> *groupPaddingRows;  // Extra padding rows per group for min height
@property (nonatomic, assign) NSInteger totalPaddingRowsCached;  // Pre-computed sum of all padding rows
@property (nonatomic, copy) NSArray<NSNumber *> *cumulativePaddingCache;  // Pre-computed cumulative padding before each group

// SUBGROUPS - playlist indices where subgroups start, header text per subgroup
@property (nonatomic, copy) NSArray<NSNumber *> *subgroupStarts;  // Playlist indices where subgroups start
@property (nonatomic, copy) NSArray<NSString *> *subgroupHeaders;  // Header text per subgroup
@property (nonatomic, copy) NSArray<NSNumber *> *subgroupCountPerGroup;  // Pre-computed subgroup count per group
@property (nonatomic, copy) NSIndexSet *subgroupRowSet;  // Pre-computed subgroup row numbers for O(1) lookup and O(log n) range counting
@property (nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *subgroupRowToIndex;  // Map row -> subgroup index

// Formatted column values cache (lazily populated during draw, auto-evicts under memory pressure)
@property (nonatomic, strong) NSCache<NSNumber *, NSArray<NSString *> *> *formattedValuesCache;

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
@property (nonatomic, readonly) BOOL isDragging;  // True during active drag operation

// Appearance settings
@property (nonatomic, assign) BOOL showNowPlayingShading;  // Yellow background for playing row
@property (nonatomic, assign) NSInteger headerDisplayStyle;  // 0 = above tracks, 1 = album art aligned, 2 = inline, 3 = under album art
@property (nonatomic, assign) BOOL dimParentheses;  // Dim text inside () and []
@property (nonatomic, assign) BOOL showGroupDuration;  // Show total duration in group headers
@property (nonatomic, assign) NSInteger queueDisplayStyle;  // 0 = brackets [1], 1 = accent color
@property (nonatomic, assign) NSInteger displaySize;  // 0 = compact, 1 = normal, 2 = large
@property (nonatomic, assign) BOOL glassBackground;  // Transparent mode for glass effect
@property (nonatomic, assign) NSInteger groupHeaderSpacing;  // 0 = compact, 1 = normal, 2 = larger

// Row decorator providers (intake doc 04 Part A). Set once by the controller
// at panel init. When NO (zero providers registered — the common case) the
// draw path takes the pre-decorator code path: no delegate calls, no cache
// work, gutter width 0.
@property (nonatomic, assign) BOOL decorationsEnabled;
@property (nonatomic, assign) CGFloat decorationGutterWidth;  // 0 unless a provider exists

// Reload data and redraw
- (void)reloadData;

// Selection management
- (void)selectRowAtIndex:(NSInteger)index;
- (void)selectRowAtIndex:(NSInteger)index extendSelection:(BOOL)extend;
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
- (NSInteger)rowCount;  // Total display rows = tracks + headers + subgroups + padding
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

// Called when user presses Q to queue selected tracks
- (void)playlistView:(SimPlaylistView *)view didRequestQueueTracks:(NSIndexSet *)playlistIndices;

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

// Row decorator providers (only called when decorationsEnabled is YES).
// Synchronous cache-only lookup for a visible row; nil = no decoration.
- (nullable RowDecoration *)playlistView:(SimPlaylistView *)view rowDecorationForPlaylistIndex:(NSInteger)playlistIndex;

// Synchronous cache-only lookup for a group header badge; nil = none.
- (nullable GroupDecoration *)playlistView:(SimPlaylistView *)view groupDecorationForGroupIndex:(NSInteger)groupIndex;

// Called once per draw with the visible row range + overscan so the delegate
// can batch-query providers off-main for uncached items and invalidate later.
- (void)playlistView:(SimPlaylistView *)view prepareDecorationsForRowRange:(NSRange)rowRange;

@end

NS_ASSUME_NONNULL_END
