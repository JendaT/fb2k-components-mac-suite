//
//  SimPlaylistHeaderBar.mm
//  foo_simplaylist_mac
//

#import "SimPlaylistHeaderBar.h"
#import "../Core/ColumnDefinition.h"

// Column-index sentinels shared by the hit-test methods and the gesture state.
// The group (album art) column is not part of _columns, so it has no index of
// its own and is reported with its own sentinel.
static const NSInteger kNoColumn = -1;
static const NSInteger kGroupColumn = -2;

@interface SimPlaylistHeaderBar ()
@property (nonatomic, assign) CGFloat scrollOffset;
@property (nonatomic, assign) NSInteger resizingColumn;      // kNoColumn if not resizing
@property (nonatomic, assign) CGFloat resizeStartX;
@property (nonatomic, assign) CGFloat resizeStartWidth;
@property (nonatomic, assign) NSInteger draggingColumn;      // kNoColumn if not dragging
@property (nonatomic, assign) CGFloat dragStartX;
@property (nonatomic, assign) NSInteger dropTargetIndex;
@property (nonatomic, assign) NSInteger hoveredColumn;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@property (nonatomic, strong, nullable) NSDictionary *headerTextAttrs;
@property (nonatomic, assign) fb2k_ui::SizeVariant headerTextAttrsSize;
@property (nonatomic, assign) BOOL resizeCursorShown;
@end

@implementation SimPlaylistHeaderBar

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
    _columns = @[];
    _groupColumnWidth = 80;
    _scrollOffset = 0;
    _resizingColumn = kNoColumn;
    _draggingColumn = kNoColumn;
    _dropTargetIndex = kNoColumn;
    _hoveredColumn = kNoColumn;
}

// Single place where a live gesture is invalidated. The column array is
// replaced from settings reloads and from the controller's own persist path,
// which can happen mid-drag: indices captured on mouseDown would then address
// a different column or run off the end.
- (void)setColumns:(NSArray<ColumnDefinition *> *)columns {
    _columns = columns;

    if (_resizingColumn >= 0) {
        // Balances the push in mouseDown:; the group-column resize (kGroupColumn)
        // does not depend on the array and is left running.
        [NSCursor pop];
        _resizingColumn = kNoColumn;
        _resizeCursorShown = NO;
    }
    if (_draggingColumn >= 0) {
        _draggingColumn = kNoColumn;
        _dropTargetIndex = kNoColumn;
    }
    _hoveredColumn = kNoColumn;

    [self setNeedsDisplay:YES];
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setScrollOffset:(CGFloat)offset {
    // Vertical scrolling fires bounds-change notifications too; skip the
    // redraw when the horizontal offset did not actually change.
    if (_scrollOffset == offset) return;
    _scrollOffset = offset;
    [self setNeedsDisplay:YES];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];

    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }

    _trackingArea = [[NSTrackingArea alloc]
                     initWithRect:self.bounds
                          options:(NSTrackingMouseMoved |
                                   NSTrackingMouseEnteredAndExited |
                                   NSTrackingActiveInKeyWindow |
                                   NSTrackingInVisibleRect)
                            owner:self
                         userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

#pragma mark - Layout

- (CGFloat)xOffsetForColumn:(NSInteger)columnIndex {
    CGFloat x = _groupColumnWidth + _decorationGutterWidth - _scrollOffset;
    for (NSInteger i = 0; i < columnIndex && i < (NSInteger)_columns.count; i++) {
        x += _columns[i].width;
    }
    return x;
}

- (NSInteger)columnAtX:(CGFloat)x {
    // drawRect: clips cells to x >= _groupColumnWidth. Without the same bound
    // here, a column scrolled behind the album-art strip stays hit-testable and
    // clicking the visually empty group-column header starts its drag/reorder.
    if (x < _groupColumnWidth) {
        return kNoColumn;
    }

    CGFloat currentX = _groupColumnWidth + _decorationGutterWidth - _scrollOffset;

    for (NSInteger i = 0; i < (NSInteger)_columns.count; i++) {
        CGFloat colWidth = _columns[i].width;
        if (x >= currentX && x < currentX + colWidth) {
            return i;
        }
        currentX += colWidth;
    }
    return kNoColumn;
}

// Returns kGroupColumn for the group column resize handle, kNoColumn for none, >=0 for a regular column
- (NSInteger)resizeHandleAtX:(CGFloat)x {
    // Check group column resize handle first (right edge of group column)
    if (_groupColumnWidth > 0) {
        CGFloat groupHandleX = _groupColumnWidth - fb2k_ui::kResizeHandleWidth / 2;
        if (x >= groupHandleX && x <= groupHandleX + fb2k_ui::kResizeHandleWidth) {
            return kGroupColumn;  // Special value for group column
        }
    }

    CGFloat currentX = _groupColumnWidth + _decorationGutterWidth - _scrollOffset;

    for (NSInteger i = 0; i < (NSInteger)_columns.count; i++) {
        CGFloat colWidth = _columns[i].width;
        CGFloat handleX = currentX + colWidth - fb2k_ui::kResizeHandleWidth / 2;

        // Handles scrolled entirely behind the album-art strip are not drawn,
        // so they must not be grabbable either.
        if (handleX + fb2k_ui::kResizeHandleWidth >= _groupColumnWidth &&
            x >= handleX && x <= handleX + fb2k_ui::kResizeHandleWidth) {
            return i;
        }
        currentX += colWidth;
    }
    return kNoColumn;
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGFloat width = self.bounds.size.width;
    CGFloat height = fb2k_ui::headerHeight(_headerSize);

    // Background - use glass-aware colors (returns nil for full transparency, semi-opaque for accessibility)
    NSColor *bgColor = _glassBackground
        ? fb2k_ui::headerBackgroundColorForGlass(_accentMode)
        : fb2k_ui::headerBackgroundColor(_accentMode);
    if (bgColor) {
        [bgColor setFill];
        NSRectFill(self.bounds);
    }

    // Top highlight line (subtle lighter edge like native headers)
    NSColor *highlight = _glassBackground
        ? fb2k_ui::headerTopHighlightColorForGlass(_accentMode)
        : fb2k_ui::headerTopHighlightColor(_accentMode);
    if (highlight) {
        [highlight setFill];
        NSRectFill(NSMakeRect(0, 0, width, 1));
    }

    // Group column area is empty (no header cell needed)
    // Just draw a subtle separator at the right edge
    if (_groupColumnWidth > 0) {
        [fb2k_ui::headerDividerColor() setFill];
        NSRectFill(NSMakeRect(_groupColumnWidth - 1, 5, 1, height - 10));
    }

    // Draw column headers - start right after group column
    CGFloat x = _groupColumnWidth + _decorationGutterWidth - _scrollOffset;

    for (NSInteger i = 0; i < (NSInteger)_columns.count; i++) {
        ColumnDefinition *col = _columns[i];
        NSRect colRect = NSMakeRect(x, 0, col.width, height);

        // Only draw if visible
        if (NSMaxX(colRect) > _groupColumnWidth && NSMinX(colRect) < self.bounds.size.width) {
            // Clip to after group column
            if (NSMinX(colRect) < _groupColumnWidth) {
                CGFloat clipAmount = _groupColumnWidth - NSMinX(colRect);
                colRect.origin.x = _groupColumnWidth;
                colRect.size.width -= clipAmount;
            }

            BOOL isHighlighted = (i == _hoveredColumn);
            BOOL isDragging = (i == _draggingColumn);

            if (!isDragging) {
                [self drawHeaderCell:col.name inRect:colRect highlighted:isHighlighted];
            }

            // Draw column divider
            [fb2k_ui::headerDividerColor() setFill];
            NSRectFill(NSMakeRect(x + col.width - 1, 5, 1, height - 10));
        }

        x += col.width;
    }

    // Draw drop indicator during drag
    if (_draggingColumn >= 0 && _dropTargetIndex >= 0) {
        CGFloat indicatorX = [self xOffsetForColumn:_dropTargetIndex];
        [fb2k_ui::focusRingColor() setFill];
        NSRectFill(NSMakeRect(indicatorX - 1, 0, 3, height));
    }

    // Draw dragged column overlay
    if (_draggingColumn >= 0 && _draggingColumn < (NSInteger)_columns.count) {
        ColumnDefinition *dragCol = _columns[_draggingColumn];
        CGFloat dragX = _dragStartX - _scrollOffset;
        NSRect dragRect = NSMakeRect(dragX, 0, dragCol.width, height);

        // Semi-transparent background
        [[fb2k_ui::headerBackgroundColor(_accentMode) colorWithAlphaComponent:0.9] setFill];
        NSRectFill(dragRect);

        [self drawHeaderCell:dragCol.name inRect:dragRect highlighted:YES];

        // Border
        [fb2k_ui::focusRingColor() setStroke];
        NSBezierPath *borderPath = [NSBezierPath bezierPathWithRect:NSInsetRect(dragRect, 0.5, 0.5)];
        [borderPath stroke];
    }

    // Bottom border (darker separator line)
    [fb2k_ui::headerBottomBorderColor() setFill];
    NSRectFill(NSMakeRect(0, height - 1, width, 1));
}

- (void)drawHeaderCell:(NSString *)title inRect:(NSRect)rect highlighted:(BOOL)highlighted {
    if (highlighted) {
        [[[NSColor labelColor] colorWithAlphaComponent:0.06] setFill];
        NSRectFill(rect);
    }

    // Native header: 4px left padding, text vertically centered
    NSRect textRect = rect;
    textRect.origin.x += 4;
    textRect.size.width -= 8;  // 4px each side

    // Rebuilt only when the header size changes: drawRect: reaches this method
    // once per column per frame, on a live resize/drag path. The stored colour
    // is a dynamic system colour, so appearance changes still resolve at draw
    // time without a rebuild.
    if (!_headerTextAttrs || _headerTextAttrsSize != _headerSize) {
        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineBreakMode = NSLineBreakByTruncatingTail;
        _headerTextAttrs = @{
            NSFontAttributeName: fb2k_ui::headerFont(_headerSize),
            NSForegroundColorAttributeName: fb2k_ui::headerTextColor(),
            NSParagraphStyleAttributeName: style
        };
        _headerTextAttrsSize = _headerSize;
    }
    NSDictionary *attrs = _headerTextAttrs;

    // Calculate vertical centering
    NSSize textSize = [title sizeWithAttributes:attrs];
    CGFloat yOffset = (rect.size.height - textSize.height) / 2.0;
    textRect.origin.y = yOffset;
    textRect.size.height = textSize.height;

    [title drawInRect:textRect withAttributes:attrs];
}

#pragma mark - Mouse Events

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Check for resize handle first
    NSInteger resizeHandle = [self resizeHandleAtX:location.x];
    if (resizeHandle == kGroupColumn) {
        // Group column resize
        _resizingColumn = kGroupColumn;
        _resizeStartX = location.x;
        _resizeStartWidth = _groupColumnWidth;
        [[NSCursor resizeLeftRightCursor] push];
        return;
    } else if (resizeHandle >= 0) {
        _resizingColumn = resizeHandle;
        _resizeStartX = location.x;
        _resizeStartWidth = _columns[resizeHandle].width;
        [[NSCursor resizeLeftRightCursor] push];
        return;
    }

    // Check for column header click
    NSInteger column = [self columnAtX:location.x];
    if (column >= 0) {
        _draggingColumn = column;
        _dragStartX = [self xOffsetForColumn:column] + _scrollOffset;
        _dropTargetIndex = kNoColumn;
    }
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    if (_resizingColumn == kGroupColumn) {
        // Resizing group column
        CGFloat delta = location.x - _resizeStartX;
        CGFloat newWidth = MAX(40, MIN(300, _resizeStartWidth + delta));  // Clamp 40-300

        _groupColumnWidth = newWidth;

        if ([_delegate respondsToSelector:@selector(headerBar:didResizeGroupColumnToWidth:)]) {
            [_delegate headerBar:self didResizeGroupColumnToWidth:newWidth];
        }

        [self setNeedsDisplay:YES];

    } else if (_resizingColumn >= 0) {
        // The column list can be replaced mid-gesture (settings reload); a
        // stale index would go out of range.
        if (_resizingColumn >= (NSInteger)_columns.count) {
            _resizingColumn = kNoColumn;
            [NSCursor pop];
            return;
        }

        // Resizing regular column
        CGFloat delta = location.x - _resizeStartX;
        CGFloat newWidth = MAX(40, _resizeStartWidth + delta);  // Min width 40

        ColumnDefinition *col = _columns[_resizingColumn];
        col.width = newWidth;

        if ([_delegate respondsToSelector:@selector(headerBar:didResizeColumn:toWidth:)]) {
            [_delegate headerBar:self didResizeColumn:_resizingColumn toWidth:newWidth];
        }

        [self setNeedsDisplay:YES];

    } else if (_draggingColumn >= 0) {
        // Same stale-index concern as the resize branch above.
        if (_draggingColumn >= (NSInteger)_columns.count) {
            _draggingColumn = kNoColumn;
            _dropTargetIndex = kNoColumn;
            return;
        }

        // Dragging column for reorder
        CGFloat dragDelta = location.x - ([self xOffsetForColumn:_draggingColumn]);
        _dragStartX = [self xOffsetForColumn:_draggingColumn] + _scrollOffset + dragDelta;

        // Calculate drop target
        _dropTargetIndex = [self columnAtX:location.x];
        if (_dropTargetIndex < 0) {
            // Off the end
            if (location.x > [self xOffsetForColumn:_columns.count - 1]) {
                _dropTargetIndex = _columns.count;
            } else {
                _dropTargetIndex = 0;
            }
        }

        [self setNeedsDisplay:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    if (_resizingColumn == kGroupColumn) {
        // Finished resizing group column
        [NSCursor pop];

        if ([_delegate respondsToSelector:@selector(headerBar:didFinishResizingGroupColumn:)]) {
            [_delegate headerBar:self didFinishResizingGroupColumn:_groupColumnWidth];
        }

        _resizingColumn = kNoColumn;

    } else if (_resizingColumn >= 0) {
        [NSCursor pop];

        if (_resizingColumn < (NSInteger)_columns.count &&
            [_delegate respondsToSelector:@selector(headerBar:didFinishResizingColumn:)]) {
            [_delegate headerBar:self didFinishResizingColumn:_resizingColumn];
        }

        _resizingColumn = kNoColumn;

    } else if (_draggingColumn >= 0) {
        if (_draggingColumn < (NSInteger)_columns.count &&
            _dropTargetIndex >= 0 && _dropTargetIndex != _draggingColumn &&
            _dropTargetIndex != _draggingColumn + 1) {
            // Reorder columns
            if ([_delegate respondsToSelector:@selector(headerBar:didReorderColumnFrom:to:)]) {
                [_delegate headerBar:self didReorderColumnFrom:_draggingColumn to:_dropTargetIndex];
            }
        } else {
            // Just a click, not a drag
            NSInteger clickedColumn = [self columnAtX:location.x];
            if (clickedColumn >= 0 && clickedColumn == _draggingColumn) {
                if ([_delegate respondsToSelector:@selector(headerBar:didClickColumn:)]) {
                    [_delegate headerBar:self didClickColumn:clickedColumn];
                }
            }
        }

        _draggingColumn = kNoColumn;
        _dropTargetIndex = kNoColumn;
        [self setNeedsDisplay:YES];
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint windowPoint = event.locationInWindow;
    NSPoint screenPoint = [[self window] convertPointToScreen:windowPoint];

    if ([_delegate respondsToSelector:@selector(headerBar:showColumnMenuAtPoint:)]) {
        [_delegate headerBar:self showColumnMenuAtPoint:screenPoint];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];

    // Update cursor for resize handles. mouseMoved: fires at 60-120 Hz, so only
    // touch the cursor on a transition; resetCursorRects already registers the
    // steady-state shapes.
    NSInteger resizeHandle = [self resizeHandleAtX:location.x];
    BOOL wantsResizeCursor = (resizeHandle == kGroupColumn || resizeHandle >= 0);
    if (wantsResizeCursor != _resizeCursorShown) {
        _resizeCursorShown = wantsResizeCursor;
        if (wantsResizeCursor) {
            [[NSCursor resizeLeftRightCursor] set];
        } else {
            [[NSCursor arrowCursor] set];
        }
    }

    // Update hovered column
    NSInteger newHovered = [self columnAtX:location.x];
    if (newHovered != _hoveredColumn) {
        _hoveredColumn = newHovered;
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseExited:(NSEvent *)event {
    [[NSCursor arrowCursor] set];
    _resizeCursorShown = NO;
    if (_hoveredColumn >= 0) {
        _hoveredColumn = kNoColumn;
        [self setNeedsDisplay:YES];
    }
}

- (void)resetCursorRects {
    [super resetCursorRects];

    // Group column resize handle
    if (_groupColumnWidth > 0) {
        NSRect groupHandleRect = NSMakeRect(_groupColumnWidth - fb2k_ui::kResizeHandleWidth / 2, 0,
                                            fb2k_ui::kResizeHandleWidth, fb2k_ui::headerHeight(_headerSize));
        [self addCursorRect:groupHandleRect cursor:[NSCursor resizeLeftRightCursor]];
    }

    CGFloat x = _groupColumnWidth + _decorationGutterWidth - _scrollOffset;

    for (NSInteger i = 0; i < (NSInteger)_columns.count; i++) {
        CGFloat colWidth = _columns[i].width;
        NSRect handleRect = NSMakeRect(x + colWidth - fb2k_ui::kResizeHandleWidth / 2, 0,
                                       fb2k_ui::kResizeHandleWidth, fb2k_ui::headerHeight(_headerSize));
        // Mirrors the bound in resizeHandleAtX:: handles hidden behind the
        // album-art strip must not offer a resize cursor.
        if (NSMaxX(handleRect) >= _groupColumnWidth) {
            [self addCursorRect:handleRect cursor:[NSCursor resizeLeftRightCursor]];
        }
        x += colWidth;
    }
}

@end
