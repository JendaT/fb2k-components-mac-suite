//
//  TreeModel.h
//  foo_plorg_mac
//
//  Manages the playlist organizer tree structure
//

#pragma once

#import <Foundation/Foundation.h>
#import "TreeNode.h"

NS_ASSUME_NONNULL_BEGIN

// Notification posted when tree structure changes
extern NSNotificationName const TreeModelDidChangeNotification;

// Notification userInfo keys
extern NSString * const TreeModelChangeTypeKey;      // NSNumber (TreeModelChangeType)
extern NSString * const TreeModelChangedNodeKey;     // TreeNode that changed
extern NSString * const TreeModelChangeIndexKey;     // NSNumber index (for insertions/removals)

typedef NS_ENUM(NSInteger, TreeModelChangeType) {
    TreeModelChangeTypeReload,      // Full reload needed
    TreeModelChangeTypeInsert,      // Node inserted
    TreeModelChangeTypeRemove,      // Node removed
    TreeModelChangeTypeUpdate,      // Node updated (renamed, etc.)
    TreeModelChangeTypeMove         // Node moved
};

@interface TreeModel : NSObject

// Singleton - all organizer panels share the same tree
+ (instancetype)shared;

// Root nodes (folders and playlists at top level)
@property (nonatomic, readonly) NSArray<TreeNode *> *rootNodes;

// Configuration
@property (nonatomic, copy) NSString *nodeFormat;  // Title format pattern

// Tree operations
- (void)addRootNode:(TreeNode *)node;
- (void)insertRootNode:(TreeNode *)node atIndex:(NSInteger)index;
- (void)removeRootNode:(TreeNode *)node;
- (void)moveNode:(TreeNode *)node toParent:(nullable TreeNode *)newParent atIndex:(NSInteger)index;

// Search
- (nullable TreeNode *)findPlaylistWithName:(NSString *)name;
- (nullable TreeNode *)findPlaylistWithName:(NSString *)name inNodes:(NSArray<TreeNode *> *)nodes;
- (nullable TreeNode *)findFolderAtPath:(NSString *)path;

// Playlist sync
- (void)handlePlaylistCreated:(NSString *)name;
- (void)handlePlaylistRenamed:(NSString *)oldName to:(NSString *)newName;
- (void)handlePlaylistDeleted:(NSString *)name;
- (void)syncWithFoobarPlaylists;  // Add any missing playlists from foobar2000

// Persistence
- (void)loadFromConfig;
- (void)saveToConfig;
- (NSString *)toYaml;  // Export tree as YAML
- (NSInteger)importFromYaml:(NSString *)yaml;  // Import/merge YAML into tree, returns count

// Expanded state
- (NSSet<NSString *> *)expandedFolderPaths;
- (void)setExpandedFolderPaths:(NSSet<NSString *> *)paths;

// Default tree (for first run)
- (void)createDefaultTree;

@end

NS_ASSUME_NONNULL_END
