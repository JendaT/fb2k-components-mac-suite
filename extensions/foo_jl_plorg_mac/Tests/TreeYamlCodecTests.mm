//
//  TreeYamlCodecTests.mm
//  foo_plorg_mac
//
//  Unit tests for TreeYamlCodec (tree YAML serialization/parsing).
//  Compiled standalone (Foundation only); gating phase of Scripts/build.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/TreeNode.h"
#import "../src/Core/TreeYamlCodec.h"

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

// Structural equality of two trees (name, type, expanded, children)
static BOOL treesEqual(NSArray<TreeNode *> *a, NSArray<TreeNode *> *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        TreeNode *x = a[i], *y = b[i];
        if (x.isFolder != y.isFolder) return NO;
        if (![x.name isEqualToString:y.name]) return NO;
        if (x.isFolder) {
            if (x.isExpanded != y.isExpanded) return NO;
            if (!treesEqual(x.children ?: @[], y.children ?: @[])) return NO;
        }
    }
    return YES;
}

int main(void) {
    @autoreleasepool {

    // --- Escaping ---
    {
        g_context = "escaping";
        CHECK_EQ([TreeYamlCodec escapeString:@"a\"b\\c"], @"a\\\"b\\\\c", "quote and backslash escaped");
        CHECK_EQ([TreeYamlCodec unescapeString:@"a\\\"b\\\\c"], @"a\"b\\c", "unescape round-trips");
    }

    // --- extractQuotedValue ---
    {
        g_context = "extract-quoted";
        CHECK_EQ([TreeYamlCodec extractQuotedValue:@"- folder: \"My Folder\"" afterPrefix:@"- folder:"],
                 @"My Folder", "simple quoted value");
        CHECK_EQ([TreeYamlCodec extractQuotedValue:@"- playlist: \"Q \\\"A\\\"\"" afterPrefix:@"- playlist:"],
                 @"Q \"A\"", "escaped quotes unescaped");
        CHECK_EQ([TreeYamlCodec extractQuotedValue:@"- folder: bare" afterPrefix:@"- folder:"],
                 @"bare", "unquoted value returned raw");
        CHECK(([TreeYamlCodec extractQuotedValue:@"- folder: \"x\"" afterPrefix:@"- playlist:"] == nil),
              "missing prefix -> nil");
    }

    // --- Serialization shape ---
    {
        g_context = "serialize";
        TreeNode *folder = [TreeNode folderWithName:@"Jazz"];
        folder.isExpanded = YES;
        [folder addChild:[TreeNode playlistWithName:@"Bebop"]];
        TreeNode *rootPl = [TreeNode playlistWithName:@"Inbox"];

        NSString *yaml = [TreeYamlCodec yamlForTree:@[folder, rootPl] nodeFormat:@"%node_name%"];
        CHECK([yaml containsString:@"node_format: \"%node_name%\""], "node_format emitted");
        CHECK([yaml containsString:@"- folder: \"Jazz\""], "folder emitted");
        CHECK([yaml containsString:@"expanded: true"], "expanded emitted");
        CHECK([yaml containsString:@"- playlist: \"Bebop\""], "child playlist emitted");
        CHECK([yaml containsString:@"- playlist: \"Inbox\""], "root playlist emitted");

        NSString *empty = [TreeYamlCodec yamlForTree:@[] nodeFormat:nil];
        CHECK([empty containsString:@"tree: []"], "empty tree emits []");
        CHECK([empty containsString:@"node_format: \"%node_name%\""], "nil format falls back to default");
    }

    // --- Round trip: serialize -> parseConfigYaml ---
    {
        g_context = "round-trip";
        TreeNode *a = [TreeNode folderWithName:@"A"];
        a.isExpanded = YES;
        TreeNode *b = [TreeNode folderWithName:@"B \"quoted\""];
        [a addChild:b];
        [b addChild:[TreeNode playlistWithName:@"deep\\pl"]];
        [a addChild:[TreeNode playlistWithName:@"shallow"]];
        TreeNode *c = [TreeNode folderWithName:@"C"];  // collapsed, empty
        NSArray *orig = @[a, c, [TreeNode playlistWithName:@"root pl"]];

        NSString *yaml = [TreeYamlCodec yamlForTree:orig nodeFormat:@"fmt \"x\""];

        NSArray<TreeNode *> *parsed = nil;
        NSString *fmt = nil;
        BOOL ok = [TreeYamlCodec parseConfigYaml:yaml rootNodes:&parsed nodeFormat:&fmt];
        CHECK(ok, "parse succeeds");
        CHECK_EQ(fmt, @"fmt \"x\"", "node_format round-trips with escaping");
        CHECK(treesEqual(orig, parsed), "tree structure round-trips");
    }

    // --- Round trip: serialize -> parseNodeList ---
    {
        g_context = "node-list";
        TreeNode *a = [TreeNode folderWithName:@"Rock"];
        [a addChild:[TreeNode playlistWithName:@"70s"]];
        [a addChild:[TreeNode playlistWithName:@"80s"]];
        NSArray *orig = @[a, [TreeNode playlistWithName:@"Loose"]];

        NSString *yaml = [TreeYamlCodec yamlForTree:orig nodeFormat:nil];
        NSArray<TreeNode *> *parsed = [TreeYamlCodec parseNodeList:yaml];
        CHECK(treesEqual(orig, parsed), "parseNodeList round-trips");
        CHECK_EQ([TreeYamlCodec parseNodeList:nil], @[], "nil yaml -> empty");
        CHECK_EQ([TreeYamlCodec parseNodeList:@""], @[], "empty yaml -> empty");
        CHECK_EQ([TreeYamlCodec parseNodeList:@"no tree section"], @[], "no tree section -> empty");
    }

    // --- Deep nesting round trip ---
    {
        g_context = "deep-nesting";
        TreeNode *root = [TreeNode folderWithName:@"L0"];
        TreeNode *cur = root;
        for (int i = 1; i < 6; i++) {
            TreeNode *next = [TreeNode folderWithName:[NSString stringWithFormat:@"L%d", i]];
            next.isExpanded = (i % 2 == 0);
            [cur addChild:next];
            cur = next;
        }
        [cur addChild:[TreeNode playlistWithName:@"leaf"]];
        // Sibling after the deep chain must return to root level
        NSArray *orig = @[root, [TreeNode playlistWithName:@"after"]];

        NSString *yaml = [TreeYamlCodec yamlForTree:orig nodeFormat:nil];
        NSArray *viaConfig = nil;
        [TreeYamlCodec parseConfigYaml:yaml rootNodes:&viaConfig nodeFormat:NULL];
        CHECK(treesEqual(orig, viaConfig), "deep nesting round-trips via parseConfigYaml");
        CHECK(treesEqual(orig, [TreeYamlCodec parseNodeList:yaml]),
              "deep nesting round-trips via parseNodeList");
    }

    // --- Malformed / degenerate input ---
    {
        g_context = "malformed";
        NSArray *r = nil;
        NSString *f = nil;
        CHECK(![TreeYamlCodec parseConfigYaml:@"" rootNodes:&r nodeFormat:&f], "empty -> NO");
        CHECK_EQ(r, @[], "empty -> empty roots");
        CHECK(![TreeYamlCodec parseConfigYaml:@"tree:\n" rootNodes:&r nodeFormat:&f], "tree only -> NO");
        CHECK(![TreeYamlCodec parseConfigYaml:@"node_format: \"X\"\ntree: []\n"
                                     rootNodes:&r nodeFormat:&f], "empty tree -> NO");
        CHECK_EQ(f, @"X", "node_format still extracted when tree empty");
        // Comments and blank lines ignored
        BOOL ok = [TreeYamlCodec parseConfigYaml:@"# c\n\ntree:\n  - playlist: \"P\"\n"
                                       rootNodes:&r nodeFormat:&f];
        CHECK(ok && r.count == 1, "comments/blank lines skipped");
    }

    }
    printf("TreeYamlCodecTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
