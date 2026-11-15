//
//  PlorgTreeOps.h
//  foo_plorg_mac
//
//  Pure tree queries and merge operations on TreeNode hierarchies.
//  Foundation-only (no SDK) so it is unit-testable standalone.
//

#pragma once

#import <Foundation/Foundation.h>
#import "TreeNode.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlorgTreeOps : NSObject

// Recursive search for a playlist (leaf) by exact name
+ (nullable TreeNode *)findPlaylistNamed:(NSString *)name inNodes:(NSArray<TreeNode *> *)nodes;

// Path-aware lookup: walk folder components (all but the last), then find the
// playlist leaf in the final folder. Returns nil if any component is missing.
+ (nullable TreeNode *)findPlaylistForComponents:(NSArray<NSString *> *)components
                                         inRoots:(NSArray<TreeNode *> *)roots;

// Walk every component as a folder name. Returns the folder the full path
// resolves to, or nil if any component is missing or is not a folder.
+ (nullable TreeNode *)findFolderForComponents:(NSArray<NSString *> *)components
                                       inRoots:(NSArray<TreeNode *> *)roots;

// Merge parsed nodes into the tree. Folders merge by name; playlists are
// skipped when a playlist with the same name exists anywhere under roots.
// Returns the number of nodes added (folders count their subtree).
+ (NSInteger)mergeNodes:(NSArray<TreeNode *> *)nodes
             intoParent:(nullable TreeNode *)parent
                  roots:(NSMutableArray<TreeNode *> *)roots;

// Total node count, folders recursed
+ (NSInteger)countNodes:(NSArray<TreeNode *> *)nodes;

// Playlist node for a foobar2000 name. A path-encoded name resolves by its path;
// a one-part name prefers a root-level leaf, then a leaf anywhere. Last resort:
// a leaf whose name is the whole string.
+ (nullable TreeNode *)findPlaylistForFoobarName:(NSString *)foobarName
                                         inRoots:(NSArray<TreeNode *> *)roots;

// Follows a foobar2000 playlist renamed outside the organizer.
// decodeNewPath NO: the node keeps its place and takes newName as its name.
// decodeNewPath YES: the node moves under the folders newName encodes, creating
// missing ones, and takes the last component as its name; when the folder does
// not change, the node keeps its position.
// If another playlist node already sits where newName points, that node is kept
// and the old one is removed.
// Returns the node that now stands for the playlist, or nil when there is no
// node for oldName (the tree is left unchanged).
+ (nullable TreeNode *)followRenameFrom:(NSString *)oldName
                                     to:(NSString *)newName
                          decodeNewPath:(BOOL)decodeNewPath
                                  roots:(NSMutableArray<TreeNode *> *)roots;

@end

NS_ASSUME_NONNULL_END
