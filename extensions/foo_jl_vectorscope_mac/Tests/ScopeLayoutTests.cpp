//
//  ScopeLayoutTests.cpp
//  foo_jl_vectorscope_mac
//
//  Unit tests for the panel geometry (scope square, correlation meter
//  placement, bar tracks). Standalone: no SDK, no Xcode.
//

#include "TestHarness.h"
#include "../src/Core/ScopeLayout.h"

using namespace scope_layout;

namespace {

Input panel(double w, double h, int position, int bars = 1, bool labels = true, double thickness = 6.0) {
    Input in;
    in.width = w;
    in.height = h;
    in.position = position;
    in.bars = bars;
    in.labels = labels;
    in.barThickness = thickness;
    return in;
}

bool overlap(const Rect& a, const Rect& b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

bool inside(const Rect& r, double w, double h) {
    return r.x >= 0.0 && r.y >= 0.0 && r.x + r.w <= w && r.y + r.h <= h;
}

// The meter below the scope, checked against hand-computed numbers.
void testBottom() {
    g_context = "bottom";
    const Result r = layout(panel(400, 400, MeterBottom));
    CHECK_EQ(r.position, MeterBottom, "position is kept");
    CHECK(!r.vertical, "bars are horizontal");
    CHECK_FLOAT_EQ(r.meter.x, 0.0, "strip starts at the left edge");
    CHECK_FLOAT_EQ(r.meter.y, 0.0, "strip sits on the bottom edge");
    CHECK_FLOAT_EQ(r.meter.w, 400.0, "strip spans the panel");
    CHECK_FLOAT_EQ(r.meter.h, 35.0, "pad + one row + scale + pad");
    CHECK(r.axisLabels, "a large scope has axis labels");
    CHECK_FLOAT_EQ(r.plot.w, 324.0, "scope fills the space above the strip");
    CHECK_FLOAT_EQ(r.plot.h, 324.0, "scope is square");
    CHECK_FLOAT_EQ(r.plot.x, 38.0, "scope is centred horizontally");
    CHECK_FLOAT_EQ(r.plot.y, 56.0, "scope is centred above the strip");
    CHECK_EQ(r.bars, 1, "one track");
    CHECK_FLOAT_EQ(r.track[0].x, 24.0, "bar starts under the scope's left label");
    CHECK_FLOAT_EQ(r.track[0].w, 314.0, "bar leaves room for the readout");
    CHECK_FLOAT_EQ(r.track[0].y, 20.5, "bar sits above the scale");
    CHECK_FLOAT_EQ(r.track[0].h, 6.0, "bar has the requested thickness");

    const Result bands = layout(panel(400, 400, MeterBottom, 3));
    CHECK_EQ(bands.bars, 3, "three tracks");
    CHECK_FLOAT_EQ(bands.meter.h, 57.0, "three rows");
    CHECK_FLOAT_EQ(bands.track[0].x - (bands.plot.x - kLabelInset), kRowLabelWidth, "band names take room before the bars");
    CHECK(bands.track[0].y > bands.track[1].y && bands.track[1].y > bands.track[2].y, "low band on top");
    CHECK_FLOAT_EQ(bands.track[0].y - bands.track[1].y, 11.0, "rows are one pitch apart");

    const Result bare = layout(panel(400, 400, MeterBottom, 3, false));
    CHECK_FLOAT_EQ(bare.meter.h, 45.0, "no scale row without labels");
    CHECK(!bare.axisLabels, "no axis labels without labels");
    CHECK(bare.track[0].w > bands.track[0].w, "bars take the label space");
}

void testTop() {
    g_context = "top";
    const Result below = layout(panel(400, 300, MeterBottom, 3));
    const Result above = layout(panel(400, 300, MeterTop, 3));
    CHECK(!above.vertical, "bars are horizontal");
    CHECK_FLOAT_EQ(above.meter.y + above.meter.h, 300.0, "strip touches the top edge");
    CHECK_FLOAT_EQ(above.meter.h, below.meter.h, "same strip height as below");
    CHECK_FLOAT_EQ(above.plot.w, below.plot.w, "same scope size as below");
    CHECK(above.plot.y + above.plot.h <= above.meter.y, "scope is under the strip");
    CHECK_FLOAT_EQ(above.track[0].y - above.meter.y, below.track[0].y - below.meter.y, "rows keep their order");
}

void testBeside() {
    g_context = "beside";
    const Result right = layout(panel(600, 400, MeterRight, 3));
    CHECK(right.vertical, "bars are vertical");
    CHECK_FLOAT_EQ(right.meter.x + right.meter.w, 600.0, "strip touches the right edge");
    CHECK_FLOAT_EQ(right.meter.h, 400.0, "strip spans the panel height");
    CHECK_FLOAT_EQ(right.meter.w, 61.0, "pad + three columns + scale + pad");
    CHECK(right.plot.x + right.plot.w <= right.meter.x, "scope is left of the strip");
    CHECK_EQ(right.bars, 3, "three tracks");
    CHECK(right.track[0].x < right.track[1].x && right.track[1].x < right.track[2].x, "low band first");
    CHECK_FLOAT_EQ(right.track[1].x - right.track[0].x, 11.0, "columns are one pitch apart");
    CHECK(right.legend[0].y > right.legend[1].y && right.legend[1].y > right.legend[2].y, "legend lists the low band first");
    CHECK(right.legend[0].y + right.legend[0].h <= right.track[0].y, "legend is under the bars");
    CHECK(right.legend[0].w >= kLegendNameWidth + kLegendValueWidth, "legend line fits a name and a readout");
    CHECK_FLOAT_EQ(right.track[0].w, 6.0, "bar has the requested thickness");
    CHECK_FLOAT_EQ(right.track[0].y + right.track[0].h / 2.0, right.plot.y + right.plot.h / 2.0,
                   "zero lines up with the scope's side axis");
    // Scale on the outer edge: beyond the last bar.
    CHECK(right.meter.x + right.meter.w - (right.track[2].x + right.track[2].w) >= kScaleWidth, "scale fits right of the bars");

    const Result left = layout(panel(600, 400, MeterLeft, 3));
    CHECK(left.vertical, "bars are vertical");
    CHECK_FLOAT_EQ(left.meter.x, 0.0, "strip touches the left edge");
    CHECK_FLOAT_EQ(left.meter.w, right.meter.w, "same strip width as on the right");
    CHECK_FLOAT_EQ(left.plot.w, right.plot.w, "same scope size as on the right");
    CHECK(left.plot.x >= left.meter.w, "scope is right of the strip");
    CHECK(left.track[0].x >= kMeterPad + kScaleWidth, "scale fits left of the bars");

    const Result bare = layout(panel(600, 400, MeterRight, 3, false));
    CHECK_FLOAT_EQ(bare.meter.w, 45.0, "unlabelled columns are packed");
    CHECK(bare.track[0].h > right.track[0].h, "bars take the legend's room");
    CHECK(bare.legend[0].empty(), "no legend without labels");

    const Result single = layout(panel(600, 400, MeterRight));
    CHECK_FLOAT_EQ(single.meter.w, 39.0, "one column, scale, and a readout underneath");
    CHECK(single.track[0].h > right.track[0].h, "one legend line leaves longer bars");

    const Result thin = layout(panel(600, 400, MeterRight, 3, true, 4.0));
    CHECK_FLOAT_EQ(thin.meter.w, 59.0, "strip stays wide enough for the legend");

    const Result thick = layout(panel(600, 400, MeterRight, 3, true, 24.0));
    CHECK_FLOAT_EQ(thick.track[0].w, 24.0, "thick bars keep their thickness");
    CHECK_FLOAT_EQ(thick.track[1].x - thick.track[0].x, 29.0, "and move one pitch apart");
}

void testAuto() {
    g_context = "auto";
    CHECK_EQ(layout(panel(800, 300, MeterAuto)).position, MeterRight, "wide panel: meter beside the scope");
    CHECK_EQ(layout(panel(300, 800, MeterAuto)).position, MeterBottom, "tall panel: meter below the scope");
    CHECK_EQ(layout(panel(400, 400, MeterAuto)).position, MeterBottom, "square panel: meter below the scope");

    Input hidden = panel(800, 300, MeterAuto);
    hidden.showMeter = false;
    CHECK(layout(hidden).meter.empty(), "no strip when the meter is off");
    CHECK_FLOAT_EQ(layout(hidden).plot.w, 260.0, "scope takes the whole panel");

    // Too narrow for three thick columns beside the scope: below still shows it.
    const Result r = layout(panel(130, 150, MeterAuto, 3, true, 24.0));
    CHECK_EQ(r.position, MeterBottom, "keeps the meter rather than the larger scope");
    CHECK(!r.meter.empty(), "meter is shown");

    for (double w = 60; w <= 900; w += 35) {
        for (double h = 60; h <= 900; h += 35) {
            for (int bars = 1; bars <= 3; bars += 2) {
                const Result a = layout(panel(w, h, MeterAuto, bars));
                const Result below = layout(panel(w, h, MeterBottom, bars));
                const Result beside = layout(panel(w, h, MeterRight, bars));
                CHECK(a.position == MeterBottom || a.position == MeterRight, "auto resolves to below or right");
                if (!below.meter.empty() && !beside.meter.empty()) {
                    CHECK(a.plot.w >= below.plot.w && a.plot.w >= beside.plot.w, "auto picks the larger scope");
                }
                CHECK(a.meter.empty() == (below.meter.empty() && beside.meter.empty()), "auto shows the meter when it fits");
            }
        }
    }
}

void testSmallPanels() {
    g_context = "small";
    const Result low = layout(panel(300, 80, MeterBottom));
    CHECK(low.meter.empty(), "meter hides in a short panel");
    CHECK_EQ(low.bars, 0, "no tracks");
    CHECK_FLOAT_EQ(low.plot.w, 68.0, "scope takes the full height");
    CHECK(!low.axisLabels, "small scope has no axis labels");

    CHECK(layout(panel(80, 300, MeterRight)).meter.empty(), "meter hides in a narrow panel");
    CHECK(layout(panel(20, 20, MeterBottom)).plot.empty(), "no scope when nothing fits");

    // Thick bars that would leave no room for the scope give way to it.
    const Result crowded = layout(panel(200, 100, MeterBottom, 3, true, 24.0));
    CHECK(crowded.meter.empty(), "meter hides rather than squeeze out the scope");
    CHECK(!crowded.plot.empty(), "scope is still drawn");

    const Result narrow = layout(panel(100, 300, MeterRight, 3, true, 24.0));
    CHECK(narrow.meter.empty(), "columns that do not fit give way");
    CHECK(!narrow.plot.empty(), "scope is still drawn");

    // A strip whose bars would be too short to read is not reserved at all.
    CHECK(layout(panel(300, 100, MeterRight, 3)).meter.empty(), "no room for bars between the legend rows");
    CHECK(!layout(panel(300, 100, MeterRight, 3, false)).meter.empty(), "unlabelled bars still fit");
    CHECK(layout(panel(92, 300, MeterBottom, 3)).meter.empty(), "no room for bars between name and readout");
}

void testBadInput() {
    g_context = "bad input";
    const Result bottom = layout(panel(400, 400, MeterBottom));
    const Result unknown = layout(panel(400, 400, 99));
    CHECK_EQ(unknown.position, MeterBottom, "unknown position falls back to bottom");
    CHECK_FLOAT_EQ(unknown.plot.w, bottom.plot.w, "with the bottom layout");
    CHECK_EQ(layout(panel(400, 400, -3)).position, MeterBottom, "negative position falls back to bottom");
    CHECK_EQ(layout(panel(400, 400, MeterBottom, 0)).bars, 1, "at least one bar");
    CHECK_EQ(layout(panel(400, 400, MeterBottom, 9)).bars, 3, "at most three bars");
    CHECK(layout(panel(0, 0, MeterAuto)).plot.empty(), "empty panel has no scope");
    CHECK(layout(panel(0, 0, MeterAuto)).meter.empty(), "empty panel has no meter");
}

// Nothing overlaps or leaves the panel, whatever the size and settings.
void testInvariants() {
    g_context = "invariants";
    const int positions[] = { MeterAuto, MeterBottom, MeterTop, MeterLeft, MeterRight };
    const double thicknesses[] = { 4.0, 6.0, 13.0, 24.0 };
    for (double w = 40; w <= 1000; w += 37) {
        for (double h = 40; h <= 1000; h += 41) {
            for (int position : positions) {
                for (double thickness : thicknesses) {
                    for (int bars = 1; bars <= 3; bars += 2) {
                        for (int labels = 0; labels <= 1; ++labels) {
                            const Result r = layout(panel(w, h, position, bars, labels != 0, thickness));
                            CHECK(r.position != MeterAuto, "position is resolved");
                            if (!r.plot.empty()) {
                                CHECK(inside(r.plot, w, h), "scope is inside the panel");
                                CHECK_FLOAT_EQ(r.plot.w, r.plot.h, "scope is square");
                            }
                            if (r.meter.empty()) {
                                CHECK_EQ(r.bars, 0, "no tracks without a strip");
                                continue;
                            }
                            CHECK_EQ(r.bars, bars, "a shown meter draws every bar");
                            CHECK(inside(r.meter, w, h), "strip is inside the panel");
                            CHECK(!r.plot.empty(), "a shown meter leaves room for the scope");
                            CHECK(!overlap(r.plot, r.meter), "scope and strip do not overlap");
                            for (int i = 0; i < r.bars; ++i) {
                                const Rect& t = r.track[i];
                                CHECK(t.w >= (r.vertical ? thickness : kMinBarLength) &&
                                      t.h >= (r.vertical ? kMinBarLength : thickness), "track has a drawable size");
                                CHECK(inside(t, w, h), "track is inside the panel");
                                if (r.vertical && labels) {
                                    const Rect& line = r.legend[i];
                                    CHECK(inside(line, w, h), "legend line is inside the panel");
                                    CHECK(line.x >= r.meter.x && line.x + line.w <= r.meter.x + r.meter.w, "legend line is inside the strip");
                                    CHECK(line.y + line.h <= t.y, "legend line is under the bars");
                                    // The same room is left above the bars.
                                    CHECK(t.y + t.h + (t.y - r.legend[r.bars - 1].y) <= h, "bars stay centred");
                                } else {
                                    CHECK(r.legend[i].empty(), "legend only beside the scope with labels");
                                }
                                CHECK(r.vertical ? (t.x >= r.meter.x && t.x + t.w <= r.meter.x + r.meter.w)
                                                 : (t.y >= r.meter.y && t.y + t.h <= r.meter.y + r.meter.h),
                                      "track is inside the strip");
                                if (i > 0) CHECK(!overlap(r.track[i - 1], r.track[i]), "tracks do not overlap");
                            }
                        }
                    }
                }
            }
        }
    }
}

} // namespace

int main() {
    testBottom();
    testTop();
    testBeside();
    testAuto();
    testSmallPanels();
    testBadInput();
    testInvariants();
    TEST_MAIN_END();
}
