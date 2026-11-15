//
//  IntakeWatchFilterTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeWatchFilter: the CLI's isSidecarName rule
//  (feature/intake-cli util.ts), the directory of a sidecar event, and the
//  batch builder (each directory once, rescan, other names ignored).
//  Synthetic paths only.
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeWatchFilter.h"
#include "TestHarness.h"

#include <string>

using namespace intake;

static void testSidecarNames() {
    g_context = "sidecar-names";
    CHECK(isSidecarFileName(".intake.json"), "the whole-directory sidecar");
    CHECK(isSidecarFileName(".intake.itk_0000000a.json"), "a named sidecar");
    CHECK(isSidecarFileName(".intake.a.json") && isSidecarFileName(".intake.0.json") &&
              isSidecarFileName(".intake._.json"),
          "a one-character id from [a-z0-9_]");
    CHECK(isSidecarFileName(".INTAKE.ITK_0000000A.JSON") && isSidecarFileName(".Intake.Itk_A.Json"),
          "the named form ignores case (the regex has the i flag)");
    CHECK(isSidecarFileName(".intake.hint.json"), "'hint' is a valid id under the rule");

    CHECK(!isSidecarFileName(".INTAKE.JSON") && !isSidecarFileName(".Intake.json"),
          "the whole-directory form is an exact, case-sensitive match");
    CHECK(!isSidecarFileName(".intake-tmp-123"), "the CLI's temp file");
    CHECK(!isSidecarFileName(".intake-tmp-123.json") && !isSidecarFileName(".intake-tmp-.intake.json"),
          "temp files ending in .json");
    CHECK(!isSidecarFileName(".intake-hint.json"), "doc 05's hint file");
    CHECK(!isSidecarFileName(".intake..json"), "an empty id");
    CHECK(!isSidecarFileName(".intake.itk-1.json") && !isSidecarFileName(".intake.a b.json") &&
              !isSidecarFileName(".intake.a.b.json"),
          "id characters outside [A-Za-z0-9_] ('-', ' ', '.')");
    CHECK(!isSidecarFileName(".intake.json.tmp") && !isSidecarFileName(".intake.json~") &&
              !isSidecarFileName("x.intake.json"),
          "near misses around the whole-directory name");
    CHECK(!isSidecarFileName(".intake.itk_1.json.swp") && !isSidecarFileName(".intake.itk_1.jso"),
          "near misses around the named form");
    CHECK(!isSidecarFileName("") && !isSidecarFileName(".intake") && !isSidecarFileName(".intake.") &&
              !isSidecarFileName("intake.json"),
          "empty and partial names");
    CHECK(!isSidecarFileName("01 - Test Track One.wav") && !isSidecarFileName(".DS_Store"), "ordinary files");
    CHECK(!isSidecarFileName(std::string_view(".intake.a\0.json", 15)), "a NUL in the id");
}

static void testEventDirectory() {
    g_context = "event-directory";
    std::string dir;
    CHECK(sidecarEventDirectory("/income/dump/Fixture Artist - New Album/.intake.json", dir) &&
              dir == "/income/dump/Fixture Artist - New Album",
          "a whole-directory sidecar's folder");
    CHECK(sidecarEventDirectory("/income/shop/Loose Tracks/.intake.itk_00000016.json", dir) &&
              dir == "/income/shop/Loose Tracks",
          "a named sidecar's folder");
    CHECK(sidecarEventDirectory("/.intake.json", dir) && dir == "/", "a sidecar at the root: '/'");
    CHECK(!sidecarEventDirectory("/income/dump/Album/.intake-tmp-9", dir) && dir.empty(),
          "a temp file is no sidecar event, and the directory is cleared");
    CHECK(!sidecarEventDirectory("/income/dump/Album", dir), "a directory event");
    CHECK(!sidecarEventDirectory(".intake.json", dir), "a bare name (no '/') is not an event path");
    CHECK(!sidecarEventDirectory("/income/dump/.intake.json/", dir), "a trailing '/' has an empty name");
    CHECK(pathFileName("/a/b/.intake.json") == ".intake.json" && pathFileName("name") == "name" &&
              pathFileName("/a/") == "",
          "pathFileName");
}

static void testBatchBuilder() {
    g_context = "batch-builder";
    WatchBatchBuilder b;
    CHECK(b.empty(), "a new builder is empty");
    CHECK(!b.addPath("/w/dump/A/01 - Test Track One.wav"), "an audio file is ignored");
    CHECK(!b.addPath("/w/dump/A/.intake-tmp-77"), "a temp file is ignored");
    CHECK(!b.addPath("/w/dump/A/.intake-hint.json"), "a hint file is ignored");
    CHECK(b.empty(), "ignored events leave it empty");
    CHECK(b.addPath("/w/dump/A/.intake.json"), "a sidecar event counts");
    CHECK(b.addPath("/w/dump/A/.intake.json"), "the same sidecar again counts");
    CHECK(b.addPath("/w/shop/Loose/.intake.itk_00000016.json"), "a named sidecar");
    CHECK(b.addPath("/w/shop/Loose/.intake.itk_00000017.json"), "a second named sidecar in that folder");
    WatchBatch batch = b.take();
    CHECK(batch.directories.size() == 2 && batch.directories[0] == "/w/dump/A" &&
              batch.directories[1] == "/w/shop/Loose",
          "each directory once, in arrival order");
    CHECK_EQ(batch.sidecarEvents, 4, "every sidecar event counted");
    CHECK(!batch.rescan && !batch.empty(), "no rescan; not empty");
    CHECK(b.empty(), "take() starts over");

    b.addPath("/w/dump/A/.intake.json");
    WatchBatch second = b.take();
    CHECK(second.directories.size() == 1 && second.directories[0] == "/w/dump/A",
          "a directory seen in an earlier batch is reported again");

    b.addRescan();
    CHECK(!b.empty(), "a rescan alone makes a batch");
    WatchBatch rescan = b.take();
    CHECK(rescan.rescan && rescan.directories.empty() && !rescan.empty(), "rescan without directories");
    CHECK(b.empty() && !b.take().rescan, "the rescan flag is cleared by take()");
}

int main(void) {
    @autoreleasepool {
        testSidecarNames();
        testEventDirectory();
        testBatchBuilder();
    }
    TEST_MAIN_END();
}
