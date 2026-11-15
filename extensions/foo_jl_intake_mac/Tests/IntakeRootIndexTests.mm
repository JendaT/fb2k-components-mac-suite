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
// TEST_DEPS: src/Core/IntakePath.mm
//

#import <Foundation/Foundation.h>
#import "../src/Core/IntakeRootIndex.h"
#include "TestHarness.h"

#include <string>

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

        // --- Unicode: NFC and NFD spell the same folder ---
        // The CLI reports what it walked and foobar2000 stores what the file
        // dialog gave it; either side may be NFD (HFS+, SMB) or NFC.
        g_context = "unicode";
        NSString *nfc = [NSString stringWithUTF8String:"/income/Caf\xC3\xA9 Album"];
        NSString *nfd = [NSString stringWithUTF8String:"/income/Cafe\xCC\x81 Album"];
        [idx setRoots:@[ root(@"nfc", nfc) ]];
        CHECK([[idx rootForFilePath:[nfd stringByAppendingString:@"/01.flac"]].identifier
                  isEqualToString:@"nfc"],
              "NFD query matches an NFC root");
        CHECK([[idx rootForUTF8Path:"/income/Cafe\xCC\x81 Album/01.flac"].identifier
                  isEqualToString:@"nfc"],
              "NFD UTF-8 query matches an NFC root");
        [idx setRoots:@[ root(@"nfd", nfd) ]];
        CHECK([[idx rootForFilePath:[nfc stringByAppendingString:@"/01.flac"]].identifier
                  isEqualToString:@"nfd"],
              "NFC query matches an NFD root");
        CHECK([[idx rootForFilePath:nfd].identifier isEqualToString:@"nfd"],
              "NFD query equal to an NFD root matches");
        CHECK(([idx rootForFilePath:@"/income/Cafe Album/01.flac"] == nil),
              "the unaccented spelling is a different folder");

        // --- no filesystem access: /private/tmp is kept as written ---
        // stringByStandardizingPath strips "/private" when the shorter path
        // exists on disk; /private/tmp and /tmp both exist on every Mac.
        g_context = "private-tmp";
        [idx setRoots:@[ root(@"pt", @"/private/tmp") ]];
        IntakeRoot *pt = [idx rootForFilePath:@"/private/tmp/fixture.flac"];
        CHECK([pt.identifier isEqualToString:@"pt"], "/private/tmp root matches its own spelling");
        CHECK([pt.rootPath isEqualToString:@"/private/tmp"], "root path keeps /private");
        CHECK([pt.matchKey isEqualToString:@"/private/tmp"], "match key keeps /private");
        CHECK(([idx rootForFilePath:@"/tmp/fixture.flac"] == nil),
              "/tmp is not resolved to /private/tmp");
        [idx setRoots:@[ root(@"t", @"/tmp") ]];
        CHECK(([idx rootForFilePath:@"/private/tmp/fixture.flac"] == nil),
              "/private/tmp is not resolved to /tmp");

        // --- file:// and other schemes ---
        g_context = "schemes";
        [idx setRoots:@[ root(@"r1", @"/income/Fixture Artist - Test Album") ]];
        CHECK([[idx rootForFilePath:@"file:///income/Fixture Artist - Test Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "file:// query matches");
        CHECK([[idx rootForUTF8Path:"file:///income/Fixture Artist - Test Album/01.flac"].identifier
                  isEqualToString:@"r1"],
              "file:// UTF-8 query matches");
        CHECK(([idx rootForFilePath:@"mac-volume://0A1B2C3D/income/Fixture Artist - Test Album/01.flac"] ==
               nil),
              "mac-volume:// query matches nothing (Integration converts it first)");
        CHECK(([idx rootForFilePath:@"income/Fixture Artist - Test Album/01.flac"] == nil),
              "relative query matches nothing");
        CHECK(([idx rootForUTF8Path:NULL] == nil), "NULL UTF-8 query matches nothing");
        [idx setRoots:@[ root(@"url", @"file:///income/Fixture Artist - Test Album/") ]];
        CHECK([[idx rootForFilePath:@"/income/Fixture Artist - Test Album/01.flac"].identifier
                  isEqualToString:@"url"],
              "file:// root path is normalized too");
        [idx setRoots:@[ root(@"rel", @"income/Album"), root(@"mv", @"mac-volume://X/income") ]];
        CHECK_EQ(idx.rootCount, 2, "unusable roots are still counted");
        CHECK(([idx rootForFilePath:@"/income/Album/01.flac"] == nil),
              "relative or foreign-scheme roots never match");

        // --- nested roots via the ancestor walk ---
        g_context = "nested-walk";
        [idx setRoots:@[ root(@"top", @"/income"),
                         root(@"box", @"/income/box"),
                         root(@"disc", @"/income/box/disc2/extras") ]];
        CHECK([[idx rootForFilePath:@"/income/box/disc2/extras/a/b.flac"].identifier
                  isEqualToString:@"disc"],
              "deepest of three nested roots wins");
        CHECK([[idx rootForFilePath:@"/income/box/disc2/01.flac"].identifier
                  isEqualToString:@"box"],
              "a gap between roots falls back to the nearest ancestor");
        CHECK([[idx rootForFilePath:@"/income/other/01.flac"].identifier isEqualToString:@"top"],
              "outermost root catches the rest");
        CHECK(([idx rootForFilePath:@"/elsewhere/01.flac"] == nil), "outside every root");
        [idx setRoots:@[ root(@"slash", @"/") ]];
        CHECK([[idx rootForFilePath:@"/any/path.flac"].identifier isEqualToString:@"slash"],
              "a root at / contains every absolute path");

        // --- ancestor walk at depth, many roots ---
        g_context = "depth";
        NSMutableArray<IntakeRoot *> *many = [NSMutableArray array];
        for (int i = 0; i < 500; i++) {
            [many addObject:root([NSString stringWithFormat:@"r%d", i],
                                 [NSString stringWithFormat:@"/income/perf/Fixture Artist %d - Test Album", i])];
        }
        [idx setRoots:many];
        CHECK_EQ(idx.rootCount, 500, "500 roots indexed");
        std::string deep = "/income/perf/Fixture Artist 317 - Test Album";
        for (int d = 0; d < 60; d++) deep += "/d" + std::to_string(d);
        deep += "/track.flac";
        CHECK([[idx rootForUTF8Path:deep.c_str()].identifier isEqualToString:@"r317"],
              "a file 60 levels below its root still resolves");
        CHECK([[idx rootForFilePath:@"/income/perf/Fixture Artist 499 - Test Album/01.flac"].identifier
                  isEqualToString:@"r499"],
              "last-registered root resolves");
        CHECK(([idx rootForFilePath:@"/income/perf/Fixture Artist 500 - Test Album/01.flac"] == nil),
              "an unregistered sibling resolves to nothing");
        int hits = 0;
        for (int i = 0; i < 500; i++) {
            std::string q = "/income/perf/Fixture Artist " + std::to_string(i) +
                            " - Test Album/CD1/01.flac";
            IntakeRoot *r = [idx rootForUTF8Path:q.c_str()];
            if ([r.identifier isEqualToString:[NSString stringWithFormat:@"r%d", i]]) hits++;
        }
        CHECK_EQ(hits, 500, "every root resolves its own files");

        // --- shared directory (virtual roots) ---
        g_context = "virtual";
        [idx setRoots:@[ root(@"itk_000000b2", @"/income/loose"),
                         root(@"itk_000000a1", @"/income/loose") ]];
        CHECK_EQ(idx.rootCount, 2, "both virtual roots are counted");
        CHECK([[idx rootForFilePath:@"/income/loose/01.flac"].identifier
                  isEqualToString:@"itk_000000a1"],
              "a shared directory answers the lowest identifier");
        [idx setRoots:@[ root(@"itk_000000a1", @"/income/loose"),
                         root(@"itk_000000b2", @"/income/loose") ]];
        CHECK([[idx rootForFilePath:@"/income/loose/01.flac"].identifier
                  isEqualToString:@"itk_000000a1"],
              "the answer does not depend on listing order");

        // --- rootPath keeps the CLI's spelling for I/O ---
        // On SMB the folder name on disk is NFD; the NFC match key would not
        // stat, so rootPath must stay byte-identical to the CLI's root_path.
        g_context = "io-path";
        NSData *(^utf8)(NSString *) = ^NSData *(NSString *s) {
            return [s dataUsingEncoding:NSUTF8StringEncoding];
        };
        IntakeRoot *decomposed = root(@"nfd", nfd);
        CHECK([utf8(decomposed.rootPath) isEqualToData:utf8(nfd)],
              "rootPath keeps the NFD bytes the CLI reported");
        CHECK([utf8(decomposed.matchKey) isEqualToData:utf8(nfc)],
              "matchKey is the NFC spelling");
        [idx setRoots:@[ decomposed ]];
        CHECK([utf8([idx rootForFilePath:[nfc stringByAppendingString:@"/01.flac"]].rootPath)
                  isEqualToData:utf8(nfd)],
              "a matched root still hands back the NFD I/O path");
        IntakeRoot *messy = root(@"messy", @"/income//dump/Album/");
        CHECK([messy.rootPath isEqualToString:@"/income//dump/Album/"],
              "rootPath is not lexically rewritten");
        CHECK([messy.matchKey isEqualToString:@"/income/dump/Album"],
              "matchKey is lexically normalized");
        IntakeRoot *unusable = root(@"rel", @"income/Album");
        CHECK(unusable.matchKey == nil, "an unusable path has no match key");
        CHECK([unusable.rootPath isEqualToString:@"income/Album"],
              "an unusable path is kept as given");

        // --- a separate match path: the mount-alias key (PLAN.md B3) ---
        // The alias key must start with '/' to pass IntakePath; rootPath
        // stays the mount-point spelling for I/O.
        g_context = "alias-key";
        IntakeRoot *aliased =
            [[IntakeRoot alloc] initWithIdentifier:@"alias"
                                          rootPath:@"/Volumes/fixture-share-1/income/Fixture Artist - Test Album"
                                         matchPath:@"/smbfs:fixture-share/income/Fixture Artist - Test Album"];
        CHECK([aliased.matchKey isEqualToString:@"/smbfs:fixture-share/income/Fixture Artist - Test Album"],
              "an absolute alias key is its own match key");
        [idx setRoots:@[ aliased ]];
        IntakeRoot *hit = [idx rootForUTF8Path:"/smbfs:fixture-share/income/Fixture Artist - Test Album/01.flac"];
        CHECK([hit.identifier isEqualToString:@"alias"], "an alias-key query matches an alias-key root");
        CHECK([hit.rootPath isEqualToString:@"/Volumes/fixture-share-1/income/Fixture Artist - Test Album"],
              "the aliased root keeps its mount-point I/O path");
        CHECK(([idx rootForFilePath:@"/Volumes/fixture-share-1/income/Fixture Artist - Test Album/01.flac"] ==
               nil),
              "matching uses the match path, not rootPath");
        IntakeRoot *aliasNFD = [[IntakeRoot alloc]
            initWithIdentifier:@"alias-nfd"
                      rootPath:@"/Volumes/fixture-share/income/x"
                     matchPath:[NSString stringWithUTF8String:"/smbfs:fixture-share/income/Cafe\xCC\x81"]];
        [idx setRoots:@[ aliasNFD ]];
        CHECK([[idx rootForUTF8Path:"/smbfs:fixture-share/income/Caf\xC3\xA9/01.flac"].identifier
                  isEqualToString:@"alias-nfd"],
              "alias keys get NFC on both sides too");
        IntakeRoot *bare = [[IntakeRoot alloc] initWithIdentifier:@"bare"
                                                         rootPath:@"/Volumes/fixture-share/income/A"
                                                        matchPath:@"smbfs:fixture-share/income/A"];
        CHECK(bare.matchKey == nil, "an alias key without a leading '/' is Relative");
        [idx setRoots:@[ bare ]];
        CHECK(([idx rootForFilePath:@"/Volumes/fixture-share/income/A/01.flac"] == nil),
              "and such a root never matches, not even by rootPath");
    }
    TEST_MAIN_END();
}
