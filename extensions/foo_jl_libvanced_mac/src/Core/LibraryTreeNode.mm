//
//  LibraryTreeNode.mm
//  foo_jl_libvanced
//

#import "LibraryTreeNode.h"

@implementation LibraryTreeNode

+ (instancetype)rootNode {
    LibraryTreeNode *node = [[LibraryTreeNode alloc] init];
    node->_nodeType = LibraryNodeTypeRoot;
    node->_displayName = @"";
    node->_children = [NSMutableArray array];
    node->_expanded = YES;
    return node;
}

+ (instancetype)groupNodeWithName:(NSString *)name {
    LibraryTreeNode *node = [[LibraryTreeNode alloc] init];
    node->_nodeType = LibraryNodeTypeGroup;
    node->_displayName = [name copy];
    node->_children = [NSMutableArray array];
    node->_expanded = NO;
    return node;
}

+ (instancetype)trackNodeWithName:(NSString *)name path:(NSString *)path subsong:(NSUInteger)subsong {
    LibraryTreeNode *node = [[LibraryTreeNode alloc] init];
    node->_nodeType = LibraryNodeTypeTrack;
    node->_displayName = [name copy];
    node->_children = [NSMutableArray array];
    node->_trackPath = [path copy];
    node->_trackSubsong = subsong;
    return node;
}

- (void)addChild:(LibraryTreeNode *)child {
    child.parent = self;
    [_children addObject:child];
}

- (void)removeAllChildren {
    for (LibraryTreeNode *child in _children) {
        child.parent = nil;
    }
    [_children removeAllObjects];
}

- (void)sortChildrenWithComparator:(NSComparator)comparator {
    [_children sortUsingComparator:comparator];
}

- (NSInteger)trackCount {
    if (_nodeType == LibraryNodeTypeTrack) return 1;
    NSInteger count = 0;
    for (LibraryTreeNode *child in _children) {
        count += child.trackCount;
    }
    return count;
}

- (NSArray<NSString *> *)allTrackPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    [self collectTrackPaths:paths];
    return paths;
}

- (void)collectTrackPaths:(NSMutableArray<NSString *> *)paths {
    if (_nodeType == LibraryNodeTypeTrack && _trackPath) {
        [paths addObject:_trackPath];
    } else {
        for (LibraryTreeNode *child in _children) {
            [child collectTrackPaths:paths];
        }
    }
}

- (NSArray<LibraryTreeNode *> *)allTrackNodes {
    NSMutableArray<LibraryTreeNode *> *nodes = [NSMutableArray array];
    [self collectTrackNodes:nodes];
    return nodes;
}

- (void)collectTrackNodes:(NSMutableArray<LibraryTreeNode *> *)nodes {
    if (_nodeType == LibraryNodeTypeTrack) {
        [nodes addObject:self];
    } else {
        for (LibraryTreeNode *child in _children) {
            [child collectTrackNodes:nodes];
        }
    }
}

@end
