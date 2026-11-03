//
//  MonoResampler.mm
//  foo_jl_bpm_mac
//

#import <AVFoundation/AVFoundation.h>

#include "MonoResampler.h"

#include "../Core/LogMelSpectrogram.h"
#include "../Core/ResampleLowpass.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <optional>

namespace bpm {

struct MonoResampler::Impl {
    double inputRate;
    bool passThrough = false;
    bool failed = false;
    std::optional<ResampleLowpass> lowpass;   // the decimator, or the roll-off after the converter
    AVAudioFormat *inputFormat = nil;
    AVAudioFormat *outputFormat = nil;
    AVAudioConverter *converter = nil;
    std::vector<float> converted;

    explicit Impl(double in) : inputRate(in) {
        if (!(in > 0.0)) {
            failed = true;
            return;
        }
        if (in == kMelSampleRate) {
            passThrough = true;
            return;
        }
        if (in == 2 * kMelSampleRate || in == 4 * kMelSampleRate) {
            lowpass.emplace(static_cast<int>(in / kMelSampleRate));
            return;
        }
        lowpass.emplace(1);
        inputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:in channels:1 interleaved:NO];
        outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                        sampleRate:kMelSampleRate
                                                          channels:1
                                                       interleaved:NO];
        converter = inputFormat && outputFormat ? [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat] : nil;
        if (!converter) {
            failed = true;
            return;
        }
        // High, not max: as close to soxr through the roll-off (0.2% of the
        // network's sure beats differ, against 0.4% at max) and twice as fast
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering;
        converter.sampleRateConverterQuality = AVAudioQualityHigh;
    }

    // Runs the converter until it wants more input (or, at the end, has
    // given everything), appending its output
    void convert(AVAudioPCMBuffer *input, bool end, std::vector<float> &out) {
        __block bool supplied = input == nil;
        AVAudioConverterInputBlock feed = ^AVAudioBuffer *(AVAudioPacketCount packets, AVAudioConverterInputStatus *status) {
            (void)packets;
            if (!supplied) {
                supplied = true;
                *status = AVAudioConverterInputStatus_HaveData;
                return input;
            }
            *status = end ? AVAudioConverterInputStatus_EndOfStream : AVAudioConverterInputStatus_NoDataNow;
            return nil;
        };
        const AVAudioFrameCount capacity = static_cast<AVAudioFrameCount>(
            std::ceil((input ? input.frameLength : 0) * kMelSampleRate / inputRate) + 4096);
        for (;;) {
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat frameCapacity:capacity];
            NSError *error = nil;
            const AVAudioConverterOutputStatus status = [converter convertToBuffer:buffer error:&error withInputFromBlock:feed];
            if (status == AVAudioConverterOutputStatus_Error) {
                failed = true;
                return;
            }
            const float *samples = buffer.floatChannelData[0];
            out.insert(out.end(), samples, samples + buffer.frameLength);
            if (status == AVAudioConverterOutputStatus_InputRanDry || status == AVAudioConverterOutputStatus_EndOfStream) return;
            if (buffer.frameLength == 0) return;
        }
    }
};

MonoResampler::MonoResampler(double inputRate) : m(std::make_unique<Impl>(inputRate)) {}
MonoResampler::~MonoResampler() = default;

bool MonoResampler::ok() const { return !m->failed; }

void MonoResampler::process(const float *samples, size_t count, std::vector<float> &out) {
    if (m->failed || count == 0) return;
    if (m->passThrough) {
        out.insert(out.end(), samples, samples + count);
        return;
    }
    if (!m->converter) {
        m->lowpass->process(samples, count, out);
        return;
    }
    @autoreleasepool {
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:m->inputFormat
                                                                frameCapacity:static_cast<AVAudioFrameCount>(count)];
        if (!input) {
            m->failed = true;
            return;
        }
        std::memcpy(input.floatChannelData[0], samples, count * sizeof(float));
        input.frameLength = static_cast<AVAudioFrameCount>(count);
        m->converted.clear();
        m->convert(input, false, m->converted);
        m->lowpass->process(m->converted.data(), m->converted.size(), out);
    }
}

void MonoResampler::finish(std::vector<float> &out) {
    if (m->failed || m->passThrough) return;
    if (m->converter) {
        @autoreleasepool {
            m->converted.clear();
            m->convert(nil, true, m->converted);
            m->lowpass->process(m->converted.data(), m->converted.size(), out);
        }
    }
    m->lowpass->finish(out);
}

} // namespace bpm
