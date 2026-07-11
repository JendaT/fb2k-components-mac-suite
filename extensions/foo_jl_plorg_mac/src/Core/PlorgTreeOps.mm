//
//  PlorgTreeOps.mm
//  foo_plorg_mac
//

#import "PlorgTreeOps.h"

@implementation PlorgTreeOps

+ (TreeNode *)findPlaylistNamed:(NSString *)name inNodes:(NSArray<TreeNode *> *)nodes {
    for (TreeNode *node in nodes) {
        if (!node.isFolder && [node.name isEqualToString:name]) {
            return node;
        }
        if (node.isFolder && node.children.count > 0) {
            TreeNode *found = [self findPlaylistNamed:name inNodes:node.children];
            if (found) return found;
        }
    }
    return nil;
}

+ (TreeNode *)findPlaylistForComponents:(NSArray<NSString *> *)components
                                inRoots:(NSArray<TreeNode *> *)roots {
    if (components.count == 0) return nil;

    NSArray<TreeNode *> *currentLevel = roots;
    for (NSUInteger i = 0; i < components.count - 1; i++) {
        NSString *folderName = components[i];
        TreeNode *foundFolder = nil;
        for (TreeNode *node in currentLevel) {
            if (node.isFolder && [node.name isEqualToString:folderName]) {
                foundFolder = node;
                break;
            }
        }
        if (!foundFolder) return nil;
        currentLevel = foundFolder.children;
    }

    // Find the playlist in the final folder
    NSString *playlistName = components.lastObject;
    for (TreeNode *node in currentLevel) {
        if (!node.isFolder && [node.name isEqualToString:playlistName]) {
            return node;
        }
    }
    return nil;
}

+ (TreeNode *)findFolderForComponents:(NSArray<NSString *> *)components
                              inRoots:(NSArray<TreeNode *> *)roots {
    if (components.count == 0) return nil;

    NSArray<TreeNode *> *currentLevel = roots;
    TreeNode *resolved = nil;

    for (NSString *component in components) {
        TreeNode *found = nil;
        for (TreeNode *node in currentLevel) {
            if (node.isFolder && [node.name isEqualToString:component]) {
                found = node;
                break;
            }
        }
        if (!found) return nil;
        resolved = found;
        currentLevel = found.children;
    }

    return resolved;
}

+ (NSInteger)mergeNodes:(NSArray<TreeNode *> *)nodes
             intoParent:(TreeNode *)parent
                  roots:(NSMutableArray<TreeNode *> *)roots {
    NSInteger count = 0;

    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            // Check if folder exists
            TreeNode *existingFolder = nil;
            NSArray *searchNodes = parent ? parent.children : roots;

            for (TreeNode *existing in searchNodes) {
                if (existing.isFolder && [existing.name isEqualToString:node.name]) {
                    existingFolder = existing;
                    break;
                }
            }

            if (existingFolder) {
                // Merge children into existing folder
                count += [self mergeNodes:node.children intoParent:existingFolder roots:roots];
            } else {
                // Add new folder
                if (parent) {
                    [parent addChild:node];
                } else {
                    [roots addObject:node];
                }
                count += 1 + [self countNodes:node.children];
            }
        } else {
            // Playlist - check if exists anywhere in tree
            if (![self findPlaylistNamed:node.name inNodes:roots]) {
                if (parent) {
                    [parent addChild:node];
                } else {
                    [roots addObject:node];
                }
                count++;
            }
        }
    }

    return count;
}

+ (NSInteger)countNodes:(NSArray<TreeNode *> *)nodes {
    NSInteger count = nodes.count;
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            count += [self countNodes:node.children];
        }
    }
    return count;
}

@end
