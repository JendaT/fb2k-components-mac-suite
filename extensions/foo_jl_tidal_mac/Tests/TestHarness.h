//
//  TestHarness.h
//  foo_jl_tidal_mac
//
//  Minimal standalone test harness (no XCTest). Test files are plain
//  int main() programs compiled directly with clang++ by run_tests.sh.
//

#pragma once

#include <cstdio>

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond, ...) do { \
    ++g_checks; \
    if (!(cond)) { \
        ++g_failures; \
        printf("FAIL [%s:%d] ", __FILE__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

#define CHECK_EQ(a, b, ...) CHECK((a) == (b), __VA_ARGS__)

#ifdef __OBJC__
// nil-safe NSString comparison (nil == nil passes)
#define CHECK_STREQ(a, b, ...) do { \
    NSString *_sa = (a); NSString *_sb = (b); \
    CHECK((_sa == _sb) || [_sa isEqualToString:_sb], __VA_ARGS__); \
} while (0)
#endif

// Prints the summary line and returns the process exit code.
static inline int testHarnessFinish(const char *suiteName) {
    printf("%s: %s — %d checks, %d failures\n",
           suiteName,
           g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED",
           g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
