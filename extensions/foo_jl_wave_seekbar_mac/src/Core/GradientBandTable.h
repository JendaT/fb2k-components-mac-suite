//
//  GradientBandTable.h
//  foo_wave_seekbar_mac
//
//  The gradient-band choices offered in preferences, as one table.
//
//  Preferences previously carried two hand-maintained representations of this
//  mapping - an if/else ladder to select the popup item and a parallel array
//  to write the value back - which could drift apart. Both directions now
//  come from here.
//

#pragma once

#include <cstddef>

namespace waveseek {

// Band counts offered in the popup, in menu order. 0 means a flat trace with
// no gradient.
constexpr int kGradientBandValues[] = {0, 2, 4, 8, 12, 16, 24, 32};
constexpr size_t kGradientBandOptionCount =
    sizeof(kGradientBandValues) / sizeof(kGradientBandValues[0]);

// Index selected when the stored value is not one of the offered choices
// (hand-edited config, or a value from a future build).
constexpr int kGradientBandDefaultIndex = 3;  // 8 bands

inline int gradientBandValueForIndex(int index) {
    if (index < 0 || static_cast<size_t>(index) >= kGradientBandOptionCount) {
        return kGradientBandValues[kGradientBandDefaultIndex];
    }
    return kGradientBandValues[index];
}

inline int gradientBandIndexForValue(int value) {
    for (size_t i = 0; i < kGradientBandOptionCount; i++) {
        if (kGradientBandValues[i] == value) {
            return static_cast<int>(i);
        }
    }
    return kGradientBandDefaultIndex;
}

inline bool isValidGradientBandIndex(int index) {
    return index >= 0 && static_cast<size_t>(index) < kGradientBandOptionCount;
}

} // namespace waveseek
