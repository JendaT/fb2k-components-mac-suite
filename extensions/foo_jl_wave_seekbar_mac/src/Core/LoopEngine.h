//
//  LoopEngine.h
//  foo_wave_seekbar_mac
//
//  A beat loop without a gap: the audio side of the mixer's loop, run by a
//  DSP placed first in the playback chain. Looping by seeking flushes the
//  output, so every pass starts with a gap; instead the loop is bound to
//  the seek to its start (the first block after that flush starts on the
//  loop's first beat), its first pass plays through while it is recorded,
//  and then the recording repeats sample for sample.
//
//  While it repeats, each block of decoded audio is held back and a
//  quantum of the loop goes out instead, so the decoder moves on only
//  slowly. The held audio starts exactly where the recording ends: a
//  longer loop takes its extra beats from it, and leaving the loop plays
//  the rest of the pass, then the held audio, then the stream as it comes,
//  without a break. Held audio drains faster than it arrives until none is
//  left.
//
//  The engine logs what each output frame plays (a timeline of segments),
//  so the view can map the audible time since the seek to a track position.
//
//  Single-threaded: the DSP calls it on the playback thread and applies
//  the view's requests between blocks. Header-only, tested standalone.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

namespace waveseek {

// Output frames counted from the seek that bound the loop, and the track
// time each plays: the loop repeating (start + ((offset + frame - first)
// mod loopFrames) / rate), or straight on from `linearFrom` seconds
struct LoopSegment {
    uint64_t first = 0;
    uint64_t loopFrames = 0;    // 0: straight on
    uint64_t offset = 0;        // frames into the loop at `first`
    double linearFrom = 0.0;
};

// The track time output frame `frame` plays; NAN without a timeline
inline double trackTimeAt(const std::vector<LoopSegment> &timeline, double loopStart, double rate, double frame) {
    if (timeline.empty() || !(rate > 0.0) || !(frame >= 0.0)) return NAN;
    const LoopSegment *segment = &timeline.front();
    for (const LoopSegment &s : timeline) {
        if (static_cast<double>(s.first) <= frame) segment = &s;
        else break;
    }
    const double into = frame - static_cast<double>(segment->first);
    if (segment->loopFrames == 0) return segment->linearFrom + into / rate;
    return loopStart + std::fmod(static_cast<double>(segment->offset) + into, static_cast<double>(segment->loopFrames)) / rate;
}

template <typename Sample>
class LoopEngine {
public:
    // Interleaved audio in one format
    struct Block {
        std::vector<Sample> samples;
        unsigned channels = 0;
        unsigned rate = 0;
        unsigned config = 0;    // the channel layout, carried through

        size_t frames() const { return channels ? samples.size() / channels : 0; }
    };

    enum Phase {
        Idle,           // passing audio through
        Recording,      // the first pass: through, and recorded
        Repeating,      // the recording again and again; decoded audio held back
        Draining,       // left: the rest of the recording, then the held audio, faster than it comes
    };

    // Seconds of loop sent per block while repeating: less makes the
    // decoder run ahead faster (a block is held per quantum), more delays
    // a new length or leaving the loop by up to this much
    static constexpr double kQuantumSeconds = 1.0;
    // Held audio past this leaves the loop at the end of the pass (the
    // decoder would otherwise run on toward the track's end)
    static constexpr double kMaxHeldSeconds = 120.0;

    // The next flush (the seek to `start`) binds loop `id`, `length` seconds long
    void arm(uint64_t id, double start, double length) {
        armedId_ = id;
        armedStart_ = start;
        armedLength_ = length;
    }

    // A new length for the bound loop, from its start: recorded further,
    // grown from the held audio, or wrapped back into when it already
    // plays past the new end
    void setLength(double seconds) {
        if (phase_ != Recording && phase_ != Repeating) {
            length_ = seconds;
            return;
        }
        length_ = seconds;
        const uint64_t frames = framesFor(seconds);
        if (frames == 0) return;     // before the first block: it records this long
        if (phase_ == Recording) {
            if (frames > recorded_) {   // the first pass records further
                target_ = loopFrames_ = frames;
                timeline_.back().loopFrames = frames;
                return;
            }
            // Shorter than what already played: the first pass played
            // straight through to here
            timeline_.back().loopFrames = std::max<uint64_t>(recorded_, 1);
            target_ = loopFrames_ = frames;
            if (exitRequested_) {
                endLinearly(recorded_);
                return;
            }
            phase_ = Repeating;
            readPos_ = recorded_ % frames;
            timeline_.push_back({ emitted_, loopFrames_, readPos_, 0.0 });
            return;
        }
        loopFrames_ = frames;
        if (readPos_ >= loopFrames_) readPos_ %= loopFrames_;
        timeline_.push_back({ emitted_, loopFrames_, readPos_, 0.0 });
    }

    // Leave at the end of the pass playing and play on
    void requestExit() { exitRequested_ = true; }

    // A seek: binds an armed loop, else drops everything and passes through
    void flush() {
        held_.clear();
        heldFrames_ = 0;
        recording_.clear();
        timeline_.clear();
        exitRequested_ = false;
        emitted_ = recorded_ = readPos_ = drainPos_ = target_ = loopFrames_ = 0;
        lastInFrames_ = 0;
        if (armedId_ != 0) {
            boundId_ = armedId_;
            armedId_ = 0;
            start_ = armedStart_;
            length_ = armedLength_;
            phase_ = Recording;
            rate_ = channels_ = config_ = 0;    // from the first block
            flushedAway_ = false;
        } else {
            if (boundId_ != 0) flushedAway_ = true;
            phase_ = Idle;
        }
    }

    // One block in; what to play appended to `out`
    void process(Block &&in, std::vector<Block> &out) {
        if (in.frames() == 0) return;
        switch (phase_) {
            case Idle:
                out.push_back(std::move(in));
                return;
            case Recording:
                record(std::move(in), out);
                return;
            case Repeating:
                hold(std::move(in));
                if (heldSeconds() > kMaxHeldSeconds) exitRequested_ = true;
                emitLoop(std::max<uint64_t>(lastInFrames_, framesFor(kQuantumSeconds)), out);
                return;
            case Draining:
                hold(std::move(in));
                emitDrain(2 * static_cast<uint64_t>(lastInFrames_), out);
                return;
        }
    }

    // The end of the stream: everything still to play, now
    void endOfStream(std::vector<Block> &out) {
        if (phase_ == Recording) endLinearly(recorded_);
        if (phase_ == Repeating) {
            exitRequested_ = true;
            emitLoop(UINT64_MAX / 2, out);
        }
        if (phase_ == Draining) emitDrain(UINT64_MAX / 2, out);
    }

    Phase phase() const { return phase_; }
    uint64_t boundId() const { return boundId_; }
    bool flushedAway() const { return flushedAway_; }      // the bound loop was dropped by another seek
    unsigned rate() const { return rate_; }
    double start() const { return start_; }
    const std::vector<LoopSegment> &timeline() const { return timeline_; }
    uint64_t emitted() const { return emitted_; }
    // Decoded audio waiting behind the loop, in seconds
    double heldSeconds() const {
        const uint64_t tail = phase_ == Draining && recorded_ > drainPos_ ? recorded_ - drainPos_ : 0;
        return rate_ ? static_cast<double>(heldFrames_ + tail) / rate_ : 0.0;
    }

private:
    uint64_t framesFor(double seconds) const {
        return rate_ && seconds > 0.0 ? static_cast<uint64_t>(std::llround(seconds * rate_)) : 0;
    }

    static Block slice(const Block &b, size_t from, size_t frames) {
        Block s;
        s.channels = b.channels;
        s.rate = b.rate;
        s.config = b.config;
        s.samples.assign(b.samples.begin() + static_cast<std::ptrdiff_t>(from * b.channels),
                         b.samples.begin() + static_cast<std::ptrdiff_t>((from + frames) * b.channels));
        return s;
    }

    static void dropFront(Block &b, size_t frames) {
        b.samples.erase(b.samples.begin(), b.samples.begin() + static_cast<std::ptrdiff_t>(frames * b.channels));
    }

    Block fromRecording(uint64_t from, uint64_t frames) const {
        Block s;
        s.channels = channels_;
        s.rate = rate_;
        s.config = config_;
        s.samples.assign(recording_.begin() + static_cast<std::ptrdiff_t>(from * channels_),
                         recording_.begin() + static_cast<std::ptrdiff_t>((from + frames) * channels_));
        return s;
    }

    void hold(Block &&in) {
        lastInFrames_ = in.frames();
        heldFrames_ += in.frames();
        held_.push_back(std::move(in));
    }

    // Up to `frames` from the front of the held audio, in the loop's format
    // only (another format, a new track, ends what the recording can grow from)
    enum class Take { Taken, Empty, OtherFormat };
    Take takeHeld(uint64_t frames, Block &out) {
        if (held_.empty() || frames == 0) return Take::Empty;
        Block &front = held_.front();
        if (front.channels != channels_ || front.rate != rate_) return Take::OtherFormat;
        const size_t n = static_cast<size_t>(std::min<uint64_t>(frames, front.frames()));
        out = slice(front, 0, n);
        if (n == front.frames()) held_.pop_front();
        else dropFront(front, n);
        heldFrames_ -= n;
        return Take::Taken;
    }

    void record(Block &&in, std::vector<Block> &out) {
        if (rate_ == 0) {
            rate_ = in.rate;
            channels_ = in.channels;
            config_ = in.config;
            target_ = loopFrames_ = framesFor(length_);
            if (target_ == 0) {
                phase_ = Idle;
                out.push_back(std::move(in));
                return;
            }
            timeline_.push_back({ 0, target_, 0, 0.0 });
        }
        if (in.rate != rate_ || in.channels != channels_) {   // a new format mid-pass: no loop
            phase_ = Idle;
            timeline_.push_back({ emitted_, 0, 0, start_ + static_cast<double>(recorded_) / rate_ });
            out.push_back(std::move(in));
            return;
        }
        lastInFrames_ = in.frames();
        const size_t take = static_cast<size_t>(std::min<uint64_t>(in.frames(), target_ - recorded_));
        recording_.insert(recording_.end(), in.samples.begin(), in.samples.begin() + static_cast<std::ptrdiff_t>(take * channels_));
        recorded_ += take;
        emitted_ += take;
        if (take == in.frames()) {
            out.push_back(std::move(in));
        } else {
            out.push_back(slice(in, 0, take));
            Block rest = slice(in, take, in.frames() - take);
            heldFrames_ += rest.frames();
            held_.push_back(std::move(rest));
        }
        if (recorded_ < target_) return;
        if (exitRequested_) {
            endLinearly(recorded_);
        } else {
            phase_ = Repeating;
            readPos_ = 0;
        }
    }

    // Plays on from `frames` into the loop: the recording past there, the
    // held audio, then the stream
    void endLinearly(uint64_t frames) {
        drainPos_ = std::min(frames, recorded_);
        phase_ = Draining;
        timeline_.push_back({ emitted_, 0, 0, start_ + static_cast<double>(frames) / rate_ });
    }

    void emitLoop(uint64_t frames, std::vector<Block> &out) {
        while (frames > 0 && phase_ == Repeating) {
            if (readPos_ >= loopFrames_) {   // the end of a pass
                if (exitRequested_) {
                    endLinearly(loopFrames_);
                    emitDrain(frames, out);
                    return;
                }
                readPos_ = 0;
            }
            if (readPos_ < recorded_) {
                const uint64_t n = std::min(frames, std::min(loopFrames_, recorded_) - readPos_);
                out.push_back(fromRecording(readPos_, n));
                readPos_ += n;
                emitted_ += n;
                frames -= n;
                continue;
            }
            // Longer than recorded: its next beats come from the held audio,
            // as fast as they are decoded
            Block piece;
            const Take took = takeHeld(std::min(frames, loopFrames_ - recorded_), piece);
            if (took == Take::Empty) return;
            if (took == Take::OtherFormat) {   // the track ended: the pass ends here
                loopFrames_ = recorded_;
                timeline_.push_back({ emitted_, loopFrames_, 0, 0.0 });
                readPos_ = loopFrames_;
                continue;
            }
            recording_.insert(recording_.end(), piece.samples.begin(), piece.samples.end());
            const uint64_t n = piece.frames();
            recorded_ += n;
            readPos_ += n;
            emitted_ += n;
            frames -= n;
            out.push_back(std::move(piece));
        }
    }

    void emitDrain(uint64_t frames, std::vector<Block> &out) {
        while (frames > 0 && drainPos_ < recorded_) {
            const uint64_t n = std::min(frames, recorded_ - drainPos_);
            out.push_back(fromRecording(drainPos_, n));
            drainPos_ += n;
            emitted_ += n;
            frames -= n;
        }
        while (frames > 0 && !held_.empty()) {
            Block &front = held_.front();
            const size_t n = static_cast<size_t>(std::min<uint64_t>(frames, front.frames()));
            if (n == front.frames()) {
                out.push_back(std::move(front));
                held_.pop_front();
            } else {
                out.push_back(slice(front, 0, n));
                dropFront(front, n);
            }
            heldFrames_ -= n;
            emitted_ += n;
            frames -= n;
        }
        if (held_.empty() && drainPos_ >= recorded_) {   // caught up: through again
            phase_ = Idle;
            recording_.clear();
            recording_.shrink_to_fit();
            recorded_ = drainPos_ = 0;
        }
    }

    Phase phase_ = Idle;
    uint64_t armedId_ = 0;
    double armedStart_ = 0.0, armedLength_ = 0.0;
    uint64_t boundId_ = 0;
    bool flushedAway_ = false;
    double start_ = 0.0, length_ = 0.0;
    unsigned rate_ = 0, channels_ = 0, config_ = 0;

    std::vector<Sample> recording_;
    uint64_t recorded_ = 0;         // frames recorded
    uint64_t target_ = 0;           // frames the first pass records
    uint64_t loopFrames_ = 0;       // the loop's length now
    uint64_t readPos_ = 0;          // frames into the loop
    uint64_t drainPos_ = 0;         // after leaving: frames of the recording played
    std::deque<Block> held_;
    uint64_t heldFrames_ = 0;
    uint64_t emitted_ = 0;          // output frames since the seek
    size_t lastInFrames_ = 0;
    bool exitRequested_ = false;
    std::vector<LoopSegment> timeline_;
};

} // namespace waveseek
