//
//  IntakePathTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakePath (file:// strip, lexical normalization, NFC).
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//
//  All paths are synthetic.
//
// TEST_FRAMEWORKS: CoreFoundation
//

#import <Foundation/Foundation.h>
#include "../src/Core/IntakePath.h"
#include "TestHarness.h"

#include <string>
#include <string_view>

using intake::PathStatus;

// Normalizes through the copying overload and compares with `want`.
static void checkNormal(const char *input, const char *want) {
    std::string out;
    const PathStatus status = intake::normalizePath(input, out);
    g_checks++;
    if (status != PathStatus::Ok || out != want) {
        g_failures++;
        printf("FAIL %s:%d [%s] normalize(\"%s\"): got %s \"%s\", expected \"%s\"\n",
               __FILE__, __LINE__, g_context.c_str(), input,
               intake::pathStatusName(status), out.c_str(), want);
    }
}

static void checkStatus(const char *input, PathStatus want) {
    std::string out = "stale";
    const PathStatus status = intake::normalizePath(input, out);
    g_checks++;
    if (status != want || !out.empty()) {
        g_failures++;
        printf("FAIL %s:%d [%s] normalize(\"%s\"): got %s (out \"%s\"), expected %s with empty out\n",
               __FILE__, __LINE__, g_context.c_str(), input,
               intake::pathStatusName(status), out.c_str(), intake::pathStatusName(want));
    }
}

int main(void) {
    @autoreleasepool {
        // --- already normal: returned as is ---
        g_context = "identity";
        checkNormal("/", "/");
        checkNormal("/income/dump/Fixture Artist - Test Album/01.flac",
                    "/income/dump/Fixture Artist - Test Album/01.flac");
        checkNormal("/a/.hidden/b", "/a/.hidden/b");
        checkNormal("/a/..b/c", "/a/..b/c");
        checkNormal("/a/.../b", "/a/.../b");
        checkNormal("/a/b.", "/a/b.");

        // --- lexical normalization table ---
        g_context = "lexical";
        checkNormal("/a/b/", "/a/b");
        checkNormal("/a//b", "/a/b");
        checkNormal("//a/b", "/a/b");
        checkNormal("///", "/");
        checkNormal("/a/./b", "/a/b");
        checkNormal("/a/b/.", "/a/b");
        checkNormal("/./a", "/a");
        checkNormal("/a/../b", "/b");
        checkNormal("/a/b/..", "/a");
        checkNormal("/a/b/../../..", "/");
        checkNormal("/..", "/");
        checkNormal("/../a", "/a");
        checkNormal("/a/./../b//c/", "/b/c");

        // --- no filesystem access: nothing resolved against the disk ---
        g_context = "no-filesystem";
        // /private/tmp exists and /tmp links to it; a realpath or
        // stringByStandardizingPath would rewrite one into the other.
        checkNormal("/private/tmp", "/private/tmp");
        checkNormal("/tmp/intake-fixture", "/tmp/intake-fixture");
        checkNormal("/private/var/../tmp", "/private/tmp");

        // --- file:// strip ---
        g_context = "file-url";
        checkNormal("file:///a/b", "/a/b");
        checkNormal("FILE:///a/b/", "/a/b");
        checkNormal("file:///a/./b//c", "/a/b/c");
        checkNormal("file:///", "/");
        checkNormal("file:///Fixture Artist - Test Album/01 Track.flac",
                    "/Fixture Artist - Test Album/01 Track.flac");
        checkStatus("file://", PathStatus::Empty);
        checkStatus("file://fixture-host/a/b", PathStatus::UnhandledScheme);

        // --- other schemes are reported, never guessed at ---
        g_context = "schemes";
        checkStatus("mac-volume://0A1B2C3D/income/a.flac", PathStatus::UnhandledScheme);
        checkStatus("http://example.invalid/a.mp3", PathStatus::UnhandledScheme);
        checkStatus("tidal://track/1", PathStatus::UnhandledScheme);
        // A native path may contain "://" anywhere after its leading '/'.
        checkNormal("/a/mac-volume://b", "/a/mac-volume:/b");

        // --- empty and relative input ---
        g_context = "empty-relative";
        checkStatus("", PathStatus::Empty);
        checkStatus("a/b", PathStatus::Relative);
        checkStatus("./a", PathStatus::Relative);
        checkStatus("~/Music/a.flac", PathStatus::Relative);
        checkStatus("file:/a/b", PathStatus::Relative);
        checkStatus("1http://x/y", PathStatus::Relative);  // not a valid scheme

        // --- NFC ---
        g_context = "nfc";
        // "Café": NFD (e + U+0301) becomes NFC (U+00E9); NFC stays.
        checkNormal("/income/Cafe\xCC\x81 Album", "/income/Caf\xC3\xA9 Album");
        checkNormal("/income/Caf\xC3\xA9 Album", "/income/Caf\xC3\xA9 Album");
        checkNormal("file:///x/../income/Cafe\xCC\x81/", "/income/Caf\xC3\xA9");
        // Hangul: conjoining jamo (NFD) compose to one syllable.
        checkNormal("/\xE1\x84\x92\xE1\x85\xA1", "/\xED\x95\x98");
        // Invalid UTF-8 cannot be normalized, but the bytes survive.
        checkNormal("/a/\xFF/../b\xFF", "/a/b\xFF");

        // --- ASCII fast path: no copy, buffer untouched ---
        g_context = "fast-path";
        {
            std::string buffer;
            std::string_view out;
            const std::string input = "/income/dump/Fixture Artist - Test Album/01.flac";
            CHECK(intake::normalizePath(input, buffer, out) == PathStatus::Ok, "fast path ok");
            CHECK(out.data() == input.data() && out.size() == input.size(),
                  "normal ASCII input is returned as a view of itself");
            CHECK(buffer.empty() && buffer.capacity() < input.size(),
                  "buffer was not written on the fast path");

            const std::string url = "file:///income/a.flac";
            CHECK(intake::normalizePath(url, buffer, out) == PathStatus::Ok, "file url ok");
            CHECK(out.data() == url.data() + 7 && out == "/income/a.flac",
                  "file:// strip alone is still zero-copy");

            const std::string messy = "/income//a/./b/";
            CHECK(intake::normalizePath(messy, buffer, out) == PathStatus::Ok, "slow path ok");
            CHECK(out.data() == buffer.data() && out == "/income/a/b",
                  "non-normal input lands in the caller's buffer");

            // A failed call leaves out empty.
            out = input;
            CHECK(intake::normalizePath("relative", buffer, out) == PathStatus::Relative &&
                      out.empty(),
                  "out is cleared on failure");
        }

        // --- input viewing the caller's own buffer (normalize in place) ---
        g_context = "aliasing";
        {
            std::string buf = "/x/../y";
            std::string_view out;
            CHECK(intake::normalizePath(buf, buf, out) == PathStatus::Ok && out == "/y",
                  "input viewing buffer: lexical result is correct");
            CHECK(out.data() == buf.data(), "result lands in the buffer");

            buf = "file:///a//Cafe\xCC\x81/";
            CHECK(intake::normalizePath(buf, buf, out) == PathStatus::Ok &&
                      out == "/a/Caf\xC3\xA9",
                  "input viewing buffer: file:// strip, lexical and NFC");

            buf = "/income/dump/../Fixture Artist - Test Album/./01.flac";
            const std::string_view tail = std::string_view(buf).substr(7);  // "/dump/../..."
            CHECK(intake::normalizePath(tail, buf, out) == PathStatus::Ok &&
                      out == "/Fixture Artist - Test Album/01.flac",
                  "input viewing the middle of buffer");

            std::string same = "/a//b/";
            CHECK(intake::normalizePath(same, same) == PathStatus::Ok && same == "/a/b",
                  "copying overload with input == out (slow path)");
            same = "file:///a/b";
            CHECK(intake::normalizePath(same, same) == PathStatus::Ok && same == "/a/b",
                  "copying overload with input == out (zero-copy path)");
        }

        // --- idempotence: a second pass returns the same bytes ---
        // Callers may normalize, rewrite (mount alias, B3), and let the
        // index normalize again.
        g_context = "idempotent";
        {
            const char *inputs[] = {
                "/a/./../b//c/", "file:///x/../income/Cafe\xCC\x81/", "/\xE1\x84\x92\xE1\x85\xA1",
                "/a/\xFF/../b\xFF", "/smbfs:fixture-share/income/Fixture Artist - Test Album",
            };
            int stable = 0;
            for (const char *in : inputs) {
                std::string once, twice;
                if (intake::normalizePath(in, once) == PathStatus::Ok &&
                    intake::normalizePath(once, twice) == PathStatus::Ok && once == twice) {
                    stable++;
                }
            }
            CHECK_EQ(stable, 5, "normalize(normalize(x)) == normalize(x)");
        }

        // --- mount-alias keys (PLAN.md B3): must start with '/' ---
        g_context = "alias-key";
        checkNormal("/smbfs:fixture-share/income/Fixture Artist - Test Album",
                    "/smbfs:fixture-share/income/Fixture Artist - Test Album");
        checkNormal("/smbfs:fixture-share/income//A/", "/smbfs:fixture-share/income/A");
        checkStatus("smbfs:fixture-share/income/A", PathStatus::Relative);

        // --- status names ---
        g_context = "names";
        CHECK(std::string(intake::pathStatusName(PathStatus::Ok)) == "Ok", "Ok name");
        CHECK(std::string(intake::pathStatusName(PathStatus::UnhandledScheme)) == "UnhandledScheme",
              "UnhandledScheme name");

        // --- Foundation wrapper ---
        g_context = "nsstring";
        PathStatus status = PathStatus::Empty;
        CHECK([IntakeNormalizedPath(@"file:///a/b/", &status) isEqualToString:@"/a/b"] &&
                  status == PathStatus::Ok,
              "NSString wrapper normalizes");
        NSString *nfd = [NSString stringWithUTF8String:"/Cafe\xCC\x81"];
        NSString *nfc = [NSString stringWithUTF8String:"/Caf\xC3\xA9"];
        CHECK([[IntakeNormalizedPath(nfd, nullptr) dataUsingEncoding:NSUTF8StringEncoding]
                  isEqualToData:[nfc dataUsingEncoding:NSUTF8StringEncoding]],
              "NSString wrapper composes NFD to NFC bytes");
        CHECK(IntakeNormalizedPath(@"mac-volume://X/a", &status) == nil &&
                  status == PathStatus::UnhandledScheme,
              "NSString wrapper reports an unhandled scheme");
        CHECK(IntakeNormalizedPath(nil, &status) == nil && status == PathStatus::Empty,
              "nil input is Empty");
        std::string bytes;
        intake::copyUTF8(nfc, bytes);
        CHECK(bytes == "/Caf\xC3\xA9", "copyUTF8 copies the UTF-8 bytes");
    }
    TEST_MAIN_END();
}
