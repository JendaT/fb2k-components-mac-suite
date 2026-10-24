//
//  MeterLayoutTests.cpp
//  foo_jl_levelmeter_mac
//
//  Placement of the digital meter's parts across panel sizes.
//

#include "TestHarness.h"
#include "../src/Core/MeterLayout.h"

#include <string>
#include <vector>

using namespace meter_layout;

namespace {

bool inside(const Rect &r, double w, double h) {
    return r.empty() || (r.x >= -0.5 && r.y >= -0.5 && r.maxX() <= w + 0.5 && r.maxY() <= h + 0.5);
}

bool overlaps(const Rect &a, const Rect &b) {
    if (a.empty() || b.empty()) return false;
    return a.x < b.maxX() - 0.5 && b.x < a.maxX() - 0.5 && a.y < b.maxY() - 0.5 && b.y < a.maxY() - 0.5;
}

Input input(double w, double h, meter::Orientation o = meter::Orientation::Auto) {
    Input in;
    in.width = w;
    in.height = h;
    in.orientation = o;
    return in;
}

void checkSane(const Input &in, const char *what) {
    g_context = std::string(what) + " " + std::to_string((int)in.width) + "x" + std::to_string((int)in.height);
    const Result r = layout(in);
    std::vector<Rect> parts;
    for (int i = 0; i < BarCount; ++i) parts.push_back(r.bar[i]);
    parts.push_back(r.scale);
    parts.push_back(r.loudnessScale);
    parts.push_back(r.stats);
    parts.push_back(r.correlation);
    parts.push_back(r.balance);
    bool allInside = true, noOverlap = true;
    for (size_t i = 0; i < parts.size(); ++i) {
        if (!inside(parts[i], in.width, in.height)) allInside = false;
        for (size_t j = i + 1; j < parts.size(); ++j) {
            if (overlaps(parts[i], parts[j])) noOverlap = false;
        }
    }
    for (int i = 0; i < BarCount; ++i) {
        if (!inside(r.readout[i], in.width, in.height)) allInside = false;
    }
    CHECK(allInside, "every part inside the panel");
    CHECK(noOverlap, "bars, scales and figures do not overlap");
    CHECK(!r.bar[BarL].empty() && !r.bar[BarR].empty(), "level bars always present");
}

void testSizes() {
    const double sizes[][2] = { {260, 420}, {120, 200}, {60, 120}, {760, 104}, {400, 40}, {1200, 60},
                                {300, 300}, {180, 600}, {900, 220} };
    for (const auto &s : sizes) {
        checkSane(input(s[0], s[1]), "auto");
        checkSane(input(s[0], s[1], meter::Orientation::Vertical), "vertical");
        checkSane(input(s[0], s[1], meter::Orientation::Horizontal), "horizontal");
    }
}

void testOrientation() {
    g_context = "auto orientation";
    CHECK(layout(input(200, 400)).vertical, "tall panel is vertical");
    CHECK(!layout(input(800, 100)).vertical, "wide panel is horizontal");
    CHECK(layout(input(300, 300)).vertical, "square panel stays upright");
    CHECK(!layout(input(300, 300, meter::Orientation::Horizontal)).vertical, "forced horizontal");
}

void testDegrade() {
    g_context = "full vertical";
    Result full = layout(input(260, 420));
    CHECK(!full.bar[BarM].empty(), "loudness bars");
    CHECK(!full.stats.empty(), "stats");
    CHECK(!full.correlation.empty() && !full.balance.empty(), "stereo bars");
    CHECK(full.statsTwoColumns, "two stat columns");

    g_context = "short vertical";
    Result shortV = layout(input(260, 150, meter::Orientation::Vertical));
    CHECK(shortV.correlation.empty(), "stereo dropped first");
    CHECK(shortV.bar[BarL].h >= 60.0, "bars keep their minimum length");

    g_context = "narrow vertical";
    Result narrow = layout(input(50, 300, meter::Orientation::Vertical));
    CHECK(narrow.bar[BarM].empty(), "loudness bars dropped when too narrow");

    g_context = "horizontal stats";
    CHECK(!layout(input(760, 104)).stats.empty(), "wide horizontal shows stats");
    CHECK(layout(input(300, 104, meter::Orientation::Horizontal)).stats.empty(), "short horizontal drops stats");

    g_context = "switches";
    Input off = input(260, 420);
    off.loudness = false;
    off.correlation = false;
    off.balance = false;
    off.readouts = false;
    Result bare = layout(off);
    CHECK(bare.bar[BarM].empty() && bare.stats.empty() && bare.correlation.empty(), "sections off");
    CHECK(bare.readout[BarL].empty(), "readouts off");

    g_context = "stereo rows";
    Input corrOnly = input(260, 420);
    corrOnly.balance = false;
    Result c = layout(corrOnly);
    CHECK(!c.correlation.empty() && c.balance.empty(), "correlation alone");
    Input balOnly = input(260, 420);
    balOnly.correlation = false;
    Result b = layout(balOnly);
    CHECK(b.correlation.empty() && !b.balance.empty(), "balance alone");
    CHECK(b.bar[BarL].h > full.bar[BarL].h, "one stereo row leaves the bars more room");
    Input wideBal = input(760, 104);
    wideBal.correlation = false;
    CHECK(!layout(wideBal).balance.empty(), "horizontal: balance alone in the side column");

    g_context = "stereo drop order";
    // Just tall enough for one stereo row: balance goes first.
    Result tight = layout(input(260, 60 + 14 + 9 + 16 + 32 + 15 + 12, meter::Orientation::Vertical));
    CHECK(!tight.correlation.empty() && tight.balance.empty(), "balance dropped before correlation");

    g_context = "empty panel";
    Result none = layout(input(0, 0));
    CHECK(none.bar[BarL].empty(), "nothing in a zero panel");
}

} // namespace

int main() {
    testSizes();
    testOrientation();
    testDegrade();
    TEST_MAIN_END();
}
