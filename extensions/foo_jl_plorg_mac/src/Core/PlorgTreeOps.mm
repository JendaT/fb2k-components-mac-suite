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

// Same-named sibling folders (e.g. from an imported tree) mask each other under
// first-match resolution. Fold each duplicate's children into the first
// occurrence and empty the duplicate; the surrounding arrays are not mutated.
+ (void)foldDuplicateSiblingFolders:(NSArray<TreeNode *> *)nodes {
    NSMutableDictionary<NSString *, TreeNode *> *firstFolders = [NSMutableDictionary dictionary];
    for (TreeNode *node in nodes) {
        if (!node.isFolder) continue;
        TreeNode *survivor = firstFolders[node.name];
        if (!survivor) {
            firstFolders[node.name] = node;
            continue;
        }
        NSArray<TreeNode *> *moved = [node.children copy];
        [node.children removeAllObjects];
        for (TreeNode *child in moved) {
            [survivor addChild:child];
        }
    }
    for (TreeNode *folder in firstFolders.allValues) {
        if (folder.children.count > 0) {
            [self foldDuplicateSiblingFolders:folder.children];
        }
    }
}

+ (TreeNode *)findPlaylistForComponents:(NSArray<NSString *> *)components
                                inRoots:(NSArray<TreeNode *> *)roots {
    if (components.count == 0) return nil;

    [self foldDuplicateSiblingFolders:roots];

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

    [self foldDuplicateSiblingFolders:roots];

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

    [self foldDuplicateSiblingFolders:parent ? parent.children : roots];

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
