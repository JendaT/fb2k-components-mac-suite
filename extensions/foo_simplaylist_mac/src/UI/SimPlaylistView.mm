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
@property (nonatomic, assign) NSInteger dropTargetRow;  // Row where items would be dropped
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

    // SPARSE GROUP MODEL - efficient O(G) storage
    _itemCount = 0;
    _groupStarts = @[];
    _groupHeaders = @[];
    _groupArtKeys = @[];
    _formattedValuesCache = [NSMutableDictionary dictionary];

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

    // PERFORMANCE: Enable layer-backed async drawing
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
    self.layer.drawsAsynchronously = YES;

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

- (void)reloadSettings {
    using namespace simplaylist_config;
    _rowHeight = getConfigInt(kRowHeight, kDefaultRowHeight);
    _headerHeight = getConfigInt(kHeaderHeight, kDefaultHeaderHeight);
    _subgroupHeight = getConfigInt(kSubgroupHeight, kDefaultSubgroupHeight);
    _groupColumnWidth = getConfigInt(kGroupColumnWidth, kDefaultGroupColumnWidth);

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
    NSSize contentSize = [self intrinsicContentSize];
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

// Returns total row count: itemCount + groupCount (each group adds 1 header row)
- (NSInteger)rowCount {
    // Total rows = items + headers + padding rows
    NSInteger totalPadding = 0;
    for (NSNumber *padding in _groupPaddingRows) {
        totalPadding += [padding integerValue];
    }
    return _itemCount + (NSInteger)_groupStarts.count + totalPadding;
}

// Helper: cumulative padding rows up to (but not including) group g
- (NSInteger)cumulativePaddingBeforeGroup:(NSInteger)groupIndex {
    if (groupIndex <= 0 || _groupPaddingRows.count == 0) return 0;
    NSInteger total = 0;
    for (NSInteger i = 0; i < groupIndex && i < (NSInteger)_groupPaddingRows.count; i++) {
        total += [_groupPaddingRows[i] integerValue];
    }
    return total;
}

// Helper: total rows in group g (header + tracks + padding)
- (NSInteger)totalRowsInGroup:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) return 0;
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    NSInteger trackCount = groupEnd - groupStart;
    NSInteger padding = (groupIndex < (NSInteger)_groupPaddingRows.count)
        ? [_groupPaddingRows[groupIndex] integerValue] : 0;
    return 1 + trackCount + padding;  // 1 header + tracks + padding
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

// Row number where group header appears
- (NSInteger)rowForGroupHeader:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) return -1;
    // Header row = groupStart[g] + g + cumulative padding from previous groups
    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    return [_groupStarts[groupIndex] integerValue] + groupIndex + cumulativePadding;
}

// Check if row is a group header
- (BOOL)isRowGroupHeader:(NSInteger)row {
    if (_groupStarts.count == 0) return NO;
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

    // Row is padding if it's after all tracks in the group
    return (rowWithinGroup > trackCount);
}

// Convert row to playlist index (-1 for header rows and padding rows)
- (NSInteger)playlistIndexForRow:(NSInteger)row {
    if (row < 0 || row >= [self rowCount]) return -1;
    if (_groupStarts.count == 0) return row;  // No groups = flat mode

    NSInteger groupIndex = [self groupIndexForRow:row];
    NSInteger headerRow = [self rowForGroupHeader:groupIndex];

    if (row == headerRow) {
        return -1;  // This is a header row
    }

    // Calculate position within group
    NSInteger rowWithinGroup = row - headerRow;  // 0 = header, 1+ = content

    // Get track count for this group
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    NSInteger trackCount = groupEnd - groupStart;

    // If row is beyond tracks, it's a padding row
    if (rowWithinGroup > trackCount) {
        return -1;  // Padding row
    }

    // Track row: playlist index = groupStart + (rowWithinGroup - 1)
    return groupStart + rowWithinGroup - 1;
}

// Convert playlist index to row
- (NSInteger)rowForPlaylistIndex:(NSInteger)playlistIndex {
    if (playlistIndex < 0 || playlistIndex >= _itemCount) return -1;
    if (_groupStarts.count == 0) return playlistIndex;  // No groups

    // Find which group this playlist index belongs to
    NSInteger groupIndex = 0;
    for (NSInteger g = (NSInteger)_groupStarts.count - 1; g >= 0; g--) {
        if ([_groupStarts[g] integerValue] <= playlistIndex) {
            groupIndex = g;
            break;
        }
    }

    // Row = playlist index + headers + cumulative padding from previous groups
    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    return playlistIndex + groupIndex + 1 + cumulativePadding;
}

// Clear formatted values cache (call when playlist changes)
- (void)clearFormattedValuesCache {
    [_formattedValuesCache removeAllObjects];
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

    // No separate background for album art column - it uses same background as rows

    // Draw only visible rows (typically ~30 rows)
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        NSRect rowRect = [self rectForRow:row];
        if (NSIntersectsRect(rowRect, dirtyRect)) {
            [self drawSparseRow:row inRect:rowRect];
        }
    }

    // Draw album art in group column for visible groups
    if (_groupColumnWidth > 0 && _groupStarts.count > 0) {
        [self drawSparseGroupColumnInRect:dirtyRect firstRow:firstRow lastRow:lastRow];
    }

    // Draw focus ring
    if (self.window.firstResponder == self && _focusIndex >= 0) {
        NSInteger focusRow = [self rowForPlaylistIndex:_focusIndex];
        if (focusRow >= firstRow && focusRow <= lastRow) {
            NSRect focusRect = [self rectForRow:focusRow];
            [self drawFocusRingForRect:focusRect];
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
    BOOL isPadding = [self isRowPaddingRow:row];
    NSInteger playlistIndex = (isHeader || isPadding) ? -1 : [self playlistIndexForRow:row];

    // Padding rows are empty - just return (background already drawn)
    if (isPadding) {
        return;
    }

    // Check selection and playing state
    BOOL isSelected = (playlistIndex >= 0 && [_selectedIndices containsIndex:playlistIndex]);
    BOOL isPlaying = (playlistIndex >= 0 && playlistIndex == _playingIndex);

    // Selection/playing background - only in columns area, not album art column
    if (isSelected || isPlaying) {
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
    } else {
        [self drawSparseTrackRow:playlistIndex inRect:rect selected:isSelected];
    }
}

// Draw group header row - just text with centered horizontal line
- (void)drawSparseHeaderRow:(NSInteger)groupIndex inRect:(NSRect)rect {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupHeaders.count) return;

    NSString *headerText = _groupHeaders[groupIndex];

    // Header text attributes
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont boldSystemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };

    // Calculate text size
    NSSize textSize = [headerText sizeWithAttributes:attrs];
    CGFloat textX = _groupColumnWidth + 8;
    CGFloat textY = rect.origin.y + (rect.size.height - textSize.height) / 2;

    // Draw header text
    [headerText drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];

    // Draw horizontal line after text (centered vertically)
    CGFloat lineY = rect.origin.y + rect.size.height / 2;
    CGFloat lineStartX = textX + textSize.width + 12;
    CGFloat lineEndX = rect.size.width - 8;

    if (lineStartX < lineEndX) {
        [[NSColor separatorColor] setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(lineStartX, lineY)];
        [line lineToPoint:NSMakePoint(lineEndX, lineY)];
        line.lineWidth = 1.0;
        [line stroke];
    }
}

// Draw track row with lazy column formatting
- (void)drawSparseTrackRow:(NSInteger)playlistIndex inRect:(NSRect)rect selected:(BOOL)selected {
    if (playlistIndex < 0) return;

    // Get cached column values or request from delegate
    NSArray<NSString *> *columnValues = _formattedValuesCache[@(playlistIndex)];
    if (!columnValues && [_delegate respondsToSelector:@selector(playlistView:columnValuesForPlaylistIndex:)]) {
        columnValues = [_delegate playlistView:self columnValuesForPlaylistIndex:playlistIndex];
        if (columnValues) {
            _formattedValuesCache[@(playlistIndex)] = columnValues;
        }
    }

    // Draw columns
    CGFloat x = _groupColumnWidth;
    NSColor *textColor = selected ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor];
    NSFont *font = [NSFont systemFontOfSize:12];

    for (NSUInteger colIndex = 0; colIndex < _columns.count; colIndex++) {
        ColumnDefinition *col = _columns[colIndex];
        NSRect colRect = NSMakeRect(x + 4, rect.origin.y + 2,
                                    col.width - 8, rect.size.height - 4);

        NSString *value = (colIndex < columnValues.count) ? columnValues[colIndex] : @"";

        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        switch (col.alignment) {
            case ColumnAlignmentCenter: style.alignment = NSTextAlignmentCenter; break;
            case ColumnAlignmentRight: style.alignment = NSTextAlignmentRight; break;
            default: style.alignment = NSTextAlignmentLeft; break;
        }

        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: textColor,
            NSParagraphStyleAttributeName: style
        };

        [value drawInRect:colRect withAttributes:attrs];
        x += col.width;
    }
}

// Draw album art in group column for visible groups
- (void)drawSparseGroupColumnInRect:(NSRect)dirtyRect firstRow:(NSInteger)firstRow lastRow:(NSInteger)lastRow {
    if (_groupStarts.count == 0) return;

    // First, paint the entire group column area with background to prevent row selection bleeding through
    NSRect visibleRect = [self visibleRect];
    NSRect groupColRect = NSMakeRect(0, NSMinY(visibleRect), _groupColumnWidth, visibleRect.size.height);
    if (NSIntersectsRect(groupColRect, dirtyRect)) {
        [[self backgroundColor] setFill];
        NSRectFill(NSIntersectionRect(groupColRect, dirtyRect));
    }

    // Find which groups are visible
    NSInteger firstGroupIndex = [self groupIndexForRow:firstRow];
    NSInteger lastGroupIndex = [self groupIndexForRow:lastRow];

    CGFloat padding = 6;

    for (NSInteger g = firstGroupIndex; g <= lastGroupIndex && g < (NSInteger)_groupStarts.count; g++) {
        NSInteger groupStart = [_groupStarts[g] integerValue];

        // Calculate group's row range (now includes padding rows for minimum height)
        NSInteger headerRow = [self rowForGroupHeader:g];
        CGFloat groupTop = [self yOffsetForRow:headerRow];
        CGFloat groupHeight = [self totalRowsInGroup:g] * _rowHeight;  // header + tracks + padding

        // Calculate available height for album art (below header, minus padding)
        CGFloat availableHeight = groupHeight - _rowHeight - padding * 2;

        // Use configured size, bounded only by available height (NOT by column width)
        // This allows the album art to extend beyond the column if needed
        CGFloat artSize = MIN(_albumArtSize, availableHeight);
        artSize = MAX(artSize, 32);  // Minimum 32px

        // Album art at TOP of group, centered horizontally in column
        CGFloat artY = groupTop + _rowHeight + padding;  // Below header row
        CGFloat artX = (_groupColumnWidth - artSize) / 2;  // Center horizontally
        if (artX < padding) artX = padding;  // But not less than padding from left edge
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

        // No selection indicator on album art column - cleaner look
    }
}

- (void)drawDropIndicatorAtRow:(NSInteger)row {
    CGFloat y;
    NSInteger count = [self rowCount];
    if (row >= count) {
        // Drop at end
        if (_flatModeEnabled) {
            y = count * _rowHeight;
        } else if (_nodes.count > 0) {
            y = [self yOffsetForRow:_nodes.count - 1] + [self heightForNode:_nodes.lastObject];
        } else {
            y = 0;
        }
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
    } else if (isPlaying) {
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
    } else if (isPlaying) {
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
    if (isSelected || isPlaying) {
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
    NSRect textRect = NSInsetRect(rect, 4, 2);

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

    // Use 13pt system font to match standard list appearance
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: selected ? [NSColor selectedMenuItemTextColor] : [NSColor labelColor],
        NSParagraphStyleAttributeName: style
    };

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

    // Skip header rows when navigating
    NSInteger playlistIndex = [self playlistIndexForRow:newRow];
    while (playlistIndex < 0 && newRow >= 0 && newRow < totalRows) {
        newRow += (delta > 0) ? 1 : -1;
        if (newRow < 0 || newRow >= totalRows) break;
        playlistIndex = [self playlistIndexForRow:newRow];
    }

    if (playlistIndex < 0) return;  // Couldn't find a valid track

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

    if (hasCmd) {
        // Cmd+click: toggle selection
        [self toggleSelectionAtIndex:row];
        _focusIndex = row;
    } else if (hasShift && _focusIndex >= 0) {
        // Shift+click: extend selection
        [self selectRowAtIndex:row extendSelection:YES];
    } else {
        // Regular click: select only this row
        [self selectRowAtIndex:row extendSelection:NO];
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

    // Only drag if there's a selection
    if (_selectedIndices.count == 0) return;

    // Create dragging item with selected row indices
    NSMutableArray<NSNumber *> *rowNumbers = [NSMutableArray array];
    [_selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [rowNumbers addObject:@(idx)];
    }];

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:rowNumbers
                                         requiringSecureCoding:NO
                                                         error:nil];

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setData:data forType:SimPlaylistPasteboardType];

    // Create dragging image
    NSDraggingItem *dragItem = [[NSDraggingItem alloc] initWithPasteboardWriter:pbItem];

    // Use selection bounds as frame
    __block NSRect selectionBounds = NSZeroRect;
    [_selectedIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        NSRect rowRect = [self rectForRow:idx];
        if (NSIsEmptyRect(selectionBounds)) {
            selectionBounds = rowRect;
        } else {
            selectionBounds = NSUnionRect(selectionBounds, rowRect);
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
    if (row >= 0 && ![_selectedIndices containsIndex:row]) {
        [self selectRowAtIndex:row];
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
        return NSDragOperationMove;
    }
    return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session
           endedAtPoint:(NSPoint)screenPoint
              operation:(NSDragOperation)operation {
    _isDragging = NO;
    _dropTargetRow = -1;
    [self setNeedsDisplay:YES];
}

#pragma mark - NSDraggingDestination

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];

    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        return NSDragOperationMove;
    } else if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
    }
    return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    NSPoint location = [self convertPoint:[sender draggingLocation] fromView:nil];
    NSInteger targetRow = [self rowAtPoint:location];

    // Calculate drop position (before which row)
    if (targetRow < 0) {
        // At the end if below all rows
        _dropTargetRow = [self rowCount];
    } else {
        // Determine if we're in top or bottom half of the row
        NSRect rowRect = [self rectForRow:targetRow];
        CGFloat midY = NSMidY(rowRect);
        if (location.y < midY) {
            _dropTargetRow = targetRow;
        } else {
            _dropTargetRow = targetRow + 1;
        }
    }

    [self setNeedsDisplay:YES];

    NSPasteboard *pb = [sender draggingPasteboard];
    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        return NSDragOperationMove;
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

    // Internal reorder
    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        NSData *data = [pb dataForType:SimPlaylistPasteboardType];
        if (data) {
            NSArray<NSNumber *> *rowNumbers = [NSKeyedUnarchiver unarchivedObjectOfClasses:
                                               [NSSet setWithObjects:[NSArray class], [NSNumber class], nil]
                                                                                  fromData:data
                                                                                     error:nil];
            if (rowNumbers && rowNumbers.count > 0) {
                NSMutableIndexSet *sourceRows = [NSMutableIndexSet indexSet];
                for (NSNumber *num in rowNumbers) {
                    [sourceRows addIndex:[num unsignedIntegerValue]];
                }

                if ([_delegate respondsToSelector:@selector(playlistView:didReorderRows:toRow:)]) {
                    [_delegate playlistView:self didReorderRows:sourceRows toRow:_dropTargetRow];
                }
            }
        }
        _dropTargetRow = -1;
        [self setNeedsDisplay:YES];
        return YES;
    }

    // File drop from Finder
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

    _dropTargetRow = -1;
    [self setNeedsDisplay:YES];
    return NO;
}

- (void)concludeDragOperation:(id<NSDraggingInfo>)sender {
    _dropTargetRow = -1;
    [self setNeedsDisplay:YES];
}

@end
