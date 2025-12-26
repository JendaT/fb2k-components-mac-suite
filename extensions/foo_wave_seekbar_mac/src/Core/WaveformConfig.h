//
//  WaveformConfig.h
//  foo_wave_seekbar_mac
//
//  Configuration variables for the waveform seekbar
//

#pragma once

#include "../fb2k_sdk.h"

namespace waveform_config {

// Configuration GUIDs
static const GUID guid_cfg_display_mode = {
    0x1A2B3C4D, 0x5E6F, 0x7A8B,
    {0x9C, 0x0D, 0x1E, 0x2F, 0x3A, 0x4B, 0x5C, 0x6D}
};

static const GUID guid_cfg_shade_played = {
    0x2B3C4D5E, 0x6F7A, 0x8B9C,
    {0x0D, 0x1E, 0x2F, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E}
};

static const GUID guid_cfg_flip_display = {
    0x3C4D5E6F, 0x7A8B, 0x9C0D,
    {0x1E, 0x2F, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F}
};

static const GUID guid_cfg_cache_size_mb = {
    0x4D5E6F7A, 0x8B9C, 0x0D1E,
    {0x2F, 0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90}
};

static const GUID guid_cfg_cache_retention_days = {
    0x5E6F7A8B, 0x9C0D, 0x1E2F,
    {0x3A, 0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90, 0xA1}
};

// Color configuration GUIDs (light mode)
static const GUID guid_cfg_wave_color_light = {
    0x6F7A8B9C, 0x0D1E, 0x2F3A,
    {0x4B, 0x5C, 0x6D, 0x7E, 0x8F, 0x90, 0xA1, 0xB2}
};

static const GUID guid_cfg_played_color_light = {
    0x7A8B9C0D, 0x1E2F, 0x3A4B,
    {0x5C, 0x6D, 0x7E, 0x8F, 0x90, 0xA1, 0xB2, 0xC3}
};

static const GUID guid_cfg_bg_color_light = {
    0x8B9C0D1E, 0x2F3A, 0x4B5C,
    {0x6D, 0x7E, 0x8F, 0x90, 0xA1, 0xB2, 0xC3, 0xD4}
};

// Color configuration GUIDs (dark mode)
static const GUID guid_cfg_wave_color_dark = {
    0x9C0D1E2F, 0x3A4B, 0x5C6D,
    {0x7E, 0x8F, 0x90, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5}
};

static const GUID guid_cfg_played_color_dark = {
    0x0D1E2F3A, 0x4B5C, 0x6D7E,
    {0x8F, 0x90, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6}
};

static const GUID guid_cfg_bg_color_dark = {
    0x1E2F3A4B, 0x5C6D, 0x7E8F,
    {0x90, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07}
};

// Display modes
enum DisplayMode {
    DisplayModeStereo = 0,
    DisplayModeMono = 1
};

// Cursor effects at playback position
enum CursorEffect {
    CursorEffectNone = 0,      // Sharp transition, no effect
    CursorEffectGradient = 1,  // Fade gradient at edge
    CursorEffectGlow = 2,      // Pulsing halo/bloom
    CursorEffectScanline = 3,  // Multiple thin vertical lines
    CursorEffectPulse = 4,     // Breathing cursor line
    CursorEffectTrail = 5,     // Motion blur trail behind cursor
    CursorEffectShimmer = 6    // Oscillating brightness bands
};

// Waveform rendering styles
enum WaveformStyle {
    WaveformStyleSolid = 0,    // Single color (uses waveform color setting)
    WaveformStyleHeatMap = 1,  // Amplitude mapped to color gradient (blue→green→yellow→red)
    WaveformStyleRainbow = 2   // Position-based rainbow gradient across track
};

// Default values
constexpr int kDefaultDisplayMode = DisplayModeStereo;
constexpr bool kDefaultShadePlayedPortion = true;
constexpr int kDefaultPlayedDimming = 50;  // 0-100 percent opacity for played portion dimming
constexpr int kDefaultCursorEffect = CursorEffectGradient;  // Default to gradient (current behavior)
constexpr int kDefaultWaveformStyle = WaveformStyleSolid;   // Default to solid color
constexpr int kDefaultGradientBands = 8;                    // Number of gradient bands for solid style (2-32)
constexpr bool kDefaultBpmSync = false;                     // Sync cursor animations to track BPM
constexpr int kDefaultCacheSizeMB = 2048;
constexpr int kDefaultCacheRetentionDays = 180;

// Default colors (ARGB format)
constexpr uint32_t kDefaultWaveColorLight = 0xFF3380CC;    // Blue
constexpr uint32_t kDefaultBgColorLight = 0xFFF2F2F2;      // Light gray

constexpr uint32_t kDefaultWaveColorDark = 0xFF4D99E6;     // Lighter blue
constexpr uint32_t kDefaultBgColorDark = 0xFF1A1A1A;       // Dark gray

// Waveform constants
constexpr size_t kWaveformBucketCount = 2048;
constexpr int kDefaultScanResolution = 200;  // Peaks per second during scan

} // namespace waveform_config

// Note: Configuration is now stored via fb2k::configStore API
// See ConfigHelper.h for access functions
