//
//  BeatThisModel.mm
//  foo_jl_bpm_mac
//

#import <CoreML/CoreML.h>

#include "BeatThisModel.h"

#include "../fb2k_sdk.h"
#include "../Core/LogMelSpectrogram.h"
#include "../Core/NetworkBeats.h"

#include <algorithm>
#include <atomic>
#include <mutex>
#include <vector>

// Finds the component's bundle (the class name is global in the process)
@interface JLBpmBeatThisBundleAnchor : NSObject
@end
@implementation JLBpmBeatThisBundleAnchor
@end

namespace bpm {

namespace {

NSString *const kModelName = @"BeatThisSmall0";

struct ModelState {
    std::once_flag loaded;
    MLModel *model = nil;
    std::mutex mutex;                   // one prediction at a time
    std::vector<float> input;           // kNetworkChunk x kMelBands, the model's fixed input
    std::atomic<bool> reportedFailure{ false };
};

// Built on first use, never while the component loads
ModelState &state() {
    static ModelState *s = new ModelState();
    return *s;
}

void load(ModelState &s) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle bundleForClass:[JLBpmBeatThisBundleAnchor class]];
        NSURL *url = [bundle URLForResource:kModelName withExtension:@"mlmodelc"];
        if (!url) {
            FB2K_console_formatter() << "[BPM] Beat This! model missing from the component; using the classic beat tracker";
            return;
        }
        MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
        // float32 on CPU and GPU picks the same beats as the reference; the
        // Neural Engine computes in float16 and moves some of them
        config.computeUnits = MLComputeUnitsCPUAndGPU;
        NSError *error = nil;
        MLModel *model = [MLModel modelWithContentsOfURL:url configuration:config error:&error];
        if (!model) {
            FB2K_console_formatter() << "[BPM] Beat This! model could not be loaded ("
                                     << (error ? error.localizedDescription.UTF8String : "unknown error")
                                     << "); using the classic beat tracker";
            return;
        }
        s.model = model;
        s.input.assign(static_cast<size_t>(kNetworkChunk) * kMelBands, 0.0f);
    }
}

// The first `rows` values of a [1, kNetworkChunk] output (float32 as
// converted; double accepted too)
bool copyOutput(MLMultiArray *array, long rows, float *out) {
    if (!array || array.count < rows || array.shape.count < 2) return false;
    const long stride = array.strides.lastObject.longValue;
    const MLMultiArrayDataType type = array.dataType;
    auto read = [&](const void *bytes) {
        for (long r = 0; r < rows; r++) {
            switch (type) {
                case MLMultiArrayDataTypeFloat32: out[r] = static_cast<const float *>(bytes)[r * stride]; break;
                case MLMultiArrayDataTypeDouble: out[r] = static_cast<float>(static_cast<const double *>(bytes)[r * stride]); break;
                default: return false;
            }
        }
        return true;
    };
    if (@available(macOS 12.3, *)) {
        __block bool ok = false;
        [array getBytesWithHandler:^(const void *bytes, NSInteger size) {
            (void)size;
            ok = read(bytes);
        }];
        return ok;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return read(array.dataPointer);
#pragma clang diagnostic pop
}

} // namespace

bool beatThisAvailable() {
    ModelState &s = state();
    std::call_once(s.loaded, [&] { load(s); });
    return s.model != nil;
}

bool runBeatThis(const float *input, long rows, float *beat, float *downbeat) {
    if (!beatThisAvailable() || rows <= 0 || rows > kNetworkChunk) return false;
    ModelState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    @autoreleasepool {
        std::fill(s.input.begin(), s.input.end(), 0.0f);
        std::copy_n(input, static_cast<size_t>(rows) * kMelBands, s.input.begin());
        NSError *error = nil;
        MLMultiArray *spect = [[MLMultiArray alloc] initWithDataPointer:s.input.data()
                                                                  shape:@[ @1, @(kNetworkChunk), @(kMelBands) ]
                                                               dataType:MLMultiArrayDataTypeFloat32
                                                                strides:@[ @(kNetworkChunk * static_cast<long>(kMelBands)), @(kMelBands), @1 ]
                                                            deallocator:nil
                                                                  error:&error];
        MLDictionaryFeatureProvider *features =
            spect ? [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"spect" : [MLFeatureValue featureValueWithMultiArray:spect] }
                                                                     error:&error]
                  : nil;
        id<MLFeatureProvider> result = features ? [s.model predictionFromFeatures:features error:&error] : nil;
        const bool ok = result && copyOutput([result featureValueForName:@"beat"].multiArrayValue, rows, beat) &&
                        copyOutput([result featureValueForName:@"downbeat"].multiArrayValue, rows, downbeat);
        if (!ok && !s.reportedFailure.exchange(true)) {
            FB2K_console_formatter() << "[BPM] Beat This! prediction failed ("
                                     << (error ? error.localizedDescription.UTF8String : "unexpected output")
                                     << "); using the classic beat tracker";
        }
        return ok;
    }
}

} // namespace bpm
