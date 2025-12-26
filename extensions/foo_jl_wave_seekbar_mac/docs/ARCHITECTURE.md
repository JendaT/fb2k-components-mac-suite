# foo_wave_seekbar_mac - Architecture Documentation

## Overview

foo_wave_seekbar_mac is a foobar2000 macOS component that displays a complete audio waveform as an interactive seekbar. It scans audio files to extract peak data, caches results for fast loading, and renders the waveform with playback position indication.

This document covers the technical architecture, data structures, and implementation details.

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Data Model](#2-data-model)
3. [Audio Scanning](#3-audio-scanning)
4. [Cache System](#4-cache-system)
5. [Rendering](#5-rendering)
6. [Playback Integration](#6-playback-integration)
7. [Configuration](#7-configuration)
8. [Preferences UI](#8-preferences-ui)
9. [Threading Model](#9-threading-model)
10. [File Format Reference](#10-file-format-reference)
11. [Error Handling](#11-error-handling)
12. [Subsong Support](#12-subsong-support)

---

## 1. System Architecture

### 1.1 Component Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     foo_wave_seekbar_mac                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────────┐   │
│  │  UI Layer   │    │ Core Layer  │    │ Integration Layer │   │
│  │             │    │             │    │                   │   │
│  │ Seekbar     │◄──►│ Waveform    │◄──►│ play_callback     │   │
│  │ View        │    │ Service     │    │                   │   │
│  │             │    │             │    │ ui_element_mac    │   │
│  │ Preferences │    │ Scanner     │    │                   │   │
│  │ Controller  │    │             │    │ preferences_page  │   │
│  │             │    │ Cache       │    │                   │   │
│  └─────────────┘    └─────────────┘    └──────────────────┘   │
│         │                  │                    │               │
│         ▼                  ▼                    ▼               │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────────┐   │
│  │   Cocoa     │    │   SQLite    │    │   foobar2000     │   │
│  │  (AppKit)   │    │  Database   │    │      SDK         │   │
│  └─────────────┘    └─────────────┘    └──────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 Layer Responsibilities

| Layer | Purpose | Dependencies |
|-------|---------|--------------|
| **UI** | Rendering, user interaction | Cocoa, Core Layer |
| **Core** | Business logic, data processing | SQLite, zlib, Accelerate |
| **Integration** | SDK registration, callbacks | foobar2000 SDK |

### 1.3 Data Flow

```
Track Change → Scanner Request → Decode Audio → Extract Peaks
                                                      │
                                                      ▼
UI Update ← Notify View ← Cache Store ← Compress Data
    │
    ▼
Playback Position → Update Display → Render Waveform
    │
    ▼
User Click → Convert to Time → Seek Request → playback_control
```

---

## 2. Data Model

### 2.1 WaveformData Structure

The core data structure stores audio peaks at a fixed resolution of 2048 buckets per track, regardless of track duration.

```cpp
// WaveformData.h
#include <vector>
#include <cstdint>
#include <string>

struct WaveformData {
    static const size_t BUCKET_COUNT = 2048;

    // Per-channel peak data (supports up to 2 channels)
    std::vector<float> min[2];   // Minimum sample value per bucket [-1.0, 0.0]
    std::vector<float> max[2];   // Maximum sample value per bucket [0.0, 1.0]
    std::vector<float> rms[2];   // RMS energy per bucket [0.0, 1.0]

    uint32_t channelCount;       // 1 = mono, 2 = stereo
    uint32_t sampleRate;         // Original sample rate
    double duration;             // Track duration in seconds

    // Serialization
    void serialize(std::vector<uint8_t>& out) const;
    bool deserialize(const uint8_t* data, size_t size);

    // Compression
    std::vector<uint8_t> compress() const;
    static WaveformData decompress(const uint8_t* data, size_t size);

    // Utility
    bool isValid() const;
    size_t memorySize() const;
};
```

### 2.2 Storage Format

Each bucket stores 3 floats per channel:
- **min**: Lowest sample value in bucket range (negative for waveform bottom)
- **max**: Highest sample value in bucket range (positive for waveform top)
- **rms**: Root-mean-square energy (used for fill intensity)

Memory layout per channel:
```
[min0, min1, min2, ... min2047] - 2048 floats (8KB)
[max0, max1, max2, ... max2047] - 2048 floats (8KB)
[rms0, rms1, rms2, ... rms2047] - 2048 floats (8KB)
```

Total uncompressed: ~48KB for stereo, ~24KB for mono.

### 2.3 Why 2048 Buckets?

- **Sufficient resolution**: 2048 points covers most display widths (1920px, 2560px, etc.)
- **Fixed memory**: Predictable memory usage regardless of track length
- **Fast lookup**: Direct array indexing for any position
- **Proven**: Same resolution used by Windows foo_wave_seekbar

### 2.4 Sample Index Limits

```cpp
// Maximum supported track length:
// - 24 hour track @ 192kHz = 24 * 3600 * 192000 = ~16.5 billion samples
// - uint64_t max = ~18.4 quintillion
// - Safe for any practical audio file

// sampleIndex uses uint64_t which handles:
// - Up to 2.6 million hours at 192kHz
// - No overflow risk for audio files
```

---

## 3. Audio Scanning

### 3.1 Scanner Architecture

```cpp
// WaveformScanner.h
#include <atomic>
#include <functional>
#include <dispatch/dispatch.h>

class WaveformScanner {
public:
    using CompletionCallback = std::function<void(WaveformData)>;
    using ProgressCallback = std::function<void(double progress)>;
    using ErrorCallback = std::function<void(const std::string& error)>;

    void scanAsync(const playable_location& location,
                   CompletionCallback onComplete,
                   ErrorCallback onError = nullptr,
                   ProgressCallback onProgress = nullptr);

    void cancel();
    bool isScanning() const;

private:
    void scanWorker(playable_location location,
                   CompletionCallback onComplete,
                   ErrorCallback onError,
                   ProgressCallback onProgress);

    WaveformData extractPeaks(input_helper& decoder, abort_callback& aborter);
    WaveformData extractPeaksOptimized(input_helper& decoder, abort_callback& aborter);

    // Proper abort callback - NOT abort_callback_dummy
    abort_callback_impl m_aborter;
    std::atomic<bool> m_scanning{false};
    dispatch_queue_t m_scanQueue;
};
```

### 3.2 Cancellation Support

**CRITICAL**: Use a real `abort_callback_impl`, not `abort_callback_dummy`:

```cpp
void WaveformScanner::cancel() {
    m_aborter.set();  // Signal abort to decoder
}

void WaveformScanner::scanWorker(playable_location location, ...) {
    m_aborter.reset();  // Clear any previous abort signal
    m_scanning = true;

    try {
        input_helper decoder;

        // Pass real aborter - allows cancellation during decode
        decoder.open(service_ptr_t<file>(), location, 0, m_aborter);

        auto result = extractPeaksOptimized(decoder, m_aborter);

        if (!m_aborter.is_aborting()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                onComplete(result);
            });
        }
    }
    catch (const exception_aborted&) {
        // Normal cancellation - clean exit
    }
    catch (const exception_io_timeout&) {
        // Network file timeout - see Section 11
        if (onError) onError("Network timeout");
    }
    catch (const pfc::exception& e) {
        if (onError) onError(e.what());
    }

    m_scanning = false;
}
```

### 3.3 Peak Extraction with SIMD Optimization

Using Apple's Accelerate framework for 3-5x faster scanning:

```cpp
#include <Accelerate/Accelerate.h>

WaveformData WaveformScanner::extractPeaksOptimized(input_helper& decoder,
                                                     abort_callback& aborter) {
    WaveformData result;

    file_info_impl info;
    decoder.get_info(0, info, aborter);

    double duration = info.get_length();
    uint32_t sampleRate = info.info_get_int("samplerate");
    uint32_t channels = info.info_get_int("channels");

    result.channelCount = std::min(channels, 2u);
    result.sampleRate = sampleRate;
    result.duration = duration;

    // Initialize buckets
    for (uint32_t ch = 0; ch < result.channelCount; ch++) {
        result.min[ch].resize(WaveformData::BUCKET_COUNT, 0.0f);
        result.max[ch].resize(WaveformData::BUCKET_COUNT, 0.0f);
        result.rms[ch].resize(WaveformData::BUCKET_COUNT, 0.0f);
    }

    uint64_t totalSamples = static_cast<uint64_t>(duration * sampleRate);
    double samplesPerBucket = static_cast<double>(totalSamples) /
                              WaveformData::BUCKET_COUNT;

    // Per-bucket accumulators (allocated once, fixed size)
    std::vector<float> bucketMin[2], bucketMax[2];
    std::vector<double> bucketRmsSum[2];
    std::vector<uint64_t> bucketSampleCount[2];

    for (uint32_t ch = 0; ch < result.channelCount; ch++) {
        bucketMin[ch].resize(WaveformData::BUCKET_COUNT, 1.0f);
        bucketMax[ch].resize(WaveformData::BUCKET_COUNT, -1.0f);
        bucketRmsSum[ch].resize(WaveformData::BUCKET_COUNT, 0.0);
        bucketSampleCount[ch].resize(WaveformData::BUCKET_COUNT, 0);
    }

    // Temporary buffers for deinterleaving
    std::vector<float> channelBuffer(8192);

    audio_chunk_impl chunk;
    uint64_t sampleIndex = 0;

    while (decoder.run(chunk, aborter)) {
        // Check abort each chunk for responsiveness
        if (aborter.is_aborting()) break;

        const audio_sample* data = chunk.get_data();
        size_t sampleCount = chunk.get_sample_count();
        uint32_t chunkChannels = chunk.get_channel_count();

        for (uint32_t ch = 0; ch < result.channelCount; ch++) {
            // Deinterleave channel data
            if (channelBuffer.size() < sampleCount) {
                channelBuffer.resize(sampleCount);
            }

            for (size_t i = 0; i < sampleCount; i++) {
                channelBuffer[i] = (ch < chunkChannels) ?
                    data[i * chunkChannels + ch] :
                    data[i * chunkChannels];
            }

            // Process in bucket-sized chunks using vDSP
            size_t processed = 0;
            while (processed < sampleCount) {
                size_t bucket = static_cast<size_t>((sampleIndex + processed) / samplesPerBucket);
                if (bucket >= WaveformData::BUCKET_COUNT)
                    bucket = WaveformData::BUCKET_COUNT - 1;

                // Find how many samples belong to this bucket
                size_t bucketEnd = static_cast<size_t>((bucket + 1) * samplesPerBucket);
                size_t remaining = sampleCount - processed;
                size_t countInBucket = std::min(remaining,
                    bucketEnd - (sampleIndex + processed));

                if (countInBucket > 0) {
                    float* bufPtr = channelBuffer.data() + processed;

                    // vDSP for min/max
                    float minVal, maxVal;
                    vDSP_minv(bufPtr, 1, &minVal, countInBucket);
                    vDSP_maxv(bufPtr, 1, &maxVal, countInBucket);

                    bucketMin[ch][bucket] = std::min(bucketMin[ch][bucket], minVal);
                    bucketMax[ch][bucket] = std::max(bucketMax[ch][bucket], maxVal);

                    // vDSP for sum of squares (RMS)
                    float sumSquares;
                    vDSP_svesq(bufPtr, 1, &sumSquares, countInBucket);
                    bucketRmsSum[ch][bucket] += sumSquares;
                    bucketSampleCount[ch][bucket] += countInBucket;
                }

                processed += countInBucket;
            }
        }

        sampleIndex += sampleCount;
    }

    // Finalize RMS
    for (uint32_t ch = 0; ch < result.channelCount; ch++) {
        for (size_t b = 0; b < WaveformData::BUCKET_COUNT; b++) {
            result.min[ch][b] = bucketMin[ch][b];
            result.max[ch][b] = bucketMax[ch][b];

            if (bucketSampleCount[ch][b] > 0) {
                result.rms[ch][b] = std::sqrt(
                    bucketRmsSum[ch][b] / bucketSampleCount[ch][b]
                );
            }
        }
    }

    return result;
}
```

### 3.4 Scan Performance

**Note**: These are estimates. Actual performance varies with codec, file location, and hardware. Verify empirically on target hardware.

| Track Duration | Expected Scan Time (Apple Silicon) | Notes |
|----------------|-----------------------------------|-------|
| 3 min (FLAC 44.1kHz) | ~0.3-0.5 sec | With vDSP optimization |
| 10 min (FLAC 44.1kHz) | ~0.8-1.5 sec | |
| 60 min (FLAC 44.1kHz) | ~4-8 sec | May be longer for 96kHz/24-bit |
| 3 min (MP3 320kbps) | ~0.2-0.4 sec | Decode faster than FLAC |

Performance depends on:
- Codec complexity (FLAC decode is CPU-intensive)
- Sample rate and bit depth
- Storage speed (SSD vs HDD vs network)
- CPU (Apple Silicon ~2x faster than Intel for this workload)

---

## 4. Cache System

### 4.1 SQLite Configuration

**CRITICAL**: Configure SQLite for thread safety and concurrent access:

```sql
-- Database: ~/Library/Application Support/foobar2000/waveform_cache.db

-- Enable WAL mode for concurrent read/write
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS waveforms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cache_key TEXT NOT NULL UNIQUE,  -- Hash-based key
    path TEXT NOT NULL,              -- Original path for debugging
    subsong INTEGER DEFAULT 0,
    file_size INTEGER,
    file_time INTEGER,
    channels INTEGER,
    sample_rate INTEGER,
    duration REAL,
    data BLOB,
    compression INTEGER DEFAULT 1,
    created_at INTEGER,
    accessed_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_cache_key ON waveforms(cache_key);
CREATE INDEX IF NOT EXISTS idx_accessed ON waveforms(accessed_at);

-- Metadata entries
INSERT OR REPLACE INTO metadata VALUES ('version', '2');
INSERT OR REPLACE INTO metadata VALUES ('created', strftime('%s', 'now'));
```

### 4.2 Database Initialization

```cpp
void WaveformCache::openDatabase() {
    std::string path = get_cache_path();

    // Open with FULLMUTEX for serialized thread safety
    int rc = sqlite3_open_v2(
        path.c_str(),
        &m_db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        nullptr
    );

    if (rc != SQLITE_OK) {
        throw std::runtime_error("Failed to open cache database");
    }

    // Enable WAL mode
    sqlite3_exec(m_db, "PRAGMA journal_mode = WAL", nullptr, nullptr, nullptr);
    sqlite3_exec(m_db, "PRAGMA synchronous = NORMAL", nullptr, nullptr, nullptr);

    // Create schema
    migrateSchema();
}
```

### 4.3 Cache Key Generation

**Fixed**: Use null separators and hashing to avoid delimiter collision:

```cpp
#include <CommonCrypto/CommonDigest.h>

std::string WaveformCache::generateKey(const playable_location& loc) {
    t_filestats stats;
    try {
        auto file = filesystem::g_open(loc.get_path(),
                                       filesystem::open_mode_read,
                                       abort_callback_dummy());
        stats = file->get_stats(abort_callback_dummy());
    } catch (...) {
        return "";
    }

    // Build canonical key with null separators (can't appear in paths)
    std::string canonical;
    canonical += loc.get_path();
    canonical += '\0';
    canonical += std::to_string(loc.get_subsong());
    canonical += '\0';
    canonical += std::to_string(stats.m_size);
    canonical += '\0';
    canonical += std::to_string(stats.m_timestamp);  // Platform-specific timestamp

    // SHA-256 hash for fixed-length key
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(canonical.data(), static_cast<CC_LONG>(canonical.size()), hash);

    // Convert to hex string
    std::string result;
    result.reserve(CC_SHA256_DIGEST_LENGTH * 2);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        char buf[3];
        snprintf(buf, sizeof(buf), "%02x", hash[i]);
        result += buf;
    }

    return result;
}
```

### 4.4 Cache Operations

```cpp
// WaveformCache.h
class WaveformCache {
public:
    static WaveformCache& instance();

    // Core operations
    std::optional<WaveformData> get(const playable_location& loc);
    void put(const playable_location& loc, const WaveformData& data);
    void remove(const playable_location& loc);

    // Maintenance
    void evictOldEntries(int maxAgeDays);
    void evictToSize(int64_t maxSizeBytes);
    void clear();

    // Statistics
    int64_t totalSize() const;
    size_t entryCount() const;

private:
    sqlite3* m_db = nullptr;
    std::mutex m_mutex;  // Protects m_db pointer, not SQLite operations

    void openDatabase();
    void migrateSchema();
    void handleCorruption();  // See Section 11
};
```

### 4.5 Compression

Uses zlib with balanced compression level (6 instead of 9 for faster scanning):

```cpp
std::vector<uint8_t> WaveformData::compress() const {
    std::vector<uint8_t> raw;
    serialize(raw);

    uLongf compressedSize = compressBound(raw.size());
    std::vector<uint8_t> compressed(compressedSize + 4);

    // Store original size in first 4 bytes (little-endian)
    uint32_t originalSize = static_cast<uint32_t>(raw.size());
    memcpy(compressed.data(), &originalSize, 4);

    // Use Z_DEFAULT_COMPRESSION (6) - good balance of speed vs size
    // Z_BEST_COMPRESSION (9) is ~2x slower for minimal size improvement
    compress2(compressed.data() + 4, &compressedSize,
              raw.data(), raw.size(), Z_DEFAULT_COMPRESSION);

    compressed.resize(compressedSize + 4);
    return compressed;
}
```

---

## 5. Rendering

### 5.1 View Architecture

```objc
// WaveformSeekbarView.h
@interface WaveformSeekbarView : NSView

// Data
@property (nonatomic, strong) WaveformDataWrapper *waveformData;

// Playback state
@property (nonatomic) double playbackPosition;  // Current position in seconds
@property (nonatomic) double duration;          // Track duration in seconds
@property (nonatomic) BOOL isPlaying;

// Appearance
@property (nonatomic) WaveformDisplayMode displayMode;  // Mono or Stereo
@property (nonatomic, strong) NSColor *waveformColor;
@property (nonatomic, strong) NSColor *playedColor;
@property (nonatomic, strong) NSColor *backgroundColor;

// Interaction
@property (nonatomic) BOOL isDragging;
@property (nonatomic) double previewPosition;

@end
```

### 5.2 Display Modes

```objc
typedef NS_ENUM(NSInteger, WaveformDisplayMode) {
    WaveformDisplayModeStereo = 0,  // L/R channels stacked
    WaveformDisplayModeMono = 1     // Mixed to single waveform
};
```

**Stereo Mode:**
```
┌────────────────────────────────┐
│▃▅▇█▇▅▃▁▃▅▇█▇▅▃   Left Channel │
├────────────────────────────────┤
│▃▅▇█▇▅▃▁▃▅▇█▇▅▃   Right Channel│
└────────────────────────────────┘
```

**Mono Mode:**
```
┌────────────────────────────────┐
│        ▃▅▇█▇▅▃▁                │
│▃▅▇█▇▅▃▁        ▃▅▇█▇▅▃        │
└────────────────────────────────┘
```

### 5.3 Drawing Implementation

```objc
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    NSRect bounds = self.bounds;

    // 1. Background
    [self drawBackground:ctx inRect:bounds];

    if (!self.waveformData) {
        [self drawPlaceholder:ctx inRect:bounds];
        return;
    }

    // 2. Waveform
    if (self.displayMode == WaveformDisplayModeStereo) {
        [self drawStereoWaveform:ctx inRect:bounds];
    } else {
        [self drawMonoWaveform:ctx inRect:bounds];
    }

    // 3. Played portion overlay
    if (self.playbackPosition > 0) {
        [self drawPlayedOverlay:ctx inRect:bounds];
    }

    // 4. Position indicator
    [self drawPositionIndicator:ctx inRect:bounds];

    // 5. Preview position (during drag)
    if (self.isDragging) {
        [self drawPreviewIndicator:ctx inRect:bounds];
    }
}

- (void)drawWaveformChannel:(CGContextRef)ctx
                    inRect:(NSRect)rect
                   channel:(NSInteger)channel
                  inverted:(BOOL)inverted {
    CGFloat width = rect.size.width;
    CGFloat height = rect.size.height;
    CGFloat centerY = inverted ? 0 : height;
    CGFloat direction = inverted ? 1.0 : -1.0;

    const float* minData = self.waveformData.minValues[channel];
    const float* maxData = self.waveformData.maxValues[channel];
    size_t bucketCount = self.waveformData.bucketCount;

    CGContextSetFillColorWithColor(ctx, self.waveformColor.CGColor);

    for (size_t i = 0; i < bucketCount; i++) {
        CGFloat x = (CGFloat)i / bucketCount * width + rect.origin.x;
        CGFloat barWidth = width / bucketCount;

        float minVal = minData[i];
        float maxVal = maxData[i];

        CGFloat y1 = centerY + minVal * height * direction;
        CGFloat y2 = centerY + maxVal * height * direction;

        CGRect barRect = CGRectMake(x, MIN(y1, y2) + rect.origin.y,
                                    barWidth, fabs(y2 - y1));
        CGContextFillRect(ctx, barRect);
    }
}
```

### 5.4 Played Area Overlay

**Fixed**: Added null check for gradient and dynamic fade width:

```objc
// Fade width constant - scaled to view width
static const CGFloat kMinFadeWidth = 10.0;
static const CGFloat kMaxFadeWidth = 30.0;
static const CGFloat kFadeWidthRatio = 0.02;  // 2% of view width

- (void)drawPlayedOverlay:(CGContextRef)ctx inRect:(NSRect)bounds {
    if (self.duration <= 0) return;

    CGFloat playedWidth = (self.playbackPosition / self.duration) * bounds.size.width;

    // Semi-transparent overlay
    NSColor *overlayColor = [self.playedColor colorWithAlphaComponent:0.3];
    CGContextSetFillColorWithColor(ctx, overlayColor.CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, playedWidth, bounds.size.height));

    // Dynamic fade width based on view size
    CGFloat fadeWidth = bounds.size.width * kFadeWidthRatio;
    fadeWidth = MAX(kMinFadeWidth, MIN(fadeWidth, kMaxFadeWidth));

    // Gradient fade at edge
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    CGFloat components[] = {
        self.playedColor.redComponent,
        self.playedColor.greenComponent,
        self.playedColor.blueComponent,
        0.3,
        self.playedColor.redComponent,
        self.playedColor.greenComponent,
        self.playedColor.blueComponent,
        0.0
    };

    CGGradientRef gradient = CGGradientCreateWithColorComponents(
        colorSpace, components, NULL, 2);

    if (gradient) {
        CGContextDrawLinearGradient(ctx, gradient,
            CGPointMake(playedWidth - fadeWidth, 0),
            CGPointMake(playedWidth, 0),
            0);
        CGGradientRelease(gradient);
    }

    CGColorSpaceRelease(colorSpace);
}
```

### 5.5 Retina Support

```objc
- (void)drawRect:(NSRect)dirtyRect {
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;

    // Use scale for pixel-perfect lines
    CGFloat lineWidth = 1.0 / scale;
    CGContextSetLineWidth(ctx, lineWidth);

    // Offset for crisp single-pixel lines
    CGFloat offset = 0.5 / scale;
    // ...
}
```

---

## 6. Playback Integration

### 6.1 Play Callback Implementation

**Fixed**: Added exception handling to all callbacks:

```cpp
// In Main.mm
namespace {
    class waveform_play_callback : public play_callback_static {
    public:
        unsigned get_flags() override {
            return flag_on_playback_new_track |
                   flag_on_playback_stop |
                   flag_on_playback_seek |
                   flag_on_playback_time |
                   flag_on_playback_pause;
        }

        void on_playback_new_track(metadb_handle_ptr track) override {
            try {
                WaveformService::instance().requestWaveform(track);
            } catch (const std::exception& e) {
                console::formatter() << "WaveSeek: " << e.what();
            } catch (...) {}
        }

        void on_playback_stop(play_callback::t_stop_reason reason) override {
            try {
                WaveformService::instance().cancelCurrentScan();
                WaveformService::instance().notifyTrackCleared();
            } catch (...) {}
        }

        void on_playback_seek(double time) override {
            try {
                WaveformService::instance().notifyPositionChanged(time);
            } catch (...) {}
        }

        void on_playback_time(double time) override {
            try {
                WaveformService::instance().notifyPositionChanged(time);
            } catch (...) {}
        }

        void on_playback_pause(bool paused) override {
            try {
                WaveformService::instance().notifyPauseStateChanged(paused);
            } catch (...) {}
        }

        void on_playback_starting(play_control::t_track_command, bool) override {}
        void on_playback_edited(metadb_handle_ptr) override {}
        void on_playback_dynamic_info(const file_info&) override {}
        void on_playback_dynamic_info_track(const file_info&) override {}
        void on_volume_change(float) override {}
    };

    FB2K_SERVICE_FACTORY(waveform_play_callback);
}
```

### 6.2 Waveform Service

**Fixed**: Added retain cycle warning for observers:

```cpp
// WaveformService.h
class WaveformService {
public:
    static WaveformService& instance();

    void requestWaveform(metadb_handle_ptr track);
    void cancelCurrentScan();

    void notifyPositionChanged(double time);
    void notifyTrackCleared();
    void notifyPauseStateChanged(bool paused);

    // Observer pattern for UI updates
    // IMPORTANT: Callbacks MUST use weak self capture to avoid retain cycles!
    //
    // Example (Objective-C++):
    //   __weak typeof(self) weakSelf = self;
    //   service.addObserver((__bridge void*)self,
    //       [weakSelf](const WaveformData& data) {
    //           [weakSelf handleWaveformReady:data];
    //       },
    //       [weakSelf](double time) {
    //           [weakSelf updatePosition:time];
    //       });
    //
    using WaveformReadyCallback = std::function<void(const WaveformData&)>;
    using PositionCallback = std::function<void(double time)>;

    void addObserver(void* owner,
                    WaveformReadyCallback onReady,
                    PositionCallback onPosition);
    void removeObserver(void* owner);

private:
    WaveformScanner m_scanner;
    WaveformCache& m_cache;

    std::vector<Observer> m_observers;
    std::mutex m_observerMutex;

    metadb_handle_ptr m_currentTrack;
};
```

### 6.3 Seeking

**Fixed**: Added main thread check to avoid deadlock:

```objc
// In WaveformSeekbarView.mm
- (void)seekToPosition:(double)normalizedPosition {
    double seekTime = normalizedPosition * self.duration;
    seekTime = MAX(0, MIN(seekTime, self.duration));

    auto doSeek = [seekTime]() {
        auto pc = playback_control::get();
        if (pc->is_playing() && pc->playback_can_seek()) {
            pc->playback_seek(seekTime);
        }
    };

    // CRITICAL: Check thread to avoid deadlock
    // fb2k::inMainThread blocks if already on main thread
    if ([NSThread isMainThread]) {
        doSeek();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            doSeek();
        });
    }
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
    double normalized = location.x / self.bounds.size.width;

    self.isDragging = YES;
    self.previewPosition = normalized * self.duration;
    [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)event {
    if (self.isDragging) {
        NSPoint location = [self convertPoint:event.locationInWindow fromView:nil];
        double normalized = location.x / self.bounds.size.width;
        [self seekToPosition:normalized];

        self.isDragging = NO;
        [self setNeedsDisplay:YES];
    }
}
```

---

## 7. Configuration

### 7.1 Configuration Variables

```cpp
// WaveformConfig.h
#include "fb2k_sdk.h"

static const GUID guid_waveform_config = {
    0x12345678, 0xabcd, 0xef01,
    { 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01 }
};

namespace waveform_config {
    extern cfg_int cfg_display_mode;
    extern cfg_bool cfg_shade_played;
    extern cfg_bool cfg_flip_display;

    extern cfg_int cfg_wave_color_light;
    extern cfg_int cfg_played_color_light;
    extern cfg_int cfg_bg_color_light;

    extern cfg_int cfg_wave_color_dark;
    extern cfg_int cfg_played_color_dark;
    extern cfg_int cfg_bg_color_dark;

    extern cfg_int cfg_cache_size_mb;
    extern cfg_int cfg_cache_retention_days;

    namespace defaults {
        const int display_mode = 0;
        const bool shade_played = true;
        const bool flip_display = false;

        const int wave_color_light = 0xFF0066CC;
        const int played_color_light = 0x40000000;
        const int bg_color_light = 0xFFFFFFFF;

        const int wave_color_dark = 0xFF66CCFF;
        const int played_color_dark = 0x40FFFFFF;
        const int bg_color_dark = 0xFF1E1E1E;

        const int cache_size_mb = 500;
        const int cache_retention_days = 90;
    }
}
```

---

## 8. Preferences UI

### 8.1 Preferences Layout

```
┌──────────────────────────────────────────────────────────────┐
│  Waveform Seekbar                                            │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Display                                                     │
│  ─────────────────────────────────────────────────────────  │
│  Mode:  [Stereo (L/R)     ▼]                                │
│                                                              │
│  [✓] Shade played portion                                   │
│  [ ] Flip display direction                                 │
│                                                              │
│  Colors (Light Mode)                                         │
│  ─────────────────────────────────────────────────────────  │
│  Waveform:   [■■■■]  Played:   [■■■■]  Background:  [■■■■] │
│                                                              │
│  Colors (Dark Mode)                                          │
│  ─────────────────────────────────────────────────────────  │
│  Waveform:   [■■■■]  Played:   [■■■■]  Background:  [■■■■] │
│                                                              │
│  Cache                                                       │
│  ─────────────────────────────────────────────────────────  │
│  Maximum size:  [500    ] MB                                │
│  Keep entries:  [90     ] days                              │
│                                                              │
│  Current usage: 127 MB (342 tracks)                         │
│  [Clear Cache]                                              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### 8.2 Accessibility Requirements

All UI elements should support:

```objc
// VoiceOver labels for color wells
[self.waveColorLightWell setAccessibilityLabel:@"Waveform color for light mode"];
[self.waveColorDarkWell setAccessibilityLabel:@"Waveform color for dark mode"];

// Keyboard navigation
- (BOOL)acceptsFirstResponder { return YES; }

// Accessibility role for seekbar
- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilitySliderRole;
}

- (NSString *)accessibilityValue {
    return [NSString stringWithFormat:@"%.0f of %.0f seconds",
            self.playbackPosition, self.duration];
}
```

---

## 9. Threading Model

### 9.1 Thread Responsibilities

| Thread | Purpose | Operations |
|--------|---------|------------|
| **Main** | UI, SDK calls | Drawing, seeking, config access |
| **Scan Queue** | Audio decoding | Peak extraction |
| **Cache Queue** | Database I/O | SQLite operations |

### 9.2 GCD Queue Setup

```objc
- (instancetype)init {
    self = [super init];
    if (self) {
        _scanQueue = dispatch_queue_create(
            "com.yourname.waveform.scan",
            DISPATCH_QUEUE_SERIAL
        );
        _cacheQueue = dispatch_queue_create(
            "com.yourname.waveform.cache",
            DISPATCH_QUEUE_SERIAL
        );
    }
    return self;
}
```

### 9.3 Memory Pressure Handling

```objc
- (void)setupMemoryPressureHandler {
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,
        0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_main_queue()
    );

    dispatch_source_set_event_handler(source, ^{
        dispatch_source_memorypressure_flags_t flags =
            dispatch_source_get_data(source);

        if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) {
            // Clear in-memory caches
            [self clearMemoryCache];
            // Cancel pending scans
            [self cancelCurrentScan];
        }
    });

    dispatch_resume(source);
    _memoryPressureSource = source;
}

// Also check low power mode
- (BOOL)shouldPauseScanning {
    if (@available(macOS 12.0, *)) {
        return [[NSProcessInfo processInfo] isLowPowerModeEnabled];
    }
    return NO;
}
```

---

## 10. File Format Reference

### 10.1 Cache Database Location

```
~/Library/Application Support/foobar2000/waveform_cache.db
```

### 10.2 Compressed Data Format

**All multi-byte values are little-endian.**

```
Offset  Size    Description
------  ----    -----------
0       4       Original size (uint32_t, little-endian)
4       N       zlib-compressed data

Uncompressed format:
Offset  Size    Type        Description
------  ----    ----        -----------
0       4       char[4]     Magic "WAVE"
4       4       uint32_t    Version (currently 1)
8       4       uint32_t    Channel count (1 or 2)
12      4       uint32_t    Sample rate
16      8       double      Duration in seconds
24      4       uint32_t    Bucket count (2048)
28      N       float[]     Channel 0 min values (2048 floats)
...     N       float[]     Channel 0 max values (2048 floats)
...     N       float[]     Channel 0 RMS values (2048 floats)
...     N       float[]     Channel 1 min values (if stereo)
...     N       float[]     Channel 1 max values (if stereo)
...     N       float[]     Channel 1 RMS values (if stereo)
```

---

## 11. Error Handling

### 11.1 Error Recovery Strategy

```cpp
class WaveformCache {
public:
    void handleCorruption() {
        // 1. Close current connection
        if (m_db) {
            sqlite3_close(m_db);
            m_db = nullptr;
        }

        // 2. Backup corrupted file
        std::string path = get_cache_path();
        std::string backup = path + ".corrupt." + std::to_string(time(nullptr));
        rename(path.c_str(), backup.c_str());

        console::warning("Waveform cache corrupted, recreating...");

        // 3. Recreate fresh database
        openDatabase();
    }
};

// In scanner
void WaveformScanner::handleDecoderError(const std::exception& e,
                                         ErrorCallback onError) {
    std::string msg = e.what();

    // Classify error
    if (msg.find("timeout") != std::string::npos) {
        msg = "Network timeout - file may be on disconnected share";
    } else if (msg.find("access denied") != std::string::npos) {
        msg = "Access denied - check file permissions";
    } else if (msg.find("unsupported") != std::string::npos) {
        msg = "Unsupported format - no decoder available";
    }

    if (onError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onError(msg);
        });
    }
}
```

### 11.2 Network File Handling

```cpp
void WaveformScanner::scanWorker(...) {
    try {
        // ... scanning code ...
    }
    catch (const exception_io_timeout&) {
        // Network file timed out - don't cache, don't retry automatically
        if (onError) onError("Network timeout");
    }
    catch (const exception_io_denied&) {
        if (onError) onError("Access denied");
    }
    catch (const exception_io&) {
        // General I/O error
        if (onError) onError("I/O error");
    }
}
```

### 11.3 Disk Full Handling

```cpp
void WaveformCache::put(const playable_location& loc, const WaveformData& data) {
    auto compressed = data.compress();

    try {
        // Try to insert
        sqlite3_stmt* stmt = prepareInsert();
        // ... bind parameters ...

        int rc = sqlite3_step(stmt);
        if (rc == SQLITE_FULL) {
            // Disk full - evict old entries and retry
            evictToSize(m_maxSize / 2);

            sqlite3_reset(stmt);
            rc = sqlite3_step(stmt);
        }

        if (rc != SQLITE_DONE) {
            console::warning("Failed to cache waveform");
        }
    }
    catch (...) {
        // Don't let cache failures affect playback
    }
}
```

---

## 12. Subsong Support

### 12.1 Subsong Detection

Some file formats contain multiple tracks (subsongs):
- CUE sheets with embedded audio
- Game music formats (SID, NSF, SPC)
- Multi-track containers

```cpp
void WaveformService::requestWaveform(metadb_handle_ptr track) {
    playable_location_impl loc;
    track->get_location(loc);

    uint32_t subsong = loc.get_subsong();

    // Each subsong is cached separately
    std::string cacheKey = m_cache.generateKey(loc);  // Includes subsong

    // Check cache first
    auto cached = m_cache.get(loc);
    if (cached) {
        notifyWaveformReady(*cached);
        return;
    }

    // Scan this specific subsong
    m_scanner.scanAsync(loc, ...);
}
```

### 12.2 Multi-Subsong Containers

For containers with many subsongs (e.g., SID files with 50+ tunes):

```cpp
// Strategy: On-demand scanning only
// Don't pre-scan all subsongs - wait for user to play each one

// Optional: Batch scan for small containers (< 10 subsongs)
void WaveformService::maybePrefetchSubsongs(metadb_handle_ptr track) {
    file_info_impl info;
    track->get_info(info);

    // Only prefetch if few subsongs and short duration
    int subsongCount = info.info_get_int("subsong_count");
    double totalDuration = info.get_length() * subsongCount;

    if (subsongCount > 0 && subsongCount <= 5 && totalDuration < 600) {
        // Queue background prefetch
    }
}
```

---

## References

- [foobar2000 SDK Documentation](https://www.foobar2000.org/SDK)
- [foo_wave_seekbar (Windows)](https://github.com/zao/foo_wave_seekbar) - Original implementation
- [Apple Core Graphics Documentation](https://developer.apple.com/documentation/coregraphics)
- [Apple Accelerate Framework](https://developer.apple.com/documentation/accelerate)
- [SQLite Documentation](https://www.sqlite.org/docs.html)
