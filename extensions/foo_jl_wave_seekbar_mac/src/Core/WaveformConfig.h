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

// Preferences page GUID (shared by page registration and "open preferences" actions)
static const GUID guid_preferences_page = {
    0xABCD1234, 0x5678, 0x9ABC,
    {0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC}
};

// Waveform styles
// Stored under waveform_style. 0-2 are the original styles with their
// original values, so a style chosen before the redesign carries over.
enum Style {
    StyleSolid = 0,     // Classic: theme colour fading from the centre out in gradient bands
    StyleHeatMap = 1,   // Classic: colour per column by peak, blue -> green -> yellow -> red
    StyleRainbow = 2,   // Classic: hue runs through the rainbow across the track
    StyleLayered = 3,   // peak envelope around a loudness body, dBFS axis
    StyleTwoTone = 4,   // Simple: split L/R lanes, linear, flat peak and RMS core
    StyleGlow = 5,      // Simple: peaks fade to the tips, hot RMS core
    StyleHeat = 6,      // Simple: colour by amplitude, deep -> accent -> hot
    StyleCount
};

// Channels shown, stored under display_mode with the original values
enum ChannelMode {
    ChannelsStereo = 0, // L and R in their own lanes
    ChannelsMono = 1,   // mixed to one
    ChannelsSplit = 2,  // L up, R down around one centre line
    ChannelModeCount
};

// When the loudness summary badge shows
enum SummaryMode {
    SummaryOff = 0,
    SummaryOnHover = 1,
    SummaryAlways = 2
};

// How strongly Layered's body follows the spectral balance
enum BodyTint {
    BodyTintOff = 0,
    BodyTintSubtle = 1,
    BodyTintStrong = 2
};
constexpr float kBodyTintStrength[] = { 0.0f, 0.5f, 1.0f };

// Where the hover readout sits
enum ReadoutPosition {
    ReadoutFollowsMouse = 0,
    ReadoutTopRight = 1,
    ReadoutBottomRight = 2      // above the loudness summary when that shows
};

// Default values
constexpr int kDefaultStyle = StyleTwoTone;
constexpr int kDefaultReadoutPosition = ReadoutFollowsMouse;
constexpr int kDefaultBodyTint = BodyTintOff;
constexpr int kDefaultGradientBands = 8;        // Classic Solid; choices in GradientBandTable.h
constexpr bool kDefaultHoverReadout = true;
constexpr int kDefaultSummaryMode = SummaryOnHover;
constexpr bool kDefaultClipMarkers = true;
constexpr int kDefaultClipMarkerOpacity = 67;  // percent
constexpr int kMinClipMarkerOpacity = 20;
constexpr int kMaxClipMarkerOpacity = 100;
constexpr int kDefaultTextSize = 14;            // overlay and scale text, pt
constexpr int kTextSizes[] = { 10, 12, 14, 16 };
constexpr bool kDefaultTimeRuler = false;
constexpr bool kDefaultLevelScale = true;
constexpr int kDefaultChannelMode = ChannelsStereo;
// Played part: dimmed by an overlay of the background, shaped at the cursor
enum CursorEffect {
    CursorEffectNone = 0,      // Sharp transition, no effect
    CursorEffectGradient = 1,  // Fade gradient at edge
    CursorEffectGlow = 2,      // Pulsing halo/bloom
    CursorEffectScanline = 3,  // Multiple thin vertical lines
    CursorEffectPulse = 4,     // Breathing played area
    CursorEffectTrail = 5,     // Motion blur trail behind cursor
    CursorEffectShimmer = 6,   // Oscillating brightness bands
    CursorEffectCount
};
constexpr bool kDefaultShadePlayedPortion = true;
constexpr int kDefaultPlayedDimming = 25;       // percent: 0 = as bright as the rest
constexpr int kDefaultCursorEffect = CursorEffectNone;
constexpr bool kDefaultBpmSync = false;         // sync animated cursor effects to the track's BPM
constexpr bool kDefaultCursorTime = false;       // elapsed time chip beside the cursor
constexpr bool kDefaultGlassBackground = false; // Opaque background by default
constexpr int kDefaultCacheSizeMB = 2048;
constexpr int kDefaultCacheRetentionDays = 180;

// Default colors (ARGB): the P4 white theme
constexpr uint32_t kDefaultWaveColorLight = 0xFF3C434B;
constexpr uint32_t kDefaultBgColorLight = 0xFFF4F5F6;

constexpr uint32_t kDefaultWaveColorDark = 0xFFE6EDF2;
constexpr uint32_t kDefaultBgColorDark = 0xFF0F1113;

} // namespace waveform_config

// Note: Configuration is now stored via fb2k::configStore API
// See ConfigHelper.h for access functions
