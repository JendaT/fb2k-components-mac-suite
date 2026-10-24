//
//  LevelMeterConfig.h
//  foo_jl_levelmeter_mac
//
//  Configuration keys, defaults and fb2k::configStore accessors, plus the
//  loaders that turn stored settings into the engine's and renderer's
//  structs. Config is persisted via fb2k::configStore (cfg_var does not
//  persist on macOS v2).
//

#pragma once

#include "../fb2k_sdk.h"
#include "DisplaySettings.h"
#include "LevelMeterThemes.h"
#include "MeterEngine.h"

namespace levelmeter_config {

using namespace meter;

// Preferences page GUID (shared by page registration and "open preferences" actions)
static const GUID guid_preferences_page = {
    0x5FB7017F, 0xE98F, 0x469A,
    {0xA3, 0x93, 0x68, 0x5A, 0x0F, 0x1D, 0x92, 0x71}
};

// --- Ranges and defaults ---
constexpr int kDefaultStyle          = (int)MeterStyle::Digital;
constexpr int kDefaultOrientation    = (int)Orientation::Auto;
constexpr int kDefaultBarMode        = (int)BarMode::PeakAndRms;
constexpr int kDefaultScale          = (int)ScaleType::Dbfs;
constexpr int kDefaultSpacing        = (int)ScaleSpacing::Extended;
constexpr int kDefaultFloorDb        = -60;
static const int kFloorChoices[]     = { -24, -40, -48, -60, -72, -80, -90, -120 };
constexpr bool kDefaultSegments      = false;
constexpr bool kDefaultShowReadouts  = true;
constexpr bool kDefaultShowLoudness  = true;
constexpr bool kDefaultShowStereo    = true;
constexpr bool kDefaultTruePeak      = true;
constexpr int kDefaultWarnDb         = -12;
constexpr int kDefaultOverDb         = -3;
constexpr int kMinZoneDb             = -40;
constexpr int kDefaultRmsMs          = 300;
constexpr int kMinRmsMs              = 50;
constexpr int kMaxRmsMs              = 3000;
constexpr bool kDefaultRmsSinePeak   = false;
constexpr int kDefaultPeakFallTenths = 118;   // 20 dB in 1.7 s
constexpr int kMinPeakFallTenths     = 30;
constexpr int kMaxPeakFallTenths     = 600;
constexpr int kDefaultPeakHoldMs     = 1500;
constexpr int kMaxPeakHoldMs         = 5000;
constexpr bool kDefaultHoldForever   = false;
constexpr int kDefaultTargetLufs     = -14;
static const int kTargetChoices[]    = { -9, -11, -14, -16, -18, -23, -24 };
constexpr bool kDefaultResetOnTrack  = true;
constexpr int kDefaultFace           = (int)FaceStyle::Vintage;
constexpr int kDefaultNeedleLayout   = (int)NeedleLayout::Auto;
constexpr int kDefaultNeedle         = (int)NeedleBallistics::VU;
constexpr int kDefaultReferenceDb    = -18;
constexpr int kMinReferenceDb        = -24;
constexpr int kMaxReferenceDb        = -6;
constexpr bool kDefaultPeakLed       = true;
constexpr int kDefaultPeakLedDb      = -1;
constexpr int kMinPeakLedDb          = -20;
constexpr bool kDefaultGlass         = false;

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix      = "foo_jl_levelmeter.";
static const char* const kKeyStyle          = "style";
static const char* const kKeyOrientation    = "orientation";
static const char* const kKeyBarMode        = "bar_mode";
static const char* const kKeyScale          = "scale";
static const char* const kKeySpacing        = "scale_spacing";
static const char* const kKeyFloorDb        = "floor_db";
static const char* const kKeySegments       = "segments";
static const char* const kKeyShowReadouts   = "show_readouts";
static const char* const kKeyShowLoudness   = "show_loudness";
static const char* const kKeyShowStereo     = "show_stereo";
static const char* const kKeyTruePeak       = "true_peak";
static const char* const kKeyWarnDb         = "warn_db";
static const char* const kKeyOverDb         = "over_db";
static const char* const kKeyRmsMs          = "rms_ms";
static const char* const kKeyRmsSinePeak    = "rms_sine_reads_peak";
static const char* const kKeyPeakFallTenths = "peak_fall_tenths";
static const char* const kKeyPeakHoldMs     = "peak_hold_ms";
static const char* const kKeyHoldForever    = "peak_hold_forever";
static const char* const kKeyTargetLufs     = "target_lufs";
static const char* const kKeyResetOnTrack   = "reset_loudness_on_track";
static const char* const kKeyFace           = "face";
static const char* const kKeyNeedleLayout   = "needle_layout";
static const char* const kKeyNeedle         = "needle_ballistics";
static const char* const kKeyReferenceDb    = "reference_db";
static const char* const kKeyPeakLed        = "peak_led";
static const char* const kKeyPeakLedDb      = "peak_led_db";
static const char* const kKeyGlass          = "glass_background";
static const char* const kKeyTheme          = "theme";
// Colours: background, text, safe, warn, over, loudness
constexpr int kColorCount = 6;
static const char* const kKeyColorLight[kColorCount] = {
    "bg_color_light", "text_color_light", "safe_color_light", "warn_color_light", "over_color_light", "loudness_color_light" };
static const char* const kKeyColorDark[kColorCount] = {
    "bg_color_dark", "text_color_dark", "safe_color_dark", "warn_color_dark", "over_color_dark", "loudness_color_dark" };
static const char* const kColorNames[kColorCount] = { "Background", "Text", "Level", "Warning", "Over", "Loudness" };

// Notification posted when preferences change so live views can reload.
#ifdef __OBJC__
static NSString* const kSettingsChangedNotification = @"LevelMeterSettingsChanged";
#endif

// --- configStore accessors ---
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        return store->getConfigInt(fullKey.c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        store->setConfigInt(fullKey.c_str(), value);
    } catch (...) {
    }
}

inline bool getConfigBool(const char* key, bool defaultVal) {
    return getConfigInt(key, defaultVal ? 1 : 0) != 0;
}

inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

// Stored values are user-editable; keep them inside the range the controls offer.
inline int getConfigIntClamped(const char* key, int defaultVal, int lo, int hi) {
    const int64_t v = getConfigInt(key, defaultVal);
    return (int)(v < lo ? lo : (v > hi ? hi : v));
}

inline uint32_t defaultColor(int index, bool dark) {
    const MeterTheme &t = kMeterThemes[kDefaultMeterTheme];
    return dark ? t.dark[index] : t.light[index];
}

inline uint32_t getColor(int index, bool dark) {
    return (uint32_t)getConfigInt(dark ? kKeyColorDark[index] : kKeyColorLight[index], defaultColor(index, dark));
}

// Write a preset's colours into config. No-op for index 0 (Custom) or invalid.
inline void applyThemeToConfig(int index) {
    if (index <= 0 || index >= kMeterThemeCount) return;
    const MeterTheme &t = kMeterThemes[index];
    for (int i = 0; i < kColorCount; ++i) {
        setConfigInt(kKeyColorLight[i], t.light[i]);
        setConfigInt(kKeyColorDark[i], t.dark[i]);
    }
}

// --- Loaders ---

inline EngineSettings loadEngineSettings() {
    EngineSettings s;
    s.rmsWindowSeconds = getConfigIntClamped(kKeyRmsMs, kDefaultRmsMs, kMinRmsMs, kMaxRmsMs) / 1000.0;
    s.rmsSineReadsPeak = getConfigBool(kKeyRmsSinePeak, kDefaultRmsSinePeak);
    s.peakFallDbPerSecond = getConfigIntClamped(kKeyPeakFallTenths, kDefaultPeakFallTenths,
                                                kMinPeakFallTenths, kMaxPeakFallTenths) / 10.0;
    s.peakHoldSeconds = getConfigIntClamped(kKeyPeakHoldMs, kDefaultPeakHoldMs, 0, kMaxPeakHoldMs) / 1000.0;
    s.peakHoldForever = getConfigBool(kKeyHoldForever, kDefaultHoldForever);
    s.truePeak = getConfigBool(kKeyTruePeak, kDefaultTruePeak);
    s.needle = (NeedleBallistics)getConfigIntClamped(kKeyNeedle, kDefaultNeedle, 0, kNeedleBallisticsCount - 1);
    s.referenceDbfs = getConfigIntClamped(kKeyReferenceDb, kDefaultReferenceDb, kMinReferenceDb, kMaxReferenceDb);
    return s;
}

inline DisplaySettings loadDisplaySettings(bool dark) {
    DisplaySettings d;
    d.style = (MeterStyle)getConfigIntClamped(kKeyStyle, kDefaultStyle, 0, 1);
    d.orientation = (Orientation)getConfigIntClamped(kKeyOrientation, kDefaultOrientation, 0, 2);
    d.barMode = (BarMode)getConfigIntClamped(kKeyBarMode, kDefaultBarMode, 0, 2);
    d.scale = (ScaleType)getConfigIntClamped(kKeyScale, kDefaultScale, 0, 3);
    d.spacing = (ScaleSpacing)getConfigIntClamped(kKeySpacing, kDefaultSpacing, 0, 1);
    d.floorDb = getConfigIntClamped(kKeyFloorDb, kDefaultFloorDb, -120, -24);
    d.segments = getConfigBool(kKeySegments, kDefaultSegments);
    d.showReadouts = getConfigBool(kKeyShowReadouts, kDefaultShowReadouts);
    d.showLoudness = getConfigBool(kKeyShowLoudness, kDefaultShowLoudness);
    d.showStereo = getConfigBool(kKeyShowStereo, kDefaultShowStereo);
    d.truePeak = getConfigBool(kKeyTruePeak, kDefaultTruePeak);
    d.loudnessTarget = getConfigIntClamped(kKeyTargetLufs, kDefaultTargetLufs, -40, 0);
    d.warnDb = getConfigIntClamped(kKeyWarnDb, kDefaultWarnDb, kMinZoneDb, 0);
    d.overDb = std::max(d.warnDb, (double)getConfigIntClamped(kKeyOverDb, kDefaultOverDb, kMinZoneDb, 0));
    d.face = (FaceStyle)getConfigIntClamped(kKeyFace, kDefaultFace, 0, 2);
    d.needleLayout = (NeedleLayout)getConfigIntClamped(kKeyNeedleLayout, kDefaultNeedleLayout, 0, 2);
    d.needle = (NeedleBallistics)getConfigIntClamped(kKeyNeedle, kDefaultNeedle, 0, kNeedleBallisticsCount - 1);
    d.referenceDbfs = getConfigIntClamped(kKeyReferenceDb, kDefaultReferenceDb, kMinReferenceDb, kMaxReferenceDb);
    d.peakLed = getConfigBool(kKeyPeakLed, kDefaultPeakLed);
    d.peakLedDbfs = getConfigIntClamped(kKeyPeakLedDb, kDefaultPeakLedDb, kMinPeakLedDb, 0);

    Palette &p = d.palette;
    p.dark = dark;
    p.background = getColor(0, dark);
    p.text = getColor(1, dark);
    p.safe = getColor(2, dark);
    p.warn = getColor(3, dark);
    p.over = getColor(4, dark);
    p.loudness = getColor(5, dark);
    if (getConfigBool(kKeyGlass, kDefaultGlass)) p.background = 0;   // let the blur show through
    return d;
}

} // namespace levelmeter_config
