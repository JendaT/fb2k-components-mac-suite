//
//  BeatThisModel.h
//  foo_jl_bpm_mac
//
//  The bundled Beat This! network (Resources/BeatThisSmall0.mlpackage,
//  compiled by Xcode into the component's Resources) on Core ML, CPU and
//  GPU. Loaded once on first use; predictions are serialised. If the model
//  cannot be loaded the beat grid falls back to the classic tracker.
//

#pragma once

namespace bpm {

// Loads the model on first call (seconds on the first run: Core ML compiles
// it for the GPU). Any thread; false when it is unavailable.
bool beatThisAvailable();

// One chunk: `rows` (<= kNetworkChunk) frames of kMelBands log-mel values,
// zero-padded to the model's kNetworkChunk; `rows` beat and downbeat logits
// out. Any thread. False on failure (logged once).
bool runBeatThis(const float *input, long rows, float *beat, float *downbeat);

} // namespace bpm
