//
//  IntakeTint.mm
//  foo_jl_intake
//

#include "IntakeTint.h"

#include <cmath>
#include <cstdio>

namespace intake {

const char *tintKey(TintSlot slot) {
    switch (slot) {
        case TintSlot::New: return "tint_new";
        case TintSlot::Review: return "tint_review";
        case TintSlot::Proposed: return "tint_proposed";
        case TintSlot::Approved: return "tint_approved";
        case TintSlot::Placed: return "tint_placed";
        case TintSlot::Rejected: return "tint_rejected";
    }
    return "tint_unknown";
}

const char *tintLabel(TintSlot slot) {
    switch (slot) {
        case TintSlot::New: return "New";
        case TintSlot::Review: return "Needs review";
        case TintSlot::Proposed: return "Proposed";
        case TintSlot::Approved: return "Approved / placing";
        case TintSlot::Placed: return "Placed";
        case TintSlot::Rejected: return "Rejected";
    }
    return "";
}

IntakeRgba tintOf(const IntakePalette &palette, TintSlot slot) {
    switch (slot) {
        case TintSlot::New: return palette.tintNew;
        case TintSlot::Review: return palette.tintReview;
        case TintSlot::Proposed: return palette.tintProposed;
        case TintSlot::Approved: return palette.tintApproved;
        case TintSlot::Placed: return palette.tintPlaced;
        case TintSlot::Rejected: return palette.tintRejected;
    }
    return 0;
}

void setTint(IntakePalette &palette, TintSlot slot, IntakeRgba value) {
    switch (slot) {
        case TintSlot::New: palette.tintNew = value; break;
        case TintSlot::Review: palette.tintReview = value; break;
        case TintSlot::Proposed: palette.tintProposed = value; break;
        case TintSlot::Approved: palette.tintApproved = value; break;
        case TintSlot::Placed: palette.tintPlaced = value; break;
        case TintSlot::Rejected: palette.tintRejected = value; break;
    }
}

// --- packing ---

uint8_t unitToByte(double unit) {
    if (std::isnan(unit)) return 0;
    const double scaled = unit * 255.0;
    if (scaled <= 0) return 0;
    if (scaled >= 255) return 255;
    // std::round: half away from zero (127.5 -> 128).
    return static_cast<uint8_t>(std::round(scaled));
}

double byteToUnit(uint8_t byte) {
    return byte / 255.0;
}

IntakeRgba packRgba(double red, double green, double blue, double alpha) {
    return (static_cast<IntakeRgba>(unitToByte(red)) << 24) | (static_cast<IntakeRgba>(unitToByte(green)) << 16) |
           (static_cast<IntakeRgba>(unitToByte(blue)) << 8) | static_cast<IntakeRgba>(unitToByte(alpha));
}

RgbaUnits unpackRgba(IntakeRgba rgba) {
    RgbaUnits u;
    u.red = byteToUnit(static_cast<uint8_t>(rgba >> 24));
    u.green = byteToUnit(static_cast<uint8_t>(rgba >> 16));
    u.blue = byteToUnit(static_cast<uint8_t>(rgba >> 8));
    u.alpha = byteToUnit(static_cast<uint8_t>(rgba));
    return u;
}

std::string rgbaHex(IntakeRgba rgba) {
    char text[16];
    snprintf(text, sizeof(text), "0x%08X", static_cast<unsigned>(rgba));
    return text;
}

// --- the stored setting ---

ParsedTint parseTintSetting(int64_t stored, IntakeRgba defaultTint) {
    ParsedTint p;
    if (stored == kTintSettingAbsent) {
        p.rgba = defaultTint;
        p.kind = TintSettingKind::Default;
    } else if (stored == 0) {
        p.rgba = 0;
        p.kind = TintSettingKind::Off;
    } else if (stored > 0 && stored <= kTintSettingMax) {
        p.rgba = static_cast<IntakeRgba>(stored);
        p.kind = TintSettingKind::Colour;
    } else {
        p.rgba = defaultTint;
        p.kind = TintSettingKind::Malformed;
    }
    return p;
}

PaletteSettings paletteFromSettings(const std::function<int64_t(const char *key)> &read) {
    PaletteSettings out;
    const IntakePalette defaults;
    for (TintSlot slot : kTintSlots) {
        const int64_t stored = read ? read(tintKey(slot)) : kTintSettingAbsent;
        const ParsedTint parsed = parseTintSetting(stored, tintOf(defaults, slot));
        setTint(out.palette, slot, parsed.rgba);
        if (parsed.kind == TintSettingKind::Malformed) {
            out.problems.push_back(std::string(tintKey(slot)) + ": " + std::to_string(stored) +
                                   " is not 0 or a 0xRRGGBBAA colour; using the default " +
                                   rgbaHex(tintOf(defaults, slot)));
        }
    }
    return out;
}

std::string describePaletteChanges(const IntakePalette &palette) {
    const IntakePalette defaults;
    std::string out;
    for (TintSlot slot : kTintSlots) {
        const IntakeRgba value = tintOf(palette, slot);
        if (value == tintOf(defaults, slot)) continue;
        if (!out.empty()) out += ", ";
        // "tint_placed" -> "placed"
        out += tintKey(slot) + 5;
        out += ' ';
        out += value == 0 ? std::string("none") : rgbaHex(value);
    }
    return out;
}

} // namespace intake
