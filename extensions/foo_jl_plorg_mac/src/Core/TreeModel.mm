//
//  TreeModel.mm
//  foo_plorg_mac
//

#import "TreeModel.h"
#import "ConfigHelper.h"
#import "TreeNode.h"
#import "PathCodec.h"
#import "TreeOps.h"
#import "TreeYamlCodec.h"
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

@synthesize migrationGeneration = _migrationGeneration;

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
    return [TreeOps findPlaylistNamed:name inNodes:nodes];
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

#pragma mark - Path-Encoded Foobar Names

- (NSString *)encodedFoobarNameForNode:(TreeNode *)node {
    if (!node || node.isFolder) return nil;

    // Build path components from leaf to root
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    TreeNode *current = node;
    while (current) {
        [components insertObject:(current.name ?: @"") atIndex:0];
        current = current.parent;
    }

    return [PathCodec encodedNameForComponents:components];
}

- (NSString *)foobarNameForNode:(TreeNode *)node {
    if (!node || node.isFolder) return nil;

    BOOL encodingEnabled = plorg_config::getConfigBool(plorg_config::kPathEncodedNames,
                                                        plorg_config::kDefaultPathEncodedNames);
    if (!encodingEnabled) {
        return node.name;
    }

    return [self encodedFoobarNameForNode:node];
}

- (TreeNode *)findPlaylistForFoobarName:(NSString *)foobarName {
    if (!foobarName || foobarName.length == 0) return nil;

    // Decode the path components
    NSArray<NSString *> *components = [PathCodec splitEncodedName:foobarName];
    if (components.count == 0) return nil;

    // Single component -> search everywhere by leaf name
    if (components.count == 1) {
        return [self findPlaylistWithName:components[0]];
    }

    // Multi-component: always try path-aware lookup regardless of encoding setting.
    // Foobar playlists may have encoded names from a previous migration even when
    // encoding is currently off. Without this, sync creates duplicate nodes.
    return [TreeOps findPlaylistForComponents:components inRoots:self.mutableRootNodes];
}

- (void)migrateToPathEncodedNames {
    _migrationGeneration++;

    @try {
        auto pm = playlist_manager::get();
        [self migrateNodeToEncoded:self.mutableRootNodes playlistManager:pm];
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Exception during migration to path-encoded names";
    }
}

- (void)migrateNodeToEncoded:(NSArray<TreeNode *> *)nodes playlistManager:(playlist_manager::ptr)pm {
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            [self migrateNodeToEncoded:node.children playlistManager:pm];
        } else {
            // Root-level playlists don't need encoding
            if (!node.parent) continue;

            NSString *oldName = node.name;
            NSString *newName = [self encodedFoobarNameForNode:node];
            if (!newName || [oldName isEqualToString:newName]) continue;

            t_size index = pm->find_playlist([oldName UTF8String], pfc_infinite);
            if (index == pfc_infinite) {
                FB2K_console_formatter() << "[Plorg] Migration: playlist not found: " << [oldName UTF8String];
                continue;
            }

            pfc::string8 newNameStr([newName UTF8String]);
            pm->playlist_rename(index, newNameStr.c_str(), newNameStr.get_length());
            FB2K_console_formatter() << "[Plorg] Migrated: " << [oldName UTF8String] << " -> " << newNameStr.c_str();
        }
    }
}

- (void)migrateFromPathEncodedNames {
    _migrationGeneration++;

    @try {
        auto pm = playlist_manager::get();
        [self migrateNodeFromEncoded:self.mutableRootNodes playlistManager:pm];
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Exception during migration from path-encoded names";
    }
}

- (void)migrateNodeFromEncoded:(NSArray<TreeNode *> *)nodes playlistManager:(playlist_manager::ptr)pm {
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            [self migrateNodeFromEncoded:node.children playlistManager:pm];
        } else {
            if (!node.parent) continue;

            NSString *encodedName = [self encodedFoobarNameForNode:node];
            if (!encodedName) continue;

            t_size index = pm->find_playlist([encodedName UTF8String], pfc_infinite);
            if (index == pfc_infinite) {
                FB2K_console_formatter() << "[Plorg] Migration: encoded playlist not found: " << [encodedName UTF8String];
                continue;
            }

            NSString *leafName = node.name;
            // Check for collision with existing foobar playlists
            t_size existing = pm->find_playlist([leafName UTF8String], pfc_infinite);
            if (existing != pfc_infinite && existing != index) {
                // Collision: make unique
                NSString *uniqueName = [self makeUniquePlaylistName:leafName playlistManager:pm];
                node.name = uniqueName;
                leafName = uniqueName;
            }

            pfc::string8 newNameStr([leafName UTF8String]);
            pm->playlist_rename(index, newNameStr.c_str(), newNameStr.get_length());
            FB2K_console_formatter() << "[Plorg] Unmigrated: " << [encodedName UTF8String] << " -> " << newNameStr.c_str();
        }
    }
}

- (NSString *)makeUniquePlaylistName:(NSString *)baseName playlistManager:(playlist_manager::ptr)pm {
    NSString *candidate = baseName;
    int suffix = 2;
    while (pm->find_playlist([candidate UTF8String], pfc_infinite) != pfc_infinite) {
        candidate = [NSString stringWithFormat:@"%@ (%d)", baseName, suffix++];
    }
    return candidate;
}

- (void)repairCorruptedFoobarNames {
    // One-time repair for foobar playlist names corrupted by the old verifyEncodedNames.
    // That method double-encoded dirty node names (e.g., "music.hq >> Ambient" as a leaf name),
    // producing mangled foobar names like "music.hq >> music.hq >>>> Ambient".
    // This computes the exact corrupted form and renames back to the correct encoded name.

    BOOL encodingEnabled = plorg_config::getConfigBool(plorg_config::kPathEncodedNames,
                                                        plorg_config::kDefaultPathEncodedNames);
    if (!encodingEnabled) return;

    // Within-session idempotency (loadFromConfig is called twice per startup)
    static BOOL hasRunThisSession = NO;
    if (hasRunThisSession) return;
    hasRunThisSession = YES;

    // Persistent one-time guard
    if (plorg_config::getConfigBool("repair_corrupted_names_v1_done", false)) return;

    @try {
        auto pm = playlist_manager::get();
        NSInteger repairedCount = 0;

        [self repairCorruptedNamesInNodes:self.mutableRootNodes playlistManager:pm repairedCount:&repairedCount];

        if (repairedCount > 0) {
            FB2K_console_formatter() << "[Plorg] Repaired " << (int)repairedCount << " corrupted foobar playlist names";
        }

        plorg_config::setConfigBool("repair_corrupted_names_v1_done", true);
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Exception during repairCorruptedFoobarNames";
    }
}

- (void)repairCorruptedNamesInNodes:(NSArray<TreeNode *> *)nodes
                    playlistManager:(playlist_manager::ptr)pm
                      repairedCount:(NSInteger *)count {
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            [self repairCorruptedNamesInNodes:node.children playlistManager:pm repairedCount:count];
            continue;
        }
        if (!node.parent) continue;  // Root-level playlists were never encoded

        NSString *expected = [self encodedFoobarNameForNode:node];
        if (!expected) continue;

        // Already correct?
        if (pm->find_playlist([expected UTF8String], pfc_infinite) != pfc_infinite) continue;

        // Compute the corrupted form deterministically:
        // The old dirty node.name WAS the expected encoded name (e.g., "music.hq >> Ambient").
        // verifyEncodedNames treated it as a leaf, escaped it, and prepended the parent path.
        NSString *dirtyLeaf = expected;
        NSString *escapedDirty = [PathCodec escapeComponent:dirtyLeaf];

        // Build parent path components
        NSMutableArray<NSString *> *parentComponents = [NSMutableArray array];
        TreeNode *parent = node.parent;
        while (parent) {
            NSString *escaped = [PathCodec escapeComponent:parent.name];
            if (escaped.length > 0) {
                [parentComponents insertObject:escaped atIndex:0];
            }
            parent = parent.parent;
        }
        [parentComponents addObject:escapedDirty];
        NSString *corruptedName = [parentComponents componentsJoinedByString:PlorgPathSeparator];

        // Find the corrupted playlist
        t_size corruptedIdx = pm->find_playlist([corruptedName UTF8String], pfc_infinite);
        if (corruptedIdx == pfc_infinite) continue;

        // Collision check: verify target doesn't already exist
        if (pm->find_playlist([expected UTF8String], pfc_infinite) != pfc_infinite) continue;

        // Rename corrupted -> expected
        pfc::string8 newNameStr([expected UTF8String]);
        pm->playlist_rename(corruptedIdx, newNameStr.c_str(), newNameStr.get_length());
        FB2K_console_formatter() << "[Plorg] Repaired: " << [corruptedName UTF8String]
                                  << " -> " << [expected UTF8String];
        (*count)++;
    }
}

- (NSInteger)countPathEncodingCollisions {
    // Count how many leaf names would collide in a flat namespace
    NSMutableDictionary<NSString *, NSMutableArray<TreeNode *> *> *nameMap = [NSMutableDictionary dictionary];
    [self collectLeafNames:self.mutableRootNodes into:nameMap];

    NSInteger collisions = 0;
    for (NSString *name in nameMap) {
        if (nameMap[name].count > 1) {
            collisions += nameMap[name].count;
        }
    }
    return collisions;
}

- (void)collectLeafNames:(NSArray<TreeNode *> *)nodes into:(NSMutableDictionary<NSString *, NSMutableArray<TreeNode *> *> *)map {
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            [self collectLeafNames:node.children into:map];
        } else {
            if (!map[node.name]) {
                map[node.name] = [NSMutableArray array];
            }
            [map[node.name] addObject:node];
        }
    }
}

#pragma mark - Playlist Sync

- (void)handlePlaylistCreated:(NSString *)name {
    BOOL encodingEnabled = plorg_config::getConfigBool(plorg_config::kPathEncodedNames,
                                                        plorg_config::kDefaultPathEncodedNames);

    // Always try path-aware lookup (handles encoded names regardless of setting)
    if ([self findPlaylistForFoobarName:name]) return;

    // Also try flat name lookup
    if ([self findPlaylistWithName:name]) return;

    // Add playlist - decode into folder hierarchy if name contains path separator
    BOOL nameHasPath = [name containsString:PlorgPathSeparator];
    [self addPlaylistFromFoobarName:name encodingEnabled:(encodingEnabled || nameHasPath)];
}

- (void)addPlaylistFromFoobarName:(NSString *)foobarName encodingEnabled:(BOOL)encodingEnabled {
    if (encodingEnabled) {
        NSArray<NSString *> *components = [PathCodec splitEncodedName:foobarName];
        if (components.count > 1) {
            // Multi-component: create/find folder path, add playlist as leaf
            TreeNode *parent = nil;
            NSMutableArray<TreeNode *> *currentLevel = self.mutableRootNodes;

            for (NSUInteger i = 0; i < components.count - 1; i++) {
                NSString *folderName = components[i];
                TreeNode *foundFolder = nil;
                for (TreeNode *node in currentLevel) {
                    if (node.isFolder && [node.name isEqualToString:folderName]) {
                        foundFolder = node;
                        break;
                    }
                }
                if (!foundFolder) {
                    foundFolder = [TreeNode folderWithName:folderName];
                    if (parent) {
                        [parent addChild:foundFolder];
                    } else {
                        [self.mutableRootNodes addObject:foundFolder];
                    }
                }
                parent = foundFolder;
                currentLevel = foundFolder.children;
            }

            NSString *leafName = components.lastObject;
            TreeNode *playlist = [TreeNode playlistWithName:leafName];
            [parent addChild:playlist];
            return;
        }
    }

    // Single-component or encoding off: add at root with the name as-is
    TreeNode *playlist = [TreeNode playlistWithName:foobarName];
    playlist.parent = nil;
    [self.mutableRootNodes addObject:playlist];
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

- (void)cleanupEncodedNamesInTree {
    // Fix playlist nodes whose names contain the path separator " >> ".
    // The FTH import stored full path-encoded names from the theme file as node names
    // (e.g., "music.hq >> Ambient" instead of just "Ambient"). These nodes are already
    // in the correct folder but need their names stripped to just the leaf component.
    NSMutableArray<TreeNode *> *toRelocate = [NSMutableArray array];
    [self collectMisplacedNodes:self.mutableRootNodes separator:PlorgPathSeparator into:toRelocate];

    for (TreeNode *node in toRelocate) {
        NSString *encodedName = node.name;
        NSArray<NSString *> *components = [PathCodec splitEncodedName:encodedName];
        if (components.count < 2) continue;

        // Remove from current location
        if (node.parent) {
            [node.parent removeChild:node];
        } else {
            [self.mutableRootNodes removeObject:node];
        }

        // Check if a correctly-named node already exists at the target location
        NSArray<TreeNode *> *targetLevel = self.mutableRootNodes;
        TreeNode *parentFolder = nil;
        for (NSUInteger i = 0; i < components.count - 1; i++) {
            NSString *folderName = components[i];
            TreeNode *foundFolder = nil;
            for (TreeNode *n in targetLevel) {
                if (n.isFolder && [n.name isEqualToString:folderName]) {
                    foundFolder = n;
                    break;
                }
            }
            if (!foundFolder) {
                foundFolder = [TreeNode folderWithName:folderName];
                if (parentFolder) {
                    [parentFolder addChild:foundFolder];
                } else {
                    [self.mutableRootNodes addObject:foundFolder];
                }
            }
            parentFolder = foundFolder;
            targetLevel = foundFolder.children;
        }

        NSString *leafName = components.lastObject;

        // Skip if the correct node already exists in the target folder
        BOOL exists = NO;
        for (TreeNode *n in targetLevel) {
            if (!n.isFolder && [n.name isEqualToString:leafName]) {
                exists = YES;
                break;
            }
        }
        if (exists) continue;

        // Relocate with corrected leaf name
        node.name = leafName;
        [parentFolder addChild:node];
        FB2K_console_formatter() << "[Plorg] Relocated misplaced node: " << [encodedName UTF8String]
                                  << " -> " << [leafName UTF8String] << " in folder " << [parentFolder.name UTF8String];
    }

    if (toRelocate.count > 0) {
        [self saveToConfig];
        [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
    }
}

- (void)collectMisplacedNodes:(NSArray<TreeNode *> *)nodes separator:(NSString *)sep into:(NSMutableArray<TreeNode *> *)result {
    for (TreeNode *node in nodes) {
        if (node.isFolder) {
            [self collectMisplacedNodes:node.children separator:sep into:result];
        } else if ([node.name containsString:sep]) {
            [result addObject:node];
        }
    }
}

- (void)syncWithFoobarPlaylists {
    BOOL encodingEnabled = plorg_config::getConfigBool(plorg_config::kPathEncodedNames,
                                                        plorg_config::kDefaultPathEncodedNames);

    @try {
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        NSInteger addedCount = 0;

        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            NSString *playlistName = [NSString stringWithUTF8String:name.c_str()];

            if (playlistName && playlistName.length > 0) {
                // Always try path-aware lookup first (handles encoded names regardless
                // of current encoding setting - prevents duplicate node creation)
                if ([self findPlaylistForFoobarName:playlistName]) continue;

                // Also try flat name lookup as fallback
                if ([self findPlaylistWithName:playlistName]) continue;

                // Not tracked - always decode into folder hierarchy if name contains
                // the path separator, even when encoding is off (the name IS encoded)
                BOOL nameHasPath = [playlistName containsString:PlorgPathSeparator];
                [self addPlaylistFromFoobarName:playlistName encodingEnabled:(encodingEnabled || nameHasPath)];
                addedCount++;
            }
        }

        if (addedCount > 0) {
            FB2K_console_formatter() << "[Plorg] Synced " << (int)addedCount << " missing playlists";
            [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
            [self saveToConfig];
        }

        // Clean up any nodes that still have full encoded paths as names
        [self cleanupEncodedNamesInTree];
    } @catch (NSException *exception) {
        NSLog(@"[Plorg] Exception syncing playlists: %@", exception);
    }
}

#pragma mark - YAML Serialization

- (NSString *)toYaml {
    return [TreeYamlCodec yamlForTree:self.mutableRootNodes nodeFormat:self.nodeFormat];
}

- (NSInteger)importFromYaml:(NSString *)yaml {
    if (!yaml || yaml.length == 0) return 0;

    NSArray<TreeNode *> *parsedRoots = [TreeYamlCodec parseNodeList:yaml];

    // Merge parsed nodes into current tree
    NSInteger imported = [TreeOps mergeNodes:parsedRoots intoParent:nil roots:self.mutableRootNodes];
    [self saveToConfig];
    [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];

    return imported;
}

- (BOOL)parseYaml:(NSString *)yaml {
    NSArray<TreeNode *> *rootNodes = nil;
    NSString *nodeFormat = nil;
    BOOL hasTree = [TreeYamlCodec parseConfigYaml:yaml rootNodes:&rootNodes nodeFormat:&nodeFormat];

    if (nodeFormat) {
        self.nodeFormat = nodeFormat;
    }

    if (hasTree) {
        [self.mutableRootNodes setArray:rootNodes];
        return YES;
    }

    return NO;
}

#pragma mark - Persistence

- (void)loadFromConfig {
    @try {
        // Load from YAML file
        NSString *config = plorg_config::loadTreeFromFile();
        if (config.length > 0 && [self parseYaml:config]) {
            FB2K_console_formatter() << "[Plorg] Loaded tree from " << [plorg_config::getConfigFilePath() UTF8String];
            [self cleanupEncodedNamesInTree];
            [self notifyChange:TreeModelChangeTypeReload node:nil index:-1];
            return;
        }

        // Migration: try loading from old configStore location
        NSString *oldConfig = plorg_config::getConfigString("tree_structure", "");
        if (oldConfig.length > 0) {
            // Try YAML
            if ([self parseYaml:oldConfig]) {
                FB2K_console_formatter() << "[Plorg] Migrated tree from configStore to file";
                [self cleanupEncodedNamesInTree];
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
                    [self cleanupEncodedNamesInTree];
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
