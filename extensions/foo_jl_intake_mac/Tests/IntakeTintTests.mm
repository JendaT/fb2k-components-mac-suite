//
//  IntakeTintTests.mm
//  foo_jl_intake_mac
//
//  The row colour settings (PLAN.md B10, 3.9): packing sRGB components to
//  0xRRGGBBAA and back (rounding at .5, clamping, alpha, 0), the stored
//  int's meaning (absent, 0, a colour, malformed), the palette built from a
//  settings reader with its problem lines, the change summary, and a tint
//  of 0 reaching the row visual as no tint with the host's icon colour (as
//  does a tint of alpha 0x99 or more, which keeps its background).
//  Pure: no files, no configStore.
//
// TEST_DEPS: src/Core/IntakeDecorationMap.mm src/Core/IntakeReviewRule.mm
// TEST_DEPS: src/Core/IntakeTargetPath.mm src/Core/IntakeGroupBadge.mm
//

#import <Foundation/Foundation.h>

#include "../src/Core/IntakeStatusModel.h"
#include "../src/Core/IntakeTint.h"
#include "TestHarness.h"

#include <cmath>
#include <limits>
#include <map>
#include <string>

using namespace intake;

static void testSlots() {
    g_context = "slots";
    CHECK(std::string(tintKey(TintSlot::New)) == "tint_new" && std::string(tintKey(TintSlot::Review)) == "tint_review" &&
              std::string(tintKey(TintSlot::Proposed)) == "tint_proposed" &&
              std::string(tintKey(TintSlot::Approved)) == "tint_approved" &&
              std::string(tintKey(TintSlot::Placed)) == "tint_placed" &&
              std::string(tintKey(TintSlot::Rejected)) == "tint_rejected",
          "the six keys");
    CHECK(std::string(tintLabel(TintSlot::New)) == "New" && std::string(tintLabel(TintSlot::Review)) == "Needs review" &&
              std::string(tintLabel(TintSlot::Approved)) == "Approved / placing",
          "plain labels");
    IntakePalette p;
    IntakeRgba value = 1;
    for (TintSlot slot : kTintSlots) setTint(p, slot, value++);
    bool each = true;
    value = 1;
    for (TintSlot slot : kTintSlots) each = each && tintOf(p, slot) == value++;
    CHECK(each, "setTint and tintOf address one field per slot");
    CHECK(IntakePalette() == IntakePalette() && !(p == IntakePalette()), "palette equality");
}

static void testPacking() {
    g_context = "packing";
    // Every default survives unpack then pack.
    const IntakePalette defaults;
    for (TintSlot slot : kTintSlots) {
        const IntakeRgba rgba = tintOf(defaults, slot);
        const RgbaUnits u = unpackRgba(rgba);
        CHECK_EQ(packRgba(u.red, u.green, u.blue, u.alpha), rgba, tintKey(slot));
    }
    bool everyByte = true;
    for (int b = 0; b < 256; b++) {
        everyByte = everyByte && unitToByte(byteToUnit(static_cast<uint8_t>(b))) == b;
    }
    CHECK(everyByte, "every byte survives byteToUnit then unitToByte");

    // Rounding: half away from zero.
    CHECK_EQ(unitToByte(0.5), 128, "0.5 is 127.5: rounds up to 128");
    CHECK_EQ(unitToByte((127.5 - 0.01) / 255.0), 127, "just below .5 rounds down");
    CHECK_EQ(unitToByte((127.5 + 0.01) / 255.0), 128, "just above .5 rounds up");
    CHECK_EQ(unitToByte(0.25), 64, "63.75 -> 64");
    CHECK_EQ(unitToByte(0.75), 191, "191.25 -> 191");

    // Clamping.
    CHECK_EQ(unitToByte(-0.2), 0, "below 0 clamps to 0");
    CHECK_EQ(unitToByte(-1e-12), 0, "a hair below 0 is 0");
    CHECK_EQ(unitToByte(1.0), 255, "1 is 255");
    CHECK_EQ(unitToByte(1.3), 255, "above 1 clamps to 255");
    CHECK_EQ(unitToByte(std::numeric_limits<double>::infinity()), 255, "+inf clamps to 255");
    CHECK_EQ(unitToByte(-std::numeric_limits<double>::infinity()), 0, "-inf clamps to 0");
    CHECK_EQ(unitToByte(std::nan("")), 0, "NaN is 0");
    CHECK_EQ(packRgba(-0.5, 1.5, 0.5, 2.0), 0x00FF80FFu, "each component clamped on its own");

    // Alpha kept, byte order RRGGBBAA.
    CHECK_EQ(packRgba(1, 0, 1, 0.5), 0xFF00FF80u, "opaque magenta at half alpha");
    CHECK_EQ(packRgba(0.25, 0.5, 0.75, 1), 0x4080BFFFu, "R, G, B, A in that order");
    const RgbaUnits half = unpackRgba(0xFF00FF80);
    CHECK(half.red == 1.0 && half.green == 0.0 && half.blue == 1.0 && std::fabs(half.alpha - 128 / 255.0) < 1e-12,
          "unpack: components 0..1, alpha kept");

    // 0
    CHECK_EQ(packRgba(0, 0, 0, 0), 0u, "all zero packs to 0 (no tint)");
    const RgbaUnits zero = unpackRgba(0);
    CHECK(zero.red == 0 && zero.green == 0 && zero.blue == 0 && zero.alpha == 0, "0 unpacks to all zero");
    CHECK_EQ(packRgba(0, 0, 0, 1), 0x000000FFu, "opaque black is not 0");

    CHECK(rgbaHex(0x3FB95038) == "0x3FB95038" && rgbaHex(0) == "0x00000000" && rgbaHex(0xff00ffff) == "0xFF00FFFF",
          "hex text, upper case, 8 digits");
}

static void testParse() {
    g_context = "parse";
    const IntakeRgba def = 0x3FB95038;
    ParsedTint p = parseTintSetting(kTintSettingAbsent, def);
    CHECK(p.kind == TintSettingKind::Default && p.rgba == def, "absent: the default");
    p = parseTintSetting(0, def);
    CHECK(p.kind == TintSettingKind::Off && p.rgba == 0, "0: no tint");
    p = parseTintSetting(0xFF00FFFF, def);
    CHECK(p.kind == TintSettingKind::Colour && p.rgba == 0xFF00FFFF, "a colour");
    p = parseTintSetting(1, def);
    CHECK(p.kind == TintSettingKind::Colour && p.rgba == 1, "the smallest colour");
    p = parseTintSetting(kTintSettingMax, def);
    CHECK(p.kind == TintSettingKind::Colour && p.rgba == 0xFFFFFFFF, "the largest colour");
    p = parseTintSetting(-5, def);
    CHECK(p.kind == TintSettingKind::Malformed && p.rgba == def, "negative: malformed, the default");
    p = parseTintSetting(0x1FFFFFFFFLL, def);
    CHECK(p.kind == TintSettingKind::Malformed && p.rgba == def, "wider than 32 bits: malformed");
    p = parseTintSetting(std::numeric_limits<int64_t>::max(), def);
    CHECK(p.kind == TintSettingKind::Malformed && p.rgba == def, "INT64_MAX: malformed");
}

static void testPaletteFromSettings() {
    g_context = "palette";
    const PaletteSettings none = paletteFromSettings(nullptr);
    CHECK(none.palette == IntakePalette() && none.problems.empty(), "no reader: the defaults");
    const PaletteSettings absent = paletteFromSettings([](const char *) { return kTintSettingAbsent; });
    CHECK(absent.palette == IntakePalette() && absent.problems.empty(), "every key absent: the defaults");

    const std::map<std::string, int64_t> stored = {
        {"tint_placed", 0xFF00FFFF},
        {"tint_rejected", 0},
        {"tint_new", -5},
    };
    std::vector<std::string> asked;
    const PaletteSettings s = paletteFromSettings([&stored, &asked](const char *key) {
        asked.push_back(key);
        auto found = stored.find(key);
        return found == stored.end() ? kTintSettingAbsent : found->second;
    });
    CHECK_EQ(asked.size(), kTintSlotCount, "each key read once");
    const IntakePalette defaults;
    CHECK_EQ(s.palette.tintPlaced, 0xFF00FFFFu, "a stored colour");
    CHECK_EQ(s.palette.tintRejected, 0u, "0: no tint");
    CHECK_EQ(s.palette.tintNew, defaults.tintNew, "malformed: the default");
    CHECK(s.palette.tintReview == defaults.tintReview && s.palette.tintProposed == defaults.tintProposed &&
              s.palette.tintApproved == defaults.tintApproved,
          "absent keys: the defaults");
    CHECK(s.problems.size() == 1 &&
              s.problems[0] == "tint_new: -5 is not 0 or a 0xRRGGBBAA colour; using the default 0x4A90D938",
          "one problem line for the malformed key");

    CHECK(describePaletteChanges(IntakePalette()).empty(), "the defaults: no change to describe");
    CHECK(describePaletteChanges(s.palette) == "placed 0xFF00FFFF, rejected none",
          "the changed tints, in slot order; 0 as none");
}

static void testOffReachesTheRow() {
    g_context = "row";
    IntakeRecord placed;
    placed.id = "itk_00000001";
    placed.rootPath = placed.rootKey = "/income/dump/Fixture Artist - Placed Album";
    placed.status = IntakeStatus::Placed;
    placed.hasPlaced = true;
    placed.placedVerified = true;

    IntakePalette custom;
    custom.tintPlaced = 0xFF00FF98;
    IntakeRowVisual v = rowVisualFor(placed, custom);
    CHECK(v.bgTint == 0xFF00FF98 && v.iconColor == 0xFF00FFFF && v.icon == IntakeIcon::CircleFilled,
          "a custom placed tint below 0x99: background, and the icon in its RGB at alpha FF");
    custom.tintPlaced = 0xFF00FF99;
    v = rowVisualFor(placed, custom);
    CHECK(v.bgTint == 0xFF00FF99 && v.iconColor == 0 && v.icon == IntakeIcon::CircleFilled,
          "alpha 0x99: background, the icon in the label colour");
    custom.tintPlaced = 0xFF00FFFF;
    v = rowVisualFor(placed, custom);
    CHECK(v.bgTint == 0xFF00FFFF && v.iconColor == 0 && v.icon == IntakeIcon::CircleFilled,
          "an opaque placed tint (B10a): background, the icon in the label colour so it shows");

    IntakePalette off;
    off.tintPlaced = 0;
    v = rowVisualFor(placed, off);
    CHECK(v.bgTint == 0 && v.iconColor == 0 && v.icon == IntakeIcon::CircleFilled && !v.isNone(),
          "tint 0: no background, the host's label colour, the icon stays");

    IntakePalette clear;
    clear.tintPlaced = 0x3FB95000;
    v = rowVisualFor(placed, clear);
    CHECK(v.bgTint == 0x3FB95000 && v.iconColor == 0x3FB950FF, "alpha 0 is kept; the icon is opaque");
}

int main(void) {
    @autoreleasepool {
        testSlots();
        testPacking();
        testParse();
        testPaletteFromSettings();
        testOffReachesTheRow();
    }
    TEST_MAIN_END();
}
