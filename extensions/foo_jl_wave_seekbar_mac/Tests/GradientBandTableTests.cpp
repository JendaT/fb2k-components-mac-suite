//
//  GradientBandTableTests.cpp
//  foo_wave_seekbar_mac
//

#include "TestSupport.h"
#include "../src/Core/GradientBandTable.h"

using namespace waveseek;

namespace {

void testRoundTrip() {
    TEST_CASE("index/value round trip");

    // Preferences reads with one direction and writes with the other; they
    // must agree for every offered choice.
    for (size_t i = 0; i < kGradientBandOptionCount; i++) {
        int index = static_cast<int>(i);
        int value = gradientBandValueForIndex(index);
        CHECK(gradientBandIndexForValue(value) == index, "every menu entry round-trips");
    }
}

void testKnownValues() {
    TEST_CASE("known values");

    CHECK(gradientBandValueForIndex(0) == 0, "first choice is the flat trace");
    CHECK(gradientBandValueForIndex(3) == 8, "the default choice is 8 bands");
    CHECK(gradientBandValueForIndex(7) == 32, "the last choice is 32 bands");
    CHECK(kGradientBandOptionCount == 8, "the menu offers eight choices");

    // The table must stay ordered, since the popup shows it in order.
    for (size_t i = 1; i < kGradientBandOptionCount; i++) {
        CHECK(kGradientBandValues[i] > kGradientBandValues[i - 1], "band values increase");
    }
}

void testOutOfRangeIndex() {
    TEST_CASE("out-of-range index");

    // A popup index of -1 means "nothing selected"; fall back rather than
    // reading off the front of the table.
    CHECK(gradientBandValueForIndex(-1) == 8, "a negative index falls back to the default");
    CHECK(gradientBandValueForIndex(8) == 8, "an index past the end falls back to the default");
    CHECK(gradientBandValueForIndex(9999) == 8, "a wild index falls back to the default");

    CHECK(isValidGradientBandIndex(0), "zero is a valid index");
    CHECK(isValidGradientBandIndex(7), "seven is a valid index");
    CHECK(!isValidGradientBandIndex(-1), "negative is not a valid index");
    CHECK(!isValidGradientBandIndex(8), "past the end is not a valid index");
}

void testUnknownStoredValue() {
    TEST_CASE("unknown stored value");

    // Config could hold anything - a hand edit, or a value from a build with
    // a different table. Selecting the default beats selecting nothing.
    CHECK(gradientBandIndexForValue(7) == kGradientBandDefaultIndex,
          "a value between choices falls back to the default index");
    CHECK(gradientBandIndexForValue(-5) == kGradientBandDefaultIndex,
          "a negative value falls back to the default index");
    CHECK(gradientBandIndexForValue(1000) == kGradientBandDefaultIndex,
          "an oversized value falls back to the default index");

    // The fallback must itself be a real choice.
    CHECK(isValidGradientBandIndex(kGradientBandDefaultIndex), "the default index is in range");
}

} // namespace

int main() {
    testRoundTrip();
    testKnownValues();
    testOutOfRangeIndex();
    testUnknownStoredValue();
    return testsupport::summarize("GradientBandTableTests");
}
