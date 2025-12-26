//
//  TreeModel.mm
//  foo_plorg_mac
//

#import "TreeModel.h"
#import "ConfigHelper.h"
#import "TreeNode.h"
#include "../fb2k_sdk.h"

// Notifications
NSNotificationName const TreeModelDidChangeNotification = @"TreeModelDidChangeNotification";
NSString * const TreeModelChangeTypeKey = @"changeType";
NSString * const TreeModelChangedNodeKey = @"changedNode";
NSString * const TreeModelChangeIndexKey = @"changeIndex";

@interface TreeModel ()
@property (nonatomic, strong) NSMutableArray<TreeNode *> *mutableRootNodes;
@end

@implementation TreeModel

#pragma mark - Singleton

+ (instancetype)shared {
    static TreeModel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TreeModel alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableRootNodes = [NSMutableArray array];
        _nodeFormat = @"%node_name%";  // Default format
    }
    return self;
}

#pragma mark - Properties

- (NSArray<TreeNode *> *)rootNodes {
    return [self.mutableRootNodes copy];
}

#pragma mark - Tree Operations

- (void)addRootNode:(TreeNode *)node {
    if (!node) return;
    node.parent = nil;
    [self.mutableRootNodes addObject:node];
    [self notifyChange:TreeModelChangeTypeInsert node:node index:self.mutableRootNodes.count - 1];
    [self saveToConfig];
}

- (void)insertRootNode:(TreeNode *)node atIndex:(NSInteger)index {
    if (!node) return;
    if (index < 0) index = 0;
    if (index > (NSInteger)self.mutableRootNodes.count) index = self.mutableRootNodes.count;
    node.parent = nil;
    [self.mutableRootNodes insertObject:node atIndex:index];
    [self notifyChange:TreeModelChangeTypeInsert node:node index:index];
    [self saveToConfig];
}

- (void)removeRootNode:(TreeNode *)node {
    if (!node) return;
    NSInteger index = [self.mutableRootNodes indexOfObject:node];
    if (index != NSNotFound) {
        [self.mutableRootNodes removeObjectAtIndex:index];
        [self notifyChange:TreeModelChangeTypeRemove node:node index:index];
        [self saveToConfig];
    }
}

- (void)moveNode:(TreeNode *)node toParent:(TreeNode *)newParent atIndex:(NSInteger)index {
    if (!node) return;

    // Remove from current location
    if (node.parent) {
        [node.parent removeChild:node];
    } else {
        [self.mutableRootNodes removeObject:node];
    }

    // Add to new location
    if (newParent) {
        [newParent insertChild:node atIndex:index];
    } else {
        if (index < 0) index = 0;
        if (index > (NSInteger)self.mutableRootNodes.count) index = self.mutableRootNodes.count;
        node.parent = nil;
        [self.mutableRootNodes insertObject:node atIndex:index];
    }

    [self notifyChange:TreeModelChangeTypeMove node:node index:index];
    [self saveToConfig];
}

#pragma mark - Search

- (TreeNode *)findPlaylistWithName:(NSString *)name {
    return [self findPlaylistWithName:name inNodes:self.mutableRootNodes];
}

- (TreeNode *)findPlaylistWithName:(NSString *)name inNodes:(NSArray<TreeNode *> *)nodes {
    for (TreeNode *node in nodes) {
        if (!node.isFolder && [node.name isEqualToString:name]) {
            return node;
        }
        if (node.isFolder && node.children.count > 0) {
            TreeNode *found = [self findPlaylistWithName:name inNodes:node.children];
            if (found) return found;
        }
    }
    return nil;
}

- (TreeNode *)findFolderAtPath:(NSString *)path {
    NSArray *components = [path componentsSeparatedByString:@"/"];
    NSArray<TreeNode *> *currentLevel = self.mutableRootNodes;

    for (NSString *component in components) {
        TreeNode *found = nil;
        for (TreeNode *node in currentLevel) {
            if (node.isFolder && [node.name isEqualToString:component]) {
                found = node;
                break;
            }
        }
        if (!found) return nil;
        currentLevel = found.children;
    }

    return nil;  // Path didn't resolve to a folder
}

#pragma mark - Playlist Sync

- (void)handlePlaylistCreated:(NSString *)name {
    // Check if sync is enabled
    if (!plorg_config::getConfigBool(plorg_config::kSyncPlaylists, true)) {
        return;
    }

    // Check if playlist already exists in tree
    if ([self findPlaylistWithName:name]) {
        return;  // Already tracked
    }

    // Add new playlist at root level
    TreeNode *newPlaylist = [TreeNode playlistWithName:name];
    [self addRootNode:newPlaylist];
}

- (void)handlePlaylistRenamed:(NSString *)oldName to:(NSString *)newName {
    TreeNode *node = [self findPlaylistWithName:oldName];
    if (node) {
        node.name = newName;
        [self notifyChange:TreeModelChangeTypeUpdate node:node index:-1];
        [self saveToConfig];
    }
}

- (void)handlePlaylistDeleted:(NSString *)name {
    TreeNode *node = [self findPlaylistWithName:name];
    if (node) {
        if (node.parent) {
            [node.parent removeChild:node];
        } else {
            [self.mutableRootNodes removeObject:node];
        }
        [self notifyChange:TreeModelChangeTypeRemove node:node index:-1];
        [self saveToConfig];
    }
}

- (void)syncWithFoobarPlaylists {
    // Check if sync is enabled
    if (!plorg_config::getConfigBool(plorg_config::kSyncPlaylists, true)) {
        return;
    }

    @try {
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        NSInteger addedCount = 0;

        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            NSString *playlistName = [NSString stringWithUTF8String:name.c_str()];

            if (playlistName && playlistName.length > 0) {
                // Check if already in tree
                if (![self findPlaylistWithName:playlistName]) {
                    TreeNode *playlist = [TreeNode playlistWithName:playlistName];
                    playlist.parent = nil;
                    [self.mutableRootNodes addObject:playlist];
                    addedCount++;
                }
            }
        }

        if (addedCount > 0) {
            FB2K_console_formatter() << "[Plorg] Synced " << (int)addedCount << " missing playlists";
            [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
            [self saveToConfig];
        }
    } @catch (NSException *exception) {
        NSLog(@"[Plorg] Exception syncing playlists: %@", exception);
    }
}

#pragma mark - YAML Serialization

- (NSString *)nodeToYaml:(TreeNode *)node indent:(NSInteger)indent {
    NSMutableString *yaml = [NSMutableString string];
    NSString *indentStr = [@"" stringByPaddingToLength:indent withString:@"  " startingAtIndex:0];

    if (node.isFolder) {
        [yaml appendFormat:@"%@- folder: \"%@\"\n", indentStr, [self escapeYamlString:node.name]];
        if (node.isExpanded) {
            [yaml appendFormat:@"%@  expanded: true\n", indentStr];
        }
        if (node.children.count > 0) {
            [yaml appendFormat:@"%@  items:\n", indentStr];
            for (TreeNode *child in node.children) {
                [yaml appendString:[self nodeToYaml:child indent:indent + 2]];
            }
        }
    } else {
        [yaml appendFormat:@"%@- playlist: \"%@\"\n", indentStr, [self escapeYamlString:node.name]];
    }

    return yaml;
}

- (NSString *)escapeYamlString:(NSString *)str {
    return [[str stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

- (NSString *)unescapeYamlString:(NSString *)str {
    return [[str stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""]
            stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
}

- (NSString *)toYaml {
    NSMutableString *yaml = [NSMutableString string];
    [yaml appendString:@"# Playlist Organizer Configuration\n"];
    [yaml appendFormat:@"node_format: \"%@\"\n\n", [self escapeYamlString:self.nodeFormat ?: @"%node_name%"]];

    if (self.mutableRootNodes.count > 0) {
        [yaml appendString:@"tree:\n"];
        for (TreeNode *node in self.mutableRootNodes) {
            [yaml appendString:[self nodeToYaml:node indent:1]];
        }
    } else {
        [yaml appendString:@"tree: []\n"];
    }

    return yaml;
}

- (NSInteger)importFromYaml:(NSString *)yaml {
    if (!yaml || yaml.length == 0) return 0;

    // Parse into temporary storage
    NSArray *lines = [yaml componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<TreeNode *> *parsedRoots = [NSMutableArray array];
    NSMutableArray<TreeNode *> *nodeStack = [NSMutableArray array];
    NSMutableArray<NSNumber *> *indentStack = [NSMutableArray array];

    BOOL inTree = NO;

    for (NSString *rawLine in lines) {
        if (rawLine.length == 0 || [rawLine hasPrefix:@"#"]) continue;

        NSInteger indent = 0;
        while (indent < rawLine.length && [rawLine characterAtIndex:indent] == ' ') {
            indent++;
        }

        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([line hasPrefix:@"tree:"]) {
            inTree = YES;
            continue;
        }

        if (!inTree) continue;

        while (indentStack.count > 0 && indent <= indentStack.lastObject.integerValue) {
            [nodeStack removeLastObject];
            [indentStack removeLastObject];
        }

        TreeNode *newNode = nil;

        if ([line hasPrefix:@"- folder:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- folder:"];
            if (name) {
                newNode = [TreeNode folderWithName:name];
            }
        } else if ([line hasPrefix:@"- playlist:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- playlist:"];
            if (name) {
                newNode = [TreeNode playlistWithName:name];
            }
        } else if ([line hasPrefix:@"expanded:"]) {
            if (nodeStack.count > 0 && nodeStack.lastObject.isFolder) {
                BOOL expanded = [line containsString:@"true"];
                nodeStack.lastObject.isExpanded = expanded;
            }
            continue;
        } else if ([line hasPrefix:@"items:"]) {
            continue;
        }

        if (newNode) {
            if (nodeStack.count > 0) {
                [nodeStack.lastObject addChild:newNode];
            } else {
                [parsedRoots addObject:newNode];
            }

            if (newNode.isFolder) {
                [nodeStack addObject:newNode];
                [indentStack addObject:@(indent)];
            }
        }
    }

    // Now merge parsed nodes into current tree
    NSInteger imported = [self mergeNodes:parsedRoots intoParent:nil];
    [self saveToConfig];
    [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];

    return imported;
}

- (NSInteger)mergeNodes:(NSArray<TreeNode *> *)nodes intoParent:(TreeNode *)parent {
    NSInteger count = 0;

    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            // Check if folder exists
            TreeNode *existingFolder = nil;
            NSArray *searchNodes = parent ? parent.children : self.mutableRootNodes;

            for (TreeNode *existing in searchNodes) {
                if (existing.isFolder && [existing.name isEqualToString:node.name]) {
                    existingFolder = existing;
                    break;
                }
            }

            if (existingFolder) {
                // Merge children into existing folder
                count += [self mergeNodes:node.children intoParent:existingFolder];
            } else {
                // Add new folder
                if (parent) {
                    [parent addChild:node];
                } else {
                    [self.mutableRootNodes addObject:node];
                }
                count += 1 + [self countNodes:node.children];
            }
        } else {
            // Playlist - check if exists anywhere in tree
            if (![self findPlaylistWithName:node.name]) {
                if (parent) {
                    [parent addChild:node];
                } else {
                    [self.mutableRootNodes addObject:node];
                }
                count++;
            }
        }
    }

    return count;
}

- (NSInteger)countNodes:(NSArray<TreeNode *> *)nodes {
    NSInteger count = nodes.count;
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            count += [self countNodes:node.children];
        }
    }
    return count;
}

- (BOOL)parseYaml:(NSString *)yaml {
    if (!yaml || yaml.length == 0) return NO;

    NSArray *lines = [yaml componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<TreeNode *> *rootNodes = [NSMutableArray array];
    NSMutableArray<TreeNode *> *nodeStack = [NSMutableArray array];  // Stack of parent nodes
    NSMutableArray<NSNumber *> *indentStack = [NSMutableArray array];  // Corresponding indents

    BOOL inTree = NO;

    for (NSString *rawLine in lines) {
        // Skip empty lines and comments
        if (rawLine.length == 0 || [rawLine hasPrefix:@"#"]) continue;

        // Count leading spaces
        NSInteger indent = 0;
        while (indent < (NSInteger)rawLine.length && [rawLine characterAtIndex:indent] == ' ') {
            indent++;
        }

        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;

        // Parse node_format
        if ([line hasPrefix:@"node_format:"]) {
            NSString *value = [line substringFromIndex:12];
            value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
                value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
            }
            self.nodeFormat = [self unescapeYamlString:value];
            continue;
        }

        // Start of tree section
        if ([line hasPrefix:@"tree:"]) {
            inTree = YES;
            continue;
        }

        if (!inTree) continue;

        // Parse folder or playlist
        TreeNode *node = nil;

        if ([line hasPrefix:@"- folder:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- folder:"];
            if (name) {
                node = [TreeNode folderWithName:name];
            }
        } else if ([line hasPrefix:@"- playlist:"]) {
            NSString *name = [self extractQuotedValue:line afterPrefix:@"- playlist:"];
            if (name) {
                node = [TreeNode playlistWithName:name];
            }
        } else if ([line hasPrefix:@"expanded:"]) {
            // This is a property of the previous folder
            if (nodeStack.count > 0) {
                TreeNode *lastNode = nodeStack.lastObject;
                if (lastNode.isFolder) {
                    lastNode.isExpanded = [line containsString:@"true"];
                }
            }
            continue;
        } else if ([line isEqualToString:@"items:"]) {
            // Items marker - children follow
            continue;
        }

        if (!node) continue;

        // Pop nodes from stack that are at same or higher indent
        while (indentStack.count > 0 && indentStack.lastObject.integerValue >= indent) {
            [nodeStack removeLastObject];
            [indentStack removeLastObject];
        }

        // Add to parent or root
        if (nodeStack.count > 0) {
            TreeNode *parent = nodeStack.lastObject;
            if (parent.isFolder) {
                [parent addChild:node];
            }
        } else {
            node.parent = nil;
            [rootNodes addObject:node];
        }

        // Push this node if it's a folder (might have children)
        if (node.isFolder) {
            [nodeStack addObject:node];
            [indentStack addObject:@(indent)];
        }
    }

    if (rootNodes.count > 0) {
        [self.mutableRootNodes setArray:rootNodes];
        return YES;
    }

    return NO;
}

- (NSString *)extractQuotedValue:(NSString *)line afterPrefix:(NSString *)prefix {
    NSRange range = [line rangeOfString:prefix];
    if (range.location == NSNotFound) return nil;

    NSString *value = [line substringFromIndex:range.location + range.length];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        return [self unescapeYamlString:value];
    }

    return value;
}

#pragma mark - Persistence

- (void)loadFromConfig {
    @try {
        // Load from YAML file
        NSString *config = plorg_config::loadTreeFromFile();
        if (config.length > 0 && [self parseYaml:config]) {
            FB2K_console_formatter() << "[Plorg] Loaded tree from " << [plorg_config::getConfigFilePath() UTF8String];
            [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
            return;
        }

        // Migration: try loading from old configStore location
        NSString *oldConfig = plorg_config::getConfigString("tree_structure", "");
        if (oldConfig.length > 0) {
            // Try YAML
            if ([self parseYaml:oldConfig]) {
                FB2K_console_formatter() << "[Plorg] Migrated tree from configStore to file";
                [self saveToConfig];  // Save to new file location
                [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
                return;
            }

            // Try JSON
            NSData *data = [oldConfig dataUsingEncoding:NSUTF8StringEncoding];
            if (data) {
                NSError *error = nil;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                if (!error && [json isKindOfClass:[NSDictionary class]]) {
                    NSString *format = json[@"nodeFormat"];
                    if ([format isKindOfClass:[NSString class]]) {
                        self.nodeFormat = format;
                    }

                    NSArray *tree = json[@"tree"];
                    if ([tree isKindOfClass:[NSArray class]]) {
                        [self.mutableRootNodes removeAllObjects];
                        for (NSDictionary *nodeDict in tree) {
                            TreeNode *node = [TreeNode fromDictionary:nodeDict];
                            if (node) {
                                node.parent = nil;
                                [self.mutableRootNodes addObject:node];
                            }
                        }
                    }

                    FB2K_console_formatter() << "[Plorg] Migrated tree from JSON configStore to YAML file";
                    [self saveToConfig];
                    [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
                    return;
                }
            }
        }

        [self createDefaultTree];
    } @catch (NSException *exception) {
        NSLog(@"[Plorg] Exception loading config: %@", exception);
        [self createDefaultTree];
    }
}

- (void)saveToConfig {
    @try {
        NSString *yaml = [self toYaml];
        plorg_config::saveTreeToFile(yaml);
    } @catch (NSException *exception) {
        NSLog(@"[Plorg] Exception saving config: %@", exception);
    }
}

#pragma mark - Expanded State

- (NSSet<NSString *> *)expandedFolderPaths {
    NSMutableSet *paths = [NSMutableSet set];
    [self collectExpandedPaths:paths fromNodes:self.mutableRootNodes];
    return paths;
}

- (void)collectExpandedPaths:(NSMutableSet *)paths fromNodes:(NSArray<TreeNode *> *)nodes {
    for (TreeNode *node in nodes) {
        if (node.isFolder && node.isExpanded) {
            [paths addObject:node.path];
            [self collectExpandedPaths:paths fromNodes:node.children];
        }
    }
}

- (void)setExpandedFolderPaths:(NSSet<NSString *> *)paths {
    [self applyExpandedPaths:paths toNodes:self.mutableRootNodes];
}

- (void)applyExpandedPaths:(NSSet<NSString *> *)paths toNodes:(NSArray<TreeNode *> *)nodes {
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            node.isExpanded = [paths containsObject:node.path];
            [self applyExpandedPaths:paths toNodes:node.children];
        }
    }
}

#pragma mark - Default Tree

- (void)createDefaultTree {
    [self.mutableRootNodes removeAllObjects];
    self.nodeFormat = @"%node_name%$if(%is_folder%, [%count%],)";

    // Import existing playlists from foobar2000
    @try {
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            NSString *playlistName = [NSString stringWithUTF8String:name.c_str()];
            if (playlistName && playlistName.length > 0) {
                TreeNode *playlist = [TreeNode playlistWithName:playlistName];
                playlist.parent = nil;
                [self.mutableRootNodes addObject:playlist];
            }
        }
        FB2K_console_formatter() << "[Plorg] Imported " << count << " existing playlists";
    } @catch (NSException *exception) {
        NSLog(@"[Plorg] Exception importing playlists: %@", exception);
    }

    [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
    [self saveToConfig];
}

#pragma mark - Notifications

- (void)notifyChange:(TreeModelChangeType)type node:(TreeNode *)node index:(NSInteger)index {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[TreeModelChangeTypeKey] = @(type);
    if (node) {
        userInfo[TreeModelChangedNodeKey] = node;
    }
    if (index >= 0) {
        userInfo[TreeModelChangeIndexKey] = @(index);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TreeModelDidChangeNotification
                                                            object:self
                                                          userInfo:userInfo];
    });
}

@end
