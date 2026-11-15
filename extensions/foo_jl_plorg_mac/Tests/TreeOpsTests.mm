//
//  TreeOpsTests.mm
//  foo_plorg_mac
//
//  Unit tests for PlorgTreeOps (tree queries, import merge, outside renames).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TreeNode.h"
#import "../src/Core/PlorgTreeOps.h"
#import "../src/Core/PlorgPathCodec.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

// Build:  Root
//           Jazz/       (folder)
//             Bebop
//             Modal/    (folder)
//               Kind of Blue
//           Inbox       (playlist)
static NSMutableArray<TreeNode *> *makeFixture(void) {
    TreeNode *jazz = [TreeNode folderWithName:@"Jazz"];
    [jazz addChild:[TreeNode playlistWithName:@"Bebop"]];
    TreeNode *modal = [TreeNode folderWithName:@"Modal"];
    [modal addChild:[TreeNode playlistWithName:@"Kind of Blue"]];
    [jazz addChild:modal];
    return [NSMutableArray arrayWithObjects:jazz, [TreeNode playlistWithName:@"Inbox"], nil];
}

// foobar2000 name for a path, as Plorg encodes it ("A \u00BB B")
static NSString *enc(NSArray<NSString *> *components) {
    return [PlorgPathCodec encodedNameForComponents:components];
}

int main(void) {
    @autoreleasepool {

    // --- findPlaylistNamed ---
    {
        g_context = "find-named";
        NSMutableArray *roots = makeFixture();
        CHECK([PlorgTreeOps findPlaylistNamed:@"Inbox" inNodes:roots] != nil, "finds root playlist");
        CHECK([PlorgTreeOps findPlaylistNamed:@"Kind of Blue" inNodes:roots] != nil, "finds nested playlist");
        CHECK([PlorgTreeOps findPlaylistNamed:@"Jazz" inNodes:roots] == nil, "folder name does not match");
        CHECK([PlorgTreeOps findPlaylistNamed:@"Missing" inNodes:roots] == nil, "missing -> nil");
    }

    // --- findPlaylistForComponents ---
    {
        g_context = "find-components";
        NSMutableArray *roots = makeFixture();
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"Jazz", @"Bebop"]) inRoots:roots] != nil,
              "one folder + leaf");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"Jazz", @"Modal", @"Kind of Blue"]) inRoots:roots] != nil,
              "two folders + leaf");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"Jazz", @"Missing", @"X"]) inRoots:roots] == nil,
              "missing folder -> nil");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"Jazz", @"Kind of Blue"]) inRoots:roots] == nil,
              "leaf not directly in that folder -> nil");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"Inbox"]) inRoots:roots] != nil,
              "single component searches root level leaves");
        CHECK([PlorgTreeOps findPlaylistForComponents:@[] inRoots:roots] == nil, "empty components -> nil");
        // Folder with the leaf's name must not match
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"Jazz", @"Modal"]) inRoots:roots] == nil,
              "folder at leaf position does not match");
    }

    // --- findFolderForComponents ---
    {
        g_context = "find-folder";
        NSMutableArray *roots = makeFixture();
        TreeNode *jazz = roots[0];
        CHECK([PlorgTreeOps findFolderForComponents:@[@"Jazz"] inRoots:roots] == jazz,
              "resolves top-level folder");
        TreeNode *modal = jazz.children[1];
        CHECK([PlorgTreeOps findFolderForComponents:(@[@"Jazz", @"Modal"]) inRoots:roots] == modal,
              "resolves nested folder");
        CHECK([PlorgTreeOps findFolderForComponents:(@[@"Jazz", @"Missing"]) inRoots:roots] == nil,
              "missing component -> nil");
        CHECK([PlorgTreeOps findFolderForComponents:@[@"Inbox"] inRoots:roots] == nil,
              "playlist is not a folder -> nil");
        CHECK([PlorgTreeOps findFolderForComponents:(@[@"Jazz", @"Bebop"]) inRoots:roots] == nil,
              "nested playlist is not a folder -> nil");
        CHECK([PlorgTreeOps findFolderForComponents:@[] inRoots:roots] == nil, "empty components -> nil");
    }

    // --- duplicate sibling folders fold during resolution ---
    {
        g_context = "duplicate-siblings";
        TreeNode *a1 = [TreeNode folderWithName:@"A"];
        [a1 addChild:[TreeNode playlistWithName:@"First"]];
        TreeNode *a2 = [TreeNode folderWithName:@"A"];
        [a2 addChild:[TreeNode playlistWithName:@"Second"]];
        NSMutableArray *roots = [NSMutableArray arrayWithObjects:a1, a2, nil];

        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"A", @"First"]) inRoots:roots] != nil,
              "playlist under first duplicate found");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"A", @"Second"]) inRoots:roots] != nil,
              "playlist under second duplicate found");
        CHECK(a1.children.count == 2, "children folded into first folder");
        CHECK(a2.children.count == 0, "duplicate folder emptied");
    }

    // --- nested duplicate folders fold recursively ---
    {
        g_context = "duplicate-nested";
        TreeNode *a1 = [TreeNode folderWithName:@"A"];
        TreeNode *sub1 = [TreeNode folderWithName:@"Sub"];
        [sub1 addChild:[TreeNode playlistWithName:@"P1"]];
        [a1 addChild:sub1];
        TreeNode *a2 = [TreeNode folderWithName:@"A"];
        TreeNode *sub2 = [TreeNode folderWithName:@"Sub"];
        [sub2 addChild:[TreeNode playlistWithName:@"P2"]];
        [a2 addChild:sub2];
        NSMutableArray *roots = [NSMutableArray arrayWithObjects:a1, a2, nil];

        CHECK([PlorgTreeOps findFolderForComponents:(@[@"A", @"Sub"]) inRoots:roots] == sub1,
              "nested duplicate resolves to first Sub");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"A", @"Sub", @"P1"]) inRoots:roots] != nil,
              "first nested playlist found");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"A", @"Sub", @"P2"]) inRoots:roots] != nil,
              "second nested playlist found");
    }

    // --- same-named folder and playlist are not merged ---
    {
        g_context = "duplicate-mixed-type";
        TreeNode *bFolder = [TreeNode folderWithName:@"B"];
        [bFolder addChild:[TreeNode playlistWithName:@"Inner"]];
        TreeNode *bPlaylist = [TreeNode playlistWithName:@"B"];
        NSMutableArray *roots = [NSMutableArray arrayWithObjects:bFolder, bPlaylist, nil];

        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"B", @"Inner"]) inRoots:roots] != nil,
              "folder path still resolves");
        CHECK([PlorgTreeOps findPlaylistForComponents:@[@"B"] inRoots:roots] == bPlaylist,
              "root playlist with folder's name still found");
        CHECK(bFolder.children.count == 1 && !bPlaylist.isFolder, "folder and playlist not merged");
    }

    // --- mergeNodes: new folder subtree counts fully ---
    {
        g_context = "merge-new-folder";
        NSMutableArray *roots = makeFixture();
        TreeNode *incoming = [TreeNode folderWithName:@"Rock"];
        [incoming addChild:[TreeNode playlistWithName:@"70s"]];
        [incoming addChild:[TreeNode playlistWithName:@"80s"]];

        NSInteger added = [PlorgTreeOps mergeNodes:@[incoming] intoParent:nil roots:roots];
        CHECK(added == 3, "new folder + 2 children = 3");
        CHECK(roots.count == 3, "folder appended at root");
        CHECK([PlorgTreeOps findPlaylistNamed:@"70s" inNodes:roots] != nil, "children present");
    }

    // --- mergeNodes: existing folder merges children, dupes skipped ---
    {
        g_context = "merge-existing-folder";
        NSMutableArray *roots = makeFixture();
        TreeNode *incoming = [TreeNode folderWithName:@"Jazz"];
        [incoming addChild:[TreeNode playlistWithName:@"Bebop"]];    // duplicate anywhere in tree
        [incoming addChild:[TreeNode playlistWithName:@"Fusion"]];   // new

        NSInteger added = [PlorgTreeOps mergeNodes:@[incoming] intoParent:nil roots:roots];
        CHECK(added == 1, "only the new playlist counted");
        CHECK(roots.count == 2, "no duplicate Jazz folder created");
        TreeNode *jazz = roots[0];
        CHECK(jazz.children.count == 3, "Fusion merged into existing Jazz");
    }

    // --- mergeNodes: playlist duplicate check is tree-wide ---
    {
        g_context = "merge-tree-wide-dupe";
        NSMutableArray *roots = makeFixture();
        // "Kind of Blue" exists deep under Jazz/Modal; importing it at root must be skipped
        NSInteger added = [PlorgTreeOps mergeNodes:@[[TreeNode playlistWithName:@"Kind of Blue"]]
                                   intoParent:nil roots:roots];
        CHECK(added == 0, "deep duplicate skipped");
        CHECK(roots.count == 2, "root unchanged");
    }

    // --- mergeNodes: nested merge into existing subfolder ---
    {
        g_context = "merge-nested";
        NSMutableArray *roots = makeFixture();
        TreeNode *jazz = [TreeNode folderWithName:@"Jazz"];
        TreeNode *modal = [TreeNode folderWithName:@"Modal"];
        [modal addChild:[TreeNode playlistWithName:@"So What"]];
        [jazz addChild:modal];

        NSInteger added = [PlorgTreeOps mergeNodes:@[jazz] intoParent:nil roots:roots];
        CHECK(added == 1, "one new nested playlist");
        TreeNode *existingModal = ((TreeNode *)roots[0]).children[1];
        CHECK(existingModal.children.count == 2, "merged into existing Modal folder");
    }

    // --- findPlaylistForFoobarName ---
    {
        g_context = "find-foobar-name";
        TreeNode *jazz = [TreeNode folderWithName:@"Jazz"];
        TreeNode *nestedX = [TreeNode playlistWithName:@"X"];
        [jazz addChild:nestedX];
        TreeNode *rootX = [TreeNode playlistWithName:@"X"];
        TreeNode *literal = [TreeNode playlistWithName:enc(@[@"Rock", @"Y"])];
        NSMutableArray *roots = [NSMutableArray arrayWithObjects:jazz, rootX, literal, nil];

        CHECK([PlorgTreeOps findPlaylistForFoobarName:enc(@[@"Jazz", @"X"]) inRoots:roots] == nestedX,
              "encoded name resolves by path");
        CHECK([PlorgTreeOps findPlaylistForFoobarName:@"X" inRoots:roots] == rootX,
              "one-part name prefers the root-level leaf");
        [roots removeObjectIdenticalTo:rootX];
        CHECK([PlorgTreeOps findPlaylistForFoobarName:@"X" inRoots:roots] == nestedX,
              "one-part name falls back to a nested leaf");
        CHECK([PlorgTreeOps findPlaylistForFoobarName:enc(@[@"Rock", @"Y"]) inRoots:roots] == literal,
              "leaf named with the whole string is the last resort");
        CHECK([PlorgTreeOps findPlaylistForFoobarName:@"Missing" inRoots:roots] == nil, "missing -> nil");
        CHECK([PlorgTreeOps findPlaylistForFoobarName:@"" inRoots:roots] == nil, "empty -> nil");
    }

    // --- followRename: move into a new folder ---
    {
        g_context = "rename-into-new-folder";
        TreeNode *tidal = [TreeNode folderWithName:@"TIDAL"];
        TreeNode *x = [TreeNode playlistWithName:@"X"];
        TreeNode *y = [TreeNode playlistWithName:@"Y"];
        [tidal addChild:x];
        [tidal addChild:y];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:tidal];

        TreeNode *result = [PlorgTreeOps followRenameFrom:enc(@[@"TIDAL", @"X"])
                                                       to:enc(@[@"TIDAL", @"Mood", @"X"])
                                            decodeNewPath:YES
                                                    roots:roots];
        TreeNode *mood = [PlorgTreeOps findFolderForComponents:@[@"TIDAL", @"Mood"] inRoots:roots];
        CHECK(result == x, "the renamed node is returned");
        CHECK(mood != nil && mood.parent == tidal, "Mood folder created under TIDAL");
        CHECK(x.parent == mood && mood.children.count == 1, "node moved into Mood");
        CHECK([x.name isEqualToString:@"X"], "leaf name kept");
        CHECK(tidal.children.count == 2 && tidal.children[0] == y, "TIDAL keeps Y and gains Mood");
        CHECK([PlorgTreeOps findPlaylistForComponents:(@[@"TIDAL", @"X"]) inRoots:roots] == nil,
              "old path is empty");
        CHECK(roots.count == 1, "no new root nodes");
    }

    // --- followRename: move between folders ---
    {
        g_context = "rename-between-folders";
        TreeNode *tidal = [TreeNode folderWithName:@"TIDAL"];
        TreeNode *a = [TreeNode folderWithName:@"A"];
        TreeNode *b = [TreeNode folderWithName:@"B"];
        TreeNode *x = [TreeNode playlistWithName:@"X"];
        TreeNode *z = [TreeNode playlistWithName:@"Z"];
        [a addChild:x];
        [b addChild:z];
        [tidal addChild:a];
        [tidal addChild:b];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:tidal];

        TreeNode *result = [PlorgTreeOps followRenameFrom:enc(@[@"TIDAL", @"A", @"X"])
                                                       to:enc(@[@"TIDAL", @"B", @"X"])
                                            decodeNewPath:YES
                                                    roots:roots];
        CHECK(result == x, "the renamed node is returned");
        CHECK(x.parent == b, "node now in B");
        CHECK(a.children.count == 0, "A left empty");
        CHECK(b.children.count == 2 && b.children[1] == x, "appended after B's playlist");
        CHECK(tidal.children.count == 2, "existing B reused, no folder created");
    }

    // --- followRename: plain rename, encoding off ---
    {
        g_context = "rename-plain";
        TreeNode *jazz = [TreeNode folderWithName:@"Jazz"];
        TreeNode *bebop = [TreeNode playlistWithName:@"Bebop"];
        [jazz addChild:bebop];
        [jazz addChild:[TreeNode playlistWithName:@"Cool"]];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:jazz];

        TreeNode *result = [PlorgTreeOps followRenameFrom:@"Bebop" to:@"Hard Bop"
                                            decodeNewPath:NO roots:roots];
        CHECK(result == bebop, "the renamed node is returned");
        CHECK([bebop.name isEqualToString:@"Hard Bop"], "name updated");
        CHECK(bebop.parent == jazz && jazz.children[0] == bebop, "stays in place");
        CHECK(jazz.children.count == 2 && roots.count == 1, "nothing added or removed");
    }

    // --- followRename: plain rename inside a folder, encoding on ---
    {
        g_context = "rename-plain-encoded";
        TreeNode *jazz = [TreeNode folderWithName:@"Jazz"];
        TreeNode *bebop = [TreeNode playlistWithName:@"Bebop"];
        [jazz addChild:bebop];
        [jazz addChild:[TreeNode playlistWithName:@"Cool"]];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:jazz];

        TreeNode *result = [PlorgTreeOps followRenameFrom:enc(@[@"Jazz", @"Bebop"])
                                                       to:enc(@[@"Jazz", @"Hard Bop"])
                                            decodeNewPath:YES
                                                    roots:roots];
        CHECK(result == bebop, "the renamed node is returned");
        CHECK([bebop.name isEqualToString:@"Hard Bop"], "leaf name updated");
        CHECK(bebop.parent == jazz && jazz.children[0] == bebop, "keeps its position in the folder");
        CHECK(jazz.children.count == 2, "nothing added or removed");
    }

    // --- followRename: escaped separator in the new leaf ---
    {
        g_context = "rename-escaped-leaf";
        TreeNode *tidal = [TreeNode folderWithName:@"TIDAL"];
        TreeNode *x = [TreeNode playlistWithName:@"X"];
        [tidal addChild:x];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:tidal];
        NSString *leaf = @"A \u00BB B";

        [PlorgTreeOps followRenameFrom:enc(@[@"TIDAL", @"X"]) to:enc(@[@"TIDAL", leaf])
                         decodeNewPath:YES roots:roots];
        CHECK([x.name isEqualToString:leaf], "leaf unescaped, not split");
        CHECK(x.parent == tidal && tidal.children.count == 1, "stays in TIDAL");
    }

    // --- followRename: one-part name moves to the root ---
    {
        g_context = "rename-to-root";
        TreeNode *tidal = [TreeNode folderWithName:@"TIDAL"];
        TreeNode *x = [TreeNode playlistWithName:@"X"];
        [tidal addChild:x];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:tidal];

        TreeNode *result = [PlorgTreeOps followRenameFrom:enc(@[@"TIDAL", @"X"]) to:@"X"
                                            decodeNewPath:YES roots:roots];
        CHECK(result == x, "the renamed node is returned");
        CHECK(x.parent == nil && roots.count == 2 && roots[1] == x, "moved to the root");
        CHECK(tidal.children.count == 0, "TIDAL left empty");
    }

    // --- followRename: one-part old name prefers the root-level leaf ---
    {
        g_context = "rename-root-preferred";
        TreeNode *jazz = [TreeNode folderWithName:@"Jazz"];
        TreeNode *nestedX = [TreeNode playlistWithName:@"X"];
        [jazz addChild:nestedX];
        TreeNode *rootX = [TreeNode playlistWithName:@"X"];
        NSMutableArray *roots = [NSMutableArray arrayWithObjects:jazz, rootX, nil];

        TreeNode *result = [PlorgTreeOps followRenameFrom:@"X" to:@"Y" decodeNewPath:YES roots:roots];
        CHECK(result == rootX, "root-level node renamed");
        CHECK([rootX.name isEqualToString:@"Y"] && rootX.parent == nil, "renamed in place at root");
        CHECK([nestedX.name isEqualToString:@"X"], "nested namesake untouched");
    }

    // --- followRename: stale node already at the target ---
    {
        g_context = "rename-stale-target";
        TreeNode *tidal = [TreeNode folderWithName:@"TIDAL"];
        TreeNode *mood = [TreeNode folderWithName:@"Mood"];
        TreeNode *oldX = [TreeNode playlistWithName:@"X"];
        TreeNode *staleX = [TreeNode playlistWithName:@"X"];
        [mood addChild:staleX];
        [tidal addChild:oldX];
        [tidal addChild:mood];
        NSMutableArray *roots = [NSMutableArray arrayWithObject:tidal];

        TreeNode *result = [PlorgTreeOps followRenameFrom:enc(@[@"TIDAL", @"X"])
                                                       to:enc(@[@"TIDAL", @"Mood", @"X"])
                                            decodeNewPath:YES
                                                    roots:roots];
        CHECK(result == staleX, "the node at the target is kept");
        CHECK(tidal.children.count == 1 && tidal.children[0] == mood, "old node removed from TIDAL");
        CHECK(oldX.parent == nil, "old node detached");
        CHECK(mood.children.count == 1 && mood.children[0] == staleX, "no duplicate at the target");
    }

    // --- followRename: stale node with the new flat name ---
    {
        g_context = "rename-stale-flat";
        TreeNode *oldNode = [TreeNode playlistWithName:@"Old"];
        TreeNode *newNode = [TreeNode playlistWithName:@"New"];
        NSMutableArray *roots = [NSMutableArray arrayWithObjects:oldNode, newNode, nil];

        TreeNode *result = [PlorgTreeOps followRenameFrom:@"Old" to:@"New" decodeNewPath:NO roots:roots];
        CHECK(result == newNode, "the existing node is kept");
        CHECK(roots.count == 1 && roots[0] == newNode, "old node removed");
    }

    // --- followRename: no node for the old name ---
    {
        g_context = "rename-no-old-node";
        NSMutableArray *roots = makeFixture();

        TreeNode *result = [PlorgTreeOps followRenameFrom:@"Missing"
                                                       to:enc(@[@"TIDAL", @"Missing"])
                                            decodeNewPath:YES
                                                    roots:roots];
        CHECK(result == nil, "nil when nothing matches");
        CHECK([PlorgTreeOps countNodes:roots] == 5, "tree unchanged");
        CHECK([PlorgTreeOps findFolderForComponents:@[@"TIDAL"] inRoots:roots] == nil, "no folder created");
        CHECK([PlorgTreeOps followRenameFrom:@"Inbox" to:@"Inbox" decodeNewPath:YES roots:roots] == nil,
              "same name is a no-op");
    }

    // --- countNodes ---
    {
        g_context = "count";
        NSMutableArray *roots = makeFixture();
        CHECK([PlorgTreeOps countNodes:roots] == 5, "5 nodes total");
        CHECK([PlorgTreeOps countNodes:@[]] == 0, "empty -> 0");
    }

    }
    printf("TreeOpsTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
