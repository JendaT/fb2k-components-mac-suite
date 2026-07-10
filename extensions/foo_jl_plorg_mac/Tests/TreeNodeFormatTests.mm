//
//  TreeNodeFormatTests.mm
//  foo_plorg_mac
//
//  Unit tests for TreeNode's titleformat mini-engine (%vars% + $if()) and
//  dictionary serialization used by the legacy configStore migration path.
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TreeNode.h"

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

static BOOL objEq(id a, id b) {
    return (a == b) || [a isEqual:b];
}

#define CHECK_EQ(got, want, what)                                                \
    do {                                                                         \
        g_checks++;                                                             \
        if (!objEq((got), (want))) {                                            \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %s, expected %s\n", g_context.c_str(),    \
                   what, [(got) description].UTF8String ?: "(nil)",             \
                   [(want) description].UTF8String ?: "(nil)");                 \
        }                                                                        \
    } while (0)

int main(void) {
    @autoreleasepool {

    // --- Variable substitution ---
    {
        g_context = "variables";
        TreeNode *pl = [TreeNode playlistWithName:@"Bebop"];
        CHECK_EQ([pl formattedNameWithFormat:@"%node_name%" playlistItemCount:12], @"Bebop",
                 "node_name for playlist");
        CHECK_EQ([pl formattedNameWithFormat:@"%count%" playlistItemCount:12], @"12",
                 "count is item count for playlists");
        CHECK_EQ([pl formattedNameWithFormat:@"[%is_folder%]" playlistItemCount:0], @"[]",
                 "is_folder empty for playlists");

        TreeNode *folder = [TreeNode folderWithName:@"Jazz"];
        [folder addChild:[TreeNode playlistWithName:@"A"]];
        [folder addChild:[TreeNode playlistWithName:@"B"]];
        CHECK_EQ([folder formattedNameWithFormat:@"%count%" playlistItemCount:99], @"2",
                 "count is child count for folders (item count ignored)");
        CHECK_EQ([folder formattedNameWithFormat:@"[%is_folder%]" playlistItemCount:0], @"[1]",
                 "is_folder is 1 for folders");

        // Empty/absent format falls back to the raw name
        CHECK_EQ([pl formattedNameWithFormat:@"" playlistItemCount:0], @"Bebop", "empty format -> name");
        NSString *nilFormat = nil;
        CHECK_EQ([pl formattedNameWithFormat:nilFormat playlistItemCount:0], @"Bebop", "nil format -> name");
    }

    // --- $if() conditionals ---
    {
        g_context = "if-conditional";
        TreeNode *folder = [TreeNode folderWithName:@"Jazz"];
        [folder addChild:[TreeNode playlistWithName:@"A"]];
        TreeNode *pl = [TreeNode playlistWithName:@"Solo"];

        // The shipped default format (see TreeModel createDefaultTree).
        // NOTE: unquoted args are whitespace-trimmed, so the space the author
        // wrote before "[" is stripped and folders render as "Jazz[1]", not
        // "Jazz [1]". Quoting the arg (' [%count%]') would preserve it.
        // Pinning current behavior; changing it alters every user's display.
        NSString *fmt = @"%node_name%$if(%is_folder%, [%count%],)";
        CHECK_EQ([folder formattedNameWithFormat:fmt playlistItemCount:0], @"Jazz[1]",
                 "folder takes true branch (leading space trimmed)");
        CHECK_EQ([pl formattedNameWithFormat:fmt playlistItemCount:7], @"Solo",
                 "playlist takes (empty) false branch");
        // The quoted form preserves the space
        CHECK_EQ([folder formattedNameWithFormat:@"%node_name%$if(%is_folder%,' [%count%]',)"
                              playlistItemCount:0], @"Jazz [1]",
                 "quoted arg preserves the leading space");

        // Non-empty condition -> true branch; empty -> false branch
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,yes,no)" playlistItemCount:0], @"yes",
                 "non-empty condition is true");
        CHECK_EQ([pl formattedNameWithFormat:@"$if(,yes,no)" playlistItemCount:0], @"no",
                 "empty condition is false");

        // Missing third arg is padded to empty
        CHECK_EQ([pl formattedNameWithFormat:@"$if(,yes)" playlistItemCount:0], @"",
                 "two-arg $if falls back to empty");
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,yes)" playlistItemCount:0], @"yes",
                 "two-arg $if true branch");
    }

    // --- Quoting: commas and parens inside single quotes are literal ---
    {
        g_context = "if-quoting";
        TreeNode *pl = [TreeNode playlistWithName:@"P"];
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,'a,b',no)" playlistItemCount:0], @"a,b",
                 "quoted comma not treated as arg separator");
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,'a)b',no)" playlistItemCount:0], @"a)b",
                 "quoted paren does not close the call");
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,' spaced ',no)" playlistItemCount:0], @" spaced ",
                 "quotes preserve surrounding spaces");
        // Unquoted args are whitespace-trimmed
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,  yes  ,no)" playlistItemCount:0], @"yes",
                 "unquoted arg trimmed");
    }

    // --- Malformed input degrades gracefully (no crash, no hang) ---
    {
        g_context = "if-malformed";
        TreeNode *pl = [TreeNode playlistWithName:@"P"];
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,yes" playlistItemCount:0], @"$if(x,yes",
                 "unclosed $if left as-is");
        CHECK_EQ([pl formattedNameWithFormat:@"$if(onlyone)" playlistItemCount:0], @"$if(onlyone)",
                 "single-arg $if left as-is");
        CHECK_EQ([pl formattedNameWithFormat:@"plain text" playlistItemCount:0], @"plain text",
                 "no $if is a passthrough");
        // Nested/sequential $if: the engine iterates (capped at 10 rewrites)
        CHECK_EQ([pl formattedNameWithFormat:@"$if(x,a,b)$if(,c,d)" playlistItemCount:0], @"ad",
                 "two sequential $if calls both resolve");
    }

    // --- Dictionary round trip (legacy JSON configStore migration path) ---
    {
        g_context = "dictionary";
        TreeNode *folder = [TreeNode folderWithName:@"Top"];
        folder.isExpanded = YES;
        TreeNode *sub = [TreeNode folderWithName:@"Sub"];
        [sub addChild:[TreeNode playlistWithName:@"Leaf"]];
        [folder addChild:sub];
        [folder addChild:[TreeNode playlistWithName:@"Direct"]];

        TreeNode *back = [TreeNode fromDictionary:[folder toDictionary]];
        CHECK(back != nil && back.isFolder, "folder round-trips");
        CHECK(back.isExpanded, "expanded flag round-trips");
        CHECK(back.childCount == 2, "children round-trip");
        TreeNode *backSub = [back childAtIndex:0];
        CHECK(backSub.isFolder && backSub.childCount == 1, "nested folder round-trips");
        CHECK_EQ([backSub childAtIndex:0].name, @"Leaf", "nested leaf name round-trips");
        CHECK([back childAtIndex:0].parent == back, "parent wired on rebuild");

        TreeNode *pl = [TreeNode playlistWithName:@"Solo"];
        TreeNode *plBack = [TreeNode fromDictionary:[pl toDictionary]];
        CHECK(plBack != nil && !plBack.isFolder, "playlist round-trips");

        NSDictionary *nilDict = nil;
        CHECK([TreeNode fromDictionary:nilDict] == nil, "nil dict -> nil");
        CHECK([TreeNode fromDictionary:@{}] == nil, "unrecognized dict -> nil");
    }

    // --- Path building ---
    {
        g_context = "path";
        TreeNode *a = [TreeNode folderWithName:@"A"];
        TreeNode *b = [TreeNode folderWithName:@"B"];
        TreeNode *leaf = [TreeNode playlistWithName:@"L"];
        [a addChild:b];
        [b addChild:leaf];
        CHECK_EQ(a.path, @"A", "root path is its name");
        CHECK_EQ(leaf.path, @"A/B/L", "nested path joins ancestors");
    }

    // --- Nil-name safety (factories coerce nil to empty) ---
    {
        g_context = "nil-safety";
        NSString *nilName = nil;
        TreeNode *f = [TreeNode folderWithName:nilName];
        CHECK_EQ(f.name, @"", "nil folder name becomes empty");
        CHECK_EQ([f formattedNameWithFormat:@"%node_name%" playlistItemCount:0], @"",
                 "empty name formats to empty");
    }

    }
    printf("TreeNodeFormatTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
