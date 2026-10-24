//
//  SpectrogramClock.h
//  foo_jl_spectrogram_mac
//
//  Decides how many columns each display frame renders. Columns sit on a
//  fixed time grid; a display clock (host time plus an offset that slowly
//  follows the stream time) walks along it. The stream time advances in
//  uneven steps and briefly reports none at all, so following it directly
//  makes the picture stutter. Pure C++ (no SDK, no Cocoa).
//

#pragma once

#include <cmath>

class SpectrogramClock {
public:
    // A difference between the display clock and the stream time larger than
    // this (seek, restart, stall) starts over at the stream time instead of
    // replaying or skipping the gap.
    static constexpr double kMaxGap = 0.5;

    // Fraction of the display clock's error to the stream time corrected per frame.
    static constexpr double kSlew = 0.05;

    // Columns trail the display clock by this much, so their audio is already
    // there when the clock runs slightly ahead of the stream.
    static constexpr double kRenderDelay = 0.05;

    // Forget the clock (pause, stop, freeze, hidden). The next frame with a
    // stream time starts over there.
    void reset() { _valid = false; }

    // Number of columns due at host time `host`, `hop` seconds apart. Pass
    // haveStream = false when the stream gave no time this frame: the clock
    // then coasts on host time. Returns 0 while (re)starting.
    int due(double host, bool haveStream, double stream, double hop) {
        if (!_valid) {
            if (!haveStream) return 0;
            _offset = stream - host;
            _last = _target = stream - kRenderDelay;
            _valid = true;
            return 0;
        }
        if (haveStream) {
            const double error = stream - (host + _offset);
            if (std::fabs(error) > kMaxGap) {
                _valid = false;
                return 0;
            }
            _offset += error * kSlew;
        }
        const double target = _target = host + _offset - kRenderDelay;
        // Columns that could not be rendered for a while (their audio never
        // arrived) are skipped, or the grid would stay stuck behind the
        // stream's backlog.
        if (target - _last > kMaxGap) _last = target - hop;
        // The epsilon keeps a whole hop from rounding down to zero columns.
        const double n = std::floor((target - _last) / hop + 1e-9);
        return n > 0 ? (int)n : 0;
    }

    // Stream time of the next column on the grid.
    double next(double hop) const { return _last + hop; }

    // The column at next(hop) has been rendered.
    void advance(double hop) { _last += hop; }

    // How far the display clock has moved past the newest rendered column at
    // the last due() call, in columns (0..1). The view shifts the picture by
    // this fraction, so it moves the same distance every frame even when the
    // refresh rate is not a multiple of the column rate.
    double phase(double hop) const {
        const double p = (_target - _last) / hop;
        return p < 0.0 ? 0.0 : (p > 1.0 ? 1.0 : p);
    }

private:
    bool   _valid = false;
    double _offset = 0.0;   // stream time minus host time, smoothed
    double _last = 0.0;     // stream time of the newest column
    double _target = 0.0;   // display clock at the last due() call, minus kRenderDelay
};
