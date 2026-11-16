//
//  IntakeTint.h
//  foo_jl_intake
//
//  The six row colours as settings (doc 04 v1.2 "Preferences page", PLAN.md
//  B10 and 3.9): configStore keys foo_jl_intake.tint_new, tint_review,
//  tint_proposed, tint_approved, tint_placed and tint_rejected, each a packed
//  sRGB 0xRRGGBBAA like jl_rgba_t, because SimPlaylist draws decoration
//  colours with colorWithSRGBRed (the suite's ThemeColor packs 0xAARRGGBB in
//  Display P3 and is not used here).
//
//  Storage: configInts (int64), not a string. The other numeric settings of
//  this component are ints too, the whole 32-bit value fits, nothing has to
//  be parsed as text, and SQLite takes a hex literal, so an edit stays
//  readable: VALUES('foo_jl_intake.tint_placed', 0xFF00FFFF).
//  Reading a key (parseTintSetting):
//   - absent (the reader returns kTintSettingAbsent): the IntakePalette
//     default;
//   - 0: no tint for that status. The row keeps its normal background, and
//     an icon that takes the tint's colour uses the host's label colour
//     (rowIconColor gives 0);
//   - 1..0xFFFFFFFF: that colour;
//   - anything else (negative, wider than 32 bits): malformed, the default,
//     and one problem line (paletteFromSettings), which IntakeService logs
//     at Debug.
//  An alpha of 0 with a colour (0xRRGGBB00) is kept as it is: the row
//  background draws nothing, and coloured icons still use the RGB at full
//  alpha (from alpha 0x99 up they use the label colour, rowIconColor).
//
//  Packing (the preferences page's NSColorWell, after conversion to sRGB):
//  each component 0..1 is scaled to 0..255, rounded half away from zero
//  (127.5 -> 128) and clamped (below 0 -> 0, above 1 -> 255, NaN -> 0).
//  Unpacking divides by 255, so every byte survives unpack then pack.
//
//  Thread-safety: pure functions, no shared state.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "IntakeDecorationMap.h"

namespace intake {

// --- the six settings ---

enum class TintSlot : uint8_t {
    New,       // new and resolved roots
    Review,    // amber: needs review (and the amber group badge)
    Proposed,
    Approved,  // approved and placing
    Placed,    // placed and verified
    Rejected,
};

inline constexpr size_t kTintSlotCount = 6;
inline constexpr TintSlot kTintSlots[kTintSlotCount] = {
    TintSlot::New, TintSlot::Review, TintSlot::Proposed, TintSlot::Approved, TintSlot::Placed, TintSlot::Rejected,
};

// The key without the "foo_jl_intake." prefix: "tint_new", "tint_review",
// "tint_proposed", "tint_approved", "tint_placed", "tint_rejected".
const char *tintKey(TintSlot slot);

// The preferences page's label: "New", "Needs review", "Proposed",
// "Approved / placing", "Placed", "Rejected".
const char *tintLabel(TintSlot slot);

IntakeRgba tintOf(const IntakePalette &palette, TintSlot slot);
void setTint(IntakePalette &palette, TintSlot slot, IntakeRgba value);

// --- packing ---

// 0..1 to 0..255: rounded half away from zero, clamped; NaN gives 0.
uint8_t unitToByte(double unit);
// 0..255 to 0..1 (byte / 255).
double byteToUnit(uint8_t byte);

// sRGB components, each 0..1, to 0xRRGGBBAA (unitToByte on each).
IntakeRgba packRgba(double red, double green, double blue, double alpha);

struct RgbaUnits {
    double red = 0;
    double green = 0;
    double blue = 0;
    double alpha = 0;
};

// 0xRRGGBBAA to components 0..1 (byteToUnit on each).
RgbaUnits unpackRgba(IntakeRgba rgba);

// "0xRRGGBBAA" (upper-case hex digits).
std::string rgbaHex(IntakeRgba rgba);

// --- the stored setting ---

// What a reader returns for a key with no row (pass it as getConfigInt's
// default). A stored INT64_MIN reads as absent; it would be malformed
// anyway, with the same result.
inline constexpr int64_t kTintSettingAbsent = INT64_MIN;
// The largest stored value that is a colour.
inline constexpr int64_t kTintSettingMax = 0xFFFFFFFFLL;

enum class TintSettingKind : uint8_t {
    Default,    // absent: the default
    Colour,     // a colour
    Off,        // 0: no tint
    Malformed,  // out of range: the default
};

struct ParsedTint {
    IntakeRgba rgba = 0;  // what the palette uses (0 for Off)
    TintSettingKind kind = TintSettingKind::Default;
};

ParsedTint parseTintSetting(int64_t stored, IntakeRgba defaultTint);

struct PaletteSettings {
    IntakePalette palette;
    // One line per malformed key: "tint_placed: -5 is not 0 or a
    // 0xRRGGBBAA colour; using the default 0x3FB95038".
    std::vector<std::string> problems;
};

// `read(key)` returns the stored int for "tint_*" (key without the prefix),
// or kTintSettingAbsent. Starts from the IntakePalette defaults.
PaletteSettings paletteFromSettings(const std::function<int64_t(const char *key)> &read);

// The tints that differ from the defaults, in slot order, e.g.
// "placed 0xFF00FFFF, rejected none"; "" when there are none.
std::string describePaletteChanges(const IntakePalette &palette);

} // namespace intake
