#import "AlbumItem.h"

@implementation AlbumTrack
@end

@implementation AlbumItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _tracks = [NSMutableArray array];
        _artistName = @"";
        _albumName = @"";
        _year = @"";
        _artPath = @"";
    }
    return self;
}

- (NSString *)groupKey {
    return [NSString stringWithFormat:@"%@ - %@", _artistName, _albumName];
}

- (NSArray<NSString *> *)allTrackPaths {
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:_tracks.count];
    for (AlbumTrack *t in _tracks) {
        [paths addObject:t.path];
    }
    return paths;
}

@end
