//
//  SpectrumConfig.h
//  foo_jl_spectrum_mac
//
//  Configuration GUIDs, enums, defaults, and fb2k::configStore accessors.
//  Config is persisted via fb2k::configStore (cfg_var does not persist on macOS v2).
//

#pragma once

#include "../fb2k_sdk.h"
#include <cmath>
#include <algorithm>

namespace spectrum_config {

// Preferences page GUID (shared by page registration and "open preferences" actions)
static const GUID guid_preferences_page = {
    0x2F9A7C41, 0x8B3D, 0x4E62,
    {0xA1, 0x05, 0x9D, 0x77, 0x3C, 0x18, 0x6E, 0x2A}
};

// Bar fill styles
enum BarStyle {
    BarStyleSolid = 0,      // Single color
    BarStyleGradient = 1,   // Vertical gradient (bottom -> top)
    BarStyleSpectrum = 2    // Hue mapped across frequency (low -> high)
};

// Frequency axis mapping
enum FreqScale {
    FreqScaleLog = 0,       // Logarithmic (musically natural)
    FreqScaleLinear = 1,    // Linear
    FreqScaleSoftLog = 2    // log10(1 + f/50): log highs, near-linear lows
};

// Corner of the soft-log scale: below it the axis runs close to linear, so the
// bottom octaves take far less width than on a pure log axis.
constexpr double kSoftLogCornerHz = 50.0;

// Axis position of a frequency in scale units. A frequency's fraction across
// the plot is (pos(f) - pos(min)) / (pos(max) - pos(min)); the analyzer's band
// table and the view's gridlines both go through this so they stay aligned.
inline double freqScalePos(int scale, double hz) {
    switch (scale) {
        case FreqScaleLinear:  return hz;
        case FreqScaleSoftLog: return std::log10(1.0 + hz / kSoftLogCornerHz);
        default:               return std::log10(hz);
    }
}

// Inverse of freqScalePos.
inline double freqScaleHz(int scale, double pos) {
    switch (scale) {
        case FreqScaleLinear:  return pos;
        case FreqScaleSoftLog: return kSoftLogCornerHz * (std::pow(10.0, pos) - 1.0);
        default:               return std::pow(10.0, pos);
    }
}

// How bar levels are smoothed over time
enum SmoothingMode {
    SmoothingAttackDecay = 0,   // Fast attack, slower decay, applied to the dB display value
    SmoothingRms = 1            // Exponential average of power per FFT bin (RTA-style)
};

// How the spectrum is drawn
enum DrawMode {
    DrawModeBars = 0,       // Discrete frequency bars
    DrawModeCurve = 1       // Continuous filled curve across all frequencies
};

// What the curve draw mode shows
enum CurveStyle {
    CurveStyleFilled = 0,        // Line over a gradient-filled area
    CurveStyleLine = 1,          // Line only
    CurveStyleColorBars = 2,     // Full-height stripes, brighter where the band is louder
    CurveStyleLineColorBars = 3  // Line, with the stripes filling the area under it
};

// Overall component orientation
enum Orientation {
    OrientationHorizontal = 0, // Frequency along X, magnitude grows up
    OrientationVertical = 1    // Frequency along Y, magnitude grows sideways
};

// --- Defaults ---
constexpr int      kDefaultBarCount   = 96;      // Number of frequency bars
constexpr int      kBarCountAuto      = 0;       // Bar count follows the view size
constexpr double   kAutoBarPitch      = 2.0;     // Auto: points per bar along the frequency axis
constexpr int      kMaxBarCount       = 2048;
constexpr int      kDefaultFftSize    = 2048;    // FFT window (power of 2)
constexpr int      kDefaultBarStyle   = BarStyleGradient;
constexpr int      kDefaultFreqScale  = FreqScaleSoftLog;
constexpr int      kDefaultDrawMode   = DrawModeCurve;
constexpr int      kDefaultCurveStyle = CurveStyleLineColorBars;
constexpr int      kDefaultColorBarBrightness = 64; // Strength of the loudest color bar, % (10-100)
constexpr int      kDefaultOrientation = OrientationHorizontal;
constexpr int      kDefaultMinHz      = 20;      // Lowest displayed frequency
constexpr int      kDefaultMaxHz      = 20000;   // Highest displayed frequency
constexpr int      kDefaultGapPercent = 12;      // Gap between bars, % of slot width
constexpr int      kDefaultSmoothing  = 82;      // Attack/decay smoothing 0-100 (higher = smoother)
constexpr int      kDefaultSmoothingMode = SmoothingRms;
constexpr int      kDefaultRmsMs      = 125;     // RMS mode: power averaging time constant (ms); 125 = IEC 61672 "Fast"
constexpr int      kMaxRmsMs          = 500;
constexpr int      kDefaultSlopeTenths = 4;      // Spectral slope around 1 kHz, in 0.1 dB/octave
constexpr int      kMaxSlopeTenths    = 60;
constexpr int      kDefaultShadowFallSpeed = 74; // Shadow band fall speed 0-100 (higher = faster)
constexpr int      kDefaultPeakFallDbPerSec = 12; // Peak line steady fall after its hold (dB/s), ~IEC 60268-18 (20 dB in 1.7 s)
constexpr int      kMinPeakFallDbPerSec = 1;
constexpr int      kMaxPeakFallDbPerSec = 60;
constexpr int      kDefaultPeakHoldMs = 1000;    // Peak line hold time before it starts falling (ms)
constexpr int      kDefaultTopDb      = 0;       // Level at the top of the display (dB)
constexpr int      kMinTopDb          = -60;
constexpr int      kMaxTopDb          = 0;
constexpr int      kDefaultRangeDb    = 80;      // dB from the top of the display to the bottom
constexpr int      kRangeDbChoices[]  = { 60, 80, 90, 120 };
constexpr bool     kDefaultPeakHold   = true;    // Show falling peak caps
constexpr bool     kDefaultShowDbGuides = true;  // Show dB scale on the right edge
constexpr bool     kDefaultShowFreqAxis = true;  // Show frequency labels/gridlines
constexpr bool     kDefaultShadowFill = true;    // Slow-decaying dim fill behind bars
constexpr int      kDefaultGridOpacity = 84;     // Grid line opacity 0-100
constexpr int      kDefaultTheme = 1;            // Color preset index (0 = Custom, 1 = Default)
constexpr bool     kDefaultGlassBackground = false;

// The fixed dB window up to 0.3.0, before Top and Range were settings. Only the
// peak fall migration still converts against it.
constexpr float    kDisplayFloorDb = -80.0f;     // mapped to bar height 0
constexpr float    kDisplayCeilDb  = 0.0f;       // mapped to bar height 1

// Default colors (ARGB)
constexpr uint32_t kDefaultBarColorLight = 0xFF2E7DD1;  // Blue
constexpr uint32_t kDefaultBgColorLight  = 0xFFF2F2F2;  // Light gray
constexpr uint32_t kDefaultBarColorDark  = 0xFF4DA3F0;  // Lighter blue
constexpr uint32_t kDefaultBgColorDark   = 0xFF161616;  // Near-black
constexpr uint32_t kDefaultGridColorLight = 0xFF808080; // Neutral gray
constexpr uint32_t kDefaultGridColorDark  = 0xFF909090; // Neutral gray

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix     = "foo_jl_spectrum.";
static const char* const kKeyBarCount       = "bar_count";
static const char* const kKeyFftSize        = "fft_size";
static const char* const kKeyBarStyle       = "bar_style";
static const char* const kKeyFreqScale      = "freq_scale";
static const char* const kKeyDrawMode       = "draw_mode";
static const char* const kKeyCurveStyle     = "curve_style";
static const char* const kKeyColorBarBrightness = "color_bar_brightness";
static const char* const kKeyOrientation    = "orientation";
static const char* const kKeyMinHz          = "min_hz";
static const char* const kKeyMaxHz          = "max_hz";
static const char* const kKeyGapPercent     = "gap_percent";
static const char* const kKeySmoothing      = "smoothing";
static const char* const kKeySmoothingMode  = "smoothing_mode";
static const char* const kKeyRmsMs          = "rms_ms";
static const char* const kKeySlopeTenths    = "slope_tenths";
static const char* const kKeyShadowFallSpeed = "shadow_fall_speed";
static const char* const kKeyPeakFallSpeed   = "peak_fall_speed";  // up to 0.3.0: 0-100 gravity, read only to migrate
static const char* const kKeyPeakFallDbPerSec = "peak_fall_db_s";
static const char* const kKeyPeakHoldMs      = "peak_hold_ms";
static const char* const kKeyPeakHold       = "peak_hold";
static const char* const kKeyTopDb          = "top_db";
static const char* const kKeyRangeDb        = "range_db";
static const char* const kKeyShowDbGuides   = "show_db_guides";
static const char* const kKeyShowFreqAxis   = "show_freq_axis";
static const char* const kKeyShadowFill     = "shadow_fill";
static const char* const kKeyGridOpacity    = "grid_opacity";
static const char* const kKeyGridColorLight = "grid_color_light";
static const char* const kKeyGridColorDark  = "grid_color_dark";
static const char* const kKeyTheme          = "color_theme";
static const char* const kKeyGlassBackground = "glass_background";
static const char* const kKeyBarColorLight  = "bar_color_light";
static const char* const kKeyBgColorLight   = "bg_color_light";
static const char* const kKeyBarColorDark   = "bar_color_dark";
static const char* const kKeyBgColorDark    = "bg_color_dark";

// Notification posted when preferences change so live views can reload.
// Guarded so this header stays includable from pure C++ translation units.
#ifdef __OBJC__
static NSString* const kSettingsChangedNotification = @"SpectrumAnalyzerSettingsChanged";
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

// RMS averaging time in ms. Up to 0.3.0 RMS mode had no key of its own and read
// "smoothing" at 2 ms per step; a user who picked RMS there keeps that time
// until they move the slider, everyone else starts at the default.
inline int getRmsMs() {
    int64_t ms = getConfigInt(kKeyRmsMs, -1);
    if (ms < 0) {
        ms = getConfigInt(kKeySmoothingMode, -1) == SmoothingRms
            ? getConfigInt(kKeySmoothing, 60) * 2   // 60 was the 0.3.0 default
            : kDefaultRmsMs;
    }
    return (int)std::max<int64_t>(0, std::min<int64_t>(ms, kMaxRmsMs));
}

// Peak line fall rate in dB/s. Up to 0.3.0 the peak fell with accelerating
// "gravity" set by a 0-100 speed; a stored speed converts to the steady rate
// that covers the same first 20 dB in the same time.
inline int getPeakFallDbPerSec() {
    int64_t rate = getConfigInt(kKeyPeakFallDbPerSec, -1);
    if (rate < 0) {
        const int64_t speed = getConfigInt(kKeyPeakFallSpeed, -1);
        if (speed >= 0) {
            const double range = kDisplayCeilDb - kDisplayFloorDb;
            const double gravityDb = (0.0001 + speed / 100.0 * 0.0027) * range;  // dB per 1/60 s frame^2
            const double frames = std::sqrt(2.0 * 20.0 / gravityDb);
            rate = std::lround(20.0 * 60.0 / frames);
        } else {
            rate = kDefaultPeakFallDbPerSec;
        }
    }
    return (int)std::max<int64_t>(kMinPeakFallDbPerSec, std::min<int64_t>(rate, kMaxPeakFallDbPerSec));
}

// Display window: the level at the top and the dB span down to the bottom.
// Shared by the analyzer (scaling) and the view (dB guides) so they line up.
inline int getTopDb() {
    return (int)std::max<int64_t>(kMinTopDb, std::min<int64_t>(getConfigInt(kKeyTopDb, kDefaultTopDb), kMaxTopDb));
}

inline int getRangeDb() {
    const int64_t range = getConfigInt(kKeyRangeDb, kDefaultRangeDb);
    for (int choice : kRangeDbChoices) {
        if (range == choice) return choice;
    }
    return kDefaultRangeDb;
}

} // namespace spectrum_config
