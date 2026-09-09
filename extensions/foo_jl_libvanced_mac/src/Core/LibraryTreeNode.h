//
//  LibraryTreeNode.h
//  foo_jl_libvanced
//
//  Tree node model for the library browser hierarchy
//

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LibraryNodeType) {
    LibraryNodeTypeRoot,
    LibraryNodeTypeGroup,   // Artist, Album, Genre, etc.
    LibraryNodeTypeTrack
};

@interface LibraryTreeNode : NSObject

@property (nonatomic, readonly) LibraryNodeType nodeType;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly, strong) NSMutableArray<LibraryTreeNode *> *children;
@property (nonatomic, weak, nullable) LibraryTreeNode *parent;
@property (nonatomic, assign) BOOL expanded;

// Track count (for group nodes: sum of all descendant tracks)
@property (nonatomic, readonly) NSInteger trackCount;

// For track nodes: stores the foobar2000 path for handle lookup
@property (nonatomic, copy, nullable) NSString *trackPath;
@property (nonatomic, assign) NSUInteger trackSubsong;

// For group nodes: representative album art path (first child track)
@property (nonatomic, copy, nullable) NSString *albumArtPath;

+ (instancetype)rootNode;
+ (instancetype)groupNodeWithName:(NSString *)name;
+ (instancetype)trackNodeWithName:(NSString *)name path:(NSString *)path subsong:(NSUInteger)subsong;

- (void)addChild:(LibraryTreeNode *)child;
- (void)removeAllChildren;
- (void)sortChildrenWithComparator:(NSComparator)comparator;

// Collect all track paths in this subtree
- (NSArray<NSString *> *)allTrackPaths;

// Collect all handles using metadb lookup
- (NSArray<LibraryTreeNode *> *)allTrackNodes;

@end

NS_ASSUME_NONNULL_END
