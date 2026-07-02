//
//  PlaylistLayoutModel.mm
//  foo_simplaylist_mac
//
//  Pure geometry/index model — see PlaylistLayoutModel.h.
//  Algorithms moved verbatim from SimPlaylistView; behavior is unchanged.
//

#import "PlaylistLayoutModel.h"

@implementation PlaylistLayoutModel

- (instancetype)init {
    self = [super init];
    if (self) {
        _itemCount = 0;
        _groupStarts = @[];
        _groupPaddingRows = @[];
        _totalPaddingRowsCached = 0;
        _cumulativePaddingCache = @[];
        _subgroupStarts = @[];
        _subgroupHeaders = @[];
        _subgroupCountPerGroup = @[];
        _subgroupRowSet = [NSIndexSet indexSet];
        _subgroupRowToIndex = @{};
        _headerDisplayStyle = 0;
        _rowHeight = 22;
        _headerHeight = 28;
    }
    return self;
}

#pragma mark - Cache rebuilds

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

- (void)rebuildSubgroupRowCache {
    if (_subgroupStarts.count == 0) {
        _subgroupRowSet = [NSIndexSet indexSet];
        _subgroupRowToIndex = @{};
        return;
    }

    NSMutableIndexSet *rowSet = [NSMutableIndexSet indexSet];
    NSMutableDictionary<NSNumber *, NSNumber *> *rowToIndex = [NSMutableDictionary dictionaryWithCapacity:_subgroupStarts.count];

    for (NSUInteger i = 0; i < _subgroupStarts.count; i++) {
        NSInteger subgroupPlaylistIndex = [_subgroupStarts[i] integerValue];
        NSInteger subgroupRow = [self rowForSubgroupAtPlaylistIndex:subgroupPlaylistIndex];

        if (subgroupRow >= 0) {
            [rowSet addIndex:(NSUInteger)subgroupRow];
            rowToIndex[@(subgroupRow)] = @(i);
        }
    }

    _subgroupRowSet = [rowSet copy];
    _subgroupRowToIndex = [rowToIndex copy];
}

#pragma mark - Row mapping

- (NSInteger)rowCount {
    NSInteger groupHeaderRows = (_headerDisplayStyle == 3) ? 0 : (NSInteger)_groupStarts.count;
    return _itemCount + groupHeaderRows + (NSInteger)_subgroupStarts.count + _totalPaddingRowsCached;
}

- (NSInteger)cumulativePaddingBeforeGroup:(NSInteger)groupIndex {
    if (groupIndex <= 0 || _cumulativePaddingCache.count == 0) return 0;
    if (groupIndex >= (NSInteger)_cumulativePaddingCache.count) {
        return [_cumulativePaddingCache.lastObject integerValue];
    }
    return [_cumulativePaddingCache[groupIndex] integerValue];
}

- (NSInteger)totalRowsInGroup:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) return 0;
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    NSInteger trackCount = groupEnd - groupStart;
    NSInteger padding = (groupIndex < (NSInteger)_groupPaddingRows.count)
        ? [_groupPaddingRows[groupIndex] integerValue] : 0;
    NSInteger headerRows = (_headerDisplayStyle == 3) ? 0 : 1;

    NSInteger subgroupCount = (groupIndex < (NSInteger)_subgroupCountPerGroup.count)
        ? [_subgroupCountPerGroup[groupIndex] integerValue] : 0;

    return headerRows + subgroupCount + trackCount + padding;
}

- (NSInteger)groupIndexForRow:(NSInteger)row {
    if (_groupStarts.count == 0 || row < 0) return -1;

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

- (NSInteger)rowForGroupHeader:(NSInteger)groupIndex {
    if (groupIndex < 0 || groupIndex >= (NSInteger)_groupStarts.count) return -1;
    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];

    NSInteger subgroupsBeforeGroup = [self subgroupCountBeforePlaylistIndex:groupStart];

    if (_headerDisplayStyle == 3) {
        return groupStart + subgroupsBeforeGroup + cumulativePadding;
    } else {
        return groupStart + groupIndex + subgroupsBeforeGroup + cumulativePadding;
    }
}

- (BOOL)isRowGroupHeader:(NSInteger)row {
    if (_groupStarts.count == 0) return NO;
    if (_headerDisplayStyle == 3) return NO;

    NSInteger groupIndex = [self groupIndexForRow:row];
    return row == [self rowForGroupHeader:groupIndex];
}

- (BOOL)isRowPaddingRow:(NSInteger)row {
    if (_groupStarts.count == 0 || _groupPaddingRows.count == 0) return NO;
    NSInteger groupIndex = [self groupIndexForRow:row];
    if (groupIndex < 0) return NO;

    NSInteger headerRow = [self rowForGroupHeader:groupIndex];
    NSInteger rowWithinGroup = row - headerRow;

    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;
    NSInteger trackCount = groupEnd - groupStart;

    NSInteger subgroupsInGroup = (groupIndex < (NSInteger)_subgroupCountPerGroup.count)
        ? [_subgroupCountPerGroup[groupIndex] integerValue] : 0;

    NSInteger contentRows = trackCount + subgroupsInGroup;

    // Styles 0-2: rowWithinGroup 0 is the header row, content occupies
    // 1..contentRows, so padding starts at contentRows + 1. Style 3 has no
    // header row: content occupies 0..contentRows-1 and padding starts at
    // contentRows. (The style-3 case was off by one historically, leaving the
    // first padding row of each group classified as an unmapped blank row.)
    NSInteger firstPaddingOffset = (_headerDisplayStyle == 3) ? contentRows : contentRows + 1;
    return (rowWithinGroup >= firstPaddingOffset);
}

- (NSInteger)playlistIndexForRow:(NSInteger)row {
    if (row < 0 || row >= [self rowCount]) return -1;
    if (_groupStarts.count == 0) return row;  // No groups = flat mode

    if ([self isRowSubgroupHeader:row]) {
        return -1;
    }

    NSInteger groupIndex = [self groupIndexForRow:row];
    NSInteger groupStartRow = [self rowForGroupHeader:groupIndex];

    if (_headerDisplayStyle != 3 && row == groupStartRow) {
        return -1;  // This is a header row
    }

    NSInteger groupStart = [_groupStarts[groupIndex] integerValue];
    NSInteger groupEnd = (groupIndex + 1 < (NSInteger)_groupStarts.count)
        ? [_groupStarts[groupIndex + 1] integerValue]
        : _itemCount;

    NSInteger subgroupsInGroup = 0;

    if (_headerDisplayStyle == 3 && [self isRowSubgroupHeader:groupStartRow]) {
        subgroupsInGroup = 1;
    }

    if (row > groupStartRow + 1) {
        NSRange range = NSMakeRange(groupStartRow + 1, row - groupStartRow - 1);
        subgroupsInGroup += (NSInteger)[_subgroupRowSet countOfIndexesInRange:range];
    }

    NSInteger rowWithinGroup = row - groupStartRow - subgroupsInGroup;

    if (_headerDisplayStyle != 3) {
        rowWithinGroup -= 1;
    }

    NSInteger trackCount = groupEnd - groupStart;

    if (rowWithinGroup >= trackCount) {
        return -1;  // Padding row
    }

    return groupStart + rowWithinGroup;
}

- (NSInteger)rowForPlaylistIndex:(NSInteger)playlistIndex {
    if (playlistIndex < 0 || playlistIndex >= _itemCount) return -1;
    if (_groupStarts.count == 0) return playlistIndex;  // No groups

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

    NSInteger subgroupsBefore = [self subgroupCountBeforePlaylistIndex:playlistIndex];
    BOOL hasSubgroupHere = [self hasSubgroupAtPlaylistIndex:playlistIndex];
    if (hasSubgroupHere) {
        subgroupsBefore++;
    }

    NSInteger headerRowsOffset = (_headerDisplayStyle == 3) ? 0 : (groupIndex + 1);

    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    NSInteger result = playlistIndex + headerRowsOffset + subgroupsBefore + cumulativePadding;

    return result;
}

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

- (NSInteger)subgroupCountBeforePlaylistIndex:(NSInteger)playlistIndex {
    if (_subgroupStarts.count == 0) return 0;

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

- (BOOL)isRowSubgroupHeader:(NSInteger)row {
    if (row < 0) return NO;
    return [_subgroupRowSet containsIndex:(NSUInteger)row];
}

- (NSString *)subgroupHeaderForRow:(NSInteger)row {
    NSNumber *indexNum = _subgroupRowToIndex[@(row)];
    if (!indexNum) return nil;

    NSUInteger i = [indexNum unsignedIntegerValue];
    if (i < _subgroupHeaders.count) {
        return _subgroupHeaders[i];
    }
    return nil;
}

- (NSInteger)rowForSubgroupAtPlaylistIndex:(NSInteger)subgroupPlaylistIndex {
    if (_groupStarts.count == 0) return subgroupPlaylistIndex;

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

    NSInteger cumulativePadding = [self cumulativePaddingBeforeGroup:groupIndex];
    NSInteger subgroupsBefore = [self subgroupCountBeforePlaylistIndex:subgroupPlaylistIndex];

    NSInteger headerRowsOffset = (_headerDisplayStyle == 3) ? 0 : (groupIndex + 1);

    return subgroupPlaylistIndex + headerRowsOffset + subgroupsBefore + cumulativePadding;
}

#pragma mark - Pixel geometry

- (CGFloat)heightForRow:(NSInteger)row {
    if ([self isRowGroupHeader:row]) {
        return _headerHeight;
    }
    return _rowHeight;
}

- (CGFloat)yOffsetForRow:(NSInteger)row {
    if (row < 0) return 0;
    NSInteger totalRows = [self rowCount];
    if (row >= totalRows) return [self totalContentHeightCached];

    NSInteger headerRowsBefore = 0;
    if (_headerDisplayStyle != 3 && _groupStarts.count > 0) {
        for (NSInteger g = 0; g < (NSInteger)_groupStarts.count; g++) {
            NSInteger headerRow = [self rowForGroupHeader:g];
            if (headerRow < row) {
                headerRowsBefore++;
            } else {
                break;  // Groups are ordered, so no more headers before this row
            }
        }
    }

    CGFloat extraHeaderHeight = headerRowsBefore * (_headerHeight - _rowHeight);
    return row * _rowHeight + extraHeaderHeight;
}

- (CGFloat)totalContentHeightCached {
    NSInteger totalRows = [self rowCount];
    NSInteger headerRowCount = (_headerDisplayStyle == 3) ? 0 : (NSInteger)_groupStarts.count;
    CGFloat extraHeaderHeight = headerRowCount * (_headerHeight - _rowHeight);
    return totalRows * _rowHeight + extraHeaderHeight;
}

- (CGFloat)pixelHeightForGroup:(NSInteger)groupIndex {
    NSInteger totalRows = [self totalRowsInGroup:groupIndex];
    NSInteger headerRows = (_headerDisplayStyle == 3) ? 0 : 1;
    return headerRows * _headerHeight + (totalRows - headerRows) * _rowHeight;
}

- (NSInteger)rowAtPoint:(NSPoint)point {
    if (point.y < 0) return -1;
    CGFloat totalHeight = [self totalContentHeightCached];
    if (point.y >= totalHeight) return -1;

    NSInteger totalRows = [self rowCount];
    NSInteger low = 0, high = totalRows - 1;
    while (low <= high) {
        NSInteger mid = (low + high) / 2;
        CGFloat midY = [self yOffsetForRow:mid];
        CGFloat midH = [self heightForRow:mid];
        if (point.y < midY) {
            high = mid - 1;
        } else if (point.y >= midY + midH) {
            low = mid + 1;
        } else {
            return mid;
        }
    }
    return -1;
}

@end
