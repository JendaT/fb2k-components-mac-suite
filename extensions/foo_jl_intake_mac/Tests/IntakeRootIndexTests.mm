//
//  IntakeRootIndexTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeRootIndex (playlist path -> intake sidecar root).
//  Compiled standalone (Foundation only) under ASan+UBSan and run as a gating
//  phase of Scripts/build.sh. See Scripts/run_tests.sh.
//
//  All paths here are synthetic. No real collection names, NAS paths or income
//  folder contents appear in this repo (see CLAUDE.local.md).
//

#import <Foundation/Foundation.h>
#import "../src/Core/IntakeRootIndex.h"
#include "TestHarness.h"

static IntakeRoot *root(NSString *identifier, NSString *path) {
    return [[IntakeRoot alloc] initWithIdentifier:identifier rootPath:path];
}

int main(void) {
    @autoreleasepool {
        // --- empty index ---
        g_context = "empty";
        IntakeRootIndex *idx = [[IntakeRootIndex alloc] init];
        CHECK_EQ(idx.rootCount, 0, "fresh index has no roots");
        CHECK(([idx rootForFilePath:@"/income/a/track.flac"] == nil),
              "empty index matches nothing");

        // --- basic containment ---
        g_context = "basic";
        [idx setRoots:@[ root(@"r1", @"/income/dump/Artist - Album") ]];
        CHECK_EQ(idx.rootCount, 1, "one root indexed");
        CHECK([[idx rootForFilePath:@"/income/dump/Artist - Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "file inside root matches");
        CHECK([[idx rootForFilePath:@"/income/dump/Artist - Album"].identifier
                  isEqualToString:@"r1"],
              "path equal to root matches the root");
        CHECK(([idx rootForFilePath:@"/income/dump/Other - Album/01.flac"] == nil),
              "sibling directory does not match");
        CHECK(([idx rootForFilePath:@"/income/dump"] == nil),
              "parent of a root does not match");

        // --- prefix must end on a path boundary ---
        // The bug this guards: naive hasPrefix: makes "/a/bc" a child of "/a/b".
        g_context = "boundary";
        [idx setRoots:@[ root(@"r1", @"/income/Album") ]];
        CHECK(([idx rootForFilePath:@"/income/AlbumOther/01.flac"] == nil),
              "sibling sharing a name prefix does not match");
        CHECK(([idx rootForFilePath:@"/income/Album2"] == nil),
              "path extending the root name does not match");
        CHECK([[idx rootForFilePath:@"/income/Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "real child still matches");

        // --- nested roots: deepest wins ---
        g_context = "nested";
        [idx setRoots:@[ root(@"outer", @"/income/box"),
                         root(@"inner", @"/income/box/disc2") ]];
        CHECK_EQ(idx.rootCount, 2, "two roots indexed");
        CHECK([[idx rootForFilePath:@"/income/box/disc2/01.flac"].identifier
                  isEqualToString:@"inner"],
              "nested root wins over its parent");
        CHECK([[idx rootForFilePath:@"/income/box/disc1/01.flac"].identifier
                  isEqualToString:@"outer"],
              "sibling of the nested root falls back to the parent");
        // Registration order must not change the answer.
        [idx setRoots:@[ root(@"inner", @"/income/box/disc2"),
                         root(@"outer", @"/income/box") ]];
        CHECK([[idx rootForFilePath:@"/income/box/disc2/01.flac"].identifier
                  isEqualToString:@"inner"],
              "deepest-wins is independent of insertion order");

        // --- normalization ---
        g_context = "normalization";
        [idx setRoots:@[ root(@"r1", @"/income/dump/Album/") ]];
        CHECK([[idx rootForFilePath:@"/income/dump/Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "trailing slash on the root is normalized away");
        CHECK([[idx rootForFilePath:@"/income/dump/Album/"].identifier
                  isEqualToString:@"r1"],
              "trailing slash on the query is normalized away");
        CHECK([[idx rootForFilePath:@"/income/dump/./Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "dot component is resolved");
        CHECK([[idx rootForFilePath:@"/income/dump/other/../Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "parent component is resolved lexically");

        // --- case sensitivity is deliberate (documented in the header) ---
        g_context = "case";
        [idx setRoots:@[ root(@"r1", @"/income/Album") ]];
        CHECK(([idx rootForFilePath:@"/income/album/01.flac"] == nil),
              "matching is case-sensitive");

        // --- degenerate input ---
        g_context = "degenerate";
        [idx setRoots:@[ root(@"r1", @"/income/Album") ]];
        CHECK(([idx rootForFilePath:@""] == nil), "empty query matches nothing");
        [idx setRoots:@[ root(@"bad", @"") ]];
        CHECK(([idx rootForFilePath:@"/income/Album/01.flac"] == nil),
              "empty root path never matches");
        CHECK_EQ(idx.rootCount, 1, "empty root is still counted");

        // --- replacing the root set clears the old one ---
        g_context = "replace";
        [idx setRoots:@[ root(@"r1", @"/income/A") ]];
        [idx setRoots:@[ root(@"r2", @"/income/B") ]];
        CHECK_EQ(idx.rootCount, 1, "setRoots replaces rather than appends");
        CHECK(([idx rootForFilePath:@"/income/A/01.flac"] == nil),
              "root from the previous set no longer matches");
        CHECK([[idx rootForFilePath:@"/income/B/01.flac"].identifier
                  isEqualToString:@"r2"],
              "root from the new set matches");
        [idx setRoots:@[]];
        CHECK_EQ(idx.rootCount, 0, "clearing to an empty set works");
        CHECK(([idx rootForFilePath:@"/income/B/01.flac"] == nil),
              "cleared index matches nothing");
    }
    TEST_MAIN_END();
}
