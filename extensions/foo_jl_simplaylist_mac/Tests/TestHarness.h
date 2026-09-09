//
//  TestHarness.h
//  foo_simplaylist_mac
//
//  Shared check macros, counters and pass/fail epilogue for the standalone
//  Core unit tests. Plain C++ except the NSArray helper, so the same header
//  works for both the Objective-C++ suites and ReorderPlannerTests.cpp.
//

#pragma once

#include <cmath>
#include <cstdio>
#include <string>

// C++17 inline variables: one shared instance per binary even if a suite
// ever spans multiple translation units.
inline int g_failures = 0;
inline int g_checks = 0;
inline std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL %s:%d [%s] %s\n",                                      \
                   __FILE__, __LINE__, g_context.c_str(), what);                \
        }                                                                       \
    } while (0)

#define CHECK_EQ(actual, expected, what)                                          \
    do {                                                                          \
        g_checks++;                                                              \
        long long chk_a = (long long)(actual), chk_e = (long long)(expected);    \
        if (chk_a != chk_e) {                                                    \
            g_failures++;                                                        \
            printf("FAIL %s:%d [%s] %s: got %lld, expected %lld\n",              \
                   __FILE__, __LINE__, g_context.c_str(), what, chk_a, chk_e);   \
        }                                                                        \
    } while (0)

#define CHECK_FLOAT_EQ(actual, expected, what)                                    \
    do {                                                                          \
        g_checks++;                                                              \
        double chk_a = (actual), chk_e = (expected);                             \
        if (fabs(chk_a - chk_e) > 0.001) {                                       \
            g_failures++;                                                        \
            printf("FAIL %s:%d [%s] %s: got %f, expected %f\n",                  \
                   __FILE__, __LINE__, g_context.c_str(), what, chk_a, chk_e);   \
        }                                                                        \
    } while (0)

#ifdef __OBJC__
#import <Foundation/Foundation.h>

static inline void checkArrayImpl(NSArray *got, NSArray *want, const char *what,
                                  const char *file, int line) {
    g_checks++;
    if (![got isEqualToArray:want]) {
        g_failures++;
        printf("FAIL %s:%d [%s] %s: got %s, expected %s\n", file, line,
               g_context.c_str(), what,
               got.description.UTF8String, want.description.UTF8String);
    }
}

// Function-like macro so failures report the call site like the CHECK_* macros.
// Variadic because array literal arguments (@[@0, @1]) contain bare commas
// that the preprocessor would otherwise split into separate arguments.
#define checkArray(...) checkArrayImpl(__VA_ARGS__, __FILE__, __LINE__)
#endif

// Prints the pass/fail summary and returns the process exit code
// (non-zero aborts the build via run_tests.sh / build.sh).
#define TEST_MAIN_END()                                                          \
    do {                                                                         \
        printf("%s: %d checks, %d failures\n",                                   \
               g_failures == 0 ? "TESTS PASSED" : "TESTS FAILED",                \
               g_checks, g_failures);                                            \
        return g_failures == 0 ? 0 : 1;                                          \
    } while (0)
