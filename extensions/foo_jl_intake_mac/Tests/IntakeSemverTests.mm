//
//  IntakeSemverTests.mm
//  foo_jl_intake_mac
//
//  Unit tests for IntakeSemver (strict MAJOR.MINOR.PATCH, feature minimums).
//  Compiled standalone under ASan+UBSan; see Scripts/run_tests.sh.
//

#include "../src/Core/IntakeSemver.h"
#include "TestHarness.h"

using intake::SemVer;

int main(void) {
    // --- parsing ---
    g_context = "parse";
    SemVer v;
    CHECK(intake::parseSemver("0.2.1", v), "0.2.1 parses");
    CHECK_EQ(v.major, 0, "major");
    CHECK_EQ(v.minor, 2, "minor");
    CHECK_EQ(v.patch, 1, "patch");
    CHECK(intake::parseSemver("10.20.300", v) && v.major == 10 && v.minor == 20 && v.patch == 300,
          "multi-digit parts");
    CHECK(intake::parseSemver("999999999.0.0", v) && v.major == 999999999, "nine digits fit");

    SemVer keep{7, 7, 7};
    const char *bad[] = {
        "", "0", "0.2", "0.2.", ".2.1", "0..1", "0.2.1.4", "v0.2.1", " 0.2.1", "0.2.1 ",
        "0.2.1-beta", "0.2.1+build5", "0.2.x", "01.2.3", "0.02.3", "0.2.03", "1234567890.0.0",
        "-1.0.0", "0.-2.0", "a.b.c", "0.2.1\n",
    };
    bool allRejected = true;
    for (const char *s : bad) {
        if (intake::parseSemver(s, keep)) {
            allRejected = false;
            printf("  unexpectedly parsed: '%s'\n", s);
        }
    }
    CHECK(allRejected, "pre-release, build metadata, prefixes, leading zeros and garbage are rejected");
    CHECK(keep.major == 7 && keep.minor == 7 && keep.patch == 7, "a failed parse leaves the output untouched");

    // --- minimum comparisons ---
    g_context = "at-least";
    CHECK(intake::semverAtLeast("0.2.0", 0, 2, 0), "equal satisfies");
    CHECK(intake::semverAtLeast("0.2.1", 0, 2, 0), "higher patch satisfies");
    CHECK(intake::semverAtLeast("0.3.0", 0, 2, 9), "higher minor beats any patch");
    CHECK(intake::semverAtLeast("1.0.0", 0, 9, 9), "higher major beats any minor");
    CHECK(!intake::semverAtLeast("0.1.9", 0, 2, 0), "lower minor fails");
    CHECK(!intake::semverAtLeast("0.2.0", 0, 2, 1), "lower patch fails");
    CHECK(!intake::semverAtLeast("0.9.9", 1, 0, 0), "lower major fails");
    CHECK(!intake::semverAtLeast("0.3.0-beta", 0, 2, 0), "a pre-release never satisfies");
    CHECK(!intake::semverAtLeast("garbage", 0, 0, 0), "garbage never satisfies, even 0.0.0");
    CHECK(intake::semverAtLeast("0.0.0", 0, 0, 0), "0.0.0 satisfies 0.0.0");

    // --- named feature checks (PLAN.md 3.4) ---
    g_context = "features";
    CHECK(!intake::cliSupportsReject("0.1.0"), "CLI 0.1.0 has no reject");
    CHECK(intake::cliSupportsReject("0.2.0"), "CLI 0.2.0 has reject");
    CHECK(intake::cliSupportsReject("0.2.1"), "CLI 0.2.1 has reject");
    CHECK(!intake::cliSupportsReject(""), "an empty version hides reject");
    CHECK(!intake::cliSupportsPerRootResume("0.2.0"), "CLI 0.2.0 resumes every placing root");
    CHECK(intake::cliSupportsPerRootResume("0.2.1"), "CLI 0.2.1 resumes per root");
    CHECK(intake::cliSupportsPerRootResume("1.0.0"), "a later major keeps per-root resume");
    CHECK(!intake::cliSupportsPerRootResume("0.2.1-rc.1"), "a 0.2.1 pre-release does not count");

    TEST_MAIN_END();
}
