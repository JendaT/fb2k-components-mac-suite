//
//  TreeOpsTests.mm
//  foo_plorg_mac
//
//  Unit tests for TreeOps (tree queries and import merge).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TreeNode.h"
#import "../src/Core/TreeOps.h"

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
        CHECK([TreeOps findPlaylistNamed:@"Inbox" inNodes:roots] != nil, "finds root playlist");
        CHECK([TreeOps findPlaylistNamed:@"Kind of Blue" inNodes:roots] != nil, "finds nested playlist");
        CHECK([TreeOps findPlaylistNamed:@"Jazz" inNodes:roots] == nil, "folder name does not match");
        CHECK([TreeOps findPlaylistNamed:@"Missing" inNodes:roots] == nil, "missing -> nil");
    }

    // --- findPlaylistForComponents ---
    {
        g_context = "find-components";
        NSMutableArray *roots = makeFixture();
        CHECK([TreeOps findPlaylistForComponents:(@[@"Jazz", @"Bebop"]) inRoots:roots] != nil,
              "one folder + leaf");
        CHECK([TreeOps findPlaylistForComponents:(@[@"Jazz", @"Modal", @"Kind of Blue"]) inRoots:roots] != nil,
              "two folders + leaf");
        CHECK([TreeOps findPlaylistForComponents:(@[@"Jazz", @"Missing", @"X"]) inRoots:roots] == nil,
              "missing folder -> nil");
        CHECK([TreeOps findPlaylistForComponents:(@[@"Jazz", @"Kind of Blue"]) inRoots:roots] == nil,
              "leaf not directly in that folder -> nil");
        CHECK([TreeOps findPlaylistForComponents:(@[@"Inbox"]) inRoots:roots] != nil,
              "single component searches root level leaves");
        CHECK([TreeOps findPlaylistForComponents:@[] inRoots:roots] == nil, "empty components -> nil");
        // Folder with the leaf's name must not match
        CHECK([TreeOps findPlaylistForComponents:(@[@"Jazz", @"Modal"]) inRoots:roots] == nil,
              "folder at leaf position does not match");
    }

    // --- findFolderForComponents ---
    {
        g_context = "find-folder";
        NSMutableArray *roots = makeFixture();
        TreeNode *jazz = roots[0];
        CHECK([TreeOps findFolderForComponents:@[@"Jazz"] inRoots:roots] == jazz,
              "resolves top-level folder");
        TreeNode *modal = jazz.children[1];
        CHECK([TreeOps findFolderForComponents:(@[@"Jazz", @"Modal"]) inRoots:roots] == modal,
              "resolves nested folder");
        CHECK([TreeOps findFolderForComponents:(@[@"Jazz", @"Missing"]) inRoots:roots] == nil,
              "missing component -> nil");
        CHECK([TreeOps findFolderForComponents:@[@"Inbox"] inRoots:roots] == nil,
              "playlist is not a folder -> nil");
        CHECK([TreeOps findFolderForComponents:(@[@"Jazz", @"Bebop"]) inRoots:roots] == nil,
              "nested playlist is not a folder -> nil");
        CHECK([TreeOps findFolderForComponents:@[] inRoots:roots] == nil, "empty components -> nil");
    }

    // --- mergeNodes: new folder subtree counts fully ---
    {
        g_context = "merge-new-folder";
        NSMutableArray *roots = makeFixture();
        TreeNode *incoming = [TreeNode folderWithName:@"Rock"];
        [incoming addChild:[TreeNode playlistWithName:@"70s"]];
        [incoming addChild:[TreeNode playlistWithName:@"80s"]];

        NSInteger added = [TreeOps mergeNodes:@[incoming] intoParent:nil roots:roots];
        CHECK(added == 3, "new folder + 2 children = 3");
        CHECK(roots.count == 3, "folder appended at root");
        CHECK([TreeOps findPlaylistNamed:@"70s" inNodes:roots] != nil, "children present");
    }

    // --- mergeNodes: existing folder merges children, dupes skipped ---
    {
        g_context = "merge-existing-folder";
        NSMutableArray *roots = makeFixture();
        TreeNode *incoming = [TreeNode folderWithName:@"Jazz"];
        [incoming addChild:[TreeNode playlistWithName:@"Bebop"]];    // duplicate anywhere in tree
        [incoming addChild:[TreeNode playlistWithName:@"Fusion"]];   // new

        NSInteger added = [TreeOps mergeNodes:@[incoming] intoParent:nil roots:roots];
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
        NSInteger added = [TreeOps mergeNodes:@[[TreeNode playlistWithName:@"Kind of Blue"]]
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

        NSInteger added = [TreeOps mergeNodes:@[jazz] intoParent:nil roots:roots];
        CHECK(added == 1, "one new nested playlist");
        TreeNode *existingModal = ((TreeNode *)roots[0]).children[1];
        CHECK(existingModal.children.count == 2, "merged into existing Modal folder");
    }

    // --- countNodes ---
    {
        g_context = "count";
        NSMutableArray *roots = makeFixture();
        CHECK([TreeOps countNodes:roots] == 5, "5 nodes total");
        CHECK([TreeOps countNodes:@[]] == 0, "empty -> 0");
    }

    }
    printf("TreeOpsTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
