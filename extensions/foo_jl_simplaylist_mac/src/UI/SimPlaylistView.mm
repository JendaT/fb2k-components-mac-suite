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

NSString *const SimPlaylistSettingsChangedNotification = @"SimPlaylistSettingsChanged";
NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.rows";

@interface SimPlaylistView ()
@property (nonatomic, assign) NSInteger selectionAnchor;  // For shift-click selection
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, assign) NSInteger hoveredRow;
@property (nonatomic, assign) NSPoint dragStartPoint;
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) BOOL suppressFocusRing;  // Suppress focus ring briefly after drag
@property (nonatomic, assign) NSInteger dropTargetRow;  // Row where items would be dropped
@property (nonatomic, assign) NSInteger pendingClickRow;  // Row to select on mouseUp if no drag (for multi-select drag)
// Performance: cached row y-offsets for O(1) lookup
@property (nonatomic, strong) NSMutableArray<NSNumber *> *rowYOffsets;
@property (nonatomic, assign) CGFloat totalContentHeight;
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
    _columns = [ColumnDefinition defaultColumns];
    _selectedIndices = [NSMutableIndexSet indexSet];
    _focusIndex = -1;
    _playingIndex = -1;
    _selectionAnchor = -1;
    _hoveredRow = -1;
    _isDragging = NO;
    _dropTargetRow = -1;
    _pendingClickRow = -1;

    // SPARSE GROUP MODEL - efficient O(G) storage
    _itemCount = 0;
    _groupStarts = @[];
    _groupHeaders = @[];
    _groupArtKeys = @[];
    _groupPaddingRows = @[];
    _totalPaddingRowsCached = 0;
    _cumulativePaddingCache = @[];
    _subgroupStarts = @[];
    _subgroupHeaders = @[];
    _subgroupCountPerGroup = @[];
    _subgroupRowSet = [NSSet set];
    _subgroupRowToIndex = @{};
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

    // Default metrics
    _rowHeight = simplaylist_config::kDefaultRowHeight;
    _headerHeight = simplaylist_config::kDefaultHeaderHeight;
    _subgroupHeight = simplaylist_config::kDefaultSubgroupHeight;
    _groupColumnWidth = simplaylist_config::kDefaultGroupColumnWidth;
    _albumArtSize = simplaylist_config::kDefaultAlbumArtSize;
    _showNowPlayingShading = simplaylist_config::getConfigBool(
        simplaylist_config::kNowPlayingShading,
        simplaylist_config::kDefaultNowPlayingShading);
    _headerDisplayStyle = simplaylist_config::getConfigInt(
        simplaylist_config::kHeaderDisplayStyle,
        simplaylist_config::kDefaultHeaderDisplayStyle);
    _dimParentheses = simplaylist_config::getConfigBool(
        simplaylist_config::kDimParentheses,
        simplaylist_config::kDefaultDimParentheses);
    _displaySize = simplaylist_config::getConfigInt(
        simplaylist_config::kDisplaySize,
        simplaylist_config::kDefaultDisplaySize);

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
        NSPasteboardTypeFileURL
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

    // Row height based on display size: compact=19, normal=22, large=26
    switch (_displaySize) {
        case 0: _rowHeight = 19; break;  // Compact
        case 2: _rowHeight = 26; break;  // Large
        default: _rowHeight = 22; break; // Normal
    }

    _headerHeight = getConfigInt(kHeaderHeight, kDefaultHeaderHeight);
    _subgroupHeight = getConfigInt(kSubgroupHeight, kDefaultSubgroupHeight);
    _groupColumnWidth = getConfigInt(kGroupColumnWidth, kDefaultGroupColumnWidth);
    _showNowPlayingShading = getConfigBool(kNowPlayingShading, kDefaultNowPlayingShading);
    _headerDisplayStyle = getConfigInt(kHeaderDisplayStyle, kDefaultHeaderDisplayStyle);
    _dimParentheses = getConfigBool(kDimParentheses, kDefaultDimParentheses);

    [self invalidateIntrinsicContentSize];
    [self setNeedsDisplay:YES];
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
}

#pragma mark - Data Management

- (void)reloadData {
    // Update frame size to match content for proper scrolling
    NSSize contentSize = [self calculatedContentSize];

    // Ensure minimum size matches scroll view's visible area
    // This is CRITICAL for empty playlists to receive drag events
    NSScrollView *scrollView = self.enclosingScrollView;
    if (scrollView) {
        NSSize visibleSize = scrollView.contentView.bounds.size;
        if (contentSize.height < visibleSize.height) {
            contentSize.height = visibleSize.height;
        }
        if (contentSize.width < visibleSize.width) {
            contentSize.width = visibleSize.width;
        }
    }

    NSRect frame = self.frame;
    frame.size = contentSize;
    self.frame = frame;

    [self invalidateIntrinsicContentSize];
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
- (NSInteger)rowCount {
    // Total rows = items + group headers + subgroup headers + padding rows
    // Uses cached totalPaddingRowsCached for O(1) instead of O(G) loop

    // Only style 3 has no header rows (header is drawn below album art)
    // Styles 0, 1, 2 all have header rows
    NSInteger groupHeaderRows = (_headerDisplayStyle == 3) ? 0 : (NSInteger)_groupStarts.count;

    return _itemCount + groupHeaderRows + (NSInteger)_subgroupStarts.count + _totalPaddingRowsCached;
}

// Helper: cumulative padding rows up to (but not including) group g - O(1) using cache
- (NSInteger)cumulativePaddingBeforeGroup:(NSInteger)groupIndex {
    if (groupIndex <= 0 || _cumulativePaddingCache.count == 0) return 0;
    if (groupIndex >= (NSInteger)_cumulativePaddingCache.count) {
        return [_cumulativePaddingCache.lastObject integerValue];
    }
    return [_cumulativePaddingCache[groupIndex] integerValue];
}

// Helper: total rows in group g (header + subgroups + tracks + padding)
// Only style 3 has no header row (header is drawn below album art)
- (NSInteger)totalRowsInGroup:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) return 0;
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    NSInteger trackCount = groupEnd - groupStart;
    NSInteger padding = (groupIndex < (NSInteger)_groupPaddingRows.count)
        ? [_groupPaddingRows[groupIndex] integerValue] : 0;
    // Only style 3 has no header row
    NSInteger headerRows = (_headerDisplayStyle == 3) ? 0 : 1;

    // Use pre-computed subgroup count (O(1) instead of O(S))
    NSInteger subgroupCount = (groupIndex < (NSInteger)_subgroupCountPerGroup.count)
        ? [_subgroupCountPerGroup[groupIndex] integerValue] : 0;

    return headerRows + subgroupCount + trackCount + padding;
}

#pragma mark - Row Mapping (O(log g) using binary search)

// Find which group a row belongs to using binary search
- (NSInteger)groupIndexForRow:(NSInteger)row {
    if (_groupStarts.count == 0 || row < 0) return -1;

    // Binary search: find the largest group index g where rowForGroupHeader(g) <= row
    NSInteger low = 0;
    NSInteger high = (NSInteger)_groupStarts.count - 1;
    NSInteger result = 0;

    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        NSInteger headerRow = [self rowForGroupHeader:mid];
        if (headerRow <= row) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return result;
}

// Row number where group header appears (or first track row for style 3)
- (NSInteger)rowForGroupHeader:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) return -1;
    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];

    // Count all subgroups that appear before this group - O(log S) using binary search
    NSInteger subgroupsBeforeGroup = [self subgroupCountBeforePlaylistIndex:groupStart];

    // Only style 3 has no header rows
    if (_headerDisplayStyle == 3) {
        // Style 3: no header rows, return position of first track
        return groupStart + subgroupsBeforeGroup + cumulativePadding;
    } else {
        // Styles 0, 1, 2: Header row = groupStart[g] + g (group headers) + subgroups before + cumulative padding
        return groupStart + groupIndex + subgroupsBeforeGroup + cumulativePadding;
    }
}

// Check if row is a group header
- (BOOL)isRowGroupHeader:(NSInteger)row {
    if (_groupStarts.count == 0) return NO;
    // Only style 3 has no header rows (header is drawn below album art)
    if (_headerDisplayStyle == 3) return NO;

    NSInteger groupIndex = [self groupIndexForRow:row];
    return row == [self rowForGroupHeader:groupIndex];
}

// Check if row is a padding row (empty space for minimum group height)
- (BOOL)isRowPaddingRow:(NSInteger)row {
    if (_groupStarts.count == 0 || _groupPaddingRows.count == 0) return NO;
    NSInteger groupIndex = [self groupIndexForRow:row];
    if (groupIndex < 0) return NO;

    NSInteger headerRow = [self rowForGroupHeader:groupIndex];
    NSInteger rowWithinGroup = row - headerRow;

    // Get track count for this group
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    NSInteger trackCount = groupEnd - groupStart;

    // Get subgroup count for this group (subgroup headers add to row count)
    NSInteger subgroupsInGroup = (groupIndex < (NSInteger)_subgroupCountPerGroup.count)
        ? [_subgroupCountPerGroup[groupIndex] integerValue] : 0;

    // Total content rows = tracks + subgroup headers (header row already excluded by rowWithinGroup)
    NSInteger contentRows = trackCount + subgroupsInGroup;

    // Row is padding if it's after all content (tracks + subgroups) in the group
    return (rowWithinGroup > contentRows);
}

// Convert row to playlist index (-1 for header rows, subgroup rows, and padding rows)
- (NSInteger)playlistIndexForRow:(NSInteger)row {
    if (row < 0 || row >= [self rowCount]) return -1;
    if (_groupStarts.count == 0) return row;  // No groups = flat mode

    // Check if this is a subgroup header row
    if ([self isRowSubgroupHeader:row]) {
        return -1;
    }

    NSInteger groupIndex = [self groupIndexForRow:row];
    NSInteger groupStartRow = [self rowForGroupHeader:groupIndex];

    // Styles 0, 1, 2 have header rows; only style 3 doesn't
    if (_headerDisplayStyle != 3 && row == groupStartRow) {
        return -1;  // This is a header row
    }

    // Count subgroups in this group before this row to get correct playlist index
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;

    // Count subgroup rows between groupStartRow and this row using cached set - O(subgroups in group)
    NSInteger subgroupsInGroup = 0;
    for (NSNumber *sgRowNum in _subgroupRowSet) {
        NSInteger sgRow = [sgRowNum integerValue];
        if (sgRow > groupStartRow && sgRow < row) {
            subgroupsInGroup++;
        }
    }

    // Calculate position within group accounting for subgroups
    NSInteger rowWithinGroup = row - groupStartRow - subgroupsInGroup;

    // Styles 0, 1, 2 have header rows; only style 3 doesn't
    if (_headerDisplayStyle != 3) {
        rowWithinGroup -= 1;
    }

    NSInteger trackCount = groupEnd - groupStart;

    // If row is beyond tracks, it's a padding row
    if (rowWithinGroup >= trackCount) {
        return -1;  // Padding row
    }

    // Track row: playlist index = groupStart + rowWithinGroup
    return groupStart + rowWithinGroup;
}

// Convert playlist index to row
- (NSInteger)rowForPlaylistIndex:(NSInteger)playlistIndex {
    if (playlistIndex < 0 || playlistIndex >= _itemCount) return -1;
    if (_groupStarts.count == 0) return playlistIndex;  // No groups

    // Find which group this playlist index belongs to - O(log G) using binary search
    NSInteger groupIndex = 0;
    NSInteger low = 0;
    NSInteger high = (NSInteger)_groupStarts.count - 1;
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        if ([_groupStarts[mid] integerValue] <= playlistIndex) {
            groupIndex = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    // Count subgroups before this playlist index - O(log S)
    // subgroupCountBeforePlaylistIndex counts subgroups with start < playlistIndex
    // But if a subgroup starts at exactly playlistIndex, its header row is BEFORE this track
    NSInteger subgroupsBefore = [self subgroupCountBeforePlaylistIndex:playlistIndex];
    if ([self hasSubgroupAtPlaylistIndex:playlistIndex]) {
        subgroupsBefore++;
    }

    // Only style 3 has no header rows
    NSInteger headerRowsOffset = (_headerDisplayStyle == 3) ? 0 : (groupIndex + 1);

    // Row = playlist index + group headers (if not style 3) + subgroup headers + cumulative padding
    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    return playlistIndex + headerRowsOffset + subgroupsBefore + cumulativePadding;
}

// Clear formatted values cache (call when playlist changes)
- (void)clearFormattedValuesCache {
    [_formattedValuesCache removeAllObjects];
}

// Rebuild subgroup row cache for O(1) lookup (call when subgroups or layout changes)
- (void)rebuildSubgroupRowCache {
    if (_subgroupStarts.count == 0) {
        _subgroupRowSet = [NSSet set];
        _subgroupRowToIndex = @{};
        return;
    }

    NSMutableSet<NSNumber *> *rowSet = [NSMutableSet setWithCapacity:_subgroupStarts.count];
    NSMutableDictionary<NSNumber *, NSNumber *> *rowToIndex = [NSMutableDictionary dictionaryWithCapacity:_subgroupStarts.count];

    for (NSUInteger i = 0; i < _subgroupStarts.count; i++) {
        NSInteger subgroupPlaylistIndex = [_subgroupStarts[i] integerValue];
        NSInteger subgroupRow = [self rowForSubgroupAtPlaylistIndex:subgroupPlaylistIndex];
        NSNumber *rowNum = @(subgroupRow);
        [rowSet addObject:rowNum];
        rowToIndex[rowNum] = @(i);
    }

    _subgroupRowSet = [rowSet copy];
    _subgroupRowToIndex = [rowToIndex copy];
}

// Rebuild padding cache for O(1) lookup (call when groupPaddingRows changes)
- (void)rebuildPaddingCache {
    if (_groupPaddingRows.count == 0) {
        _totalPaddingRowsCached = 0;
        _cumulativePaddingCache = @[];
        return;
    }

    NSMutableArray<NSNumber *> *cumulative = [NSMutableArray arrayWithCapacity:_groupPaddingRows.count];
    NSInteger runningTotal = 0;

    for (NSNumber *padding in _groupPaddingRows) {
        [cumulative addObject:@(runningTotal)];  // Cumulative BEFORE this group
        runningTotal += [padding integerValue];
    }

    _totalPaddingRowsCached = runningTotal;
    _cumulativePaddingCache = [cumulative copy];
}

// Get playlist index range for a group
- (NSRange)playlistIndexRangeForGroup:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) {
        return NSMakeRange(NSNotFound, 0);
    }
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    return NSMakeRange(groupStart, groupEnd - groupStart);
}

// Count subgroups strictly before a given playlist index - O(log S) using binary search
- (NSInteger)subgroupCountBeforePlaylistIndex:(NSInteger)playlistIndex {
    if (_subgroupStarts.count == 0) return 0;

    // Binary search for the first subgroup >= playlistIndex
    NSInteger low = 0;
    NSInteger high = (NSInteger)_subgroupStarts.count;

    while (low < high) {
        NSInteger mid = (low + high) / 2;
        if ([_subgroupStarts[mid] integerValue] < playlistIndex) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }

    return low;  // Number of subgroups with start < playlistIndex
}

// Check if a subgroup starts at exactly this playlist index - O(log S)
- (BOOL)hasSubgroupAtPlaylistIndex:(NSInteger)playlistIndex {
    if (_subgroupStarts.count == 0) return NO;

    NSInteger low = 0;
    NSInteger high = (NSInteger)_subgroupStarts.count - 1;

    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        NSInteger midVal = [_subgroupStarts[mid] integerValue];
        if (midVal == playlistIndex) {
            return YES;
        } else if (midVal < playlistIndex) {
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }
    return NO;
}

// Check if a row is a subgroup header - O(1) using pre-computed cache
- (BOOL)isRowSubgroupHeader:(NSInteger)row {
    return [_subgroupRowSet containsObject:@(row)];
}

// Get subgroup header text for a row (returns nil if not a subgroup header) - O(1) using cache
- (NSString *)subgroupHeaderForRow:(NSInteger)row {
    NSNumber *indexNum = _subgroupRowToIndex[@(row)];
    if (!indexNum) return nil;

    NSUInteger i = [indexNum unsignedIntegerValue];
    if (i < _subgroupHeaders.count) {
        return _subgroupHeaders[i];
    }
    return nil;
}

// Calculate row for a subgroup that starts at given playlist index
- (NSInteger)rowForSubgroupAtPlaylistIndex:(NSInteger)subgroupPlaylistIndex {
    if (_groupStarts.count == 0) return subgroupPlaylistIndex;

    // Find which group this subgroup belongs to - O(log G) using binary search
    NSInteger groupIndex = 0;
    NSInteger low = 0;
    NSInteger high = (NSInteger)_groupStarts.count - 1;
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        if ([_groupStarts[mid] integerValue] <= subgroupPlaylistIndex) {
            groupIndex = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    // Row = subgroupPlaylistIndex + (group headers if not inline) + (subgroups before this index) + padding
    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    NSInteger subgroupsBefore = [self subgroupCountBeforePlaylistIndex:subgroupPlaylistIndex];

    // Only style 3 has no group header rows
    NSInteger headerRowsOffset = (_headerDisplayStyle == 3) ? 0 : (groupIndex + 1);

    return subgroupPlaylistIndex + headerRowsOffset + subgroupsBefore + cumulativePadding;
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
    CGFloat totalWidth = [self totalColumnWidth] + _groupColumnWidth;
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
            return _headerHeight;
        case GroupNodeTypeSubgroup:
            return _subgroupHeight;
        case GroupNodeTypeTrack:
        default:
            return _rowHeight;
    }
}

// All rows have constant height for O(1) calculations
- (CGFloat)heightForRow:(NSInteger)row {
    if ([self isRowGroupHeader:row]) {
        return _headerHeight;
    }
    return _rowHeight;
}

- (CGFloat)yOffsetForRow:(NSInteger)row {
    if (row < 0) return 0;
    NSInteger totalRows = [self rowCount];
    if (row >= totalRows) return totalRows * _rowHeight;

    // For simplicity, use constant row height for O(1) calculation
    // Header rows use headerHeight but for now assume equal heights
    return row * _rowHeight;
}

- (NSRect)rectForRow:(NSInteger)row {
    NSInteger totalRows = [self rowCount];
    if (row < 0 || row >= totalRows) {
        return NSZeroRect;
    }
    CGFloat y = [self yOffsetForRow:row];
    CGFloat h = [self heightForRow:row];
    return NSMakeRect(0, y, self.bounds.size.width, h);
}

- (NSInteger)rowAtPoint:(NSPoint)point {
    if (point.y < 0) return -1;
    NSInteger totalRows = [self rowCount];
    CGFloat totalHeight = totalRows * _rowHeight;
    if (point.y >= totalHeight) return -1;
    return (NSInteger)(point.y / _rowHeight);
}

- (CGFloat)totalContentHeightCached {
    return [self rowCount] * _rowHeight;
}

#pragma mark - Drawing (Virtual Scrolling - SPARSE MODEL)

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    // Background
    [[self backgroundColor] setFill];
    NSRectFill(dirtyRect);

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
    // Find visible row range (O(1) calculation)
    NSRect visibleRect = [self visibleRect];
    NSInteger firstRow = [self rowAtPoint:NSMakePoint(0, NSMinY(visibleRect))];
    NSInteger lastRow = [self rowAtPoint:NSMakePoint(0, NSMaxY(visibleRect))];

    NSInteger totalRows = [self rowCount];
    if (firstRow < 0) firstRow = 0;
    if (lastRow < 0 || lastRow >= totalRows) lastRow = totalRows - 1;

    // Add small buffer for smooth scrolling
    firstRow = MAX(0, firstRow - 1);
    lastRow = MIN(totalRows - 1, lastRow + 1);

    // STEP 1: Fill group column background FIRST (before any content)
    // This ensures header text drawn later won't be covered
    if (_groupColumnWidth > 0 && _groupStarts.count > 0) {
        [self fillGroupColumnBackgroundInRect:dirtyRect];
    }

    // STEP 2: Draw only visible rows (typically ~30 rows)
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        NSRect rowRect = [self rectForRow:row];
        if (NSIntersectsRect(rowRect, dirtyRect)) {
            [self drawSparseRow:row inRect:rowRect];
        }
    }

    // STEP 3: Draw album art on top (after all row content)
    if (_groupColumnWidth > 0 && _groupStarts.count > 0) {
        [self drawAlbumArtInRect:dirtyRect firstRow:firstRow lastRow:lastRow];
    }

    // Draw focus ring - only on valid track rows, not during drag operations
    if (!_isDragging && _dropTargetRow < 0 && !_suppressFocusRing &&
        self.window.firstResponder == self && _focusIndex >= 0 && _focusIndex < _itemCount) {
        NSInteger focusRow = [self rowForPlaylistIndex:_focusIndex];
        // Verify this row maps back to a valid track (not header/subgroup/padding)
        if (focusRow >= 0 && focusRow >= firstRow && focusRow <= lastRow) {
            NSInteger verifyIndex = [self playlistIndexForRow:focusRow];
            if (verifyIndex == _focusIndex) {
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

    // Padding rows are empty - just return (background already drawn)
    if (isPadding) {
        return;
    }

    // Check selection and playing state
    BOOL isSelected = (playlistIndex >= 0 && [_selectedIndices containsIndex:playlistIndex]);
    BOOL isPlaying = (playlistIndex >= 0 && playlistIndex == _playingIndex);

    // Selection/playing background - only in columns area, not album art column
    BOOL shouldDrawBackground = isSelected || (isPlaying && _showNowPlayingShading);
    if (shouldDrawBackground) {
        NSRect contentRect = NSMakeRect(_groupColumnWidth, rect.origin.y,
                                        rect.size.width - _groupColumnWidth, rect.size.height);
        if (isSelected) {
            [[NSColor selectedContentBackgroundColor] setFill];
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
        [self drawSparseTrackRow:playlistIndex inRect:rect selected:isSelected playing:isPlaying];
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

    // Calculate text size
    NSSize textSize = [headerText sizeWithAttributes:attrs];

    CGFloat textX;
    CGFloat textY;
    CGFloat lineStartX;
    CGFloat lineEndX = rect.size.width - 8;
    CGFloat lineY;
    CGFloat padding = 6;

    if (_headerDisplayStyle == 1) {
        // Style 1 (Album art aligned): text aligned with album art left edge
        // Calculate album art X position to align text with it
        CGFloat artX = (_groupColumnWidth - _albumArtSize) / 2;
        if (artX < padding) artX = padding;
        textX = artX;
        textY = rect.origin.y + 2;  // Near top of row for more spacing from items below
        lineStartX = textX + textSize.width + 12;
        lineY = rect.origin.y + rect.size.height / 2;
    } else if (_headerDisplayStyle == 2) {
        // Style 2 (Inline): text at top of row for more spacing from tracks below
        textX = _groupColumnWidth + 8;
        textY = rect.origin.y + 2;  // Near top of row
        lineStartX = lineEndX + 1;  // No line for style 2
        lineY = 0;
    } else {
        // Style 0: text starts after album art column, near top for more spacing
        textX = _groupColumnWidth + 8;
        textY = rect.origin.y + 2;  // Near top of row for more spacing from items below
        lineStartX = textX + textSize.width + 12;
        lineY = rect.origin.y + rect.size.height / 2;
    }

    // Draw header text
    [headerText drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];

    // Draw horizontal line after text (not for style 2 - inline mode)
    if (_headerDisplayStyle != 2 && lineStartX < lineEndX) {
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

    NSDictionary *attrsWithStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSParagraphStyleAttributeName: style
    };

    [headerText drawInRect:textRect withAttributes:attrsWithStyle];
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
    CGFloat textX = _groupColumnWidth + 24;  // More indent than group header
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
- (void)drawSparseTrackRow:(NSInteger)playlistIndex inRect:(NSRect)rect selected:(BOOL)selected playing:(BOOL)playing {
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
        return;  // Nothing to draw
    }

    // Draw columns
    CGFloat x = _groupColumnWidth;
    NSColor *textColor = selected ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor];
    NSColor *dimmedColor = selected ? [[NSColor selectedMenuItemTextColor] colorWithAlphaComponent:0.5]
                                    : [NSColor secondaryLabelColor];
    // Font size based on display size: compact=12, normal=13, large=14
    CGFloat fontSize = (_displaySize == 0) ? 12 : (_displaySize == 2) ? 14 : 13;
    NSFont *font = [NSFont systemFontOfSize:fontSize];

    // Calculate vertical centering with equal top/bottom padding
    CGFloat textHeight = font.ascender - font.descender;
    CGFloat verticalPadding = floor((rect.size.height - textHeight) / 2.0);

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

        if (_dimParentheses) {
            // Draw with dimmed parentheses
            NSAttributedString *attrStr = [self attributedString:value
                                                            font:font
                                                       textColor:textColor
                                                      dimmedColor:dimmedColor
                                                  paragraphStyle:style];
            [attrStr drawInRect:colRect];
        } else {
            // Draw normally
            NSDictionary *attrs = @{
                NSFontAttributeName: font,
                NSForegroundColorAttributeName: textColor,
                NSParagraphStyleAttributeName: style
            };
            [value drawInRect:colRect withAttributes:attrs];
        }
        x += col.width;
    }
}

// Fill group column background (called BEFORE drawing row content)
- (void)fillGroupColumnBackgroundInRect:(NSRect)dirtyRect {
    if (_groupStarts.count == 0) return;

    NSRect visibleRect = [self visibleRect];

    // Style 1: Leave header row area unfilled so header text at x=8 is visible
    // Styles 0, 2, 3: Fill entire column

    if (_headerDisplayStyle == 1) {
        // Style 1: Fill only the track areas (below each header row)
        NSInteger firstRow = [self rowAtPoint:NSMakePoint(0, NSMinY(visibleRect))];
        NSInteger lastRow = [self rowAtPoint:NSMakePoint(0, NSMaxY(visibleRect))];
        if (firstRow < 0) firstRow = 0;
        NSInteger totalRows = [self rowCount];
        if (lastRow < 0 || lastRow >= totalRows) lastRow = totalRows - 1;

        NSInteger firstGroupIndex = [self groupIndexForRow:firstRow];
        NSInteger lastGroupIndex = [self groupIndexForRow:lastRow];

        for (NSInteger g = firstGroupIndex; g <= lastGroupIndex && g < (NSInteger)_groupStarts.count; g++) {
            NSInteger groupStartRow = [self rowForGroupHeader:g];
            CGFloat groupTop = [self yOffsetForRow:groupStartRow];
            CGFloat groupHeight = [self totalRowsInGroup:g] * _rowHeight;
            CGFloat headerOffset = _rowHeight;  // Style 1 has header rows

            // Fill only below the header row
            NSRect groupColRect = NSMakeRect(0, groupTop + headerOffset, _groupColumnWidth, groupHeight - headerOffset);
            if (NSIntersectsRect(groupColRect, dirtyRect)) {
                [[self backgroundColor] setFill];
                NSRectFill(NSIntersectionRect(groupColRect, dirtyRect));
            }
        }
    } else {
        // Styles 0, 2, 3: Fill entire group column with background
        NSRect groupColRect = NSMakeRect(0, NSMinY(visibleRect), _groupColumnWidth, visibleRect.size.height);
        if (NSIntersectsRect(groupColRect, dirtyRect)) {
            [[self backgroundColor] setFill];
            NSRectFill(NSIntersectionRect(groupColRect, dirtyRect));
        }
    }
}

// Draw album art for visible groups (called AFTER drawing row content)
- (void)drawAlbumArtInRect:(NSRect)dirtyRect firstRow:(NSInteger)firstRow lastRow:(NSInteger)lastRow {
    if (_groupStarts.count == 0) return;

    // Find which groups are visible
    NSInteger firstGroupIndex = [self groupIndexForRow:firstRow];
    NSInteger lastGroupIndex = [self groupIndexForRow:lastRow];

    CGFloat padding = 6;

    for (NSInteger g = firstGroupIndex; g <= lastGroupIndex && g < (NSInteger)_groupStarts.count; g++) {
        NSInteger groupStart = [_groupStarts[g] integerValue];

        // Calculate group's row range
        NSInteger groupStartRow = [self rowForGroupHeader:g];
        CGFloat groupTop = [self yOffsetForRow:groupStartRow];
        CGFloat groupHeight = [self totalRowsInGroup:g] * _rowHeight;

        // Style 0, 1: Album art is below header row
        // Style 2: Album art starts at header row Y (next to header text in content area)
        // Style 3: No header row, album art at group top
        CGFloat headerOffset = (_headerDisplayStyle == 0 || _headerDisplayStyle == 1) ? _rowHeight : 0;

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

        // Skip if rect not visible
        if (!NSIntersectsRect(artRect, dirtyRect)) continue;

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
        if (_headerDisplayStyle == 3) {
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
        y = count * _rowHeight;
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
    NSInteger firstRow = (NSInteger)floor(NSMinY(visibleRect) / _rowHeight);
    NSInteger lastRow = (NSInteger)ceil(NSMaxY(visibleRect) / _rowHeight);

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
        CGFloat y = row * _rowHeight;
        NSRect rowRect = NSMakeRect(_groupColumnWidth, y, self.bounds.size.width - _groupColumnWidth, _rowHeight);

        if (NSIntersectsRect(rowRect, dirtyRect)) {
            [self drawFlatModeRow:row inRect:rowRect];
        }
    }

    // Draw focus ring
    if (self.window.firstResponder == self && _focusIndex >= 0 && _focusIndex < _flatModeTrackCount) {
        CGFloat y = _focusIndex * _rowHeight;
        NSRect focusRect = NSMakeRect(_groupColumnWidth, y, self.bounds.size.width - _groupColumnWidth, _rowHeight);
        if (NSIntersectsRect(focusRect, dirtyRect)) {
            [self drawFocusRingForRect:focusRect];
        }
    }

    // Draw drop indicator if dragging
    if (_dropTargetRow >= 0) {
        CGFloat y = _dropTargetRow * _rowHeight;
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
        [[NSColor selectedContentBackgroundColor] setFill];
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
        [[NSColor selectedContentBackgroundColor] setFill];
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
        CGFloat groupTop = group.rowOffset * _rowHeight;
        CGFloat groupHeight = [group rowCount] * _rowHeight;
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
            [[NSColor selectedContentBackgroundColor] setFill];
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
    [[NSColor keyboardFocusIndicatorColor] setStroke];
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

- (NSColor *)backgroundColor {
    return [NSColor controlBackgroundColor];
}

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

#pragma mark - Selection Management

- (void)selectRowAtIndex:(NSInteger)index {
    [self selectRowAtIndex:index extendSelection:NO];
}

- (void)selectRowAtIndex:(NSInteger)index extendSelection:(BOOL)extend {
    NSInteger totalRows = [self rowCount];
    if (index < 0 || index >= totalRows) return;

    // Convert row to playlist index
    NSInteger playlistIndex = [self playlistIndexForRow:index];
    if (playlistIndex < 0) return;  // Don't select headers

    if (extend && _selectionAnchor >= 0) {
        // Range selection from anchor to clicked item
        NSInteger start = MIN(_selectionAnchor, playlistIndex);
        NSInteger end = MAX(_selectionAnchor, playlistIndex);
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndexesInRange:NSMakeRange(start, end - start + 1)];
    } else {
        // Single selection
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndex:playlistIndex];
        _selectionAnchor = playlistIndex;
    }

    _focusIndex = playlistIndex;
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)selectRowsInRange:(NSRange)range {
    [_selectedIndices addIndexesInRange:range];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)selectAll {
    // Select all playlist items (not row indices)
    if (_itemCount == 0) return;
    [_selectedIndices addIndexesInRange:NSMakeRange(0, _itemCount)];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)deselectAll {
    [_selectedIndices removeAllIndexes];
    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)toggleSelectionAtIndex:(NSInteger)index {
    NSInteger totalRows = [self rowCount];
    if (index < 0 || index >= totalRows) return;

    // Convert row to playlist index
    NSInteger playlistIndex = [self playlistIndexForRow:index];
    if (playlistIndex < 0) return;  // Don't select headers

    if ([_selectedIndices containsIndex:playlistIndex]) {
        [_selectedIndices removeIndex:playlistIndex];
    } else {
        [_selectedIndices addIndex:playlistIndex];
    }

    [self notifySelectionChanged];
    [self setNeedsDisplay:YES];
}

- (void)setFocusIndex:(NSInteger)index {
    // Focus index is a playlist index
    if (index < -1 || index >= _itemCount) return;
    _focusIndex = index;
    [self setNeedsDisplay:YES];
}

- (void)moveFocusBy:(NSInteger)delta extendSelection:(BOOL)extend {
    NSInteger totalRows = [self rowCount];
    if (totalRows == 0) return;

    // Convert current focus (playlist index) to row
    NSInteger currentRow = (_focusIndex >= 0) ? [self rowForPlaylistIndex:_focusIndex] : 0;
    if (currentRow < 0) currentRow = 0;

    // Move by delta rows
    NSInteger newRow = currentRow + delta;
    newRow = MAX(0, MIN(totalRows - 1, newRow));

    // Skip header/subgroup/padding rows when navigating
    NSInteger playlistIndex = [self playlistIndexForRow:newRow];
    NSInteger searchRow = newRow;
    while (playlistIndex < 0 && searchRow >= 0 && searchRow < totalRows) {
        searchRow += (delta > 0) ? 1 : -1;
        if (searchRow < 0 || searchRow >= totalRows) break;
        playlistIndex = [self playlistIndexForRow:searchRow];
    }

    // If we found a valid row, use it; otherwise try the opposite direction
    if (playlistIndex >= 0) {
        newRow = searchRow;
    } else {
        // Try opposite direction from original newRow
        searchRow = newRow;
        while (playlistIndex < 0 && searchRow >= 0 && searchRow < totalRows) {
            searchRow += (delta > 0) ? -1 : 1;  // Opposite direction
            if (searchRow < 0 || searchRow >= totalRows) break;
            playlistIndex = [self playlistIndexForRow:searchRow];
        }
        if (playlistIndex >= 0) {
            newRow = searchRow;
        }
    }

    if (playlistIndex < 0) return;  // Couldn't find a valid track in either direction

    if (extend) {
        // Extend selection from anchor to new focus
        if (_selectionAnchor < 0) {
            _selectionAnchor = _focusIndex >= 0 ? _focusIndex : playlistIndex;
        }
        NSInteger start = MIN(_selectionAnchor, playlistIndex);
        NSInteger end = MAX(_selectionAnchor, playlistIndex);
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndexesInRange:NSMakeRange(start, end - start + 1)];
    } else {
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndex:playlistIndex];
        _selectionAnchor = playlistIndex;
    }

    _focusIndex = playlistIndex;
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
    BOOL isInGroupColumn = (location.x < _groupColumnWidth && _groupColumnWidth > 0 && _groupStarts.count > 0);

    if (isGroupHeader || isInGroupColumn) {
        // Select all items in the group
        NSInteger groupIndex = [self groupIndexForRow:row];
        if (groupIndex >= 0) {
            NSRange range = [self playlistIndexRangeForGroup:groupIndex];
            if (range.location != NSNotFound && range.length > 0) {
                if (hasCmd) {
                    // Cmd+click on group: toggle group selection
                    BOOL allSelected = YES;
                    for (NSUInteger i = range.location; i < range.location + range.length; i++) {
                        if (![_selectedIndices containsIndex:i]) {
                            allSelected = NO;
                            break;
                        }
                    }
                    if (allSelected) {
                        [_selectedIndices removeIndexesInRange:range];
                    } else {
                        [_selectedIndices addIndexesInRange:range];
                    }
                } else if (hasShift && _selectionAnchor >= 0) {
                    // Shift+click: extend selection to include entire group
                    NSInteger groupStart = range.location;
                    NSInteger groupEnd = range.location + range.length - 1;
                    NSInteger start = MIN(_selectionAnchor, groupStart);
                    NSInteger end = MAX(_selectionAnchor, groupEnd);
                    [_selectedIndices removeAllIndexes];
                    [_selectedIndices addIndexesInRange:NSMakeRange(start, end - start + 1)];
                } else {
                    // Regular click: select all items in group
                    [_selectedIndices removeAllIndexes];
                    [_selectedIndices addIndexesInRange:range];
                    _selectionAnchor = range.location;
                }
                _focusIndex = range.location;
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
            _focusIndex = playlistIndex;
        }
        _pendingClickRow = -1;
    } else if (hasShift && _focusIndex >= 0) {
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

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragData
                                         requiringSecureCoding:NO
                                                         error:nil];

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setData:data forType:SimPlaylistPasteboardType];

    // Create dragging image
    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    // Use selection bounds as frame
    // Note: _selectedIndices contains playlist indices, need to convert to row indices
    __block NSRect selectionBounds = NSZeroRect;
    [_selectedIndices enumerateIndexesUsingBlock:^(NSUInteger playlistIdx, BOOL *stop) {
        NSInteger rowIdx = [self rowForPlaylistIndex:playlistIdx];
        if (rowIdx >= 0) {
            NSRect rowRect = [self rectForRow:rowIdx];
            if (NSIsEmptyRect(selectionBounds)) {
                selectionBounds = rowRect;
            } else {
                selectionBounds = NSUnionRect(selectionBounds, rowRect);
            }
        }
    }];

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

    dragItem.draggingFrame = NSMakeRect(location.x - 100, location.y - 15, 200, 30);
    dragItem.imageComponentsProvider = ^NSArray<NSDraggingImageComponent *> *{
        NSDraggingImageComponent *component = [[NSDraggingImageComponent alloc]
                                               initWithKey:NSDraggingImageComponentIconKey];
        component.contents = dragImage;
        component.frame = NSMakeRect(0, 0, 200, 30);
        return @[component];
    };

    [self beginDraggingSessionWithItems:@[dragItem] event:event source:self];
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
            [self moveFocusBy:-(_focusIndex + 1) extendSelection:hasShift];
            break;

        case NSEndFunctionKey:
            [self moveFocusBy:([self rowCount] - _focusIndex) extendSelection:hasShift];
            break;

        case ' ':  // Space - toggle selection at focus
            if (_focusIndex >= 0) {
                [self toggleSelectionAtIndex:_focusIndex];
            }
            break;

        case '\r':  // Enter - execute default action
            if (_focusIndex >= 0 && _focusIndex < _flatModeTrackCount &&
                [_delegate respondsToSelector:@selector(playlistView:didDoubleClickRow:)]) {
                [_delegate playlistView:self didDoubleClickRow:_focusIndex];
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
            } else {
                [super keyDown:event];
            }
            break;
    }
}

- (NSInteger)visibleRowCount {
    NSRect visible = [self visibleRect];
    return (NSInteger)(visible.size.height / _rowHeight);
}

#pragma mark - NSDraggingSource

- (NSDragOperation)draggingSession:(NSDraggingSession *)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    if (context == NSDraggingContextWithinApplication) {
        // Support both move and copy - destination decides based on modifier keys
        return NSDragOperationMove | NSDragOperationCopy;
    }
    return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    _isDragging = NO;
    _dropTargetRow = -1;
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

    FB2K_console_formatter() << "[SimPlaylist] draggingEntered, types: "
                             << ([pb.types containsObject:SimPlaylistPasteboardType] ? "SimPlaylist " : "")
                             << ([pb.types containsObject:NSPasteboardTypeFileURL] ? "FileURL" : "");

    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        // Option key = copy, otherwise move
        BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
        return optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;
    } else if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
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
        CGFloat posY = pos * _rowHeight;
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
    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        // Option key = copy, otherwise move
        BOOL optionKeyHeld = ([NSEvent modifierFlags] & NSEventModifierFlagOption) != 0;
        return optionKeyHeld ? NSDragOperationCopy : NSDragOperationMove;
    } else if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
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
    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        NSData *data = [pb dataForType:SimPlaylistPasteboardType];
        if (data) {
            // Unarchive drag data (dictionary with sourcePlaylist, indices, and paths)
            NSDictionary *dragData = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                                      [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSNumber class], [NSString class], nil]
                                                                         fromData:data
                                                                            error:nil];
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
        } else {
            // Fallback: read filenames directly (for media library which may not use file URLs)
            NSArray *filenames = [pb propertyListForType:NSFilenamesPboardType];
            if (filenames.count > 0) {
                NSMutableArray *fileURLs = [NSMutableArray array];
                for (NSString *path in filenames) {
                    [fileURLs addObject:[NSURL fileURLWithPath:path]];
                }
                if ([_delegate respondsToSelector:@selector(playlistView:didReceiveDroppedURLs:atRow:)]) {
                    [_delegate playlistView:self didReceiveDroppedURLs:fileURLs atRow:_dropTargetRow];
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
