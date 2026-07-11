//
//  SimPlaylistView.mm
//  foo_simplaylist_mac
//
//  Main playlist view with virtual scrolling
//

#import "SimPlaylistView.h"
#import "../Core/GroupNode.h"
#import "../Core/GroupBoundary.h"
#import "../Core/ColumnDefinition.h"
#import "../Core/ConfigHelper.h"
#import "../Core/AlbumArtCache.h"
#import "../Core/PlaylistLayoutModel.h"
#import "../Core/PlaylistSelectionModel.h"
#import "../Core/DecorationStore.h"
#import "../../../../shared/UIStyles.h"

NSString *const SimPlaylistSettingsChangedNotification = @"SimPlaylistSettingsChanged";
NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.rows";

// Decoration RGBA (0xRRGGBBAA from jl_decorator_api) to NSColor; 0 = nil.
static NSColor *colorFromRGBA(uint32_t rgba) {
    if (rgba == 0) return nil;
    return [NSColor colorWithSRGBRed:((rgba >> 24) & 0xFF) / 255.0
                               green:((rgba >> 16) & 0xFF) / 255.0
                                blue:((rgba >> 8) & 0xFF) / 255.0
                               alpha:(rgba & 0xFF) / 255.0];
}

// Gutter glyphs for jl_icon_id values (index-aligned with the enum):
// none, circle open/left-half/right-half/filled, warning, cross, check, arrow.
static NSString *glyphForIconId(uint32_t iconId) {
    static NSString *const glyphs[] = {
        @"", @"○", @"◐", @"◑", @"●",
        @"⚠", @"✕", @"✓", @"→",
    };
    if (iconId >= sizeof(glyphs) / sizeof(glyphs[0])) return nil;
    return glyphs[iconId].length > 0 ? glyphs[iconId] : nil;
}

// Format total seconds as M:SS or H:MM:SS for display in group headers
static NSString *formatGroupDuration(double seconds) {
    int total = (int)(seconds + 0.5);
    if (total < 0) total = 0;
    int s = total % 60;
    int m = (total / 60) % 60;
    int h = total / 3600;
    if (h > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", h, m, s];
    }
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

// Wraps NSURL pasteboard writing and adds SimPlaylistPasteboardType.
// NSURL's native writing is required for Finder to accept drops.
// The custom type is needed for cross-playlist drops (Plorg, other SimPlaylist panels).
@interface SimPlaylistDragItem : NSObject <NSPasteboardWriting>
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSData *internalData;
@end

@implementation SimPlaylistDragItem
- (NSArray<NSPasteboardType> *)writableTypesForPasteboard:(NSPasteboard *)pasteboard {
    NSMutableArray *types = [NSMutableArray arrayWithArray:[_fileURL writableTypesForPasteboard:pasteboard]];
    if (_internalData) {
        [types addObject:SimPlaylistPasteboardType];
    }
    return types;
}
- (id)pasteboardPropertyListForType:(NSPasteboardType)type {
    if ([type isEqualToString:SimPlaylistPasteboardType]) {
        return _internalData;
    }
    return [_fileURL pasteboardPropertyListForType:type];
}
@end

@interface SimPlaylistView ()
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) NSInteger hoveredRow;
@property (nonatomic, assign) NSPoint dragStartPoint;
@property (nonatomic, readwrite, assign) BOOL isDragging;
@property (nonatomic, assign) BOOL suppressFocusRing;  // Suppress focus ring briefly after drag
@property (nonatomic, assign) NSInteger dropTargetRow;  // Row where items would be dropped
@property (nonatomic, assign) NSInteger pendingClickRow;  // Row to select on mouseUp if no drag (for multi-select drag)
// Performance: cached row y-offsets for O(1) lookup
@property (nonatomic, strong) NSMutableArray<NSNumber *> *rowYOffsets;
@property (nonatomic, assign) CGFloat totalContentHeight;
@property (nonatomic, assign) BOOL needsFullRedraw;  // Force full visible rect redraw after group data changes
@property (nonatomic, assign) BOOL debugRendering;   // Show diagnostic text on rendering anomalies
@property (nonatomic, strong) NSDictionary *currentDragData;  // Internal drag data, passed via draggingSource
// Pure geometry/index model — owns the row-mapping arithmetic. The view mirrors
// its geometry ivars into this model (see the custom setters below) and forwards
// all mapping queries to it. Extracted for unit-testing without an NSView/host.
@property (nonatomic, strong) PlaylistLayoutModel *layout;
// Pure selection state machine — owns selectedIndices/focus/anchor and the
// multi-select math. The view's _selectedIndices ivar aliases its set.
@property (nonatomic, strong) PlaylistSelectionModel *selection;
@end

@implementation SimPlaylistView

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    _layout = [[PlaylistLayoutModel alloc] init];
    _selection = [[PlaylistSelectionModel alloc] initWithLayout:_layout];
    _columns = [ColumnDefinition defaultColumns];
    // Alias the selection model's stable set: drawing code, drag handlers and
    // the controller all read/mutate this instance directly.
    _selectedIndices = _selection.selectedIndices;
    _playingIndex = -1;
    _hoveredRow = -1;
    _isDragging = NO;
    _dropTargetRow = -1;
    _pendingClickRow = -1;

    // SPARSE GROUP MODEL - lives on _layout (its init sets the empty defaults);
    // the view's geometry properties are pure forwarders to it. Only the
    // display-data arrays below stay as view ivars (the model has no use for
    // them).
    _groupHeaders = @[];
    _groupArtKeys = @[];
    _formattedValuesCache = [[NSCache alloc] init];
    _formattedValuesCache.countLimit = 1000;  // Cache ~1000 visible row values, auto-evicts oldest

    // Legacy properties (keep for compatibility)
    _nodes = @[];
    _rowYOffsets = [NSMutableArray array];
    _totalContentHeight = 0;
    _totalItemCount = 0;
    _groupBoundaries = [NSMutableArray array];
    _groupsComplete = NO;
    _groupsCalculatedUpTo = -1;
    _flatModeEnabled = NO;
    _flatModeTrackCount = 0;

    // Default metrics (row/header metrics live on the layout model)
    _layout.rowHeight = simplaylist_config::kDefaultRowHeight;
    _subgroupHeight = simplaylist_config::kDefaultSubgroupHeight;
    _groupColumnWidth = simplaylist_config::kDefaultGroupColumnWidth;
    _albumArtSize = simplaylist_config::kDefaultAlbumArtSize;
    _showNowPlayingShading = simplaylist_config::getConfigBool(
        simplaylist_config::kNowPlayingShading,
        simplaylist_config::kDefaultNowPlayingShading);
    _layout.headerDisplayStyle = simplaylist_config::getConfigInt(
        simplaylist_config::kHeaderDisplayStyle,
        simplaylist_config::kDefaultHeaderDisplayStyle);
    _dimParentheses = simplaylist_config::getConfigBool(
        simplaylist_config::kDimParentheses,
        simplaylist_config::kDefaultDimParentheses);
    _showGroupDuration = simplaylist_config::getConfigBool(
        simplaylist_config::kShowGroupDuration,
        simplaylist_config::kDefaultShowGroupDuration);
    _queueDisplayStyle = simplaylist_config::getConfigInt(
        simplaylist_config::kQueueDisplayStyle,
        simplaylist_config::kDefaultQueueDisplayStyle);
    _displaySize = simplaylist_config::getConfigInt(
        simplaylist_config::kDisplaySize,
        simplaylist_config::kDefaultDisplaySize);
    _groupHeaderSpacing = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupHeaderSpacing,
        simplaylist_config::kDefaultGroupHeaderSpacing);

    // Header height based on spacing: Compact (0) = row height, Normal (1) = +6, Larger (2) = +12
    switch (_groupHeaderSpacing) {
        case 0:  _layout.headerHeight = _layout.rowHeight; break;
        case 2:  _layout.headerHeight = _layout.rowHeight + 12; break;
        default: _layout.headerHeight = _layout.rowHeight + 6; break;
    }

    // PERFORMANCE: Enable layer-backed async drawing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.layer.drawsAsynchronously = YES;

    // CRITICAL: Set low priorities to allow flexible container resizing.
    // Without this, the view resists shrinking when user expands adjacent columns.
    [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];

    // Register for drag & drop
    [self registerForDraggedTypes:@[
        SimPlaylistPasteboardType,
        NSPasteboardTypeFileURL,
        NSPasteboardTypeURL,    // Web URLs (e.g., from Cloud Browser)
        NSPasteboardTypeString  // Plain text URLs as fallback
    ]];

    // Register for settings changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:SimPlaylistSettingsChangedNotification
                                               object:nil];

    // Register for lightweight redraw requests
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRedrawNeeded:)
                                                 name:@"SimPlaylistRedrawNeeded"
                                               object:nil];
}

#pragma mark - Geometry properties (pure forwarders to the layout model)

// The sparse-group geometry and row metrics have exactly one owner: the
// PlaylistLayoutModel. Both accessors of each property are implemented, so no
// ivar is synthesized — there is no second copy to fall out of sync, and any
// leftover direct ivar reference fails to compile.

- (NSInteger)itemCount { return _layout.itemCount; }
- (void)setItemCount:(NSInteger)itemCount { _layout.itemCount = itemCount; }

- (NSArray<NSNumber *> *)groupStarts { return _layout.groupStarts; }
- (void)setGroupStarts:(NSArray<NSNumber *> *)groupStarts { _layout.groupStarts = groupStarts; }

- (NSArray<NSNumber *> *)groupPaddingRows { return _layout.groupPaddingRows; }
- (void)setGroupPaddingRows:(NSArray<NSNumber *> *)groupPaddingRows { _layout.groupPaddingRows = groupPaddingRows; }

- (NSInteger)totalPaddingRowsCached { return _layout.totalPaddingRowsCached; }
- (void)setTotalPaddingRowsCached:(NSInteger)totalPaddingRowsCached { _layout.totalPaddingRowsCached = totalPaddingRowsCached; }

- (NSArray<NSNumber *> *)cumulativePaddingCache { return _layout.cumulativePaddingCache; }
- (void)setCumulativePaddingCache:(NSArray<NSNumber *> *)cumulativePaddingCache { _layout.cumulativePaddingCache = cumulativePaddingCache; }

- (NSArray<NSNumber *> *)subgroupStarts { return _layout.subgroupStarts; }
- (void)setSubgroupStarts:(NSArray<NSNumber *> *)subgroupStarts { _layout.subgroupStarts = subgroupStarts; }

- (NSArray<NSString *> *)subgroupHeaders { return _layout.subgroupHeaders; }
- (void)setSubgroupHeaders:(NSArray<NSString *> *)subgroupHeaders { _layout.subgroupHeaders = subgroupHeaders; }

- (NSArray<NSNumber *> *)subgroupCountPerGroup { return _layout.subgroupCountPerGroup; }
- (void)setSubgroupCountPerGroup:(NSArray<NSNumber *> *)subgroupCountPerGroup { _layout.subgroupCountPerGroup = subgroupCountPerGroup; }

- (NSIndexSet *)subgroupRowSet { return _layout.subgroupRowSet; }
- (void)setSubgroupRowSet:(NSIndexSet *)subgroupRowSet { _layout.subgroupRowSet = subgroupRowSet; }

- (NSDictionary<NSNumber *, NSNumber *> *)subgroupRowToIndex { return _layout.subgroupRowToIndex; }
- (void)setSubgroupRowToIndex:(NSDictionary<NSNumber *, NSNumber *> *)subgroupRowToIndex { _layout.subgroupRowToIndex = subgroupRowToIndex; }

- (CGFloat)rowHeight { return _layout.rowHeight; }
- (void)setRowHeight:(CGFloat)rowHeight { _layout.rowHeight = rowHeight; }

- (CGFloat)headerHeight { return _layout.headerHeight; }
- (void)setHeaderHeight:(CGFloat)headerHeight { _layout.headerHeight = headerHeight; }

- (NSInteger)headerDisplayStyle { return _layout.headerDisplayStyle; }
- (void)setHeaderDisplayStyle:(NSInteger)headerDisplayStyle { _layout.headerDisplayStyle = headerDisplayStyle; }

// Build cached y-offsets for O(1) row lookup
- (void)rebuildRowOffsetCache {
    [_rowYOffsets removeAllObjects];
    CGFloat y = 0;
    for (GroupNode *node in _nodes) {
        [_rowYOffsets addObject:@(y)];
        y += [self heightForNode:node];
    }
    _totalContentHeight = y;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    [self reloadSettings];
}

- (void)handleRedrawNeeded:(NSNotification *)notification {
    // Lightweight redraw - just reload visual settings and redraw
    [self reloadSettings];
    [self setNeedsDisplay:YES];
}

- (void)reloadSettings {
    using namespace simplaylist_config;
    _displaySize = getConfigInt(kDisplaySize, kDefaultDisplaySize);

    // Row height from shared UIStyles (metrics live on the layout model)
    fb2k_ui::SizeVariant size = static_cast<fb2k_ui::SizeVariant>(_displaySize);
    _layout.rowHeight = fb2k_ui::rowHeight(size);

    _subgroupHeight = getConfigInt(kSubgroupHeight, kDefaultSubgroupHeight);
    _groupColumnWidth = getConfigInt(kGroupColumnWidth, kDefaultGroupColumnWidth);
    _showNowPlayingShading = getConfigBool(kNowPlayingShading, kDefaultNowPlayingShading);
    _layout.headerDisplayStyle = getConfigInt(kHeaderDisplayStyle, kDefaultHeaderDisplayStyle);
    _dimParentheses = getConfigBool(kDimParentheses, kDefaultDimParentheses);
    _showGroupDuration = getConfigBool(kShowGroupDuration, kDefaultShowGroupDuration);
    _queueDisplayStyle = getConfigInt(kQueueDisplayStyle, kDefaultQueueDisplayStyle);
    _groupHeaderSpacing = getConfigInt(kGroupHeaderSpacing, kDefaultGroupHeaderSpacing);
    _debugRendering = getConfigBool(kDebugRendering, kDefaultDebugRendering);

    // Header height based on spacing setting: Compact (0) = row height, Normal (1) = +6, Larger (2) = +12
    switch (_groupHeaderSpacing) {
        case 0:  _layout.headerHeight = _layout.rowHeight; break;      // Compact - same as track rows
        case 2:  _layout.headerHeight = _layout.rowHeight + 12; break; // Larger - generous padding
        default: _layout.headerHeight = _layout.rowHeight + 6; break;  // Normal - some extra padding
    }

    // Update frame size to reflect new row heights (header height affects total content height)
    [self reloadData];
}

#pragma mark - View Configuration

- (BOOL)isFlipped {
    return YES;  // Top-left origin for easier layout
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    [self setNeedsDisplay:YES];
    return YES;
}

- (BOOL)resignFirstResponder {
    [self setNeedsDisplay:YES];
    return YES;
}

- (void)setDecorationsEnabled:(BOOL)decorationsEnabled {
    _decorationsEnabled = decorationsEnabled;
    [self updateTrackingAreas];  // (Un)register the decorator tooltip rect
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }

    _trackingArea = [[NSTrackingArea alloc]
                     initWithRect:self.bounds
                          options:(NSTrackingMouseMoved |
                                   NSTrackingActiveInKeyWindow |
                                   NSTrackingInVisibleRect)
                            owner:self
                         userInfo:nil];
    [self addTrackingArea:_trackingArea];

    // Decorator tooltips: one dynamic full-bounds tooltip rect; the string is
    // resolved per point in view:stringForToolTip:point:userData:. Registered
    // only when a provider exists (zero-provider guard).
    [self removeAllToolTips];
    if (_decorationsEnabled) {
        [self addToolTipRect:self.bounds owner:self userData:NULL];
    }
}

// NSToolTipOwner: resolve the decoration tooltip for the row under the cursor.
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    if (!_decorationsEnabled ||
        ![_delegate respondsToSelector:@selector(playlistView:rowDecorationForPlaylistIndex:)]) {
        return nil;
    }
    NSInteger row = [self rowAtPoint:point];
    if (row < 0) return nil;
    NSInteger playlistIndex = [self playlistIndexForRow:row];
    if (playlistIndex < 0) return nil;
    RowDecoration *decoration = [_delegate playlistView:self rowDecorationForPlaylistIndex:playlistIndex];
    return decoration.tooltip.length > 0 ? decoration.tooltip : nil;
}

#pragma mark - Data Management

- (void)reloadData {
    // Update frame size to match content for proper scrolling
    NSSize contentSize = [self calculatedContentSize];

    // Ensure minimum size matches scroll view's visible area
    // This is CRITICAL for empty playlists to receive drag events
    NSScrollView *scrollView = self.enclosingScrollView;
    if (scrollView) {
        NSSize visibleSize = scrollView.documentVisibleRect.size;
        contentSize.height = MAX(contentSize.height, visibleSize.height);
        contentSize.width = MAX(contentSize.width, visibleSize.width);
    }

    // Only trigger layout if frame size actually changed
    if (!NSEqualSizes(self.frame.size, contentSize)) {
        [self setFrameSize:contentSize];
        [self invalidateIntrinsicContentSize];
    }
    // Force full visible rect redraw on next drawRect: to prevent stale
    // copy-on-scroll pixels when group data has changed
    _needsFullRedraw = YES;
    [self setNeedsDisplay:YES];
}

- (void)setNodes:(NSArray<GroupNode *> *)nodes {
    _nodes = [nodes copy];
    [self rebuildRowOffsetCache];
    [self reloadData];
}

#pragma mark - Layout Calculations

// Returns total row count: itemCount + groupCount + subgroupCount (each group/subgroup adds 1 header row)
// Only style 3 (under album art) has no header rows - header text is below album art
// NOTE: The sparse-group row/index arithmetic below lives in PlaylistLayoutModel
// (Core/PlaylistLayoutModel.*) so it can be unit-tested without an NSView/host.
// These methods forward to _layout, which mirrors the view's geometry ivars.

- (NSInteger)rowCount {
    return [_layout rowCount];
}

- (NSInteger)cumulativePaddingBeforeGroup:(NSInteger)groupIndex {
    return [_layout cumulativePaddingBeforeGroup:groupIndex];
}

- (NSInteger)totalRowsInGroup:(NSInteger)groupIndex {
    return [_layout totalRowsInGroup:groupIndex];
}

#pragma mark - Row Mapping (O(log g) using binary search) — forwards to PlaylistLayoutModel

- (NSInteger)groupIndexForRow:(NSInteger)row {
    return [_layout groupIndexForRow:row];
}

- (NSInteger)rowForGroupHeader:(NSInteger)groupIndex {
    return [_layout rowForGroupHeader:groupIndex];
}

- (BOOL)isRowGroupHeader:(NSInteger)row {
    return [_layout isRowGroupHeader:row];
}

- (BOOL)isRowPaddingRow:(NSInteger)row {
    return [_layout isRowPaddingRow:row];
}

- (NSInteger)playlistIndexForRow:(NSInteger)row {
    return [_layout playlistIndexForRow:row];
}

- (NSInteger)rowForPlaylistIndex:(NSInteger)playlistIndex {
    return [_layout rowForPlaylistIndex:playlistIndex];
}

// Clear formatted values cache (call when playlist changes)
- (void)clearFormattedValuesCache {
    [_formattedValuesCache removeAllObjects];
}

// Cache rebuilds happen on the model (the single owner of the geometry).
// rebuildSubgroupRowCache MUST run after rebuildPaddingCache.
- (void)rebuildSubgroupRowCache {
    [_layout rebuildSubgroupRowCache];
}

- (void)rebuildPaddingCache {
    [_layout rebuildPaddingCache];
}

- (NSRange)playlistIndexRangeForGroup:(NSInteger)groupIndex {
    return [_layout playlistIndexRangeForGroup:groupIndex];
}

- (NSInteger)subgroupCountBeforePlaylistIndex:(NSInteger)playlistIndex {
    return [_layout subgroupCountBeforePlaylistIndex:playlistIndex];
}

- (BOOL)hasSubgroupAtPlaylistIndex:(NSInteger)playlistIndex {
    return [_layout hasSubgroupAtPlaylistIndex:playlistIndex];
}

- (BOOL)isRowSubgroupHeader:(NSInteger)row {
    return [_layout isRowSubgroupHeader:row];
}

- (NSString *)subgroupHeaderForRow:(NSInteger)row {
    return [_layout subgroupHeaderForRow:row];
}

- (NSInteger)rowForSubgroupAtPlaylistIndex:(NSInteger)subgroupPlaylistIndex {
    return [_layout rowForSubgroupAtPlaylistIndex:subgroupPlaylistIndex];
}

// Find group boundary for a display row (unused in flat mode)
- (GroupBoundary *)groupBoundaryForRow:(NSInteger)row {
    return nil;  // No groups in flat mode
}

// Find group boundary for a playlist index (unused in flat mode)
- (GroupBoundary *)groupBoundaryForPlaylistIndex:(NSInteger)playlistIndex {
    return nil;  // No groups in flat mode
}

- (NSSize)intrinsicContentSize {
    // CRITICAL: Return no intrinsic size to allow flexible resizing.
    // Returning actual dimensions causes container limiting - the view
    // resists shrinking when user tries to expand adjacent columns.
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

// Internal method for calculating actual content size (for frame/scrolling)
- (NSSize)calculatedContentSize {
    CGFloat totalHeight = [self totalContentHeightCached];
    CGFloat totalWidth = [self totalColumnWidth] + _groupColumnWidth + _decorationGutterWidth;
    return NSMakeSize(totalWidth, totalHeight);
}

- (CGFloat)totalColumnWidth {
    CGFloat width = 0;
    for (ColumnDefinition *col in _columns) {
        width += col.width;
    }
    return width;
}

- (CGFloat)heightForNode:(GroupNode *)node {
    switch (node.type) {
        case GroupNodeTypeHeader:
            return _layout.headerHeight;
        case GroupNodeTypeSubgroup:
            return _subgroupHeight;
        case GroupNodeTypeTrack:
        default:
            return _layout.rowHeight;
    }
}

// Pixel geometry — forwards to PlaylistLayoutModel (pure, unit-testable).
- (CGFloat)heightForRow:(NSInteger)row {
    return [_layout heightForRow:row];
}

- (CGFloat)yOffsetForRow:(NSInteger)row {
    return [_layout yOffsetForRow:row];
}

// Kept in the view: needs self.bounds for the row width. Geometry comes from the model.
- (NSRect)rectForRow:(NSInteger)row {
    NSInteger totalRows = [self rowCount];
    if (row < 0 || row >= totalRows) {
        return NSZeroRect;
    }
    CGFloat y = [_layout yOffsetForRow:row];
    CGFloat h = [_layout heightForRow:row];
    return NSMakeRect(0, y, self.bounds.size.width, h);
}

- (NSInteger)rowAtPoint:(NSPoint)point {
    return [_layout rowAtPoint:point];
}

- (CGFloat)totalContentHeightCached {
    return [_layout totalContentHeightCached];
}

- (CGFloat)pixelHeightForGroup:(NSInteger)groupIndex {
    return [_layout pixelHeightForGroup:groupIndex];
}

#pragma mark - Drawing (Virtual Scrolling - SPARSE MODEL)

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // After group data changes, NSScrollView's copy-on-scroll may have copied stale
    // pixels from before the change. Expand dirtyRect to full visible rect to ensure
    // all visible rows are redrawn with current data.
    if (_needsFullRedraw) {
        _needsFullRedraw = NO;
        dirtyRect = [self visibleRect];
    }

    // Background - skip for glass mode to let underlying effect show through
    if (!_glassBackground) {
        [fb2k_ui::backgroundColor() setFill];
        NSRectFill(dirtyRect);
    }

    NSInteger totalRows = [self rowCount];
    if (totalRows == 0) {
        [self drawEmptyStateInRect:dirtyRect];
        return;
    }

    // Draw using sparse model
    [self drawSparseModelInRect:dirtyRect];
}

#pragma mark - Sparse Model Drawing

- (void)drawSparseModelInRect:(NSRect)dirtyRect {
    // Derive row range from dirtyRect so we draw exactly what AppKit says needs
    // drawing. AppKit issues a dirty rect only for the newly exposed strip on
    // scroll — deriving from dirtyRect ensures those rows are always covered.
    NSInteger firstRow = [self rowAtPoint:NSMakePoint(0, NSMinY(dirtyRect))];
    NSInteger lastRow = [self rowAtPoint:NSMakePoint(0, NSMaxY(dirtyRect))];

    NSInteger totalRows = [self rowCount];
    if (firstRow < 0) firstRow = 0;
    if (lastRow < 0 || lastRow >= totalRows) lastRow = totalRows - 1;

    // Decorator providers: let the delegate batch-resolve decorations for the
    // visible range + overscan (off-main; results land via invalidation).
    // Zero providers registered => decorationsEnabled is NO and this whole
    // block is a single branch.
    if (_decorationsEnabled &&
        [_delegate respondsToSelector:@selector(playlistView:prepareDecorationsForRowRange:)]) {
        const NSInteger overscan = 32;
        NSInteger prepFirst = MAX((NSInteger)0, firstRow - overscan);
        NSInteger prepLast = MIN(totalRows - 1, lastRow + overscan);
        [_delegate playlistView:self
            prepareDecorationsForRowRange:NSMakeRange(prepFirst, prepLast - prepFirst + 1)];
    }

    // STEP 1: Fill group column background FIRST (before any content)
    // This ensures header text drawn later won't be covered
    if (_groupColumnWidth > 0 && _layout.groupStarts.count > 0) {
        [self fillGroupColumnBackgroundInRect:dirtyRect];
    }

    // STEP 2: Draw only visible rows (typically ~30 rows)
    // Draw all rows in range without dirtyRect filtering — the row range is already
    // bounded to visible rows (±1 buffer), and skipping the intersection test prevents
    // sub-pixel boundary mismatches that can leave unrendered strips at scroll edges.
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        NSRect rowRect = [self rectForRow:row];
        [self drawSparseRow:row inRect:rowRect];
    }

    // STEP 3: Draw album art on top (after all row content)
    if (_groupColumnWidth > 0 && _layout.groupStarts.count > 0) {
        [self drawAlbumArtInRect:dirtyRect firstRow:firstRow lastRow:lastRow];
    }

    // Draw focus ring - only on valid track rows, not during drag operations
    if (!_isDragging && _dropTargetRow < 0 && !_suppressFocusRing &&
        self.window.firstResponder == self && _selection.focusIndex >= 0 && _selection.focusIndex < _layout.itemCount) {
        NSInteger focusRow = [self rowForPlaylistIndex:_selection.focusIndex];
        // Verify this row maps back to a valid track (not header/subgroup/padding)
        if (focusRow >= 0 && focusRow >= firstRow && focusRow <= lastRow) {
            NSInteger verifyIndex = [self playlistIndexForRow:focusRow];
            if (verifyIndex == _selection.focusIndex) {
                NSRect focusRect = [self rectForRow:focusRow];
                [self drawFocusRingForRect:focusRect];
            }
        }
    }

    // Draw drop indicator
    if (_dropTargetRow >= 0) {
        [self drawDropIndicatorAtRow:_dropTargetRow];
    }
}

// Draw a single row using sparse model
- (void)drawSparseRow:(NSInteger)row inRect:(NSRect)rect {
    BOOL isHeader = [self isRowGroupHeader:row];
    BOOL isSubgroupHeader = [self isRowSubgroupHeader:row];
    BOOL isPadding = [self isRowPaddingRow:row];
    NSInteger playlistIndex = (isHeader || isSubgroupHeader || isPadding) ? -1 : [self playlistIndexForRow:row];

    // Unmapped row: draw debug diagnostic if enabled, otherwise skip silently
    if (!isHeader && !isSubgroupHeader && !isPadding && playlistIndex < 0) {
        if (_debugRendering) {
            NSInteger groupIndex = [self groupIndexForRow:row];
            NSInteger headerRow = [self rowForGroupHeader:groupIndex];
            NSInteger rowInGroup = row - headerRow;
            NSInteger gStart = (groupIndex >= 0 && groupIndex < (NSInteger)_layout.groupStarts.count)
                ? [_layout.groupStarts[groupIndex] integerValue] : -1;
            NSInteger gEnd = (groupIndex + 1 < (NSInteger)_layout.groupStarts.count)
                ? [_layout.groupStarts[groupIndex + 1] integerValue] : _layout.itemCount;
            NSInteger subgroupsInGroup = (groupIndex < (NSInteger)_layout.subgroupCountPerGroup.count)
                ? [_layout.subgroupCountPerGroup[groupIndex] integerValue] : 0;
            NSInteger paddingInGroup = (groupIndex < (NSInteger)_layout.groupPaddingRows.count)
                ? [_layout.groupPaddingRows[groupIndex] integerValue] : 0;
            NSString *diag = [NSString stringWithFormat:@"BLANK r%ld g%ld rIG%ld gS%ld-%ld sg%ld pad%ld tot%ld",
                              (long)row, (long)groupIndex, (long)rowInGroup,
                              (long)gStart, (long)gEnd, (long)subgroupsInGroup,
                              (long)paddingInGroup, (long)[self rowCount]];
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor systemRedColor]
            };
            [diag drawInRect:NSMakeRect(_groupColumnWidth + 4, rect.origin.y + 2, rect.size.width - _groupColumnWidth - 8, rect.size.height - 4) withAttributes:attrs];
        }
        return;
    }

    // Padding rows are empty - just return (background already drawn)
    if (isPadding) {
        return;
    }

    // Check selection and playing state
    BOOL isSelected = (playlistIndex >= 0 && [_selectedIndices containsIndex:playlistIndex]);
    BOOL isPlaying = (playlistIndex >= 0 && playlistIndex == _playingIndex);

    // Row decoration (decorator providers): cache-only lookup, tint drawn
    // UNDER the selection/playing background.
    RowDecoration *decoration = nil;
    if (_decorationsEnabled && playlistIndex >= 0 &&
        [_delegate respondsToSelector:@selector(playlistView:rowDecorationForPlaylistIndex:)]) {
        decoration = [_delegate playlistView:self rowDecorationForPlaylistIndex:playlistIndex];
        NSColor *tint = colorFromRGBA(decoration.tintRGBA);
        if (tint) {
            [tint setFill];
            NSRectFillUsingOperation(NSMakeRect(_groupColumnWidth, rect.origin.y,
                                                rect.size.width - _groupColumnWidth, rect.size.height),
                                     NSCompositingOperationSourceOver);
        }
    }

    // Selection/playing background - only in columns area, not album art column
    BOOL shouldDrawBackground = isSelected || (isPlaying && _showNowPlayingShading);
    if (shouldDrawBackground) {
        NSRect contentRect = NSMakeRect(_groupColumnWidth, rect.origin.y,
                                        rect.size.width - _groupColumnWidth, rect.size.height);
        if (isSelected) {
            [fb2k_ui::selectedBackgroundColor() setFill];
        } else {
            [[[NSColor systemYellowColor] colorWithAlphaComponent:0.15] setFill];
        }
        NSRectFill(contentRect);
    }

    if (isHeader) {
        NSInteger groupIndex = [self groupIndexForRow:row];
        [self drawSparseHeaderRow:groupIndex inRect:rect];
    } else if (isSubgroupHeader) {
        NSString *subgroupText = [self subgroupHeaderForRow:row];
        [self drawSparseSubgroupRow:subgroupText inRect:rect];
    } else {
        [self drawSparseTrackRow:playlistIndex inRect:rect selected:isSelected playing:isPlaying
                      decoration:decoration];
    }
}

// Draw group header row - text position depends on headerDisplayStyle
// Style 0: Above tracks (text in content area after album art column)
// Style 1: Album art aligned (text aligned with album art left edge)
// Style 2: Header row, but album art starts at same Y (text in content area)
// Style 3: Not used (no header rows)
- (void)drawSparseHeaderRow:(NSInteger)groupIndex inRect:(NSRect)rect {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupHeaders.count) return;

    NSString *headerText = _groupHeaders[groupIndex];

    // Text attributes: bold, primary color
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };

    // Build attributed string: title + optional duration
    NSAttributedString *displayString = [self headerAttributedStringForGroup:groupIndex
                                                                  titleAttrs:attrs];
    NSSize textSize = displayString.size;

    CGFloat textX;
    CGFloat textY;
    CGFloat lineStartX;
    CGFloat lineEndX = rect.size.width - 8;
    CGFloat lineY;
    CGFloat padding = 6;

    if (_layout.headerDisplayStyle == 1) {
        // Style 1 (Album art aligned): text aligned with album art left edge
        CGFloat artX = (_groupColumnWidth - _albumArtSize) / 2;
        if (artX < padding) artX = padding;
        textX = artX;
        // Center text vertically in the (now variable height) row
        textY = rect.origin.y + (rect.size.height - textSize.height) / 2;
        lineStartX = textX + textSize.width + 12;
        lineY = rect.origin.y + rect.size.height / 2;
    } else if (_layout.headerDisplayStyle == 2) {
        // Style 2 (Inline): text at top of row
        textX = _groupColumnWidth + _decorationGutterWidth + 8;
        textY = rect.origin.y + 2;
        lineStartX = lineEndX + 1;  // No line for style 2
        lineY = 0;
    } else {
        // Style 0: text starts after album art column
        textX = _groupColumnWidth + _decorationGutterWidth + 8;
        // Center text vertically in the (now variable height) row
        textY = rect.origin.y + (rect.size.height - textSize.height) / 2;
        lineStartX = textX + textSize.width + 12;
        lineY = rect.origin.y + rect.size.height / 2;
    }

    // Draw header text (title + optional duration)
    [displayString drawAtPoint:NSMakePoint(textX, textY)];

    // Draw horizontal line after text (not for style 2 - inline mode)
    if (_layout.headerDisplayStyle != 2 && lineStartX < lineEndX) {
        [[NSColor separatorColor] setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(lineStartX, lineY)];
        [line lineToPoint:NSMakePoint(lineEndX, lineY)];
        line.lineWidth = 1.0;
        [line stroke];
    }
}

// Draw inline header text for style 3 - draws in the group column area below album art
// This is called from drawAlbumArtInRect after album art is drawn
- (void)drawInlineHeaderForGroup:(NSInteger)groupIndex atGroupTop:(CGFloat)groupTop artBottom:(CGFloat)artBottom groupHeight:(CGFloat)groupHeight {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupHeaders.count) return;

    NSString *headerText = _groupHeaders[groupIndex];

    // Position: centered below album art in the group column
    CGFloat textY = artBottom + 4;  // Below album art with small padding

    // Available height for text (from artBottom to groupBottom, minus padding)
    CGFloat availableHeight = (groupTop + groupHeight) - textY - 8;
    if (availableHeight < 14) availableHeight = 14;  // Minimum one line

    // Text rect for word-wrapped, centered text
    NSRect textRect = NSMakeRect(4, textY, _groupColumnWidth - 8, availableHeight);

    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentCenter;
    style.lineBreakMode = NSLineBreakByWordWrapping;  // Wrap to multiple lines

    NSDictionary *titleAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSParagraphStyleAttributeName: style
    };

    NSAttributedString *displayString = [self headerAttributedStringForGroup:groupIndex
                                                                  titleAttrs:titleAttrs];
    [displayString drawInRect:textRect];
}

// Returns attributed string for a group header: bold title + optional " • duration" appended in dimmer style
- (NSAttributedString *)headerAttributedStringForGroup:(NSInteger)groupIndex
                                            titleAttrs:(NSDictionary *)titleAttrs {
    NSString *title = _groupHeaders[groupIndex];
    NSMutableAttributedString *result =
        [[NSMutableAttributedString alloc] initWithString:title attributes:titleAttrs];

    BOOL wantDuration = _showGroupDuration && groupIndex < (NSInteger)_groupDurations.count;
    double seconds = wantDuration ? [_groupDurations[groupIndex] doubleValue] : 0;
    if (wantDuration && seconds > 0) {
        NSString *durStr = [NSString stringWithFormat:@"  •  %@", formatGroupDuration(seconds)];
        NSFont *titleFont = titleAttrs[NSFontAttributeName] ?: [NSFont systemFontOfSize:12];
        NSDictionary *durAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:titleFont.pointSize],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        };
        if (titleAttrs[NSParagraphStyleAttributeName]) {
            NSMutableDictionary *m = [durAttrs mutableCopy];
            m[NSParagraphStyleAttributeName] = titleAttrs[NSParagraphStyleAttributeName];
            durAttrs = m;
        }
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:durStr
                                                                       attributes:durAttrs]];
    }

    [self appendGroupBadgeForGroup:groupIndex to:result titleAttrs:titleAttrs];
    return result;
}

// Appends a decorator-provider badge (e.g. an intake assignment target) to a
// group header attributed string. No-op when decorations are disabled.
- (void)appendGroupBadgeForGroup:(NSInteger)groupIndex
                              to:(NSMutableAttributedString *)header
                      titleAttrs:(NSDictionary *)titleAttrs {
    if (!_decorationsEnabled ||
        ![_delegate respondsToSelector:@selector(playlistView:groupDecorationForGroupIndex:)]) {
        return;
    }
    GroupDecoration *gd = [_delegate playlistView:self groupDecorationForGroupIndex:groupIndex];
    if (gd.badgeText.length == 0) return;

    NSFont *titleFont = titleAttrs[NSFontAttributeName] ?: [NSFont systemFontOfSize:12];
    NSColor *badgeColor = colorFromRGBA(gd.badgeRGBA) ?: [NSColor secondaryLabelColor];
    NSMutableDictionary *badgeAttrs = [@{
        NSFontAttributeName: [NSFont systemFontOfSize:titleFont.pointSize],
        NSForegroundColorAttributeName: badgeColor
    } mutableCopy];
    if (titleAttrs[NSParagraphStyleAttributeName]) {
        badgeAttrs[NSParagraphStyleAttributeName] = titleAttrs[NSParagraphStyleAttributeName];
    }
    NSString *glyph = glyphForIconId(gd.iconId);
    NSString *badge = glyph
        ? [NSString stringWithFormat:@"  %@ %@", glyph, gd.badgeText]
        : [NSString stringWithFormat:@"  %@", gd.badgeText];
    [header appendAttributedString:[[NSAttributedString alloc] initWithString:badge
                                                                    attributes:badgeAttrs]];
}

// Draw subgroup header row - indented, smaller text with line
- (void)drawSparseSubgroupRow:(NSString *)subgroupText inRect:(NSRect)rect {
    if (!subgroupText || subgroupText.length == 0) return;

    // Subgroup text attributes - smaller and secondary color
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };

    // Calculate text size - indented more than group header
    NSSize textSize = [subgroupText sizeWithAttributes:attrs];
    CGFloat textX = _groupColumnWidth + _decorationGutterWidth + 24;  // More indent than group header
    CGFloat textY = rect.origin.y + (rect.size.height - textSize.height) / 2;

    // Draw subgroup text
    [subgroupText drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];

    // Draw horizontal line after text (centered vertically)
    CGFloat lineY = rect.origin.y + rect.size.height / 2;
    CGFloat lineStartX = textX + textSize.width + 8;
    CGFloat lineEndX = rect.size.width - 8;

    if (lineStartX < lineEndX) {
        [[NSColor separatorColor] setStroke];  // Same color as main header line
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(lineStartX, lineY)];
        [line lineToPoint:NSMakePoint(lineEndX, lineY)];
        line.lineWidth = 1.0;  // Same width as main header line
        [line stroke];
    }
}

// Helper: Create attributed string with dimmed parentheses
- (NSAttributedString *)attributedString:(NSString *)text
                                    font:(NSFont *)font
                               textColor:(NSColor *)textColor
                              dimmedColor:(NSColor *)dimmedColor
                          paragraphStyle:(NSParagraphStyle *)style {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: textColor,
        NSParagraphStyleAttributeName: style
    }];

    // Find and dim text inside () and []
    NSUInteger length = text.length;
    NSInteger parenDepth = 0;  // () depth
    NSInteger bracketDepth = 0;  // [] depth

    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [text characterAtIndex:i];

        if (c == '(' || c == '[') {
            // Start of parentheses/bracket - dim from this character
            if (c == '(') parenDepth++;
            else bracketDepth++;

            [result addAttribute:NSForegroundColorAttributeName
                           value:dimmedColor
                           range:NSMakeRange(i, 1)];
        } else if (c == ')' || c == ']') {
            // End of parentheses/bracket - dim this character too
            [result addAttribute:NSForegroundColorAttributeName
                           value:dimmedColor
                           range:NSMakeRange(i, 1)];

            if (c == ')' && parenDepth > 0) parenDepth--;
            else if (c == ']' && bracketDepth > 0) bracketDepth--;
        } else if (parenDepth > 0 || bracketDepth > 0) {
            // Inside parentheses/brackets - dim
            [result addAttribute:NSForegroundColorAttributeName
                           value:dimmedColor
                           range:NSMakeRange(i, 1)];
        }
    }

    return result;
}

// Draw track row with lazy column formatting
- (void)drawSparseTrackRow:(NSInteger)playlistIndex inRect:(NSRect)rect selected:(BOOL)selected playing:(BOOL)playing
                decoration:(RowDecoration *)decoration {
    if (playlistIndex < 0) return;

    // Get cached column values or request from delegate
    NSNumber *indexKey = @(playlistIndex);
    NSArray<NSString *> *columnValues = [_formattedValuesCache objectForKey:indexKey];
    if (!columnValues && [_delegate respondsToSelector:@selector(playlistView:columnValuesForPlaylistIndex:)]) {
        columnValues = [_delegate playlistView:self columnValuesForPlaylistIndex:playlistIndex];
        if (columnValues) {
            [_formattedValuesCache setObject:columnValues forKey:indexKey];
        }
    }

    if (!columnValues) {
        if (_debugRendering) {
            NSString *diag = [NSString stringWithFormat:@"NIL VALUES idx%ld", (long)playlistIndex];
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor systemOrangeColor]
            };
            [diag drawInRect:NSMakeRect(_groupColumnWidth + 4, rect.origin.y + 2, rect.size.width - _groupColumnWidth - 8, rect.size.height - 4) withAttributes:attrs];
        }
        return;
    }

    // Draw columns (shifted right by the decoration gutter when providers exist)
    CGFloat x = _groupColumnWidth + _decorationGutterWidth;
    NSColor *textColor = selected ? fb2k_ui::selectedTextColor() : fb2k_ui::textColor();
    NSColor *dimmedColor = selected ? [fb2k_ui::selectedTextColor() colorWithAlphaComponent:0.5]
                                    : fb2k_ui::secondaryTextColor();
    // Font size from shared UIStyles
    fb2k_ui::SizeVariant size = static_cast<fb2k_ui::SizeVariant>(_displaySize);
    NSFont *font = fb2k_ui::rowFont(size);

    // Calculate vertical centering with equal top/bottom padding
    CGFloat textHeight = font.ascender - font.descender;
    CGFloat verticalPadding = round((rect.size.height - textHeight) / 2.0);

    // Decoration status icon in the leading gutter column
    if (_decorationGutterWidth > 0 && decoration.iconId != 0) {
        NSString *glyph = glyphForIconId(decoration.iconId);
        if (glyph) {
            NSColor *iconColor = colorFromRGBA(decoration.iconRGBA)
                ?: (selected ? fb2k_ui::selectedTextColor() : fb2k_ui::secondaryTextColor());
            NSDictionary *iconAttrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:font.pointSize],
                NSForegroundColorAttributeName: iconColor
            };
            NSSize glyphSize = [glyph sizeWithAttributes:iconAttrs];
            CGFloat iconX = _groupColumnWidth + round((_decorationGutterWidth - glyphSize.width) / 2.0);
            [glyph drawAtPoint:NSMakePoint(iconX, rect.origin.y + verticalPadding)
                withAttributes:iconAttrs];
        }
    }

    for (NSUInteger colIndex = 0; colIndex < _columns.count; colIndex++) {
        ColumnDefinition *col = _columns[colIndex];

        // Center text vertically within row
        NSRect colRect = NSMakeRect(x + 4, rect.origin.y + verticalPadding,
                                    col.width - 8, textHeight);

        NSString *value = (colIndex < columnValues.count) ? columnValues[colIndex] : @"";

        // For first column, prepend play indicator if this is the playing track
        if (colIndex == 0 && playing) {
            value = [NSString stringWithFormat:@"\u25B6 %@", value];  // Play triangle
        }

        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        switch (col.alignment) {
            case ColumnAlignmentCenter: style.alignment = NSTextAlignmentCenter; break;
            case ColumnAlignmentRight: style.alignment = NSTextAlignmentRight; break;
            default: style.alignment = NSTextAlignmentLeft; break;
        }

        // Queue column with accent style: use system accent color for non-empty values
        BOOL isQueueAccent = (_queueDisplayStyle == 1 &&
                              [col.pattern isEqualToString:@"__queue_position__"] &&
                              value.length > 0);
        NSColor *cellColor = isQueueAccent ? [NSColor controlAccentColor] : textColor;

        if (_dimParentheses && !isQueueAccent) {
            // Draw with dimmed parentheses
            NSAttributedString *attrStr = [self attributedString:value
                                                            font:font
                                                       textColor:cellColor
                                                      dimmedColor:dimmedColor
                                                  paragraphStyle:style];
            if (decoration.strikethrough) {
                NSMutableAttributedString *struck = [attrStr mutableCopy];
                [struck addAttribute:NSStrikethroughStyleAttributeName
                               value:@(NSUnderlineStyleSingle)
                               range:NSMakeRange(0, struck.length)];
                attrStr = struck;
            }
            [attrStr drawInRect:colRect];
        } else {
            // Draw normally (or queue accent)
            NSDictionary *attrs = @{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: cellColor,
                NSParagraphStyleAttributeName: style
            };
            if (decoration.strikethrough) {
                NSMutableDictionary *struck = [attrs mutableCopy];
                struck[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
                attrs = struck;
            }
            [value drawInRect:colRect withAttributes:attrs];
        }
        x += col.width;
    }
}

// Fill group column background (called BEFORE drawing row content)
- (void)fillGroupColumnBackgroundInRect:(NSRect)dirtyRect {
    // Skip background fill for glass mode - let the effect show through
    if (_glassBackground) return;
    if (_layout.groupStarts.count == 0) return;

    NSRect visibleRect = [self visibleRect];

    // Style 1: Leave header row area unfilled so header text at x=8 is visible
    // Styles 0, 2, 3: Fill entire column

    if (_layout.headerDisplayStyle == 1) {
        // Style 1: Fill only the track areas (below each header row)
        NSInteger firstRow = [self rowAtPoint:NSMakePoint(0, NSMinY(visibleRect))];
        NSInteger lastRow = [self rowAtPoint:NSMakePoint(0, NSMaxY(visibleRect))];
        if (firstRow < 0) firstRow = 0;
        NSInteger totalRows = [self rowCount];
        if (lastRow < 0 || lastRow >= totalRows) lastRow = totalRows - 1;

        NSInteger firstGroupIndex = [self groupIndexForRow:firstRow];
        NSInteger lastGroupIndex = [self groupIndexForRow:lastRow];

        for (NSInteger g = firstGroupIndex; g <= lastGroupIndex && g < (NSInteger)_layout.groupStarts.count; g++) {
            NSInteger groupStartRow = [self rowForGroupHeader:g];
            CGFloat groupTop = [self yOffsetForRow:groupStartRow];
            CGFloat groupHeight = [self pixelHeightForGroup:g];
            CGFloat headerOffset = _layout.headerHeight;  // Style 1 has header rows

            // Fill only below the header row
            NSRect groupColRect = NSMakeRect(0, groupTop + headerOffset, _groupColumnWidth, groupHeight - headerOffset);
            if (NSIntersectsRect(groupColRect, dirtyRect)) {
                [fb2k_ui::backgroundColor() setFill];
                NSRectFill(NSIntersectionRect(groupColRect, dirtyRect));
            }
        }
    } else {
        // Styles 0, 2, 3: Fill entire group column with background
        NSRect groupColRect = NSMakeRect(0, NSMinY(visibleRect), _groupColumnWidth, visibleRect.size.height);
        if (NSIntersectsRect(groupColRect, dirtyRect)) {
            [fb2k_ui::backgroundColor() setFill];
            NSRectFill(NSIntersectionRect(groupColRect, dirtyRect));
        }
    }
}

// Draw album art for visible groups (called AFTER drawing row content)
- (void)drawAlbumArtInRect:(NSRect)dirtyRect firstRow:(NSInteger)firstRow lastRow:(NSInteger)lastRow {
    if (_layout.groupStarts.count == 0) return;

    // Find which groups are visible
    NSInteger firstGroupIndex = [self groupIndexForRow:firstRow];
    NSInteger lastGroupIndex = [self groupIndexForRow:lastRow];

    CGFloat padding = 6;

    for (NSInteger g = firstGroupIndex; g <= lastGroupIndex && g < (NSInteger)_layout.groupStarts.count; g++) {
        NSInteger groupStart = [_layout.groupStarts[g] integerValue];

        // Calculate group's row range
        NSInteger groupStartRow = [self rowForGroupHeader:g];
        CGFloat groupTop = [self yOffsetForRow:groupStartRow];
        CGFloat groupHeight = [self pixelHeightForGroup:g];

        // Style 0, 1: Album art is below header row
        // Style 2: Album art starts at header row Y (next to header text in content area)
        // Style 3: No header row, album art at group top
        CGFloat headerOffset = (_layout.headerDisplayStyle == 0 || _layout.headerDisplayStyle == 1) ? _layout.headerHeight : 0;

        // Calculate available height for album art (below header if present, minus padding)
        CGFloat availableHeight = groupHeight - headerOffset - padding * 2;

        // Use configured size, bounded only by available height
        CGFloat artSize = MIN(_albumArtSize, availableHeight);
        artSize = MAX(artSize, 32);  // Minimum 32px

        // Album art position - below header row if present, otherwise at group top
        CGFloat artY = groupTop + headerOffset + padding;
        CGFloat artX = (_groupColumnWidth - artSize) / 2;  // Center horizontally
        if (artX < padding) artX = padding;
        NSRect artRect = NSMakeRect(artX, artY, artSize, artSize);

        // Get album art from cache or delegate
        NSImage *albumArt = nil;
        if (g < (NSInteger)_groupArtKeys.count && [_delegate respondsToSelector:@selector(playlistView:albumArtForGroupAtPlaylistIndex:)]) {
            albumArt = [_delegate playlistView:self albumArtForGroupAtPlaylistIndex:groupStart];
        }

        if (albumArt) {
            [albumArt drawInRect:artRect
                        fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0
                  respectFlipped:YES
                           hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else {
            [self drawAlbumArtPlaceholderInRect:artRect];
        }

        // For style 3 (under album art), draw header text below album art in the group column
        if (_layout.headerDisplayStyle == 3) {
            CGFloat artBottom = artY + artSize;
            [self drawInlineHeaderForGroup:g atGroupTop:groupTop artBottom:artBottom groupHeight:groupHeight];
        }
    }
}

- (void)drawDropIndicatorAtRow:(NSInteger)row {
    CGFloat y;
    NSInteger count = [self rowCount];
    if (row >= count) {
        // Drop at end - use total content height
        y = [self totalContentHeightCached];
    } else {
        y = [self yOffsetForRow:row];
    }

    // Draw a thick blue line
    [[NSColor systemBlueColor] setFill];
    NSRect indicatorRect = NSMakeRect(_groupColumnWidth, y - 1, self.bounds.size.width - _groupColumnWidth, 3);
    NSRectFill(indicatorRect);
}

- (void)drawEmptyStateInRect:(NSRect)rect {
    NSString *text = @"Playlist is empty";
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:14],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
    };
    NSSize textSize = [text sizeWithAttributes:attrs];
    NSPoint point = NSMakePoint(
        (rect.size.width - textSize.width) / 2,
        (rect.size.height - textSize.height) / 2
    );
    [text drawAtPoint:point withAttributes:attrs];
}

#pragma mark - Flat Mode (Large Playlists)

- (void)drawFlatModeInRect:(NSRect)dirtyRect {
    if (_flatModeTrackCount == 0) {
        [self drawEmptyStateInRect:dirtyRect];
        return;
    }

    // In flat mode: all rows have same height, row index = playlist index
    // Calculate visible row range - O(1)
    NSRect visibleRect = [self visibleRect];
    NSInteger firstRow = (NSInteger)floor(NSMinY(visibleRect) / _layout.rowHeight);
    NSInteger lastRow = (NSInteger)ceil(NSMaxY(visibleRect) / _layout.rowHeight);

    if (firstRow < 0) firstRow = 0;
    if (lastRow >= _flatModeTrackCount) lastRow = _flatModeTrackCount - 1;

    // Add buffer rows
    firstRow = MAX(0, firstRow - 2);
    lastRow = MIN(_flatModeTrackCount - 1, lastRow + 2);

    // Draw group column background if enabled
    if (_groupColumnWidth > 0) {
        [[self groupColumnBackgroundColor] setFill];
        NSRect groupColRect = NSMakeRect(0, NSMinY(visibleRect), _groupColumnWidth, visibleRect.size.height);
        NSRectFill(NSIntersectionRect(groupColRect, dirtyRect));
    }

    // Draw only visible rows (~30-50 rows)
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        CGFloat y = row * _layout.rowHeight;
        NSRect rowRect = NSMakeRect(_groupColumnWidth, y, self.bounds.size.width - _groupColumnWidth, _layout.rowHeight);

        if (NSIntersectsRect(rowRect, dirtyRect)) {
            [self drawFlatModeRow:row inRect:rowRect];
        }
    }

    // Draw focus ring
    if (self.window.firstResponder == self && _selection.focusIndex >= 0 && _selection.focusIndex < _flatModeTrackCount) {
        CGFloat y = _selection.focusIndex * _layout.rowHeight;
        NSRect focusRect = NSMakeRect(_groupColumnWidth, y, self.bounds.size.width - _groupColumnWidth, _layout.rowHeight);
        if (NSIntersectsRect(focusRect, dirtyRect)) {
            [self drawFocusRingForRect:focusRect];
        }
    }

    // Draw drop indicator if dragging
    if (_dropTargetRow >= 0) {
        CGFloat y = _dropTargetRow * _layout.rowHeight;
        [[NSColor systemBlueColor] setFill];
        NSRectFill(NSMakeRect(_groupColumnWidth, y - 1, self.bounds.size.width - _groupColumnWidth, 3));
    }

    // Draw group column separator
    if (_groupColumnWidth > 0) {
        [[NSColor separatorColor] setFill];
        NSRectFill(NSMakeRect(_groupColumnWidth - 1, NSMinY(visibleRect), 1, visibleRect.size.height));
    }
}

- (void)drawFlatModeRow:(NSInteger)row inRect:(NSRect)rect {
    // In flat mode: row index = playlist index directly
    // Selection stores playlist indices
    BOOL isSelected = [_selectedIndices containsIndex:row];  // row == playlistIndex in flat mode
    BOOL isPlaying = (row == _playingIndex);  // playingIndex is playlist index

    // Background - clean design without alternating stripes
    if (isSelected) {
        [fb2k_ui::selectedBackgroundColor() setFill];
        NSRectFill(rect);
    } else if (isPlaying && _showNowPlayingShading) {
        [[[NSColor systemYellowColor] colorWithAlphaComponent:0.15] setFill];
        NSRectFill(rect);
    }

    // Text color
    NSColor *textColor = isSelected ? [NSColor alternateSelectedControlTextColor] : [NSColor labelColor];

    // Get column values lazily from delegate (only for visible rows!)
    NSArray<NSString *> *columnValues = nil;
    if ([_delegate respondsToSelector:@selector(playlistView:columnValuesForPlaylistIndex:)]) {
        columnValues = [_delegate playlistView:self columnValuesForPlaylistIndex:row];
    }

    // Draw columns starting at x=0 of the rect (which already accounts for group column offset)
    CGFloat x = rect.origin.x;

    for (NSInteger col = 0; col < (NSInteger)_columns.count; col++) {
        ColumnDefinition *colDef = _columns[col];
        CGFloat colWidth = colDef.width;

        if (colWidth > 0) {
            NSString *value = (col < (NSInteger)columnValues.count) ? columnValues[col] : @"";

            // Text alignment and style
            NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
            style.lineBreakMode = NSLineBreakByTruncatingTail;
            switch (colDef.alignment) {
                case ColumnAlignmentCenter:
                    style.alignment = NSTextAlignmentCenter;
                    break;
                case ColumnAlignmentRight:
                    style.alignment = NSTextAlignmentRight;
                    break;
                default:
                    style.alignment = NSTextAlignmentLeft;
                    break;
            }

            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:12],
                NSForegroundColorAttributeName: textColor,
                NSParagraphStyleAttributeName: style
            };

            NSRect textRect = NSMakeRect(x + 4, rect.origin.y + 3, colWidth - 8, rect.size.height - 6);
            [value drawInRect:textRect withAttributes:attrs];
        }
        x += colWidth;
    }

    // Draw playing indicator in first column
    if (isPlaying) {
        NSString *playIcon = @"\u25B6";  // Play triangle
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:9],
            NSForegroundColorAttributeName: [NSColor systemOrangeColor]
        };
        [playIcon drawAtPoint:NSMakePoint(rect.origin.x + 4, rect.origin.y + 5) withAttributes:attrs];
    }
}

#pragma mark - Legacy Drawing Methods (Deprecated)

// DEPRECATED: Old sparse group mode using _groupBoundaries
- (void)drawSparseGroupModeInRect_Legacy:(NSRect)dirtyRect {
    return;  // Disabled - use drawSparseModelInRect instead
}

- (void)drawSparseGroupRow_Legacy:(NSInteger)row inRect:(NSRect)rect {
    // DEPRECATED
    GroupBoundary *group = [self groupBoundaryForRow:row];
    BOOL isHeader = (group && row == group.rowOffset);
    NSInteger playlistIndex = [self playlistIndexForRow:row];

    BOOL isSelected = NO;
    BOOL isPlaying = NO;

    if (!isHeader && playlistIndex >= 0) {
        // Selection uses playlist index (not row index)
        isSelected = [_selectedIndices containsIndex:playlistIndex];
        isPlaying = (playlistIndex == _playingIndex);
    }

    // Background
    if (isSelected) {
        [fb2k_ui::selectedBackgroundColor() setFill];
        NSRectFill(rect);
    } else if (isPlaying && _showNowPlayingShading) {
        [[[NSColor systemYellowColor] colorWithAlphaComponent:0.15] setFill];
        NSRectFill(rect);
    } else if (isHeader) {
        [[self headerBackgroundColor] setFill];
        NSRectFill(rect);
    }

    if (isHeader) {
        // Draw group header
        [self drawSparseGroupHeader:group inRect:rect selected:isSelected];
    } else {
        // Draw track row
        [self drawSparseGroupTrack:playlistIndex inRect:rect selected:isSelected playing:isPlaying];
    }
}

- (void)drawSparseGroupHeader:(GroupBoundary *)group inRect:(NSRect)rect selected:(BOOL)selected {
    // Header text
    CGFloat textX = _groupColumnWidth + 8;
    NSRect textRect = NSMakeRect(textX, rect.origin.y + 4,
                                  rect.size.width - textX - 8,
                                  rect.size.height - 8);

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: selected ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor]
    };

    NSString *text = group.headerText ?: @"";
    [text drawInRect:textRect withAttributes:attrs];

    // Bottom separator
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(rect.origin.x, NSMaxY(rect) - 1, rect.size.width, 1));
}

- (void)drawSparseGroupTrack:(NSInteger)playlistIndex inRect:(NSRect)rect selected:(BOOL)selected playing:(BOOL)playing {
    // Text colors
    NSColor *textColor = selected ? [NSColor alternateSelectedControlTextColor] : [NSColor labelColor];
    NSColor *secondaryColor = selected ? [NSColor alternateSelectedControlTextColor] : [NSColor secondaryLabelColor];

    // Get column values lazily from delegate
    NSArray<NSString *> *columnValues = nil;
    if ([_delegate respondsToSelector:@selector(playlistView:columnValuesForPlaylistIndex:)]) {
        columnValues = [_delegate playlistView:self columnValuesForPlaylistIndex:playlistIndex];
    }

    // Draw columns (skip group column area)
    CGFloat x = _groupColumnWidth + 4;

    for (NSInteger col = 0; col < (NSInteger)_columns.count; col++) {
        ColumnDefinition *colDef = _columns[col];
        CGFloat colWidth = colDef.width;

        if (colWidth > 0) {
            NSString *value = (col < (NSInteger)columnValues.count) ? columnValues[col] : @"";

            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:12],
                NSForegroundColorAttributeName: (col == 0) ? textColor : secondaryColor
            };

            NSRect textRect = NSMakeRect(x + 4, rect.origin.y + 2, colWidth - 8, rect.size.height - 4);
            [value drawInRect:textRect withAttributes:attrs];
        }
        x += colWidth;
    }

    // Draw playing indicator
    if (playing) {
        NSString *playIcon = @"\u25B6";
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:10],
            NSForegroundColorAttributeName: [NSColor systemOrangeColor]
        };
        [playIcon drawAtPoint:NSMakePoint(_groupColumnWidth + 6, rect.origin.y + 4) withAttributes:attrs];
    }
}

- (void)drawSparseGroupColumnInRect_Legacy:(NSRect)dirtyRect {
    if (_groupColumnWidth <= 0) return;
    if (_groupBoundaries.count == 0) return;

    // Find visible groups
    NSRect visibleRect = [self visibleRect];

    for (GroupBoundary *group in _groupBoundaries) {
        // Calculate group's vertical extent
        CGFloat groupTop = group.rowOffset * _layout.rowHeight;
        CGFloat groupHeight = [group rowCount] * _layout.rowHeight;
        CGFloat groupBottom = groupTop + groupHeight;

        // Skip if not visible
        NSRect groupRect = NSMakeRect(0, groupTop, _groupColumnWidth, groupHeight);
        if (!NSIntersectsRect(groupRect, visibleRect)) continue;

        // Draw group column background
        [[self groupColumnBackgroundColor] setFill];
        NSRectFill(groupRect);

        // Calculate album art rect
        CGFloat padding = 4;
        CGFloat artSize = MIN(_groupColumnWidth - padding * 2, groupHeight - padding * 2);
        artSize = MIN(artSize, _groupColumnWidth - padding * 2);

        if (artSize < 20) continue;

        NSRect artRect = NSMakeRect(padding, groupTop + padding, artSize, artSize);

        // Get album art from delegate
        NSImage *albumArt = nil;
        if ([_delegate respondsToSelector:@selector(playlistView:albumArtForGroupAtPlaylistIndex:)]) {
            albumArt = [_delegate playlistView:self albumArtForGroupAtPlaylistIndex:group.startPlaylistIndex];
        }

        if (albumArt) {
            [albumArt drawInRect:artRect
                        fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0
                  respectFlipped:YES
                           hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else {
            [self drawAlbumArtPlaceholderInRect:artRect];
        }

        // Check if any track in group is selected (using playlist indices)
        BOOL groupHasSelection = NO;
        for (NSInteger i = group.startPlaylistIndex; i <= group.endPlaylistIndex; i++) {
            if ([_selectedIndices containsIndex:i]) {
                groupHasSelection = YES;
                break;
            }
        }

        // No selection border on album art - cleaner look

        // Draw group separator
        [[NSColor separatorColor] setFill];
        NSRectFill(NSMakeRect(0, groupBottom - 1, _groupColumnWidth, 1));
    }
}

- (void)drawRow:(NSInteger)row inRect:(NSRect)rect {
    GroupNode *node = _nodes[row];
    // Selection uses playlist index (not row index)
    NSInteger playlistIndex = (node.type == GroupNodeTypeTrack) ? node.playlistIndex : -1;
    BOOL isSelected = (playlistIndex >= 0 && [_selectedIndices containsIndex:playlistIndex]);
    BOOL isPlaying = (playlistIndex >= 0 && playlistIndex == _playingIndex);

    // Background - only in columns area, not album art column
    BOOL shouldDrawBackground = isSelected || (isPlaying && _showNowPlayingShading);
    if (shouldDrawBackground) {
        NSRect contentRect = NSMakeRect(_groupColumnWidth, rect.origin.y,
                                        rect.size.width - _groupColumnWidth, rect.size.height);
        if (isSelected) {
            [fb2k_ui::selectedBackgroundColor() setFill];
        } else {
            [[[NSColor systemYellowColor] colorWithAlphaComponent:0.15] setFill];
        }
        NSRectFill(contentRect);
    }

    // Draw based on node type
    switch (node.type) {
        case GroupNodeTypeHeader:
            [self drawHeaderNode:node inRect:rect selected:NO];  // Headers can't be selected
            break;
        case GroupNodeTypeSubgroup:
            [self drawSubgroupNode:node inRect:rect selected:NO];
            break;
        case GroupNodeTypeTrack:
            [self drawTrackNode:node inRect:rect selected:isSelected playing:isPlaying];
            break;
    }
}

- (void)drawHeaderNode:(GroupNode *)node inRect:(NSRect)rect selected:(BOOL)selected {
    // Header background
    if (!selected) {
        [[self headerBackgroundColor] setFill];
        NSRectFill(rect);
    }

    // Header text - use 13pt bold to match system list appearance
    CGFloat textX = _groupColumnWidth + 8;
    NSRect textRect = NSMakeRect(textX, rect.origin.y + 4,
                                  rect.size.width - textX - 8,
                                  rect.size.height - 8);

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
        NSForegroundColorAttributeName: selected ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor]
    };

    NSString *text = node.displayText ?: @"";
    [text drawInRect:textRect withAttributes:attrs];

    // Bottom separator
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(rect.origin.x, NSMaxY(rect) - 1, rect.size.width, 1));
}

- (void)drawSubgroupNode:(GroupNode *)node inRect:(NSRect)rect selected:(BOOL)selected {
    // Subgroup background
    if (!selected) {
        [[self subgroupBackgroundColor] setFill];
        NSRectFill(rect);
    }

    // Indent
    CGFloat indent = _groupColumnWidth + 16 + (node.indentLevel * 16);
    NSRect textRect = NSMakeRect(indent, rect.origin.y + 2,
                                  rect.size.width - indent - 8,
                                  rect.size.height - 4);

    // Use 12pt medium weight for subgroups
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: selected ? [NSColor selectedMenuItemTextColor] : [NSColor secondaryLabelColor]
    };

    NSString *text = node.displayText ?: @"";
    [text drawInRect:textRect withAttributes:attrs];
}

- (void)drawTrackNode:(GroupNode *)node inRect:(NSRect)rect selected:(BOOL)selected playing:(BOOL)playing {
    CGFloat x = _groupColumnWidth;
    CGFloat indent = node.indentLevel * 16;

    // Lazy load column values if not already cached
    if (!node.columnValues && node.playlistIndex >= 0) {
        if ([_delegate respondsToSelector:@selector(playlistView:columnValuesForPlaylistIndex:)]) {
            NSArray<NSString *> *values = [_delegate playlistView:self
                                   columnValuesForPlaylistIndex:node.playlistIndex];
            if (values) {
                node.columnValues = values;  // Cache for next draw
            }
        }
    }

    // Draw each column
    for (NSInteger colIndex = 0; colIndex < (NSInteger)_columns.count; colIndex++) {
        ColumnDefinition *col = _columns[colIndex];

        NSRect colRect = NSMakeRect(x, rect.origin.y,
                                    col.width, rect.size.height);

        // Get column value
        NSString *value = @"";
        if (node.columnValues && colIndex < (NSInteger)node.columnValues.count) {
            value = node.columnValues[colIndex];
        }

        // Apply indent to first column
        if (colIndex == 0) {
            colRect.origin.x += indent;
            colRect.size.width -= indent;
        }

        [self drawColumnValue:value inRect:colRect column:col selected:selected];

        x += col.width;
    }
}

- (void)drawColumnValue:(NSString *)value
                 inRect:(NSRect)rect
                 column:(ColumnDefinition *)column
               selected:(BOOL)selected {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineBreakMode = NSLineBreakByTruncatingTail;

    switch (column.alignment) {
        case ColumnAlignmentCenter:
            style.alignment = NSTextAlignmentCenter;
            break;
        case ColumnAlignmentRight:
            style.alignment = NSTextAlignmentRight;
            break;
        default:
            style.alignment = NSTextAlignmentLeft;
            break;
    }

    // Use system font to match sparse track row drawing
    NSFont *font = [NSFont systemFontOfSize:13];
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: selected ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor],
        NSParagraphStyleAttributeName: style
    };

    // Calculate proper vertical centering
    CGFloat lineHeight = font.ascender - font.descender;
    CGFloat verticalPadding = (rect.size.height - lineHeight) / 2.0;

    // Horizontal padding of 4px, vertical centered
    NSRect textRect = NSMakeRect(rect.origin.x + 4,
                                  rect.origin.y + verticalPadding,
                                  rect.size.width - 8,
                                  lineHeight);

    [value drawInRect:textRect withAttributes:attrs];
}

- (void)drawFocusRingForRect:(NSRect)rect {
    // Only draw focus ring in columns area, not album art column
    // Use same color as selection background for consistency
    [fb2k_ui::selectedBackgroundColor() setStroke];
    NSRect focusRect = NSMakeRect(_groupColumnWidth, rect.origin.y,
                                  rect.size.width - _groupColumnWidth, rect.size.height);
    focusRect = NSInsetRect(focusRect, 1, 1);
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:focusRect];
    path.lineWidth = 2;
    [path stroke];
}

#pragma mark - Group Column (Album Art)

- (void)drawGroupColumnInRect:(NSRect)dirtyRect {
    if (_groupColumnWidth <= 0) return;
    if (_nodes.count == 0) return;

    // Find visible row range first (O(log n) binary search)
    NSInteger firstRow = [self rowAtPoint:NSMakePoint(0, NSMinY(dirtyRect))];
    NSInteger lastRow = [self rowAtPoint:NSMakePoint(0, NSMaxY(dirtyRect))];

    if (firstRow < 0) firstRow = 0;
    if (lastRow < 0 || lastRow >= (NSInteger)_nodes.count) lastRow = (NSInteger)_nodes.count - 1;

    // Extend range to include groups that start before visible area but extend into it
    // Walk backwards from firstRow to find the header that contains it
    NSInteger headerRow = firstRow;
    while (headerRow > 0 && _nodes[headerRow].type != GroupNodeTypeHeader) {
        headerRow--;
    }
    firstRow = headerRow;

    // Track which groups we've already drawn to avoid duplicates
    NSMutableSet<NSNumber *> *drawnGroups = [NSMutableSet set];

    // Only iterate visible rows (plus the header that contains them)
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        GroupNode *node = _nodes[row];
        if (node.type != GroupNodeTypeHeader) continue;

        // Skip if already drawn
        if ([drawnGroups containsObject:@(row)]) continue;
        [drawnGroups addObject:@(row)];

        // Calculate group's vertical extent
        CGFloat groupTop = [self yOffsetForRow:row];
        CGFloat groupBottom;

        if (node.groupEndIndex >= 0 && node.groupEndIndex < (NSInteger)_nodes.count) {
            groupBottom = [self yOffsetForRow:node.groupEndIndex + 1];
        } else {
            // Find the next header or end
            NSInteger nextHeader = row + 1;
            while (nextHeader < (NSInteger)_nodes.count && _nodes[nextHeader].type != GroupNodeTypeHeader) {
                nextHeader++;
            }
            groupBottom = [self yOffsetForRow:nextHeader];
        }

        CGFloat groupHeight = groupBottom - groupTop;

        // Final visibility check
        NSRect groupRect = NSMakeRect(0, groupTop, _groupColumnWidth, groupHeight);
        if (!NSIntersectsRect(groupRect, dirtyRect)) continue;

        // Draw group column background
        [[self groupColumnBackgroundColor] setFill];
        NSRectFill(groupRect);

        // Calculate album art rect (square, with padding)
        CGFloat padding = 4;
        CGFloat artSize = MIN(_groupColumnWidth - padding * 2, groupHeight - padding * 2);
        artSize = MIN(artSize, _groupColumnWidth - padding * 2);  // Cap to column width

        if (artSize < 20) continue;  // Too small to draw

        NSRect artRect = NSMakeRect(
            padding,
            groupTop + padding,
            artSize,
            artSize
        );

        // Get album art from delegate
        NSImage *albumArt = nil;
        if ([_delegate respondsToSelector:@selector(playlistView:albumArtForGroupAtPlaylistIndex:)]) {
            // Use the first track index of this group
            NSInteger firstTrackIndex = node.groupStartIndex;
            if (firstTrackIndex >= 0) {
                albumArt = [_delegate playlistView:self albumArtForGroupAtPlaylistIndex:firstTrackIndex];
            }
        }

        if (albumArt) {
            // Draw album art
            [albumArt drawInRect:artRect
                        fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver
                        fraction:1.0
                  respectFlipped:YES
                           hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        } else {
            // Draw placeholder
            [self drawAlbumArtPlaceholderInRect:artRect];
        }

        // Draw right border for group column
        [[NSColor separatorColor] setFill];
        NSRectFill(NSMakeRect(_groupColumnWidth - 1, groupTop, 1, groupHeight));
    }
}

- (void)drawAlbumArtPlaceholderInRect:(NSRect)rect {
    // Background
    [[NSColor colorWithWhite:0.15 alpha:1.0] setFill];
    NSRectFill(rect);

    // Music note symbol
    NSString *musicNote = @"\u266B";
    CGFloat fontSize = MIN(rect.size.width, rect.size.height) * 0.4;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:fontSize weight:NSFontWeightLight],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.4 alpha:1.0]
    };
    NSSize textSize = [musicNote sizeWithAttributes:attrs];
    NSPoint point = NSMakePoint(
        rect.origin.x + (rect.size.width - textSize.width) / 2,
        rect.origin.y + (rect.size.height - textSize.height) / 2
    );
    [musicNote drawAtPoint:point withAttributes:attrs];
}

- (NSColor *)groupColumnBackgroundColor {
    return [[NSColor controlBackgroundColor] blendedColorWithFraction:0.05
                                                              ofColor:[NSColor blackColor]];
}

#pragma mark - Colors

- (NSColor *)alternateRowColor {
    return [[NSColor controlBackgroundColor] blendedColorWithFraction:0.03
                                                              ofColor:[NSColor labelColor]];
}

- (NSColor *)headerBackgroundColor {
    return [[NSColor controlBackgroundColor] blendedColorWithFraction:0.08
                                                              ofColor:[NSColor labelColor]];
}

- (NSColor *)subgroupBackgroundColor {
    return [[NSColor controlBackgroundColor] blendedColorWithFraction:0.04
                                                              ofColor:[NSColor labelColor]];
}

#pragma mark - Selection Management (state math in PlaylistSelectionModel)

// The selection/anchor/focus math lives in Core/PlaylistSelectionModel so it
// can be unit-tested without an NSView/host. The view converts rows to
// playlist indices, delegates the state change, then handles notification,
// scrolling and redraw.

- (void)selectRowAtIndex:(NSInteger)index {
    [self selectRowAtIndex:index extendSelection:NO];
}

- (void)selectRowAtIndex:(NSInteger)index extendSelection:(BOOL)extend {
    NSInteger totalRows = [self rowCount];
    if (index < 0 || index >= totalRows) return;

    // Convert row to playlist index
    NSInteger playlistIndex = [self playlistIndexForRow:index];
    if (playlistIndex < 0) return;  // Don't select headers

    [_selection selectPlaylistIndex:playlistIndex extendFromAnchor:extend];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)selectRowsInRange:(NSRange)range {
    [_selection addIndexesInRange:range];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)selectAll {
    // Select all playlist items (not row indices)
    if (_layout.itemCount == 0) return;
    [_selection selectAll];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)deselectAll {
    [_selection deselectAll];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)toggleSelectionAtIndex:(NSInteger)index {
    NSInteger totalRows = [self rowCount];
    if (index < 0 || index >= totalRows) return;

    // Convert row to playlist index
    NSInteger playlistIndex = [self playlistIndexForRow:index];
    if (playlistIndex < 0) return;  // Don't select headers

    [_selection togglePlaylistIndex:playlistIndex];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

// focusIndex lives in the selection model; both accessors are implemented so
// no ivar is synthesized (any leftover direct _focusIndex reference is a
// compile error rather than a silent desync).
- (NSInteger)focusIndex {
    return _selection.focusIndex;
}

- (void)setFocusIndex:(NSInteger)index {
    // Focus index is a playlist index
    if (index < -1 || index >= _layout.itemCount) return;
    _selection.focusIndex = index;
    [self setNeedsDisplay:YES];
}

// selectedIndices: the getter is synthesized and returns the ivar, which
// aliases the selection model's stable NSMutableIndexSet (assigned in
// commonInit). A property-setter write must not replace that shared instance,
// so it funnels the contents instead.
- (void)setSelectedIndices:(NSMutableIndexSet *)selectedIndices {
    [_selectedIndices removeAllIndexes];
    if (selectedIndices) {
        [_selectedIndices addIndexes:selectedIndices];
    }
}

- (void)moveFocusBy:(NSInteger)delta extendSelection:(BOOL)extend {
    NSInteger newRow = [_selection moveFocusBy:delta extendSelection:extend];
    if (newRow < 0) return;  // No move (empty list or no valid track found)

    [self scrollRowToVisible:newRow];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)scrollRowToVisible:(NSInteger)row {
    if (row < 0 || row >= [self rowCount]) return;

    NSRect rowRect = [self rectForRow:row];
    [self scrollRectToVisible:rowRect];
}

- (void)notifySelectionChanged {
    if ([_delegate respondsToSelector:@selector(playlistView:selectionDidChange:)]) {
        [_delegate playlistView:self selectionDidChange:[_selectedIndices copy]];
    }
}

- (void)setPlayingIndex:(NSInteger)index {
    _playingIndex = index;
    [self setNeedsDisplay:YES];
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    FB2K_console_formatter() << "[SimPlaylist] mouseDown at window location: "
                             << event.locationInWindow.x << "," << event.locationInWindow.y;

    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:location];

    // Store for potential drag
    _dragStartPoint = location;
    _isDragging = NO;

    if (row < 0) {
        [self deselectAll];
        return;
    }

    BOOL hasCmd = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    BOOL hasShift = (event.modifierFlags & NSEventModifierFlagShift) != 0;

    // Check if clicked on group header or group column (album art area)
    BOOL isGroupHeader = [self isRowGroupHeader:row];
    BOOL isInGroupColumn = (location.x < _groupColumnWidth && _groupColumnWidth > 0 && _layout.groupStarts.count > 0);

    if (isGroupHeader || isInGroupColumn) {
        // Select all items in the group (cmd toggles, shift extends from anchor)
        NSInteger groupIndex = [self groupIndexForRow:row];
        if (groupIndex >= 0) {
            NSRange range = [self playlistIndexRangeForGroup:groupIndex];
            if (range.location != NSNotFound && range.length > 0) {
                [_selection clickGroupRange:range commandKey:hasCmd shiftKey:hasShift];
                [self notifySelectionChanged];
                [self setNeedsDisplay:YES];
                return;
            }
        }
    }

    // Get playlist index for this row
    NSInteger playlistIndex = [self playlistIndexForRow:row];

    if (hasCmd) {
        // Cmd+click: toggle selection
        [self toggleSelectionAtIndex:row];
        if (playlistIndex >= 0) {
            _selection.focusIndex = playlistIndex;
        }
        _pendingClickRow = -1;
    } else if (hasShift && _selection.focusIndex >= 0) {
        // Shift+click: extend selection
        [self selectRowAtIndex:row extendSelection:YES];
        _pendingClickRow = -1;
    } else {
        // Regular click: check if item is already selected
        BOOL alreadySelected = (playlistIndex >= 0 && [_selectedIndices containsIndex:playlistIndex]);

        if (alreadySelected && _selectedIndices.count > 1) {
            // Clicked on already-selected item in multi-selection
            // Defer selection change until mouseUp (allows multi-item drag)
            _pendingClickRow = row;
        } else {
            // Not selected or single selection - select immediately
            [self selectRowAtIndex:row extendSelection:NO];
            _pendingClickRow = -1;
        }
    }
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Check drag threshold (5 pixels)
    CGFloat dx = location.x - _dragStartPoint.x;
    CGFloat dy = location.y - _dragStartPoint.y;
    if (!_isDragging && (dx * dx + dy * dy) < 25) {
        return;
    }

    if (_isDragging) return;  // Already started drag
    _isDragging = YES;
    _pendingClickRow = -1;  // Cancel pending selection change since drag started

    FB2K_console_formatter() << "[SimPlaylist] mouseDragged: starting drag, selection count=" << _selectedIndices.count;

    // Only drag if there's a selection
    if (_selectedIndices.count == 0) return;

    // Create dragging item with selected row indices, source playlist, AND file paths
    // File paths ensure drag works correctly even if active playlist changes mid-drag
    NSMutableDictionary *dragData = [NSMutableDictionary dictionary];
    dragData[@"sourcePlaylist"] = @(_sourcePlaylistIndex);

    NSMutableArray<NSNumber *> *rowNumbers = [NSMutableArray array];
    [_selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [rowNumbers addObject:@(idx)];
    }];
    dragData[@"indices"] = rowNumbers;

    // Capture file paths for cross-playlist drops
    BOOL hasPathsMethod = [_delegate respondsToSelector:@selector(playlistView:filePathsForPlaylistIndices:)];
    FB2K_console_formatter() << "[SimPlaylist] delegate responds to filePathsForPlaylistIndices: " << (hasPathsMethod ? "YES" : "NO");

    if (hasPathsMethod) {
        NSArray<NSString *> *paths = [_delegate playlistView:self filePathsForPlaylistIndices:_selectedIndices];
        FB2K_console_formatter() << "[SimPlaylist] DRAG START: sourcePlaylist=" << _sourcePlaylistIndex
                                 << ", indices=" << rowNumbers.count
                                 << ", paths=" << (paths ? paths.count : 0);
        if (paths && paths.count > 0) {
            dragData[@"paths"] = paths;
        }
    }

    // Store internal drag data on the view — retrieved via draggingSource in performDragOperation
    // This avoids putting custom pasteboard types alongside file URLs, which breaks Finder drops
    _currentDragData = dragData;

    // Build file URLs for Finder compatibility
    // Uses SDK filesystem::g_get_native_path() to resolve all foobar2000 path schemes
    // (file://, mac-volume://, etc.) to POSIX paths
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
    NSArray<NSString *> *dragPaths = dragData[@"paths"];
    if (dragPaths) {
        for (NSString *path in dragPaths) {
            pfc::string8 nativePath;
            if (filesystem::g_get_native_path(path.UTF8String, nativePath)) {
                NSString *posix = [NSString stringWithUTF8String:nativePath.c_str()];
                if (posix && [[NSFileManager defaultManager] fileExistsAtPath:posix]) {
                    NSURL *url = [NSURL fileURLWithPath:posix];
                    if (url) [fileURLs addObject:url];
                }
            }
        }
    }

    // Create a simple drag image
    NSImage *dragImage = [NSImage imageWithSize:NSMakeSize(200, 30) flipped:YES drawingHandler:^BOOL(NSRect dstRect) {
        [[NSColor colorWithWhite:0.3 alpha:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:dstRect xRadius:5 yRadius:5] fill];

        NSString *dragText = [NSString stringWithFormat:@"%lu items", (unsigned long)self->_selectedIndices.count];
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:12],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        NSSize textSize = [dragText sizeWithAttributes:attrs];
        [dragText drawAtPoint:NSMakePoint((dstRect.size.width - textSize.width) / 2,
                                           (dstRect.size.height - textSize.height) / 2)
               withAttributes:attrs];
        return YES;
    }];

    NSRect dragFrame = NSMakeRect(location.x - 100, location.y - 15, 200, 30);
    NSArray<NSDraggingImageComponent *> *(^imageProvider)(void) = ^{
        NSDraggingImageComponent *component = [[NSDraggingImageComponent alloc]
                                               initWithKey:NSDraggingImageComponentIconKey];
        component.contents = dragImage;
        component.frame = NSMakeRect(0, 0, 200, 30);
        return @[component];
    };

    // Archive internal data for pasteboard
    NSData *internalData = [NSKeyedArchiver archivedDataWithRootObject:dragData
                                                 requiringSecureCoding:NO
                                                                 error:nil];

    // Always use a SINGLE NSDraggingItem — multiple items cause macOS to stack them
    // with per-item Y offsets, shifting the drag image far from the cursor.
    // Internal drag data is carried via _currentDragData (retrieved via draggingSource),
    // so the pasteboard writer only needs to handle Finder compatibility.
    NSDraggingItem *dragItem;

    if (fileURLs.count > 0) {
        // Use SimPlaylistDragItem with first URL for Finder single-file drop
        SimPlaylistDragItem *writer = [[SimPlaylistDragItem alloc] init];
        writer.fileURL = fileURLs.firstObject;
        writer.internalData = internalData;
        dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:writer];
    } else {
        // No file URLs (cloud/non-local tracks) — internal type only
        NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
        [pbItem setData:internalData forType:SimPlaylistPasteboardType];
        dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];
    }

    dragItem.draggingFrame = dragFrame;
    dragItem.imageComponentsProvider = imageProvider;

    NSDraggingSession *session = [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];

    // For multi-file Finder drops, write all file URLs to the session pasteboard
    if (fileURLs.count > 1) {
        [session.draggingPasteboard writeObjects:fileURLs];
    }
}

- (void)mouseUp:(NSEvent *)event {
    // If we had a pending click (multi-selection drag start) and no drag occurred,
    // now select just the clicked row
    if (_pendingClickRow >= 0 && !_isDragging) {
        [self selectRowAtIndex:_pendingClickRow extendSelection:NO];
    }
    _pendingClickRow = -1;

    // Handle double-click
    if (event.clickCount == 2) {
        NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
        NSInteger row = [self rowAtPoint:location];
        if (row >= 0 && [_delegate respondsToSelector:@selector(playlistView:didDoubleClickRow:)]) {
            [_delegate playlistView:self didDoubleClickRow:row];
        }
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:location];

    // If clicked row not selected, select it
    // Note: _selectedIndices contains playlist indices, not row indices
    if (row >= 0) {
        NSInteger playlistIndex = [self playlistIndexForRow:row];
        if (playlistIndex >= 0 && ![_selectedIndices containsIndex:playlistIndex]) {
            [self selectRowAtIndex:row];
        }
    }

    if ([_delegate respondsToSelector:@selector(playlistView:requestContextMenuForRows:atPoint:)]) {
        [_delegate playlistView:self requestContextMenuForRows:[_selectedIndices copy] atPoint:location];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:location];

    if (row != _hoveredRow) {
        _hoveredRow = row;
        // Could add hover highlight here if desired
    }
}

- (void)scrollWheel:(NSEvent *)event {
    // Check for Ctrl+scroll to resize group column (album art)
    BOOL hasCtrl = (event.modifierFlags & NSEventModifierFlagControl) != 0;

    if (hasCtrl && _groupColumnWidth > 0) {
        // Resize group column
        CGFloat delta = event.scrollingDeltaY;
        if (event.hasPreciseScrollingDeltas) {
            delta *= 0.5;  // Reduce sensitivity for trackpad
        } else {
            delta *= 10;  // Increase for mouse wheel
        }

        CGFloat newWidth = _groupColumnWidth + delta;
        newWidth = MAX(40, MIN(300, newWidth));  // Clamp to reasonable range

        if (newWidth != _groupColumnWidth) {
            _groupColumnWidth = newWidth;

            // Notify delegate
            if ([_delegate respondsToSelector:@selector(playlistView:didChangeGroupColumnWidth:)]) {
                [_delegate playlistView:self didChangeGroupColumnWidth:newWidth];
            }

            // Update layout
            [self invalidateIntrinsicContentSize];
            [self setNeedsDisplay:YES];
        }
    } else {
        // Normal scroll - pass to super (scroll view handles it)
        [super scrollWheel:event];
    }
}

#pragma mark - Keyboard Events

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSUInteger modifiers = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 0) return [super performKeyEquivalent:event];
    unichar key = [chars characterAtIndex:0];

    BOOL cmd = (modifiers & NSEventModifierFlagCommand) != 0;
    BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
    BOOL onlyCmd = (modifiers == NSEventModifierFlagCommand);
    BOOL cmdShift = (modifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift));

    if (cmd && (key == 'z' || key == 'Z')) {
        // Cmd+Z: undo, Cmd+Shift+Z: redo
        auto pm = playlist_manager::get();
        if (cmdShift) {
            pm->activeplaylist_redo_restore();
        } else if (onlyCmd) {
            pm->activeplaylist_undo_restore();
        } else {
            return [super performKeyEquivalent:event];
        }
        return YES;
    }

    if (onlyCmd && (key == 'f' || key == 'F')) {
        // Cmd+F: find and invoke the Search menu item in foobar2000's Edit menu
        NSMenu *mainMenu = [NSApp mainMenu];
        for (NSMenuItem *topItem in mainMenu.itemArray) {
            NSMenu *submenu = topItem.submenu;
            if (!submenu) continue;
            for (NSMenuItem *item in submenu.itemArray) {
                if ([item.title localizedCaseInsensitiveContainsString:@"search"] && item.action) {
                    [NSApp sendAction:item.action to:item.target from:item];
                    return YES;
                }
            }
        }
        return NO;
    }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    NSUInteger modifiers = event.modifierFlags;
    BOOL hasCmd = (modifiers & NSEventModifierFlagCommand) != 0;
    BOOL hasShift = (modifiers & NSEventModifierFlagShift) != 0;

    if (chars.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [chars characterAtIndex:0];

    switch (key) {
        case NSUpArrowFunctionKey:
            [self moveFocusBy:-1 extendSelection:hasShift];
            break;

        case NSDownArrowFunctionKey:
            [self moveFocusBy:1 extendSelection:hasShift];
            break;

        case NSPageUpFunctionKey:
            [self moveFocusBy:-[self visibleRowCount] extendSelection:hasShift];
            break;

        case NSPageDownFunctionKey:
            [self moveFocusBy:[self visibleRowCount] extendSelection:hasShift];
            break;

        case NSHomeFunctionKey:
            [self moveFocusBy:-(_selection.focusIndex + 1) extendSelection:hasShift];
            break;

        case NSEndFunctionKey:
            [self moveFocusBy:([self rowCount] - _selection.focusIndex) extendSelection:hasShift];
            break;

        case ' ':  // Space - toggle play/pause (consistent with foobar2000 convention)
        {
            auto pc = playback_control::get();
            if (pc->is_playing() || pc->is_paused()) {
                pc->toggle_pause();
            } else {
                pc->play_or_unpause();
            }
            break;
        }

        case '\r':  // Enter - execute default action on focused track
            if (_selection.focusIndex >= 0 &&
                [_delegate respondsToSelector:@selector(playlistView:didDoubleClickRow:)]) {
                NSInteger row = [self rowForPlaylistIndex:_selection.focusIndex];
                if (row >= 0) {
                    [_delegate playlistView:self didDoubleClickRow:row];
                }
            }
            break;

        case NSDeleteCharacter:
        case NSBackspaceCharacter:
            if ([_delegate respondsToSelector:@selector(playlistViewDidRequestRemoveSelection:)]) {
                [_delegate playlistViewDidRequestRemoveSelection:self];
            }
            break;

        default:
            if (hasCmd && (key == 'a' || key == 'A')) {
                [self selectAll];
            } else if (!hasCmd && (key == 'q' || key == 'Q')) {
                // Q: queue all selected tracks
                if (_selectedIndices.count > 0 &&
                    [_delegate respondsToSelector:@selector(playlistView:didRequestQueueTracks:)]) {
                    [_delegate playlistView:self didRequestQueueTracks:[_selectedIndices copy]];
                }
            } else {
                [super keyDown:event];
            }
            break;
    }
}

- (NSInteger)visibleRowCount {
    NSRect visible = [self visibleRect];
    return (NSInteger)(visible.size.height / _layout.rowHeight);
}

#pragma mark - NSDraggingSource

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    if (context == NSDraggingContextWithinApplication) {
        // Support both move and copy - destination decides based on modifier keys
        return NSDragOperationMove | NSDragOperationCopy;
    }
    bool moveByDefault = simplaylist_config::getConfigBool(
        simplaylist_config::kDragToFinderMove,
        simplaylist_config::kDefaultDragToFinderMove);
    return moveByDefault ? NSDragOperationEvery : NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    _isDragging = NO;
    _dropTargetRow = -1;
    _currentDragData = nil;
    // Suppress focus ring briefly to avoid flash on wrong item during rebuild
    _suppressFocusRing = YES;
    [self setNeedsDisplay:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_suppressFocusRing = NO;
        [strongSelf setNeedsDisplay:YES];
    });
}

#pragma mark - NSDraggingDestination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];

    BOOL isInternalDrag = [[sender draggingSource] isKindOfClass:[SimPlaylistView class]]
                          || [pb.types containsObject:SimPlaylistPasteboardType];
    if (isInternalDrag) {
        // Option key = copy, otherwise move
        BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
        return optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;
    } else if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
    } else if ([pb.types containsObject:NSPasteboardTypeURL]) {
        // Web URLs (e.g., from Cloud Browser)
        return NSDragOperationCopy;
    } else if ([pb.types containsObject:NSPasteboardTypeString]) {
        // Plain text - check if it looks like a URL
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if ([str hasPrefix:@"http://"] || [str hasPrefix:@"https://"] ||
            [str hasPrefix:@"soundcloud://"] || [str hasPrefix:@"mixcloud://"]) {
            return NSDragOperationCopy;
        }
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPoint location = [self convertPoint:[sender draggingLocation] fromView:nil];
    NSInteger totalRows = [self rowCount];

    if (totalRows == 0) {
        _dropTargetRow = 0;
        [self setNeedsDisplay:YES];
        return NSDragOperationCopy;
    }

    // Simple distance-based logic: find the closest valid drop position
    // A drop position N means "insert before row N" and is drawn at Y = N * rowHeight
    // Valid positions: before any track, or after last track of album (at album boundary)

    CGFloat cursorY = location.y;
    NSInteger bestPosition = totalRows;  // Default to end
    CGFloat bestDistance = CGFLOAT_MAX;

    // Check all possible drop positions (0 to totalRows inclusive)
    // A position is valid if:
    // 1. It's before a track row (inserting before that track)
    // 2. It's after a track row that's followed by padding/header/end (album boundary)
    for (NSInteger pos = 0; pos <= totalRows; pos++) {
        CGFloat posY = pos * _layout.rowHeight;
        BOOL isValid = NO;

        if (pos < totalRows) {
            // Check if row at 'pos' is a track - if so, we can drop before it
            NSInteger rowAtPosPlaylistIdx = [self playlistIndexForRow:pos];
            if (rowAtPosPlaylistIdx >= 0) {
                isValid = YES;
            }
        }

        if (!isValid && pos > 0) {
            // Check if row at 'pos-1' is a track followed by non-track (album boundary)
            NSInteger prevRowPlaylistIdx = [self playlistIndexForRow:pos - 1];
            if (prevRowPlaylistIdx >= 0) {
                if (pos >= totalRows) {
                    // End of playlist
                    isValid = YES;
                } else {
                    NSInteger nextRowPlaylistIdx = [self playlistIndexForRow:pos];
                    if (nextRowPlaylistIdx < 0) {
                        // Next row is padding/header - album boundary
                        isValid = YES;
                    }
                }
            }
        }

        if (isValid) {
            CGFloat dist = fabs(cursorY - posY);
            if (dist < bestDistance) {
                bestDistance = dist;
                bestPosition = pos;
            }
        }
    }

    _dropTargetRow = bestPosition;
    [self setNeedsDisplay:YES];

    NSPasteboard *pb = [sender draggingPasteboard];
    BOOL isInternalDrag = [[sender draggingSource] isKindOfClass:[SimPlaylistView class]]
                          || [pb.types containsObject:SimPlaylistPasteboardType];
    if (isInternalDrag) {
        // Option key = copy, otherwise move
        BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
        return optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;
    }

    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
    } else if ([pb.types containsObject:NSPasteboardTypeURL]) {
        // Web URLs (e.g., from Cloud Browser)
        return NSDragOperationCopy;
    } else if ([pb.types containsObject:NSPasteboardTypeString]) {
        // Plain text - check if it looks like a URL
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if ([str hasPrefix:@"http://"] || [str hasPrefix:@"https://"] ||
            [str hasPrefix:@"soundcloud://"] || [str hasPrefix:@"mixcloud://"]) {
            return NSDragOperationCopy;
        }
    }
    return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
    _dropTargetRow = -1;
    [self setNeedsDisplay:YES];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];

    FB2K_console_formatter() << "[SimPlaylist] performDragOperation called";

    // Internal drag (reorder or cross-playlist move)
    // Drag data is stored on the source view to avoid pasteboard type conflicts with Finder
    SimPlaylistView *sourceView = nil;
    if ([[sender draggingSource] isKindOfClass:[SimPlaylistView class]]) {
        sourceView = (SimPlaylistView *)[sender draggingSource];
    }

    NSDictionary *dragData = sourceView.currentDragData;
    if (!dragData && [pb.types containsObject:SimPlaylistPasteboardType]) {
        // Fallback: read from pasteboard (for non-local file drags that use the old path)
        NSData *data = [pb dataForType:SimPlaylistPasteboardType];
        if (data) {
            dragData = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                        [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSNumber class], [NSString class], nil]
                                                           fromData:data
                                                              error:nil];
        }
    }

    if (dragData) {
        NSNumber *sourcePlaylist = dragData[@"sourcePlaylist"];
        NSArray<NSNumber *> *rowNumbers = dragData[@"indices"];
        NSArray<NSString *> *paths = dragData[@"paths"];

        BOOL samePlaylist = (sourcePlaylist && [sourcePlaylist integerValue] == _sourcePlaylistIndex);
        FB2K_console_formatter() << "[SimPlaylist] DROP: sourcePlaylist=" << [sourcePlaylist integerValue]
                                 << ", currentPlaylist=" << _sourcePlaylistIndex
                                 << ", samePlaylist=" << (samePlaylist ? "YES" : "NO")
                                 << ", paths=" << (paths ? paths.count : 0)
                                 << ", indices=" << (rowNumbers ? rowNumbers.count : 0);

        if (samePlaylist) {
            // Same playlist - reorder or duplicate based on modifier key
            if (rowNumbers && rowNumbers.count > 0) {
                NSMutableIndexSet *sourceRows = [NSMutableIndexSet indexSet];
                for (NSNumber *num in rowNumbers) {
                    [sourceRows addIndex:[num unsignedIntegerValue]];
                }

                // Option key = copy (duplicate), otherwise move (reorder)
                BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
                NSDragOperation operation = optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;

                if ([_delegate respondsToSelector:@selector(playlistView:didReorderRows:toRow:operation:)]) {
                    [_delegate playlistView:self didReorderRows:sourceRows toRow:_dropTargetRow operation:operation];
                }
            }
        } else {
            // Different playlist - use paths to move/copy items
            if (paths && paths.count > 0 && rowNumbers && rowNumbers.count > 0) {
                // Build source indices from row numbers
                NSMutableIndexSet *sourceIndices = [NSMutableIndexSet indexSet];
                for (NSNumber *num in rowNumbers) {
                    [sourceIndices addIndex:[num unsignedIntegerValue]];
                }

                // Get operation from modifier keys (same check as draggingUpdated)
                BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
                NSDragOperation operation = optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;
                FB2K_console_formatter() << "[SimPlaylist] Cross-playlist drop: optionKey=" << (optionKeyHeld ? "YES" : "NO")
                                         << ", operation=" << (int)operation
                                         << " (Move=" << (int)NSDragOperationMove << ", Copy=" << (int)NSDragOperationCopy << ")";

                if ([_delegate respondsToSelector:@selector(playlistView:didReceiveDroppedPaths:fromPlaylist:sourceIndices:atRow:operation:)]) {
                    [_delegate playlistView:self didReceiveDroppedPaths:paths
                               fromPlaylist:[sourcePlaylist integerValue]
                              sourceIndices:sourceIndices
                                      atRow:_dropTargetRow
                                  operation:operation];
                }
            }
        }
        _dropTargetRow = -1;
        [self setNeedsDisplay:YES];
        return YES;
    }

    // File drop from Finder or media library
    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                          options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
        if (urls.count > 0) {
            if ([_delegate respondsToSelector:@selector(playlistView:didReceiveDroppedURLs:atRow:)]) {
                [_delegate playlistView:self didReceiveDroppedURLs:urls atRow:_dropTargetRow];
            }
        }
        _dropTargetRow = -1;
        [self setNeedsDisplay:YES];
        return YES;
    }

    // Web URL drop (e.g., from Cloud Browser)
    if ([pb.types containsObject:NSPasteboardTypeURL]) {
        NSArray *urls = [pb readObjectsForClasses:@[[NSURL class]] options:nil];
        if (urls.count > 0) {
            FB2K_console_formatter() << "[SimPlaylist] received URL drop: " << [[urls[0] absoluteString] UTF8String];
            if ([_delegate respondsToSelector:@selector(playlistView:didReceiveDroppedURLs:atRow:)]) {
                [_delegate playlistView:self didReceiveDroppedURLs:urls atRow:_dropTargetRow];
            }
        }
        _dropTargetRow = -1;
        [self setNeedsDisplay:YES];
        return YES;
    }

    // Plain text URL drop (fallback for Cloud Browser)
    if ([pb.types containsObject:NSPasteboardTypeString]) {
        NSString *str = [pb stringForType:NSPasteboardTypeString];
        if ([str hasPrefix:@"http://"] || [str hasPrefix:@"https://"] ||
            [str hasPrefix:@"soundcloud://"] || [str hasPrefix:@"mixcloud://"]) {
            FB2K_console_formatter() << "[SimPlaylist] received string URL drop: " << [str UTF8String];
            NSURL *url = [NSURL URLWithString:str];
            if (url) {
                if ([_delegate respondsToSelector:@selector(playlistView:didReceiveDroppedURLs:atRow:)]) {
                    [_delegate playlistView:self didReceiveDroppedURLs:@[url] atRow:_dropTargetRow];
                }
            }
        }
        _dropTargetRow = -1;
        [self setNeedsDisplay:YES];
        return YES;
    }

    _dropTargetRow = -1;
    [self setNeedsDisplay:YES];
    return NO;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    _dropTargetRow = -1;
    [self setNeedsDisplay:YES];
}

@end
