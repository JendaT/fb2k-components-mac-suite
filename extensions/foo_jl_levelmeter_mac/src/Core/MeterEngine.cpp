//
//  MeterEngine.cpp
//  foo_jl_levelmeter_mac
//

#include "MeterEngine.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace meter {

namespace {
const double kNegInf = -std::numeric_limits<double>::infinity();
// The needle's end stop sits a little past the top of the VU scale (+3).
const double kNeedleStopVu = 3.6;
// Longest stretch idle() simulates in one go (keeps the silence buffer small).
const double kMaxIdleStep = 0.1;
} // namespace

Snapshot::Snapshot() : momentary(kNegInf), shortTerm(kNegInf), integrated(kNegInf) {}

MeterEngine::MeterEngine() {
    std::fill(std::begin(_psrSlot), std::end(_psrSlot), 0.0f);
    setSampleRate(48000.0);
}

void MeterEngine::configure(const EngineSettings &s) {
    const bool needleChanged = s.needle != _settings.needle;
    _settings = s;
    const double sr = _sampleRate;
    _sampleRate = 0;   // force every detector to pick up the new settings
    setSampleRate(sr);
    if (needleChanged) {
        for (int c = 0; c < 2; ++c) { _vu[c].reset(); _ppm[c].reset(); }
    }
}

void MeterEngine::setSampleRate(double sr) {
    if (sr <= 0 || sr == _sampleRate) return;
    _sampleRate = sr;
    const double ref = dbToLinear(_settings.referenceDbfs);
    const PpmTiming ppm = ppmTiming(_settings.needle);
    for (int c = 0; c < 2; ++c) {
        _rms[c].configure(sr, _settings.rmsWindowSeconds);
        _vu[c].configure(sr);
        _vu[c].setMaxValue(ref * dbToLinear(kNeedleStopVu));
        _ppm[c].configure(sr, ppm.attackSeconds, ppm.fallDbPerSecond);
    }
    _stereo.configure(sr, _settings.correlationSeconds);
    _loudness.configure(sr, _channels);
}

void MeterEngine::runDetectors(const float *lr, size_t frames) {
    const bool vu = _settings.needle == NeedleBallistics::VU;
    float peak[2] = { _blockSample[0], _blockSample[1] };
    for (size_t i = 0; i < frames; ++i) {
        const float l = lr[2 * i], r = lr[2 * i + 1];
        _rms[0].push(l);
        _rms[1].push(r);
        if (vu) { _vu[0].push(l); _vu[1].push(r); }
        else    { _ppm[0].push(l); _ppm[1].push(r); }
        _stereo.push(l, r);
        peak[0] = std::max(peak[0], std::fabs(l));
        peak[1] = std::max(peak[1], std::fabs(r));
    }
    _blockSample[0] = peak[0];
    _blockSample[1] = peak[1];
    float tpMax = 0.0f;
    for (int c = 0; c < 2; ++c) {
        // The true peak filters always run so they hold valid history when
        // the setting is switched on mid-track.
        const float tp = _tp[c].process(lr + c, frames, 2);
        _blockTrue[c] = std::max(_blockTrue[c], tp);
        tpMax = std::max(tpMax, _settings.truePeak ? tp : 0.0f);
    }
    if (!_settings.truePeak) tpMax = std::max(peak[0], peak[1]);
    notePsrPeak(tpMax, frames);
}

void MeterEngine::notePsrPeak(float peak, size_t frames) {
    const size_t slotLength = (size_t)std::max(1.0, _sampleRate * 0.1);
    _psrSlot[_psrPos] = std::max(_psrSlot[_psrPos], peak);
    _psrFill += frames;
    while (_psrFill >= slotLength) {
        _psrFill -= slotLength;
        _psrPos = (_psrPos + 1) % kPsrSlots;
        _psrSlot[_psrPos] = _psrFill > 0 ? peak : 0.0f;
    }
}

void MeterEngine::process(const float *lr, size_t frames, double sampleRate, int channels) {
    if (!lr || frames == 0 || sampleRate <= 0) return;
    channels = channels == 1 ? 1 : 2;
    if (channels != _channels) {
        _channels = channels;
        _loudness.configure(_sampleRate, _channels);
    }
    setSampleRate(sampleRate);
    runDetectors(lr, frames);
    _loudness.process(lr, frames);
    _gotAudio = true;
}

void MeterEngine::idle(double dt) {
    if (dt <= 0 || _sampleRate <= 0) return;
    dt = std::min(dt, kMaxIdleStep);
    const size_t frames = (size_t)std::lround(dt * _sampleRate);
    if (frames == 0) return;
    if (_silence.size() < frames * 2) _silence.assign(frames * 2, 0.0f);
    runDetectors(_silence.data(), frames);
    _loudness.pushSilence(dt);
}

void MeterEngine::advance(double dt) {
    dt = std::max(dt, 0.0);
    const double fall = _settings.peakFallDbPerSecond * dt;
    const double ref = dbToLinear(_settings.referenceDbfs);
    const bool vu = _settings.needle == NeedleBallistics::VU;
    const float rmsGain = _settings.rmsSineReadsPeak ? 1.4142135623730951f : 1.0f;

    for (int c = 0; c < 2; ++c) {
        ChannelReading &r = _snap.ch[c];
        const float level = _settings.truePeak ? std::max(_blockTrue[c], _blockSample[c]) : _blockSample[c];
        const float db = linearToDb(level);

        r.peakDb = db >= r.peakDb ? db : std::max(db, (float)(r.peakDb - fall));

        if (db >= r.holdDb) {
            r.holdDb = db;
            _holdTimer[c] = 0.0;
        } else {
            _holdTimer[c] += dt;
            if (!_settings.peakHoldForever && _holdTimer[c] > _settings.peakHoldSeconds) {
                r.holdDb = std::max(r.peakDb, (float)(r.holdDb - fall));
            }
        }

        r.maxDb = std::max(r.maxDb, db);
        if (db > _settings.clipDbfs) r.clip = true;
        r.rmsDb = linearToDb(_rms[c].rms() * rmsGain);
        const double needle = vu ? _vu[c].value() : _ppm[c].value();
        r.needleDb = linearToDb(needle / ref);
    }

    _snap.channels = _channels;
    if (_channels == 1) {
        // Mono reaches both channels identically; keep the readouts identical
        // even where the right channel was filtered from an exact copy.
        _snap.ch[1] = _snap.ch[0];
    }
    _snap.momentary = _loudness.momentary();
    _snap.shortTerm = _loudness.shortTerm();
    _snap.integrated = _loudness.integrated();
    _snap.range = _loudness.range();
    _snap.measuredSeconds = _loudness.measuredSeconds();
    // Only real audio counts towards the measurement's peak.
    if (_gotAudio) {
        for (int c = 0; c < 2; ++c) {
            const float level = _settings.truePeak ? std::max(_blockTrue[c], _blockSample[c]) : _blockSample[c];
            _measurementPeakDb = std::max(_measurementPeakDb, linearToDb(level));
        }
    }
    _snap.truePeakMaxDb = _measurementPeakDb;

    float recentPeak = 0.0f;
    for (float p : _psrSlot) recentPeak = std::max(recentPeak, p);
    _snap.psrDb = std::isfinite(_snap.shortTerm) && recentPeak > 0
        ? (float)(linearToDb(recentPeak) - _snap.shortTerm) : 0.0f;

    _snap.stereoSilent = _stereo.silent() || _channels == 1;
    _snap.correlation = _channels == 1 ? 1.0f : _stereo.correlation();
    _snap.balanceDb = _channels == 1 ? 0.0f : _stereo.balanceDb();
    _snap.active = _gotAudio;

    _blockSample[0] = _blockSample[1] = 0.0f;
    _blockTrue[0] = _blockTrue[1] = 0.0f;
    _gotAudio = false;
}

void MeterEngine::resetPeaks() {
    for (int c = 0; c < 2; ++c) {
        _snap.ch[c].maxDb = kFloorDb;
        _snap.ch[c].holdDb = kFloorDb;
        _snap.ch[c].clip = false;
        _holdTimer[c] = 0.0;
    }
}

void MeterEngine::resetLoudness() {
    _loudness.reset();
    _measurementPeakDb = kFloorDb;
    _snap.truePeakMaxDb = kFloorDb;
    _snap.momentary = _snap.shortTerm = _snap.integrated = kNegInf;
    _snap.range = 0.0;
    _snap.measuredSeconds = 0.0;
}

} // namespace meter
