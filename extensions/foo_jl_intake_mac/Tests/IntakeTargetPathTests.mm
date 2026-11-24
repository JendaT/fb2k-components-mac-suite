//
//  IntakeTargetPathTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeTargetPath (B13): the readable target path, from
//  the tier folder on. NFC/NFD, brackets, "&" and spaces, the CLI's
//  sanitized folder spelling, short paths and a collection not in the path.
//  Synthetic paths only (the Logic Bomb example is the user's own).
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeTargetPath.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

// "é" composed (NFC) and decomposed (NFD).
static const std::string kENfc = "\xC3\xA9";
static const std::string kENfd = "e\xCC\x81";

static void testExample() {
    g_context = "example";
    CHECK(displayTargetPath("/volume1/music/music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware",
                            "[Psytrance & Goa]") ==
              "music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware",
          "relative to the tier's parent");
    CHECK(displayTargetPath("/volume1/music/music.hq/[Psychill & Chillout & Psydub]/[Releases]/Aes Dana [2012] Pollen "
                            "(Ultimae Records; inre042)",
                            "[Psychill & Chillout & Psydub]") ==
              "music.hq/[Psychill & Chillout & Psydub]/[Releases]/Aes Dana [2012] Pollen (Ultimae Records; inre042)",
          "brackets, \"&\" and spaces; the [Releases] slot is kept");
    CHECK(displayTargetPath("/library/music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Album",
                            "Test Collection A") == "music.hq/Test Collection A/Fixture Artist/Fixture Artist - 2026 - Album",
          "a bare collection name (the mock's fixtures)");
    CHECK(displayTargetPath("/srv/x/y/music.uhq/[Ambient]/[Compilations]/VA [2020] Sampler", "[Ambient]") ==
              "music.uhq/[Ambient]/[Compilations]/VA [2020] Sampler",
          "a deeper tier root");
}

static void testUnicode() {
    g_context = "nfc-nfd";
    const std::string collectionNfc = "[Caf" + kENfc + " Music]";
    const std::string collectionNfd = "[Caf" + kENfd + " Music]";
    const std::string expected = "music.hq/" + collectionNfc + "/Artist/Release";
    CHECK(displayTargetPath("/volume1/music/music.hq/" + collectionNfd + "/Artist/Release", collectionNfc) == expected,
          "an NFD path meets an NFC collection; the result is NFC");
    CHECK(displayTargetPath("/volume1/music/music.hq/" + collectionNfc + "/Artist/Release", collectionNfd) == expected,
          "an NFC path meets an NFD collection");
    CHECK(displayTargetPath("/volume1/music/music.hq/" + collectionNfd + "/Artist/Release", collectionNfd) == expected,
          "both NFD: still found, the result is NFC");
    CHECK(displayTargetPath("/a/b/music.hq/[X]/Bj" + kENfd + "rk/R", "[Y]") == "music.hq/[X]/Bj" + kENfc + "rk/R",
          "the fallback is NFC too");
    CHECK(nfcText("plain ascii") == "plain ascii", "nfcText leaves ASCII alone");
    CHECK(nfcText(kENfd) == kENfc, "nfcText composes");
    const std::string invalid = "bad\xFF";
    CHECK(nfcText(invalid) == invalid, "nfcText leaves invalid UTF-8 alone");
}

static void testSanitized() {
    g_context = "sanitized";
    CHECK(sanitizedPathComponent("AC/DC: Live\\Set") == "AC-DC- Live-Set", "/ \\ and : become -");
    CHECK(sanitizedPathComponent("  .Name.  ") == "Name", "leading and trailing spaces and dots go");
    CHECK(sanitizedPathComponent(std::string("A\x01" "B\tC", 5)) == "ABC", "control characters go");
    CHECK(displayTargetPath("/v/music/music.hq/Drum - Bass/Artist/Release", "Drum / Bass") ==
              "music.hq/Drum - Bass/Artist/Release",
          "the folder the CLI wrote for a collection name with a slash");
    CHECK(displayTargetPath("/v/music/music.hq/Ambient/Artist/Release", "Ambient.") ==
              "music.hq/Ambient/Artist/Release",
          "the folder the CLI wrote for a collection name ending in a dot");
}

static void testShortAndMissing() {
    g_context = "short";
    CHECK(displayTargetPath("/[Coll]/Artist/Release", "[Coll]") == "[Coll]/Artist/Release",
          "the collection is the first component: start at it");
    CHECK(displayTargetPath("/music.hq/[Coll]", "[Coll]") == "music.hq/[Coll]", "the collection is the last component");
    CHECK(displayTargetPath("/music.hq/Release", "[Coll]") == "music.hq/Release",
          "fewer than four components and no collection: all of them");
    CHECK(displayTargetPath("/Release", "") == "Release", "one component");
    CHECK(displayTargetPath("", "[Coll]").empty(), "an empty path gives nothing");
    CHECK(displayTargetPath("/", "[Coll]").empty(), "the root gives nothing");

    g_context = "missing";
    CHECK(displayTargetPath("/volume1/music/music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware",
                            "[Full On]") == "music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware",
          "a collection not in the path: the last four components");
    CHECK(displayTargetPath("/volume1/music/music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware", "") ==
              "music.hq/[Psytrance & Goa]/Logic Bomb/Logic Bomb [2000] Headware",
          "no collection: the last four components");
    CHECK(displayTargetPath("/volume1/music/music.hq/[psytrance & goa]/A/R", "[Psytrance & Goa]") ==
              "music.hq/[psytrance & goa]/A/R",
          "case differs: not a match, the last four components (here the same)");
    CHECK(displayTargetPath("/v/m/music.hq/[Coll]/A/B/C/D", "[Coll]") == "music.hq/[Coll]/A/B/C/D",
          "found: everything after the collection is kept, however deep");
    CHECK(displayTargetPath("/v/m/music.hq/[Other]/A/B/C/D", "[Coll]") == "A/B/C/D",
          "not found in a deep path: the last four only");

    g_context = "separators";
    CHECK(displayTargetPath("//volume1//music/music.hq/[Coll]/Artist/Release/", "[Coll]") ==
              "music.hq/[Coll]/Artist/Release",
          "empty components and a trailing slash are skipped");
    CHECK(displayTargetPath("/music/[Coll]/x/music.hq/[Coll]/A/R", "[Coll]") == "music/[Coll]/x/music.hq/[Coll]/A/R",
          "the first match wins (the collection sits right under the tier root)");
}

int main(void) {
    @autoreleasepool {
        testExample();
        testUnicode();
        testSanitized();
        testShortAndMissing();
    }
    TEST_MAIN_END();
}
