//
//  DecorationStoreTests.mm
//  foo_simplaylist_mac
//
//  Unit tests for DecorationStore (pure decoration cache/index model).
//  Compiled standalone (Foundation only) and run as a gating phase of
//  Scripts/build.sh. See Scripts/run_tests.sh.
//

#import <Foundation/Foundation.h>
#import "../src/Core/DecorationStore.h"

#include <string>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, what)                                                     \
    do {                                                                      \
        g_checks++;                                                          \
        if (!(cond)) {                                                       \
            g_failures++;                                                    \
            printf("FAIL %s (line %d)\n", what, __LINE__);                   \
        }                                                                     \
    } while (0)

static RowDecoration *makeTint(uint32_t rgba) {
    RowDecoration *d = [[RowDecoration alloc] init];
    d.tintRGBA = rgba;
    return d;
}

int main(void) {
    @autoreleasepool {
        // --- RowDecoration.isEmpty ---
        RowDecoration *empty = [[RowDecoration alloc] init];
        CHECK(empty.isEmpty, "default RowDecoration is empty");
        CHECK(!makeTint(0x336699FF).isEmpty, "tinted decoration is not empty");
        RowDecoration *struck = [[RowDecoration alloc] init];
        struck.strikethrough = YES;
        CHECK(!struck.isEmpty, "strikethrough-only decoration is not empty");
        RowDecoration *tipped = [[RowDecoration alloc] init];
        tipped.tooltip = @"hi";
        CHECK(!tipped.isEmpty, "tooltip-only decoration is not empty");

        DecorationStore *store = [[DecorationStore alloc] init];

        // --- Unbound index lookups are nil ---
        CHECK([store decorationForIndex:0] == nil, "unbound index -> nil");
        CHECK(![store isIndexBound:0], "index not bound initially");

        // --- Bound but unresolved handle -> nil ---
        [store bindIndex:0 toHandleKey:0x1000];
        CHECK([store isIndexBound:0], "index bound after bind");
        CHECK(![store hasEntryForHandleKey:0x1000], "no cache entry yet");
        CHECK([store decorationForIndex:0] == nil, "bound+unresolved -> nil");

        // --- Resolved with decoration ---
        [store setDecoration:makeTint(0x112233FF) forHandleKey:0x1000];
        CHECK([store hasEntryForHandleKey:0x1000], "entry present after set");
        CHECK([store decorationForIndex:0].tintRGBA == 0x112233FF, "lookup returns decoration");

        // --- Resolved-empty renders as nil but stays cached ---
        [store bindIndex:1 toHandleKey:0x2000];
        [store setDecoration:[[RowDecoration alloc] init] forHandleKey:0x2000];
        CHECK([store hasEntryForHandleKey:0x2000], "empty entry cached (no re-query)");
        CHECK([store decorationForIndex:1] == nil, "resolved-empty -> nil for drawing");

        // --- Two indices sharing one handle (duplicate track in playlist) ---
        [store bindIndex:2 toHandleKey:0x1000];
        CHECK([store decorationForIndex:2].tintRGBA == 0x112233FF, "shared handle decorates both indices");

        // --- Handle invalidation drops entries, keeps bindings ---
        uintptr_t gone[] = {0x1000};
        [store invalidateHandleKeys:gone count:1];
        CHECK(![store hasEntryForHandleKey:0x1000], "entry dropped on invalidate");
        CHECK([store hasEntryForHandleKey:0x2000], "other entries survive");
        CHECK([store isIndexBound:0], "bindings survive handle invalidate");
        CHECK([store decorationForIndex:0] == nil, "invalidated handle -> nil");

        // --- Global handle invalidation ---
        [store setDecoration:makeTint(0xFF0000FF) forHandleKey:0x1000];
        [store invalidateAllHandles];
        CHECK(store.handleEntryCount == 0, "all handle entries dropped");
        CHECK(store.bindingCount == 3, "bindings survive global invalidate");

        // --- Index bindings clear (playlist changed) ---
        [store setDecoration:makeTint(0xFF0000FF) forHandleKey:0x1000];
        [store clearIndexBindings];
        CHECK(store.bindingCount == 0, "bindings cleared");
        CHECK([store hasEntryForHandleKey:0x1000], "handle cache survives binding clear");
        CHECK([store decorationForIndex:0] == nil, "cleared binding -> nil");

        // --- Group decorations, including resolved-empty via nil ---
        GroupDecoration *badge = [[GroupDecoration alloc] init];
        badge.badgeText = @"-> [Psychill] 0.91";
        [store setGroupDecoration:badge forGroupIndex:7];
        [store setGroupDecoration:nil forGroupIndex:8];
        CHECK([store isGroupResolved:7], "group 7 resolved");
        CHECK([store isGroupResolved:8], "group 8 resolved (empty)");
        CHECK(![store isGroupResolved:9], "group 9 unresolved");
        CHECK([[store groupDecorationForGroupIndex:7].badgeText length] > 0, "group badge retrievable");
        CHECK([store groupDecorationForGroupIndex:8] == nil, "resolved-empty group -> nil");
        [store clearGroupDecorations];
        CHECK(![store isGroupResolved:7], "group cache cleared");

        // --- Icon-only decoration is not empty ---
        RowDecoration *iconOnly = [[RowDecoration alloc] init];
        iconOnly.iconId = 1;
        CHECK(!iconOnly.isEmpty, "icon-only decoration is not empty");

        // --- getHandleKey:forIndex: success and failure ---
        DecorationStore *store2 = [[DecorationStore alloc] init];
        uintptr_t outKey = 0;
        CHECK(![store2 getHandleKey:&outKey forIndex:0], "getHandleKey fails when unbound");
        [store2 bindIndex:0 toHandleKey:0xAAA0];
        CHECK([store2 getHandleKey:&outKey forIndex:0] && outKey == 0xAAA0,
              "getHandleKey returns bound key");

        // --- Rebinding an index to a different key wins ---
        [store2 setDecoration:makeTint(0x11111100) forHandleKey:0xAAA0];
        [store2 bindIndex:0 toHandleKey:0xBBB0];
        [store2 setDecoration:makeTint(0x22222200) forHandleKey:0xBBB0];
        CHECK([store2 decorationForIndex:0].tintRGBA == 0x22222200,
              "rebound index resolves via the new key");

        // --- Multi-key invalidation drops exactly the given keys ---
        [store2 bindIndex:1 toHandleKey:0xCCC0];
        [store2 setDecoration:makeTint(0x33333300) forHandleKey:0xCCC0];
        uintptr_t doomed[] = {0xAAA0, 0xBBB0};
        [store2 invalidateHandleKeys:doomed count:2];
        CHECK(![store2 hasEntryForHandleKey:0xAAA0], "multi-invalidate drops first key");
        CHECK(![store2 hasEntryForHandleKey:0xBBB0], "multi-invalidate drops second key");
        CHECK([store2 hasEntryForHandleKey:0xCCC0], "multi-invalidate keeps other keys");

        // --- clearIndexBindings also clears the group cache ---
        [store2 setGroupDecoration:[[GroupDecoration alloc] init] forGroupIndex:3];
        CHECK([store2 isGroupResolved:3], "group resolved before binding clear");
        [store2 clearIndexBindings];
        CHECK(![store2 isGroupResolved:3], "binding clear drops group cache too");

        printf("%s: %d checks, %d failures\n",
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED", g_checks, g_failures);
        return g_failures == 0 ? 0 : 1;
    }
}
