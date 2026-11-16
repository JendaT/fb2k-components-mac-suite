//
//  PlorgTreeOps.mm
//  foo_plorg_mac
//

#import "PlorgTreeOps.h"
#import "PlorgPathCodec.h"

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

+ (TreeNode *)findPlaylistForFoobarName:(NSString *)foobarName
                                inRoots:(NSArray<TreeNode *> *)roots {
    if (foobarName.length == 0) return nil;

    NSArray<NSString *> *components = [PlorgPathCodec splitEncodedName:foobarName];
    TreeNode *node = nil;
    if (components.count > 1) {
        node = [self findPlaylistForComponents:components inRoots:roots];
    } else if (components.count == 1) {
        // A root-level leaf is the exact match; a nested leaf is the fallback
        node = [self findPlaylistForComponents:components inRoots:roots];
        if (!node) node = [self findPlaylistNamed:components[0] inNodes:roots];
    }
    if (!node) node = [self findPlaylistNamed:foobarName inNodes:roots];
    return node;
}

// Takes a node out of its folder, or out of roots when it sits at the top level
+ (void)detachNode:(TreeNode *)node fromRoots:(NSMutableArray<TreeNode *> *)roots {
    if (node.parent) {
        [node.parent removeChild:node];
    } else {
        [roots removeObjectIdenticalTo:node];
    }
}

+ (TreeNode *)followRenameFrom:(NSString *)oldName
                            to:(NSString *)newName
                 decodeNewPath:(BOOL)decodeNewPath
                         roots:(NSMutableArray<TreeNode *> *)roots {
    if (oldName.length == 0 || newName.length == 0 || [oldName isEqualToString:newName]) return nil;

    TreeNode *node = [self findPlaylistForFoobarName:oldName inRoots:roots];
    if (!node) return nil;

    if (!decodeNewPath) {
        // Flat names: any leaf already called newName stands for the same playlist
        TreeNode *existing = [self findPlaylistNamed:newName inNodes:roots];
        if (existing && existing != node) {
            [self detachNode:node fromRoots:roots];
            return existing;
        }
        node.name = newName;
        return node;
    }

    NSArray<NSString *> *components = [PlorgPathCodec splitEncodedName:newName];
    NSString *leafName = components.lastObject;
    if (leafName.length == 0) return nil;

    TreeNode *existing = [self findPlaylistForComponents:components inRoots:roots];
    if (existing && existing != node) {
        [self detachNode:node fromRoots:roots];
        return existing;
    }

    // Walk the folder path, creating folders that are missing
    TreeNode *parent = nil;
    NSArray<TreeNode *> *level = roots;
    for (NSUInteger i = 0; i + 1 < components.count; i++) {
        NSString *folderName = components[i];
        TreeNode *folder = nil;
        for (TreeNode *candidate in level) {
            if (candidate.isFolder && [candidate.name isEqualToString:folderName]) {
                folder = candidate;
                break;
            }
        }
        if (!folder) {
            folder = [TreeNode folderWithName:folderName];
            if (parent) {
                [parent addChild:folder];
            } else {
                [roots addObject:folder];
            }
        }
        parent = folder;
        level = folder.children;
    }

    if (node.parent != parent) {
        [self detachNode:node fromRoots:roots];
        if (parent) {
            [parent addChild:node];
        } else {
            node.parent = nil;
            [roots addObject:node];
        }
    }
    node.name = leafName;
    return node;
}

@end
