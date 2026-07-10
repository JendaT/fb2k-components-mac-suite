//
//  TreeOps.h
//  foo_plorg_mac
//
//  Pure tree queries and merge operations on TreeNode hierarchies.
//  Foundation-only (no SDK) so it is unit-testable standalone.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TreeNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface TreeOps : NSObject

// Recursive search for a playlist (leaf) by exact name
+ (nullable TreeNode *)findPlaylistNamed:(NSString *)name inNodes:(NSArray<TreeNode *> *)nodes;

// Path-aware lookup: walk folder components (all but the last), then find the
// playlist leaf in the final folder. Returns nil if any component is missing.
+ (nullable TreeNode *)findPlaylistForComponents:(NSArray<NSString *> *)components
                                         inRoots:(NSArray<TreeNode *> *)roots;

// Merge parsed nodes into the tree. Folders merge by name; playlists are
// skipped when a playlist with the same name exists anywhere under roots.
// Returns the number of nodes added (folders count their subtree).
+ (NSInteger)mergeNodes:(NSArray<TreeNode *> *)nodes
             intoParent:(nullable TreeNode *)parent
                  roots:(NSMutableArray<TreeNode *> *)roots;

// Total node count, folders recursed
+ (NSInteger)countNodes:(NSArray<TreeNode *> *)nodes;

@end

NS_ASSUME_NONNULL_END
