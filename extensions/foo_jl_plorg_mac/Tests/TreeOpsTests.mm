//
//  TreeOpsTests.mm
//  foo_plorg_mac
//
//  Unit tests for PlorgTreeOps (tree queries and import merge).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TreeNode.h"
#import "../src/Core/PlorgTreeOps.h"

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
