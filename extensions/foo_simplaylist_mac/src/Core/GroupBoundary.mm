//
//  GroupBoundary.mm
//  foo_simplaylist_mac
//

#import "GroupBoundary.h"

@implementation GroupBoundary

- (NSInteger)trackCount {
    return _endPlaylistIndex - _startPlaylistIndex + 1;
}

- (NSInteger)rowCount {
    // 1 header row + all track rows
    return 1 + [self trackCount];
}

- (BOOL)containsPlaylistIndex:(NSInteger)index {
    return index >= _startPlaylistIndex && index <= _endPlaylistIndex;
}

+ (instancetype)boundaryWithStartIndex:(NSInteger)start
                              endIndex:(NSInteger)end
                             rowOffset:(NSInteger)offset
                            headerText:(NSString *)text
                           albumArtKey:(NSString *)artKey {
    GroupBoundary *boundary = [[GroupBoundary alloc] init];
    boundary.startPlaylistIndex = start;
    boundary.endPlaylistIndex = end;
    boundary.rowOffset = offset;
    boundary.headerText = text;
    boundary.albumArtKey = artKey;
    return boundary;
}

@end
