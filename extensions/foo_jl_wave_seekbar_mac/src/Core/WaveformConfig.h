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
enum Style {
    StyleLayered = 0,   // peak envelope around a loudness body, one dBFS axis
    StyleTwoTone = 1,   // Simple: split L/R lanes, linear, flat peak and RMS core
    StyleGlow = 2,      // Simple: peaks fade to the tips, hot RMS core
    StyleHeat = 3,      // Simple: colour by amplitude, deep -> accent -> hot
    StyleCount
};

// Channels shown
enum ChannelMode {
    ChannelsStereo = 0, // L and R apart (Layered: up / down; Simple: two lanes)
    ChannelsMono = 1    // mixed to one
};

// Default values
constexpr int kDefaultStyle = StyleLayered;
constexpr int kDefaultChannelMode = ChannelsStereo;
constexpr int kDefaultPlayedOpacity = 50;       // percent; the part still to play is at 100
constexpr int kMinPlayedOpacity = 20;
constexpr int kMaxPlayedOpacity = 100;
constexpr bool kDefaultCursorTime = true;       // elapsed time chip beside the cursor
constexpr bool kDefaultGlassBackground = false; // Opaque background by default
constexpr int kDefaultCacheSizeMB = 2048;
constexpr int kDefaultCacheRetentionDays = 180;

// Default colors (ARGB): the P7 blue theme, as in Spectrum Analyzer
constexpr uint32_t kDefaultWaveColorLight = 0xFF2D6CC0;
constexpr uint32_t kDefaultBgColorLight = 0xFFF0F4F9;

constexpr uint32_t kDefaultWaveColorDark = 0xFF6FB7FF;
constexpr uint32_t kDefaultBgColorDark = 0xFF0A0E15;

} // namespace waveform_config

// Note: Configuration is now stored via fb2k::configStore API
// See ConfigHelper.h for access functions
