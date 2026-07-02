//
//  PlaylistSelectionModel.mm
//  foo_simplaylist_mac
//
//  Pure selection state machine — see PlaylistSelectionModel.h.
//  Algorithms moved verbatim from SimPlaylistView; behavior is unchanged.
//

#import "PlaylistSelectionModel.h"
#import "PlaylistLayoutModel.h"

@implementation PlaylistSelectionModel

- (instancetype)initWithLayout:(PlaylistLayoutModel *)layout {
    self = [super init];
    if (self) {
        _layout = layout;
        _selectedIndices = [NSMutableIndexSet indexSet];
        _focusIndex = -1;
        _anchorIndex = -1;
    }
    return self;
}

- (void)selectPlaylistIndex:(NSInteger)playlistIndex extendFromAnchor:(BOOL)extend {
    if (extend && _anchorIndex >= 0) {
        // Range selection from anchor to clicked item
        NSInteger start = MIN(_anchorIndex, playlistIndex);
        NSInteger end = MAX(_anchorIndex, playlistIndex);
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndexesInRange:NSMakeRange(start, end - start + 1)];
    } else {
        // Single selection
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndex:playlistIndex];
        _anchorIndex = playlistIndex;
    }
    _focusIndex = playlistIndex;
}

- (void)togglePlaylistIndex:(NSInteger)playlistIndex {
    if ([_selectedIndices containsIndex:playlistIndex]) {
        [_selectedIndices removeIndex:playlistIndex];
    } else {
        [_selectedIndices addIndex:playlistIndex];
    }
}

- (void)addIndexesInRange:(NSRange)range {
    [_selectedIndices addIndexesInRange:range];
}

- (void)selectAll {
    NSInteger itemCount = _layout.itemCount;
    if (itemCount == 0) return;
    [_selectedIndices addIndexesInRange:NSMakeRange(0, itemCount)];
}

- (void)deselectAll {
    [_selectedIndices removeAllIndexes];
}

- (void)clickGroupRange:(NSRange)range commandKey:(BOOL)hasCmd shiftKey:(BOOL)hasShift {
    if (range.location == NSNotFound || range.length == 0) return;

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
    } else if (hasShift && _anchorIndex >= 0) {
        // Shift+click: extend selection to include entire group
        NSInteger groupStart = range.location;
        NSInteger groupEnd = range.location + range.length - 1;
        NSInteger start = MIN(_anchorIndex, groupStart);
        NSInteger end = MAX(_anchorIndex, groupEnd);
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndexesInRange:NSMakeRange(start, end - start + 1)];
    } else {
        // Regular click: select all items in group
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndexesInRange:range];
        _anchorIndex = range.location;
    }
    _focusIndex = range.location;
}

- (NSInteger)moveFocusBy:(NSInteger)delta extendSelection:(BOOL)extend {
    NSInteger totalRows = [_layout rowCount];
    if (totalRows == 0) return -1;

    // Convert current focus (playlist index) to row
    NSInteger currentRow = (_focusIndex >= 0) ? [_layout rowForPlaylistIndex:_focusIndex] : 0;
    if (currentRow < 0) currentRow = 0;

    // Move by delta rows
    NSInteger newRow = currentRow + delta;
    newRow = MAX(0, MIN(totalRows - 1, newRow));

    // Skip header/subgroup/padding rows when navigating
    NSInteger playlistIndex = [_layout playlistIndexForRow:newRow];
    NSInteger searchRow = newRow;
    while (playlistIndex < 0 && searchRow >= 0 && searchRow < totalRows) {
        searchRow += (delta > 0) ? 1 : -1;
        if (searchRow < 0 || searchRow >= totalRows) break;
        playlistIndex = [_layout playlistIndexForRow:searchRow];
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
            playlistIndex = [_layout playlistIndexForRow:searchRow];
        }
        if (playlistIndex >= 0) {
            newRow = searchRow;
        }
    }

    if (playlistIndex < 0) return -1;  // Couldn't find a valid track in either direction

    if (extend) {
        // Extend selection from anchor to new focus
        if (_anchorIndex < 0) {
            _anchorIndex = _focusIndex >= 0 ? _focusIndex : playlistIndex;
        }
        NSInteger start = MIN(_anchorIndex, playlistIndex);
        NSInteger end = MAX(_anchorIndex, playlistIndex);
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndexesInRange:NSMakeRange(start, end - start + 1)];
    } else {
        [_selectedIndices removeAllIndexes];
        [_selectedIndices addIndex:playlistIndex];
        _anchorIndex = playlistIndex;
    }

    _focusIndex = playlistIndex;
    return newRow;
}

@end
