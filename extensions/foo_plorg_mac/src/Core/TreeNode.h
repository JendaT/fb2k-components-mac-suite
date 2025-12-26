//
//  TreeNode.h
//  foo_plorg_mac
//
//  Tree node model for playlist organizer
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TreeNodeType) {
    TreeNodeTypeFolder,
    TreeNodeTypePlaylist
};

@interface TreeNode : NSObject

@property (nonatomic, assign) TreeNodeType nodeType;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong, nullable) NSMutableArray<TreeNode *> *children;  // nil for playlists
@property (nonatomic, weak, nullable) TreeNode *parent;
@property (nonatomic, assign) BOOL isExpanded;  // For folders

// Factory methods
+ (instancetype)folderWithName:(NSString *)name;
+ (instancetype)playlistWithName:(NSString *)name;

// Convenience
@property (nonatomic, readonly) BOOL isFolder;
@property (nonatomic, readonly) NSInteger childCount;

// Child management (folders only)
- (void)addChild:(TreeNode *)child;
- (void)insertChild:(TreeNode *)child atIndex:(NSInteger)index;
- (void)removeChild:(TreeNode *)child;
- (void)removeChildAtIndex:(NSInteger)index;
- (nullable TreeNode *)childAtIndex:(NSInteger)index;

// Serialization (JSON)
- (NSDictionary *)toDictionary;
+ (nullable instancetype)fromDictionary:(NSDictionary *)dict;

// Path utilities
@property (nonatomic, readonly) NSString *path;  // e.g., "Folder/Subfolder/Playlist"

// Formatting
- (NSString *)formattedNameWithFormat:(NSString *)format playlistItemCount:(NSInteger)itemCount;

@end

NS_ASSUME_NONNULL_END
