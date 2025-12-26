# foobar2000 macOS - Audio Processing Guide

## Overview

This document covers audio processing in foobar2000 components, including decoding audio files, working with audio chunks, implementing DSP effects, and understanding real-time constraints.

**Target audience**: Developers building decoders, DSP plugins, visualizers, or any component that processes audio data.

## 1. audio_chunk Fundamentals

### 1.1 The audio_chunk Interface

`audio_chunk` is the fundamental container for audio data in foobar2000:

```cpp
#include <SDK/audio_chunk.h>

void process_chunk(audio_chunk& chunk) {
    // Sample data access
    audio_sample* data = chunk.get_data();           // Mutable pointer
    const audio_sample* cdata = chunk.get_data();    // Const pointer

    // Format information
    t_size sample_count = chunk.get_sample_count();  // Samples per channel
    t_size channel_count = chunk.get_channel_count();
    t_uint32 sample_rate = chunk.get_sample_rate();
    unsigned channel_config = chunk.get_channel_config(); // Speaker layout

    // Total data size
    t_size data_size = chunk.get_data_size();  // sample_count * channel_count
}
```

### 1.2 Sample Format

- **Type**: `audio_sample` (typedef for `float`)
- **Range**: `-1.0` to `+1.0` (normalized)
- **Layout**: Interleaved channels

```cpp
// Memory layout for stereo audio:
// [L0, R0, L1, R1, L2, R2, ...]

void read_samples(const audio_chunk& chunk) {
    const audio_sample* data = chunk.get_data();
    t_size samples = chunk.get_sample_count();
    t_size channels = chunk.get_channel_count();

    for (t_size i = 0; i < samples; i++) {
        for (t_size ch = 0; ch < channels; ch++) {
            audio_sample sample = data[i * channels + ch];
            // Process sample...
        }
    }
}
```

### 1.3 Channel Configuration

```cpp
// Standard channel layouts from SDK
audio_chunk::channel_config_mono         // 1 channel: center
audio_chunk::channel_config_stereo       // 2 channels: L, R
audio_chunk::channel_config_5point1      // 6 channels: L, R, C, LFE, SL, SR
audio_chunk::channel_config_7point1      // 8 channels

// Query channel mask
unsigned config = chunk.get_channel_config();
bool has_center = (config & audio_chunk::channel_center) != 0;
bool has_lfe = (config & audio_chunk::channel_lfe) != 0;
```

### 1.4 Creating and Modifying Chunks

```cpp
#include <SDK/audio_chunk.h>

void create_silence(audio_chunk_impl& chunk, t_uint32 sample_rate,
                    t_size sample_count, t_size channels) {
    // Allocate buffer
    chunk.set_data_size(sample_count * channels);
    chunk.set_sample_count(sample_count);
    chunk.set_channels(channels);
    chunk.set_sample_rate(sample_rate);

    // Fill with silence
    audio_sample* data = chunk.get_data();
    memset(data, 0, sample_count * channels * sizeof(audio_sample));
}

void apply_gain(audio_chunk& chunk, float gain) {
    audio_sample* data = chunk.get_data();
    t_size total = chunk.get_data_size();

    for (t_size i = 0; i < total; i++) {
        data[i] *= gain;
        // Clip to valid range
        if (data[i] > 1.0f) data[i] = 1.0f;
        if (data[i] < -1.0f) data[i] = -1.0f;
    }
}
```

## 2. Decoding Audio with input_helper

### 2.1 Basic Decoding Loop

```cpp
#include <helpers/input_helpers.h>

class AudioScanner {
public:
    struct ScanResult {
        double duration;
        t_uint32 sample_rate;
        t_uint32 channels;
        std::vector<float> peak_data;
    };

    ScanResult scan(const playable_location& location, abort_callback& aborter) {
        ScanResult result = {};

        try {
            input_helper decoder;

            // Open for decoding
            decoder.open(service_ptr_t<file>(), location,
                        input_flag_no_seeking, aborter, false, false);

            // Get file info
            file_info_impl info;
            decoder.get_info(0, info, aborter);

            result.duration = info.get_length();
            result.sample_rate = info.info_get_int("samplerate");
            result.channels = info.info_get_int("channels");

            // Decode loop
            audio_chunk_impl chunk;
            while (decoder.run(chunk, aborter)) {
                process_chunk(chunk, result);
            }

            decoder.close();
        }
        catch (const exception_aborted&) {
            // User cancelled - normal exit
            throw;
        }
        catch (const pfc::exception& e) {
            console::formatter() << "Decode error: " << e.what();
        }

        return result;
    }

private:
    void process_chunk(const audio_chunk& chunk, ScanResult& result) {
        // Extract peak data, accumulate statistics, etc.
    }
};
```

### 2.2 Seeking During Decode

```cpp
void decode_section(const playable_location& location,
                   double start_time, double end_time,
                   abort_callback& aborter) {
    input_helper decoder;

    // Open with seeking enabled (default)
    decoder.open(service_ptr_t<file>(), location, 0, aborter);

    // Seek to start position
    decoder.seek(start_time, aborter);

    audio_chunk_impl chunk;
    double current_time = start_time;

    while (decoder.run(chunk, aborter) && current_time < end_time) {
        // Process chunk
        double chunk_duration = (double)chunk.get_sample_count() /
                               chunk.get_sample_rate();
        current_time += chunk_duration;
    }
}
```

## 3. Waveform Generation

### 3.1 Peak Extraction Algorithm

```cpp
#include <Accelerate/Accelerate.h>  // For vDSP on macOS

struct WaveformPeaks {
    std::vector<float> min_peaks;
    std::vector<float> max_peaks;
    std::vector<float> rms_values;
    static const size_t BUCKET_COUNT = 2048;
};

class WaveformGenerator {
public:
    WaveformPeaks generate(const playable_location& location,
                          abort_callback& aborter) {
        WaveformPeaks peaks;
        peaks.min_peaks.resize(WaveformPeaks::BUCKET_COUNT, 0.0f);
        peaks.max_peaks.resize(WaveformPeaks::BUCKET_COUNT, 0.0f);
        peaks.rms_values.resize(WaveformPeaks::BUCKET_COUNT, 0.0f);

        input_helper decoder;
        decoder.open(service_ptr_t<file>(), location, 0, aborter);

        file_info_impl info;
        decoder.get_info(0, info, aborter);

        double duration = info.get_length();
        t_uint32 sample_rate = info.info_get_int("samplerate");
        uint64_t total_samples = static_cast<uint64_t>(duration * sample_rate);
        double samples_per_bucket = static_cast<double>(total_samples) /
                                   WaveformPeaks::BUCKET_COUNT;

        // Accumulators for each bucket
        std::vector<float> bucket_min(WaveformPeaks::BUCKET_COUNT, 1.0f);
        std::vector<float> bucket_max(WaveformPeaks::BUCKET_COUNT, -1.0f);
        std::vector<double> bucket_rms_sum(WaveformPeaks::BUCKET_COUNT, 0.0);
        std::vector<uint64_t> bucket_sample_count(WaveformPeaks::BUCKET_COUNT, 0);

        audio_chunk_impl chunk;
        uint64_t sample_index = 0;

        while (decoder.run(chunk, aborter)) {
            const audio_sample* data = chunk.get_data();
            t_size samples = chunk.get_sample_count();
            t_size channels = chunk.get_channel_count();

            for (t_size i = 0; i < samples; i++) {
                // Determine which bucket this sample belongs to
                size_t bucket = static_cast<size_t>(sample_index / samples_per_bucket);
                if (bucket >= WaveformPeaks::BUCKET_COUNT)
                    bucket = WaveformPeaks::BUCKET_COUNT - 1;

                // Mix all channels to mono for peak detection
                float mixed = 0.0f;
                for (t_size ch = 0; ch < channels; ch++) {
                    mixed += data[i * channels + ch];
                }
                mixed /= channels;

                // Update bucket statistics
                bucket_min[bucket] = std::min(bucket_min[bucket], mixed);
                bucket_max[bucket] = std::max(bucket_max[bucket], mixed);
                bucket_rms_sum[bucket] += mixed * mixed;
                bucket_sample_count[bucket]++;

                sample_index++;
            }
        }

        // Finalize peaks
        for (size_t b = 0; b < WaveformPeaks::BUCKET_COUNT; b++) {
            peaks.min_peaks[b] = bucket_min[b];
            peaks.max_peaks[b] = bucket_max[b];
            if (bucket_sample_count[b] > 0) {
                peaks.rms_values[b] = std::sqrt(
                    bucket_rms_sum[b] / bucket_sample_count[b]
                );
            }
        }

        return peaks;
    }
};
```

### 3.2 Using vDSP for Faster Peak Detection

```cpp
#include <Accelerate/Accelerate.h>

void find_peaks_vdsp(const float* samples, size_t count,
                     float& min_out, float& max_out) {
    vDSP_Length index;

    // Find minimum
    vDSP_minvi(samples, 1, &min_out, &index, count);

    // Find maximum
    vDSP_maxvi(samples, 1, &max_out, &index, count);
}

float calculate_rms_vdsp(const float* samples, size_t count) {
    float sum_of_squares;
    vDSP_svesq(samples, 1, &sum_of_squares, count);
    return std::sqrt(sum_of_squares / count);
}
```

## 4. Real-Time Audio Constraints

### 4.1 What NOT to Do in Audio Callbacks

When processing audio in real-time (DSP effects, visualizers with live input):

```cpp
// FORBIDDEN in audio processing callbacks:

void WRONG_audio_callback(audio_chunk& chunk) {
    // DON'T: Allocate memory
    std::vector<float> buffer(chunk.get_data_size());  // BAD!

    // DON'T: Lock mutexes that UI thread might hold
    std::lock_guard<std::mutex> lock(m_shared_mutex);  // BAD!

    // DON'T: Make file I/O calls
    FILE* f = fopen("debug.log", "a");  // BAD!

    // DON'T: Call Objective-C methods (implicit autorelease pool)
    [myObject doSomething];  // BAD!

    // DON'T: Log to console (synchronized)
    console::info("Processing...");  // BAD!

    // DON'T: Allocate pfc::string
    pfc::string8 msg;  // BAD!
    msg << "Sample count: " << chunk.get_sample_count();
}
```

### 4.2 Correct Real-Time Processing

```cpp
class RealtimeSafeDSP {
    // Pre-allocate all buffers during initialization
    std::vector<float> m_work_buffer;
    std::atomic<float> m_gain{1.0f};  // Lock-free parameter

public:
    void initialize(size_t max_samples) {
        // Do ALL allocation here, not in process()
        m_work_buffer.resize(max_samples * 8);  // Generous size
    }

    void set_gain(float gain) {
        // Lock-free parameter update
        m_gain.store(gain, std::memory_order_relaxed);
    }

    void process(audio_chunk& chunk) {
        // OK: Read atomic without lock
        float gain = m_gain.load(std::memory_order_relaxed);

        // OK: Use pre-allocated buffer
        float* temp = m_work_buffer.data();

        // OK: Direct sample manipulation
        audio_sample* data = chunk.get_data();
        t_size size = chunk.get_data_size();

        for (t_size i = 0; i < size; i++) {
            data[i] *= gain;
        }
    }
};
```

### 4.3 Buffer Deadline

Audio processing must complete within the buffer deadline:

```cpp
// Typical buffer sizes and deadlines:
// Sample rate: 44100 Hz
// Buffer size: 512 samples
// Deadline: 512 / 44100 = 11.6 ms

// At 96000 Hz with 256 samples:
// Deadline: 256 / 96000 = 2.7 ms

// RULE: Keep processing time under 50% of deadline to leave headroom
```

## 5. DSP Effect Implementation

### 5.1 Basic DSP Interface

```cpp
#include <SDK/dsp.h>

class my_dsp : public dsp_impl_base {
public:
    static GUID g_get_guid() {
        static const GUID guid = { /* generate unique GUID */ };
        return guid;
    }

    static void g_get_name(pfc::string_base& out) {
        out = "My DSP Effect";
    }

    static bool g_have_config_popup() { return true; }
    static void g_show_config_popup(const dsp_preset& preset,
                                    HWND parent, dsp_preset_edit_callback& callback) {
        // Show configuration dialog
    }

    void on_init() override {
        // Called when DSP is added to chain
        // Pre-allocate buffers here
    }

    void on_quit() override {
        // Cleanup
    }

    void on_endoftrack(abort_callback& abort) override {
        // Track ended - flush any buffered output
    }

    void on_endofplayback(abort_callback& abort) override {
        // Playback stopped
    }

    bool on_chunk(audio_chunk* chunk, abort_callback& abort) override {
        // Process the audio chunk
        // Return true to keep the chunk, false to drop it

        audio_sample* data = chunk->get_data();
        t_size size = chunk->get_data_size();

        // Apply effect...

        return true;  // Keep the chunk
    }

    void flush() override {
        // Clear internal state (called on seek)
    }

    double get_latency() override {
        // Return processing latency in seconds
        return 0.0;
    }

    bool need_track_change_mark() override {
        return false;
    }
};

static dsp_factory_t<my_dsp> g_my_dsp_factory;
```

### 5.2 DSP with Configuration

```cpp
class my_configurable_dsp : public dsp_impl_base {
    float m_param;

public:
    // Parse configuration from preset
    void on_init() override {
        dsp_preset_impl preset;
        get_config(preset);
        parse_preset(preset);
    }

    void parse_preset(const dsp_preset& preset) {
        // Extract parameters from preset data
        try {
            stream_reader_memblock_ref reader(preset.get_data(),
                                               preset.get_data_size());
            reader.read_lendian_t(m_param, abort_callback_dummy());
        }
        catch (...) {
            m_param = 1.0f;  // Default
        }
    }

    static dsp_preset_impl make_preset(float param) {
        dsp_preset_impl preset;
        preset.set_owner(g_get_guid());

        stream_writer_memblock_ref writer(preset.m_data);
        writer.write_lendian_t(param, abort_callback_dummy());

        return preset;
    }
};
```

## 6. Memory Pooling for Audio

### 6.1 Pre-allocated Buffer Pool

```cpp
class AudioBufferPool {
    static const size_t POOL_SIZE = 8;
    static const size_t BUFFER_SIZE = 8192 * 8;  // ~8 channels, 8K samples

    std::array<std::vector<float>, POOL_SIZE> m_buffers;
    std::array<std::atomic<bool>, POOL_SIZE> m_in_use;

public:
    AudioBufferPool() {
        for (size_t i = 0; i < POOL_SIZE; i++) {
            m_buffers[i].resize(BUFFER_SIZE);
            m_in_use[i].store(false);
        }
    }

    float* acquire() {
        for (size_t i = 0; i < POOL_SIZE; i++) {
            bool expected = false;
            if (m_in_use[i].compare_exchange_strong(expected, true)) {
                return m_buffers[i].data();
            }
        }
        return nullptr;  // Pool exhausted
    }

    void release(float* buffer) {
        for (size_t i = 0; i < POOL_SIZE; i++) {
            if (m_buffers[i].data() == buffer) {
                m_in_use[i].store(false);
                return;
            }
        }
    }
};
```

## 7. Scoped Abort Callback

### 7.1 Cancellable Operations

```cpp
class scoped_abort : public abort_callback_impl {
    std::atomic<bool> m_abort{false};

public:
    void request_abort() {
        m_abort.store(true, std::memory_order_release);
    }

    bool is_aborting() const override {
        return m_abort.load(std::memory_order_acquire);
    }

    void reset() {
        m_abort.store(false, std::memory_order_release);
    }
};

// Usage:
class BackgroundScanner {
    scoped_abort m_abort;
    std::thread m_thread;

public:
    void start_scan(const playable_location& loc) {
        m_abort.reset();
        m_thread = std::thread([this, loc]() {
            try {
                do_scan(loc, m_abort);
            }
            catch (const exception_aborted&) {
                // Normal cancellation
            }
        });
    }

    void cancel() {
        m_abort.request_abort();
        if (m_thread.joinable()) {
            m_thread.join();
        }
    }
};
```

## 8. Performance Tips

### 8.1 Batch Processing

```cpp
// Process samples in batches for better cache utilization
void process_efficient(audio_chunk& chunk) {
    audio_sample* data = chunk.get_data();
    t_size total = chunk.get_data_size();

    // Process in cache-friendly blocks
    const size_t BLOCK_SIZE = 256;

    for (t_size i = 0; i < total; i += BLOCK_SIZE) {
        size_t count = std::min(BLOCK_SIZE, total - i);
        process_block(&data[i], count);
    }
}
```

### 8.2 SIMD with Accelerate Framework

```cpp
#include <Accelerate/Accelerate.h>

void apply_gain_simd(float* samples, size_t count, float gain) {
    vDSP_vsmul(samples, 1, &gain, samples, 1, count);
}

void mix_stereo_to_mono(const float* stereo, float* mono, size_t frames) {
    // stereo is interleaved [L, R, L, R, ...]
    // Deinterleave, average, store
    for (size_t i = 0; i < frames; i++) {
        mono[i] = (stereo[i * 2] + stereo[i * 2 + 1]) * 0.5f;
    }
}
```

## Best Practices

1. **Pre-allocate buffers** - Never allocate memory in audio processing callbacks
2. **Use lock-free communication** - Atomics for parameters, lock-free queues for data
3. **Respect the deadline** - Keep processing under 50% of buffer duration
4. **Use vDSP/Accelerate** - Apple's optimized vector operations
5. **Handle exceptions** - Wrap all SDK operations in try-catch
6. **Support cancellation** - Check abort_callback regularly during long operations
7. **Test with short buffers** - Some configurations use 64-sample buffers
8. **Profile with Instruments** - Use Time Profiler to find bottlenecks
