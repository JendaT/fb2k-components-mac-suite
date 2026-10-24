//
//  MeterScaleTests.cpp
//  foo_jl_levelmeter_mac
//
//  Bar scale mapping and tick placement, VU face geometry.
//

#include "TestHarness.h"
#include "../src/Core/MeterScale.h"

#include <cmath>

using namespace meter;

namespace {

void testPositions() {
    for (ScaleSpacing sp : { ScaleSpacing::Linear, ScaleSpacing::Extended }) {
        g_context = sp == ScaleSpacing::Linear ? "linear" : "extended";
        BarScale s(-60, sp);
        CHECK_FLOAT_EQ(s.position(0.0), 1.0, "0 dBFS at the top");
        CHECK_FLOAT_EQ(s.position(3.0), 1.0, "overs clamp to the top");
        CHECK_FLOAT_EQ(s.position(-60.0), 0.0, "floor at the bottom");
        CHECK_FLOAT_EQ(s.position(kFloorDb), 0.0, "silence at the bottom");
        double last = -1;
        bool rising = true;
        for (int db = -60; db <= 0; ++db) {
            const double p = s.position(db);
            if (p <= last) rising = false;
            last = p;
        }
        CHECK(rising, "position rises with level");
    }
    g_context = "linear midpoint";
    CHECK_FLOAT_EQ(BarScale(-60, ScaleSpacing::Linear).position(-30), 0.5, "-30 halfway");
    g_context = "extended top";
    // Extended spacing gives the top 20 dB more than a third of the bar.
    CHECK(BarScale(-60, ScaleSpacing::Extended).position(-20) < 0.6, "top 20 dB get over 40%");
}

void checkTicks(const BarScale &s, double length, double labelPx, const char *what) {
    g_context = what;
    const auto ticks = s.ticks(length, labelPx);
    CHECK(!ticks.empty(), "has ticks");
    if (ticks.empty()) return;
    CHECK(ticks.front().major, "top tick labelled");
    CHECK(std::fabs(ticks.front().pos - 1.0) < 1e-9, "top tick at 0 dBFS");
    double lastMajorPx = -1e9;
    bool spaced = true, inRange = true;
    for (const auto &t : ticks) {
        if (t.db < s.floorDb() - 1e-9 || t.db > 1e-9) inRange = false;
        if (!t.major) continue;
        const double px = (1.0 - t.pos) * length;
        if (px - lastMajorPx < labelPx - 1e-9) spaced = false;
        lastMajorPx = px;
    }
    CHECK(spaced, "labels never closer than labelPx");
    CHECK(inRange, "ticks inside the scale");
}

void testTicks() {
    checkTicks(BarScale(-60, ScaleSpacing::Extended), 600, 12, "extended tall");
    checkTicks(BarScale(-60, ScaleSpacing::Extended), 120, 12, "extended short");
    checkTicks(BarScale(-90, ScaleSpacing::Linear), 300, 12, "linear -90");
    checkTicks(BarScale(-24, ScaleSpacing::Linear), 700, 26, "linear wide");
    checkTicks(BarScale(-60, ScaleSpacing::Extended, -20.0), 400, 12, "K-20");

    g_context = "round labels";
    // Labels come from a 1-2-5 ladder: every label is a multiple of its step.
    const auto ticks = BarScale(-60, ScaleSpacing::Extended).ticks(300, 12);
    bool round = true;
    for (const auto &t : ticks) {
        if (t.major && t.label % 2 != 0 && t.label % 5 != 0 && t.label != 0) round = false;
    }
    CHECK(round, "labels are multiples of 2 or 5");

    g_context = "K labels";
    const auto k = BarScale(-60, ScaleSpacing::Linear, -14.0).ticks(400, 12);
    CHECK_EQ(k.front().label, 14, "K-14 tops out at +14");
    bool hasZero = false;
    for (const auto &t : k) if (t.major && t.label == 0) hasZero = std::fabs(t.db + 14.0) < 1e-9;
    CHECK(hasZero, "K-14 0 sits at -14 dBFS");

    g_context = "degenerate";
    CHECK(BarScale(-60, ScaleSpacing::Linear).ticks(0, 12).empty(), "no length, no ticks");
}

void testVuFace() {
    g_context = "vu face";
    CHECK_FLOAT_EQ(vu_face::fraction(3.0), 1.0, "+3 VU at the end of the sweep");
    CHECK(std::fabs(vu_face::fraction(0.0) - 0.7079) < 1e-3, "0 VU at 71% (amplitude scale)");
    CHECK(std::fabs(vu_face::fraction(-20.0) - 0.0708) < 1e-3, "-20 VU near the rest");
    CHECK_FLOAT_EQ(vu_face::fraction(kFloorDb), 0.0, "silence rests at 0");
    CHECK(std::fabs(vu_face::percentFraction(100) - vu_face::fraction(0.0)) < 1e-9, "100% = 0 VU");
    CHECK_FLOAT_EQ(vu_face::angle(3.0), vu_face::kSweepDegrees / 2.0, "angle at +3");
    CHECK_FLOAT_EQ(vu_face::angle(kFloorDb), -vu_face::kSweepDegrees / 2.0, "angle at rest");
    CHECK(vu_face::majorMarks().front() == -20 && vu_face::majorMarks().back() == 3, "marks span -20..+3");
}

} // namespace

int main() {
    testPositions();
    testTicks();
    testVuFace();
    TEST_MAIN_END();
}
