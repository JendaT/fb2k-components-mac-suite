//
//  TestHarness.h
//  foo_jl_album_art_mac
//
//  Minimal assertion macros shared by the standalone unit tests.
//  Compiled without Xcode/XCTest - see Scripts/run_tests.sh.
//

#pragma once

#import <Foundation/Foundation.h>

static int g_failures = 0;
static int g_checks = 0;
static const char *g_context = "";

#define TEST_CONTEXT(name) g_context = (name)

#define CHECK_TRUE(cond, what)                                                   \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: expected true\n", g_context, what);           \
        }                                                                       \
    } while (0)

#define CHECK_FALSE(cond, what)                                                  \
    do {                                                                         \
        g_checks++;                                                             \
        if (cond) {                                                             \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: expected false\n", g_context, what);          \
        }                                                                       \
    } while (0)

#define CHECK_EQ(actual, expected, what)                                         \
    do {                                                                         \
        g_checks++;                                                             \
        long long a__ = (long long)(actual), e__ = (long long)(expected);       \
        if (a__ != e__) {                                                       \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got %lld, expected %lld\n",                   \
                   g_context, what, a__, e__);                                  \
        }                                                                       \
    } while (0)

#define CHECK_STR_EQ(actual, expected, what)                                     \
    do {                                                                         \
        g_checks++;                                                             \
        NSString *a__ = (actual), *e__ = (expected);                            \
        BOOL equal__ = (a__ == e__) || [a__ isEqualToString:e__];               \
        if (!equal__) {                                                         \
            g_failures++;                                                       \
            printf("FAIL [%s] %s: got \"%s\", expected \"%s\"\n",               \
                   g_context, what,                                             \
                   a__.UTF8String ?: "(nil)", e__.UTF8String ?: "(nil)");       \
        }                                                                       \
    } while (0)

#define CHECK_NIL(value, what) CHECK_TRUE((value) == nil, what)
#define CHECK_NOT_NIL(value, what) CHECK_TRUE((value) != nil, what)

static inline int test_summary(const char *suiteName) {
    if (g_failures == 0) {
        printf("PASS: %s (%d checks)\n", suiteName, g_checks);
        return 0;
    }
    printf("FAILED: %s (%d of %d checks failed)\n", suiteName, g_failures, g_checks);
    return 1;
}
