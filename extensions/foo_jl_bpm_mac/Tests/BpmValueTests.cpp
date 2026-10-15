//
//  BpmValueTests.cpp
//  foo_jl_bpm_mac
//
//  Unit tests for BPM tag parsing, formatting and comparison.
//

#include "TestHarness.h"
#include "../src/Core/BpmValue.h"

using namespace bpm;

namespace {

void checkParsed(const char *text, double expected) {
    g_context = text;
    const auto v = parseBpm(text);
    CHECK(v.has_value(), "parses");
    if (v) CHECK_FLOAT_EQ(*v, expected, "value");
}

void checkRejected(const char *text) {
    g_context = text;
    CHECK(!parseBpm(text).has_value(), "rejected");
}

} // namespace

int main() {
    checkParsed("128", 128.0);
    checkParsed("128.00", 128.0);
    checkParsed("127,5", 127.5);
    checkParsed("  96 ", 96.0);
    checkParsed("174 BPM", 174.0);
    checkParsed("174bpm", 174.0);
    checkParsed("0.5", 0.5);

    checkRejected("");
    checkRejected("   ");
    checkRejected("BPM");
    checkRejected("abc");
    checkRejected("12a");
    checkRejected("1.2.3");
    checkRejected(".");
    checkRejected("-120");
    checkRejected("0");
    checkRejected("1000");
    checkRejected("1e3");

    g_context = "formatBpmTag";
    CHECK(formatBpmTag(127.6) == "128", "rounds up");
    CHECK(formatBpmTag(127.4) == "127", "rounds down");
    CHECK(formatBpmTag(87.5) == "88", "half rounds away from zero");

    g_context = "formatBpmExact";
    CHECK(formatBpmExact(128.0) == "128", "integral");
    CHECK(formatBpmExact(62.5) == "62.5", "one decimal");
    CHECK(formatBpmExact(116.04) == "116", "rounds to tenths first");
    CHECK(formatBpmExact(116.06) == "116.1", "rounds to tenths");

    g_context = "formatBpmDisplay";
    CHECK(formatBpmDisplay(127.86) == "127.9", "one decimal");
    CHECK(formatBpmDisplay(128.0) == "128.0", "keeps decimal");

    g_context = "compareBpm";
    CHECK(compareBpm(128.0, 128.4) == Agreement::Same, "same within 1%");
    CHECK(compareBpm(128.0, 129.2) == Agreement::Same, "same at 0.9%");
    CHECK(compareBpm(128.0, 130.0) == Agreement::Different, "different at 1.6%");
    CHECK(compareBpm(70.0, 140.3) == Agreement::Double, "estimate doubled");
    CHECK(compareBpm(174.0, 87.2) == Agreement::Half, "estimate halved");
    CHECK(compareBpm(30.0, 30.45) == Agreement::Same, "0.5 BPM floor at slow tempos");
    CHECK(compareBpm(120.0, 80.0) == Agreement::Different, "3:2 is different");

    TEST_MAIN_END();
}
