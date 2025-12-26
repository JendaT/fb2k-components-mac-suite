//
//  GroupNode.mm
//  foo_simplaylist_mac
//

#import "GroupNode.h"

@implementation GroupNode

- (instancetype)init {
    self = [super init];
    if (self) {
        _type = GroupNodeTypeTrack;
        _playlistIndex = -1;
        _indentLevel = 0;
        _isSelected = NO;
        _isPlaying = NO;
        _isFocused = NO;
        _groupStartIndex = -1;
        _groupEndIndex = -1;
        _groupFirstRow = -1;
        _groupLastRow = -1;
    }
    return self;
}

+ (instancetype)headerWithText:(NSString *)text
                    startIndex:(NSInteger)start
                      endIndex:(NSInteger)end
                   albumArtKey:(nullable NSString *)artKey {
    GroupNode *node = [[GroupNode alloc] init];
    node.type = GroupNodeTypeHeader;
    node.displayText = text;
    node.groupStartIndex = start;
    node.groupEndIndex = end;
    node.albumArtKey = artKey;
    node.indentLevel = 0;
    return node;
}

+ (instancetype)subgroupWithText:(NSString *)text
                     indentLevel:(NSInteger)level {
    GroupNode *node = [[GroupNode alloc] init];
    node.type = GroupNodeTypeSubgroup;
    node.displayText = text;
    node.indentLevel = level;
    return node;
}

+ (instancetype)trackWithPlaylistIndex:(NSInteger)index
                          columnValues:(NSArray<NSString *> *)values
                           indentLevel:(NSInteger)level {
    GroupNode *node = [[GroupNode alloc] init];
    node.type = GroupNodeTypeTrack;
    node.playlistIndex = index;
    node.columnValues = values;
    node.indentLevel = level;
    return node;
}

+ (instancetype)trackWithPlaylistIndex:(NSInteger)index
                           indentLevel:(NSInteger)level {
    GroupNode *node = [[GroupNode alloc] init];
    node.type = GroupNodeTypeTrack;
    node.playlistIndex = index;
    node.columnValues = nil;  // Will be loaded lazily
    node.indentLevel = level;
    return node;
}

- (NSString *)description {
    NSString *typeStr;
    switch (self.type) {
        case GroupNodeTypeHeader:
            typeStr = @"Header";
            break;
        case GroupNodeTypeSubgroup:
            typeStr = @"Subgroup";
            break;
        case GroupNodeTypeTrack:
            typeStr = @"Track";
            break;
    }
    return [NSString stringWithFormat:@"<%@: %@ idx=%ld indent=%ld text='%@'>",
            [self class], typeStr, (long)self.playlistIndex, (long)self.indentLevel, self.displayText];
}

@end
