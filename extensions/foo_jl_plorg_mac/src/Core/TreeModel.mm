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

// Path encoding separator: space + right guillemet (U+00BB) + space
static NSString * const kPathSeparator = @" \u00BB ";
// Single guillemet character used for escaping
static unichar const kGuillemet = 0x00BB;

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

#pragma mark - Path-Encoded Foobar Names

- (NSString *)escapePathComponent:(NSString *)component {
    if (!component) return @"";  // Handle nil gracefully
    // Escape guillemet by doubling: \u00BB -> \u00BB\u00BB
    NSString *guilStr = [NSString stringWithCharacters:&kGuillemet length:1];
    NSString *doubled = [NSString stringWithFormat:@"%@%@", guilStr, guilStr];
    return [component stringByReplacingOccurrencesOfString:guilStr withString:doubled];
}

- (NSString *)unescapePathComponent:(NSString *)component {
    if (!component) return @"";  // Handle nil gracefully
    // Unescape doubled guillemet: \u00BB\u00BB -> \u00BB
    NSString *guilStr = [NSString stringWithCharacters:&kGuillemet length:1];
    NSString *doubled = [NSString stringWithFormat:@"%@%@", guilStr, guilStr];
    return [component stringByReplacingOccurrencesOfString:doubled withString:guilStr];
}

- (NSString *)encodedFoobarNameForNode:(TreeNode *)node {
    if (!node || node.isFolder) return nil;

    // Build path components from leaf to root
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    TreeNode *current = node;
    while (current) {
        NSString *escaped = [self escapePathComponent:current.name];
        if (escaped.length > 0) {  // Skip empty/nil components
            [components insertObject:escaped atIndex:0];
        }
        current = current.parent;
    }

    // Root-level playlists have only 1 component -> no prefix
    // components already contain escaped values from the while loop above
    if (components.count <= 1) {
        return components.firstObject ?: @"";
    }

    return [components componentsJoinedByString:kPathSeparator];
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

- (NSArray<NSString *> *)splitEncodedName:(NSString *)encodedName {
    // Split on " \u00BB " (the 3-char separator), then unescape each component
    NSArray<NSString *> *rawComponents = [encodedName componentsSeparatedByString:kPathSeparator];
    NSMutableArray<NSString *> *result = [NSMutableArray arrayWithCapacity:rawComponents.count];
    for (NSString *raw in rawComponents) {
        [result addObject:[self unescapePathComponent:raw]];
    }
    return result;
}

- (TreeNode *)findPlaylistForFoobarName:(NSString *)foobarName {
    if (!foobarName || foobarName.length == 0) return nil;

    // Decode the path components
    NSArray<NSString *> *components = [self splitEncodedName:foobarName];
    if (components.count == 0) return nil;

    // Single component -> search everywhere by leaf name
    if (components.count == 1) {
        return [self findPlaylistWithName:components[0]];
    }

    // Multi-component: always try path-aware lookup regardless of encoding setting.
    // Foobar playlists may have encoded names from a previous migration even when
    // encoding is currently off. Without this, sync creates duplicate nodes.
    NSArray<TreeNode *> *currentLevel = self.mutableRootNodes;
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
        NSString *escapedDirty = [self escapePathComponent:dirtyLeaf];

        // Build parent path components
        NSMutableArray<NSString *> *parentComponents = [NSMutableArray array];
        TreeNode *parent = node.parent;
        while (parent) {
            NSString *escaped = [self escapePathComponent:parent.name];
            if (escaped.length > 0) {
                [parentComponents insertObject:escaped atIndex:0];
            }
            parent = parent.parent;
        }
        [parentComponents addObject:escapedDirty];
        NSString *corruptedName = [parentComponents componentsJoinedByString:kPathSeparator];

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
    BOOL nameHasPath = [name containsString:kPathSeparator];
    [self addPlaylistFromFoobarName:name encodingEnabled:(encodingEnabled || nameHasPath)];
}

- (void)addPlaylistFromFoobarName:(NSString *)foobarName encodingEnabled:(BOOL)encodingEnabled {
    if (encodingEnabled) {
        NSArray<NSString *> *components = [self splitEncodedName:foobarName];
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
    [self collectMisplacedNodes:self.mutableRootNodes separator:kPathSeparator into:toRelocate];

    for (TreeNode *node in toRelocate) {
        NSString *encodedName = node.name;
        NSArray<NSString *> *components = [self splitEncodedName:encodedName];
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
                BOOL nameHasPath = [playlistName containsString:kPathSeparator];
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
