//
//  TestSupport.h
//  foo_wave_seekbar_mac
//
//  Minimal assertion harness shared by the Core unit tests.
//
//  No test framework: each Tests/*Tests.cpp is a standalone main() that
//  compiles against Foundation (or nothing) in about a second, so the tests
//  can gate every build. Failures print and set the exit code; the run keeps
//  going so one broken case does not hide the rest.
//

#pragma once

#include <cmath>
#include <cstdio>
#include <string>

namespace testsupport {

inline int g_checks = 0;
inline int g_failures = 0;
inline std::string g_context;

inline void setContext(const std::string& name) { g_context = name; }

inline void recordPass() { g_checks++; }

inline void recordFailure(const char* what) {
    g_checks++;
    g_failures++;
    printf("FAIL [%s] %s\n", g_context.c_str(), what);
}

// Call at the end of main(); returns the process exit code.
inline int summarize(const char* suite) {
    if (g_failures == 0) {
        printf("PASS %s (%d checks)\n", suite, g_checks);
        return 0;
    }
    printf("FAIL %s (%d failures / %d checks)\n", suite, g_failures, g_checks);
    return 1;
}

} // namespace testsupport

#define TEST_CASE(name) testsupport::setContext(name)

#define CHECK(cond, what)                                    \
    do {                                                     \
        if (cond) {                                          \
            testsupport::recordPass();                       \
        } else {                                             \
            testsupport::recordFailure(what);                \
        }                                                    \
    } while (0)

// Float comparison with an absolute tolerance; also fails on NaN, which
// would otherwise slip through any inequality test.
#define CHECK_NEAR(actual, expected, epsilon, what)                          \
    do {                                                                     \
        double a_ = (actual);                                                \
        double e_ = (expected);                                              \
        if (std::isfinite(a_) && std::fabs(a_ - e_) <= (epsilon)) {          \
            testsupport::recordPass();                                       \
        } else {                                                             \
            char buf_[512];                                                  \
            snprintf(buf_, sizeof(buf_), "%s (got %g, expected %g)",         \
                     what, a_, e_);                                          \
            testsupport::recordFailure(buf_);                                \
        }                                                                    \
    } while (0)
