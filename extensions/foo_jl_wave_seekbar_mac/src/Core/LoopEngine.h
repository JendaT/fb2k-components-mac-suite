//
//  LoopEngine.h
//  foo_wave_seekbar_mac
//
//  The mixer's audio side: loops, jumps and loop moves without a gap or a
//  click, run by a DSP placed first in the playback chain. Every seek
//  flushes foobar2000's output, which is a gap, so the engine does them
//  inside the stream instead.
//
//  It keeps the audio of the current track in one buffer: the last
//  kHistorySeconds behind the point it plays from, and whatever the decoder
//  delivered ahead of it. While audio passes untouched ("live") the input
//  goes straight out and only feeds the history. A loop, a jump back, a
//  move or a new length is a splice inside the buffer, crossfaded over
//  kFadeSeconds so it does not click. While it plays from the buffer it
//  sends out a quantum per block of decoded audio, so the decoder runs
//  ahead (the loop can move forward into that audio) but not without end;
//  after a loop it catches up at twice the decoder's pace and goes live.
//
//  With a reserve set it keeps that much decoded audio ahead while no
//  change is expected, so a forward jump within it is a splice too: a
//  second after a sync it plays from the buffer and lets the decoder run
//  ahead at twice its pace until the reserve is there, then holds it. After
//  a track change behind the buffer it catches up first, outside a loop,
//  whatever the reserve and hovering or not, and builds it again on the
//  new track. A cap bounds the audio waiting, the reserve's and hovering's
//  alike: towards a track's end the view lowers it, the audio waiting
//  drains, and the change to the next track happens live (short steps in
//  a loop go on whatever the cap). A change while the audio passes
//  through starts over on the new track and ends a loop waiting behind
//  playback; one behind the buffer ends it once the old track's audio is
//  out. Every track or format change in the audio held after a change
//  behind the buffer (a short track can be whole in it) gets a timeline
//  segment where its first frame goes out.
//
//  Track times come from a sync: a seek of the view's own (its target is
//  frame 0), the view's measurement of foobar2000's position while the
//  audio is untouched, or a gapless track change (time 0). Without one the
//  engine passes audio through and turns requests down; the view then seeks.
//  It turns them down too once the next track's audio goes out after a
//  change behind the buffer, until it is live on the new track (the old
//  track's buffer would judge them).
//
//  The engine logs what the output plays (a timeline in output seconds
//  since the seek), so the view maps the audible time to a track position.
//
//  Single-threaded: the DSP calls it on the playback thread and applies the
//  view's requests between blocks. Header-only, tested standalone.
//

#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <vector>

namespace waveseek {

// From `first` seconds of output since the seek on, the output plays track
// time `from` onward, or a loop starting at `from`, `loop` seconds long,
// `offset` seconds into it at `first`
struct LoopSegment {
    double first = 0.0;
    double from = 0.0;
    double loop = 0.0;      // 0: straight on
    double offset = 0.0;
};

// The track time playing `output` seconds after the seek; NAN without a timeline
inline double trackTimeAt(const std::vector<LoopSegment> &timeline, double output) {
    if (timeline.empty() || !(output >= 0.0)) return NAN;
    const LoopSegment *segment = &timeline.front();
    for (const LoopSegment &s : timeline) {
        if (s.first <= output) segment = &s;
        else break;
    }
    const double into = output - segment->first;
    if (!(segment->loop > 0.0)) return segment->from + into;
    return segment->from + std::fmod(segment->offset + into, segment->loop);
}

// What the view asks for, in track seconds
struct LoopAction {
    enum Kind { Loop, Resize, Move, Jump, Exit };
    Kind kind = Loop;
    uint64_t id = 0;
    double start = 0.0;     // Loop, Move: the loop's start
    double end = 0.0;       // Loop, Move, Resize: its end
    double to = NAN;        // Loop: where to play from (NAN: on from where it is); Jump: the target
    // Loop with `to` and `by` NAN: past the loop's end already, go into it
    // as far as its length goes (the beat holds), instead of letting it wait
    bool keepPhase = false;
    // Jump, Loop: play from this much from what plays when it is taken
    // (NAN: from `to`); relative, so the beat holds however late it is taken
    double by = NAN;
    // Jump, Loop: play from `to` in phase: from the place nearest `to` at
    // the same place within its beat as what plays when it is taken (a grid
    // of `beat` seconds through `beatAnchor`), so it keeps the beat without
    // waiting for one, however late it is taken (at most half a beat from `to`)
    double beat = 0.0;
    double beatAnchor = 0.0;
    // In phase onto the grid `to` is on, when that is another (a tempo
    // change, a section off the beats of what plays): the place within the
    // beat comes from what plays on (beat, beatAnchor), the landing is on
    // this grid. toBeat 0: the same grid as beat and beatAnchor.
    double toBeat = 0.0;
    double toBeatAnchor = 0.0;
};

// A seek of the view's own: the first frame after it is `target`; `then`
// applies once the first audio after it arrives, from its `to` (its `by`
// and beat are ignored: what plays then is the seek's target, not the
// audio it was made against)
struct LoopArm {
    uint64_t id = 0;
    double target = 0.0;
    std::optional<LoopAction> then;
};

template <typename Sample>
class LoopEngine {
public:
    struct Block {
        std::vector<Sample> samples;
        unsigned channels = 0;
        unsigned rate = 0;
        unsigned config = 0;    // the channel layout, carried through

        size_t frames() const { return channels ? samples.size() / channels : 0; }
    };

    static constexpr double kHistorySeconds = 40.0;
    static constexpr double kFadeSeconds = 0.005;
    // Output per block of decoded audio while playing from the buffer: it
    // adds to the delay before a request is heard (the next block comes when
    // the output has taken this much), and sets how fast the decoder runs
    // ahead (a block per quantum). While a change may come (responsive) a
    // short fixed step, whatever the block size, until kResponsiveAheadSeconds
    // are waiting; otherwise a long step in a loop and catching up outside
    // one. Past kMaxAheadSeconds of decoded audio waiting the loop ends.
    static constexpr double kResponsiveQuantumSeconds = 0.03;
    static constexpr double kResponsiveAheadSeconds = 120.0;
    static constexpr double kIdleQuantumSeconds = 1.0;
    static constexpr double kMaxAheadSeconds = 300.0;
    // The reserve: it builds only after this much output passed live since a
    // sync (the view measures its clock while the output is the input), and
    // past this much over it the audio waiting drains back towards it
    static constexpr double kReserveSettleSeconds = 1.0;
    static constexpr double kReserveSlackSeconds = 5.0;

    void setResponsive(bool on) { responsive_ = on; }

    // Decoded audio to keep ahead while no change is expected (not
    // responsive), at most kResponsiveAheadSeconds; 0 (the default) passes
    // the audio through whenever it can
    void setReserveSeconds(double seconds) {
        reserve_ = std::isfinite(seconds) ? std::clamp(seconds, 0.0, kResponsiveAheadSeconds) : 0.0;
    }

    // At most this much decoded audio waiting, for the reserve and while
    // responsive alike; above it the audio waiting drains (catching up, half
    // a second per second played). Towards a track's end the view lowers it
    // to 0, so the decoder does not cross into the next track early and the
    // change happens live. INFINITY or NAN (the default): no cap but
    // kResponsiveAheadSeconds. Playback in a loop keeps its short steps and
    // its own limit (kMaxAheadSeconds).
    void setAheadCapSeconds(double seconds) {
        aheadCap_ = std::isnan(seconds) ? INFINITY : std::max(0.0, seconds);
    }

    // Crossfade length at a splice; 0 splices hard (the tests)
    void setFadeSeconds(double seconds) { fadeSeconds_ = std::max(0.0, seconds); }

    // A seek: everything goes; `arm`, when it is the view's own, syncs it
    void flush(const LoopArm *arm) {
        ++epoch_;
        buf_.clear();
        tail_.clear();
        tailSeconds_ = 0.0;
        timeline_.clear();
        channels_ = rate_ = config_ = 0;
        bufStart_ = pos_ = 0;
        inFrames_ = 0;
        outSeconds_ = 0.0;
        liveFrames_ = 0;
        live_ = pristine_ = true;
        looping_ = engaged_ = afterBoundary_ = tailStarted_ = false;
        fadeLeft_ = 0;
        synced_ = false;
        pending_.reset();
        if (arm) {
            synced_ = true;
            t0_ = arm->target;
            boundArmId_ = arm->id;
            timeline_.push_back({ 0.0, t0_, 0.0, 0.0 });
            pending_ = arm->then;
        }
        ++version_;
    }

    // The view's measurement: frame 0 after the seek that began `epoch` is
    // track time `t0`. Taken only while the audio is untouched.
    void sync(uint64_t epoch, double t0) {
        if (epoch != epoch_ || synced_ || !pristine_) return;
        synced_ = true;
        t0_ = t0;
        timeline_.assign(1, { 0.0, t0, 0.0, 0.0 });
        liveFrames_ = 0;
        ++version_;
    }

    // A request between blocks; false when the audio for it is not here
    // (the view seeks instead)
    bool act(const LoopAction &a) {
        lastActionId_ = a.id;
        const bool ok = apply(a, false);
        if (!ok) rejectedId_ = a.id;
        ++version_;
        return ok;
    }

    // One block in. Returns true when it goes out untouched; else what to
    // play is appended to `out` (possibly nothing yet)
    bool process(const Sample *data, size_t frames, unsigned channels, unsigned rate, unsigned config, bool newTrack,
                 std::vector<Block> &out) {
        if (frames == 0 || channels == 0 || rate == 0) return true;
        if (channels_ == 0) {
            channels_ = channels;
            rate_ = rate;
            config_ = config;
            bufStart_ = pos_ = inFrames_;
        }
        const bool newFormat = channels != channels_ || rate != rate_;
        typename Held::Starts starts = Held::Nothing;
        if ((newTrack || newFormat) && !afterBoundary_) {
            if (live_) {
                // In step with the decoder (never with a loop engaged or
                // ahead, see emit and moveTo): a loop waiting behind
                // playback ends, as the new track ends it in the view; its
                // frames are the old buffer's
                looping_ = engaged_ = inLoopSegment_ = false;
                startOver(channels, rate, config, newTrack);
            } else {
                // A loop playing that ends past the track's last frame (its
                // reported length can be an estimate) can never wrap: the
                // rest of the track and then the new one play on
                if (looping_ && engaged_ && loopEnd_ > bufEnd()) exitLoop();
                afterBoundary_ = true;
                boundaryIsTrack_ = newTrack;
                boundaryFrame_ = inFrames_;
                starts = newTrack ? Held::Track : Held::Format;
            }
        } else if (afterBoundary_ && (newTrack || channels != tailChannels_ || rate != tailRate_)) {
            // Another change inside the audio held (a short track can be
            // whole in it): its own segment where it goes out, as the first
            // one's; the last one decides the time after the audio held
            boundaryIsTrack_ = newTrack;
            if (newTrack) boundaryFrame_ = inFrames_;
            starts = newTrack ? Held::Track : Held::Format;
        }
        if (afterBoundary_) {
            Held h;
            h.block.channels = channels;
            h.block.rate = rate;
            h.block.config = config;
            h.block.samples.assign(data, data + frames * channels);
            h.starts = starts;
            tail_.push_back(std::move(h));
            tailSeconds_ += static_cast<double>(frames) / rate;
            tailChannels_ = channels;
            tailRate_ = rate;
            tailConfig_ = config;
        } else {
            buf_.insert(buf_.end(), data, data + frames * channels);
        }
        inFrames_ += static_cast<int64_t>(frames);
        if (pending_) {
            const LoopAction a = *pending_;
            pending_.reset();
            lastActionId_ = a.id;
            if (!apply(a, true)) rejectedId_ = a.id;
            ++version_;
        }
        // While a change may come, play from the buffer in short steps even
        // with nothing changed, so a request is taken within a step rather
        // than a whole block (the decoder runs ahead meanwhile; the output is
        // still the input, so nothing is heard). With a reserve, likewise
        // once the output has passed live for a while since the sync. Both
        // within the cap: at 0 it passes the audio through. In a loop the
        // short steps go on whatever the cap (it bounds the audio waiting so
        // that it drains and goes live, which a loop does not)
        const double reserve = std::min(reserve_, aheadCap_);
        const double responsiveAhead = std::min(kResponsiveAheadSeconds, aheadCap_);
        const bool reserveDue =
            reserve > 0.0 && liveFrames_ >= static_cast<int64_t>(framesFor(kReserveSettleSeconds));
        if (live_ && synced_ && !afterBoundary_ &&
            ((responsive_ && aheadSeconds() < responsiveAhead) || reserveDue)) {
            live_ = false;
            pristine_ = false;
            pos_ = bufEnd() - static_cast<int64_t>(frames);   // this block is next out
        }
        if (live_) {
            pos_ = bufEnd();
            outSeconds_ += static_cast<double>(frames) / rate;
            liveFrames_ += static_cast<int64_t>(frames);
            trim();
            return true;
        }
        const double ahead = aheadSeconds();
        if (looping_ && ahead > kMaxAheadSeconds) exitLoop();
        // Behind the decoder: catch up. After a track change behind the
        // buffer always, outside a loop, hovering or not, so the new track
        // gets its own buffer and time and requests are taken again (short
        // steps would never empty the audio waiting after the change)
        const bool inLoop = looping_ && engaged_;
        const bool catchUp = afterBoundary_ && !inLoop;
        size_t want = 2 * frames;
        if (!catchUp && responsive_ && ahead < (inLoop ? kResponsiveAheadSeconds : responsiveAhead)) {
            want = std::max<size_t>(1, framesFor(kResponsiveQuantumSeconds));
        } else if (inLoop) {
            want = std::max(frames, framesFor(kIdleQuantumSeconds));
        } else if (reserve > 0.0 && !afterBoundary_) {
            // By what waited before this block: short of the reserve, half a
            // block out, so the decoder runs ahead at twice its pace; in it,
            // a block per block; well over it (after a change was expected)
            // or over the cap, catching up drains it back
            const double waiting = ahead - static_cast<double>(frames) / rate;
            if (waiting < reserve) want = std::max<size_t>(1, frames / 2);
            else if (waiting <= reserve + kReserveSlackSeconds && waiting <= aheadCap_) want = frames;
        }
        emit(want, out);
        trim();
        return false;
    }

    // The end of the stream: everything still to play, now
    void endOfStream(std::vector<Block> &out) {
        if (looping_) exitLoop();
        if (!live_) emit(SIZE_MAX / 4, out);
    }

    // What the view reads
    uint64_t version() const { return version_; }
    uint64_t epoch() const { return epoch_; }
    bool synced() const { return synced_; }
    double startTime() const { return t0_; }        // the track time of the first frame after the seek
    bool pristine() const { return pristine_; }     // nothing changed since the seek: the output is the input
    bool live() const { return live_; }
    bool looping() const { return looping_; }
    unsigned rate() const { return rate_; }
    uint64_t boundArmId() const { return boundArmId_; }
    uint64_t lastActionId() const { return lastActionId_; }
    uint64_t rejectedId() const { return rejectedId_; }
    double outSeconds() const { return outSeconds_; }
    double loopStart() const { return timeOf(loopStart_); }
    double loopEnd() const { return timeOf(loopEnd_); }
    double playingFrom() const { return timeOf(pos_); }     // the next frame out, in track time
    double bufferedFrom() const { return timeOf(bufStart_); }
    double bufferedTo() const { return timeOf(bufEnd()); }
    const std::vector<LoopSegment> &timeline() const { return timeline_; }
    // Decoded audio waiting behind the point it plays from, in seconds
    double aheadSeconds() const {
        return (rate_ ? static_cast<double>(bufEnd() - pos_) / rate_ : 0.0) + tailSeconds_;
    }

private:
    int64_t bufEnd() const { return bufStart_ + (channels_ ? static_cast<int64_t>(buf_.size() / channels_) : 0); }
    size_t framesFor(double seconds) const {
        return rate_ && seconds > 0.0 ? static_cast<size_t>(std::llround(seconds * rate_)) : 0;
    }
    int64_t frameOf(double t) const { return static_cast<int64_t>(std::llround((t - t0_) * rate_)); }
    double timeOf(int64_t frame) const { return rate_ ? t0_ + static_cast<double>(frame) / rate_ : 0.0; }
    double secondsOf(int64_t frames) const { return rate_ ? static_cast<double>(frames) / rate_ : 0.0; }
    const float *at(int64_t frame) const { return buf_.data() + static_cast<size_t>(frame - bufStart_) * channels_; }

    Block newBlock() const {
        Block b;
        b.channels = channels_;
        b.rate = rate_;
        b.config = config_;
        return b;
    }

    // In step with the decoder at a new track (or format): a fresh buffer,
    // time 0 for a new track
    void startOver(unsigned channels, unsigned rate, unsigned config, bool newTrack) {
        channels_ = channels;
        rate_ = rate;
        config_ = config;
        buf_.clear();
        bufStart_ = pos_ = inFrames_;
        liveFrames_ = 0;
        synced_ = newTrack;
        if (newTrack) {
            t0_ = -static_cast<double>(inFrames_) / rate_;
            timeline_.push_back({ outSeconds_, 0.0, 0.0, 0.0 });
        }
        ++version_;
    }

    // Where a Jump or a Loop plays from: `by` from what plays, else `to` in
    // phase with what plays, else `to`; none without a finite one. One that
    // comes with a seek (afterBind) plays from `to`: what plays then is the
    // seek's target, not the audio the request was made against.
    std::optional<int64_t> targetOf(const LoopAction &a, bool afterBind) const {
        if (!afterBind && std::isfinite(a.by)) return pos_ + static_cast<int64_t>(std::llround(a.by * rate_));
        if (!std::isfinite(a.to)) return std::nullopt;
        if (!afterBind && std::isfinite(a.beat) && a.beat > 0.0 && std::isfinite(a.beatAnchor)) {
            const double now = (timeOf(pos_) - a.beatAnchor) / a.beat;
            const double phase = now - std::floor(now);
            // Lands on the target's grid (the same one unless toBeat says otherwise)
            const bool other = std::isfinite(a.toBeat) && a.toBeat > 0.0 && std::isfinite(a.toBeatAnchor);
            const double beat = other ? a.toBeat : a.beat;
            const double anchor = other ? a.toBeatAnchor : a.beatAnchor;
            const double at = (a.to - anchor) / beat;
            return frameOf(anchor + (std::round(at - phase) + phase) * beat);
        }
        return frameOf(a.to);
    }

    bool apply(const LoopAction &a, bool afterBind) {
        if (a.kind == LoopAction::Exit) {   // always possible
            if (looping_) exitLoop();
            return true;
        }
        // Once the next track's audio goes out (a change behind the buffer)
        // the buffer is the old track's and the view the new one's: the view
        // seeks instead. Before that the old track still plays from its
        // buffer, which judges a request as ever.
        if (!synced_ || channels_ == 0 || (afterBoundary_ && tailStarted_)) return false;
        switch (a.kind) {
            case LoopAction::Loop: {
                const int64_t s = frameOf(a.start), e = frameOf(a.end);
                if (e <= s || s < bufStart_) return false;
                int64_t to = pos_;
                if (std::isnan(a.to) && (afterBind || !std::isfinite(a.by))) {
                    // On from where it is (before the loop it runs into it,
                    // past it the loop waits, or with keepPhase goes into it)
                    if (a.keepPhase && pos_ >= e) to = s + (pos_ - s) % (e - s);
                } else {
                    const std::optional<int64_t> target = targetOf(a, afterBind);
                    if (!target) return false;
                    to = *target;
                }
                // Right after a seek, playback may start further in once decoded
                if (to < bufStart_ || (!afterBind && to > bufEnd())) return false;
                looping_ = true;
                loopStart_ = s;
                loopEnd_ = e;
                live_ = pristine_ = false;
                moveTo(to);
                return true;
            }
            case LoopAction::Resize: {
                const int64_t e = frameOf(a.end);
                if (!looping_ || e <= loopStart_) return false;
                loopEnd_ = e;
                // Playing in it and past the new end: into it, as far as the
                // loop's length goes
                moveTo(engaged_ && pos_ >= e ? loopStart_ + (pos_ - loopStart_) % (e - loopStart_) : pos_);
                return true;
            }
            case LoopAction::Move: {
                if (!looping_) return false;
                const int64_t s = frameOf(a.start), e = frameOf(a.end);
                if (e <= s) return false;
                // Playing in it: the same place in the moved loop (the end of a
                // pass is the start of the next); outside it, shifted alike
                const int64_t to = engaged_ ? s + (pos_ - loopStart_) % (e - s) : pos_ + (s - loopStart_);
                if (s < bufStart_ || to < bufStart_ || to > bufEnd()) return false;
                loopStart_ = s;
                loopEnd_ = e;
                moveTo(to);
                return true;
            }
            case LoopAction::Jump: {
                // Anywhere held; a loop stays set: inside it plays it, before
                // it runs into it, past it the loop waits
                const std::optional<int64_t> to = targetOf(a, afterBind);
                if (!to || *to < bufStart_ || *to >= bufEnd()) return false;
                live_ = false;
                pristine_ = false;
                moveTo(*to);
                return true;
            }
            case LoopAction::Exit:
                return true;
        }
        return false;
    }

    // Plays on from `to`: a crossfaded splice when it is elsewhere; a new
    // timeline segment either way (the loop may have changed). A splice, or
    // playback in the loop, plays from the buffer: a new length or a move of
    // a loop waiting while the audio passes through may take in what plays.
    void moveTo(int64_t to) {
        if (to != pos_) {
            startFade();
            pos_ = to;
            pristine_ = false;
            live_ = false;
        }
        pushSegment();
        if (engaged_) live_ = false;
    }

    void startFade() {
        fadeFrom_ = pos_;
        fadeTotal_ = fadeLeft_ = framesFor(fadeSeconds_);
    }

    void pushSegment() {
        if (looping_ && pos_ >= loopStart_ && pos_ < loopEnd_) {
            timeline_.push_back({ outSeconds_, timeOf(loopStart_), secondsOf(loopEnd_ - loopStart_),
                                  secondsOf(pos_ - loopStart_) });
            engaged_ = true;
            inLoopSegment_ = true;
        } else {
            timeline_.push_back({ outSeconds_, timeOf(pos_), 0.0, 0.0 });
            engaged_ = false;   // before the loop it engages at the start; past it, not
            inLoopSegment_ = false;
        }
        ++version_;
    }

    void exitLoop() {
        looping_ = engaged_ = inLoopSegment_ = false;
        timeline_.push_back({ outSeconds_, timeOf(pos_), 0.0, 0.0 });
        ++version_;
    }

    // `frames` from the buffer at pos_, crossfading a splice's first frames
    void copyOut(Block &cur, size_t frames) {
        const float *src = at(pos_);
        if (fadeLeft_ == 0) {
            cur.samples.insert(cur.samples.end(), src, src + frames * channels_);
            pos_ += static_cast<int64_t>(frames);
            return;
        }
        for (size_t i = 0; i < frames; ++i) {
            const float *now = at(pos_);
            if (fadeLeft_ > 0) {
                const double w = (static_cast<double>(fadeTotal_ - fadeLeft_) + 0.5) / static_cast<double>(fadeTotal_);
                const bool haveOld = fadeFrom_ >= bufStart_ && fadeFrom_ < bufEnd();
                const float *old = haveOld ? at(fadeFrom_) : nullptr;
                for (unsigned c = 0; c < channels_; ++c) {
                    const double o = old ? static_cast<double>(old[c]) : 0.0;
                    cur.samples.push_back(static_cast<Sample>(o * (1.0 - w) + static_cast<double>(now[c]) * w));
                }
                --fadeLeft_;
                ++fadeFrom_;
            } else {
                cur.samples.insert(cur.samples.end(), now, now + channels_);
            }
            ++pos_;
        }
    }

    void emit(size_t n, std::vector<Block> &out) {
        Block cur = newBlock();
        auto finish = [&] {
            if (!cur.samples.empty()) {
                outSeconds_ += static_cast<double>(cur.frames()) / cur.rate;
                out.push_back(std::move(cur));
            }
            cur = newBlock();
        };
        while (n > 0) {
            if (looping_) {
                if (engaged_ && pos_ >= loopEnd_) {   // a pass ends: back to the start
                    finish();
                    startFade();
                    pos_ = loopStart_;
                    if (!inLoopSegment_) pushSegment();   // the loop's segment covers every pass
                } else if (!engaged_ && pos_ >= loopStart_ && pos_ < loopEnd_) {   // ran into the loop
                    finish();
                    pushSegment();
                }
            }
            const bool loopAhead = looping_ && !engaged_ && pos_ < loopStart_;
            int64_t avail = bufEnd() - pos_;
            if (looping_ && engaged_) avail = std::min<int64_t>(avail, loopEnd_ - pos_);
            if (loopAhead) avail = std::min<int64_t>(avail, loopStart_ - pos_);
            if (avail <= 0) {
                // Waiting for audio: in the loop, or with the loop ahead (it
                // must catch playback as it comes in, which passing the audio
                // through would not)
                if ((looping_ && engaged_) || loopAhead || pos_ < bufEnd()) break;
                finish();
                fadeLeft_ = 0;
                if (afterBoundary_) {                     // caught up: the new track's audio
                    n -= emitTail(n, out);
                    if (!tail_.empty()) break;
                    leaveBoundary();
                    break;
                }
                live_ = true;                             // the next block goes straight out
                break;
            }
            const size_t k = std::min(n, static_cast<size_t>(avail));
            copyOut(cur, k);
            n -= k;
        }
        finish();
    }

    // The audio after a track change, as it came; returns frames sent
    size_t emitTail(size_t n, std::vector<Block> &out) {
        size_t sent = 0;
        while (sent < n && !tail_.empty()) {
            if (!tailStarted_) {
                // The old track's buffer is done: a loop waiting behind
                // playback ends without a segment (its frames and time are
                // that buffer's), so a later Exit, or the limit on the audio
                // waiting, leaves the new track's time alone. One engaged or
                // ahead never gets here (emit waits for it).
                tailStarted_ = true;
                looping_ = engaged_ = inLoopSegment_ = false;
                ++version_;
            }
            Held &held = tail_.front();
            if (held.starts != Held::Nothing) {   // a track (time 0) or a format (time unknown) starts here
                timeline_.push_back({ outSeconds_, held.starts == Held::Track ? 0.0 : NAN, 0.0, 0.0 });
                held.starts = Held::Nothing;
                ++version_;
            }
            Block &front = held.block;
            const size_t k = std::min(n - sent, front.frames());
            Block piece;
            piece.channels = front.channels;
            piece.rate = front.rate;
            piece.config = front.config;
            if (k == front.frames()) {
                piece = std::move(front);
                tail_.pop_front();
            } else {
                piece.samples.assign(front.samples.begin(), front.samples.begin() + static_cast<std::ptrdiff_t>(k * front.channels));
                front.samples.erase(front.samples.begin(), front.samples.begin() + static_cast<std::ptrdiff_t>(k * front.channels));
            }
            const double seconds = static_cast<double>(k) / piece.rate;
            tailSeconds_ -= seconds;
            outSeconds_ += seconds;
            out.push_back(std::move(piece));
            sent += k;
        }
        return sent;
    }

    // All the audio held sent: live on its last track, its frame 0 where
    // that track's segment begins; not synced when a format change came
    // last (frames at two rates do not count the track's time)
    void leaveBoundary() {
        channels_ = tailChannels_;
        rate_ = tailRate_;
        config_ = tailConfig_;
        afterBoundary_ = tailStarted_ = false;
        tailSeconds_ = 0.0;
        buf_.clear();
        bufStart_ = pos_ = inFrames_;
        live_ = true;
        liveFrames_ = 0;
        synced_ = boundaryIsTrack_;
        if (synced_) t0_ = -static_cast<double>(boundaryFrame_) / rate_;
        ++version_;
    }

    // Keeps kHistorySeconds behind what may still be played; drops the rest
    // a few seconds at a time
    void trim() {
        if (!rate_ || !channels_) return;
        int64_t keep = looping_ && engaged_ ? std::min(loopStart_, pos_) : pos_;
        if (fadeLeft_ > 0) keep = std::min(keep, fadeFrom_);
        keep -= static_cast<int64_t>(framesFor(kHistorySeconds));
        const int64_t drop = keep - bufStart_;
        if (drop < static_cast<int64_t>(framesFor(5.0))) return;
        buf_.erase(buf_.begin(), buf_.begin() + static_cast<std::ptrdiff_t>(static_cast<size_t>(drop) * channels_));
        bufStart_ = keep;
    }

    // The current track's audio from frame bufStart_ (frames since the seek);
    // float halves the memory and is below any audible difference
    std::vector<float> buf_;
    int64_t bufStart_ = 0;
    int64_t pos_ = 0;               // the next frame out
    int64_t inFrames_ = 0;          // decoded frames since the seek
    unsigned channels_ = 0, rate_ = 0, config_ = 0;
    double outSeconds_ = 0.0;

    bool synced_ = false;
    double t0_ = 0.0;               // track time of frame 0
    bool live_ = true;
    bool pristine_ = true;
    bool responsive_ = false;
    double reserve_ = 0.0;          // decoded seconds to keep ahead while not responsive
    double aheadCap_ = INFINITY;    // at most this much decoded audio waiting (the reserve, responsive)
    // Output passed live since the last sync (the view's seek or measurement,
    // a track change); the reserve waits for kReserveSettleSeconds of it
    int64_t liveFrames_ = 0;
    bool looping_ = false;
    bool engaged_ = false;          // a loop is set and playback is in it (before it: it engages at the start)
    bool inLoopSegment_ = false;    // the timeline's last segment is the loop's
    int64_t loopStart_ = 0, loopEnd_ = 0;

    int64_t fadeFrom_ = 0;          // the splice's old continuation
    size_t fadeLeft_ = 0, fadeTotal_ = 1;
    double fadeSeconds_ = kFadeSeconds;

    // After a track (or format) change while behind the decoder: its audio,
    // as it came, each block marked with a change its first frame begins
    // (the first block's, and any later track or format inside it)
    struct Held {
        enum Starts { Nothing, Track, Format };
        Block block;
        Starts starts = Nothing;
    };
    bool afterBoundary_ = false;
    bool boundaryIsTrack_ = false;  // the last change held is a track's (else a format's)
    bool tailStarted_ = false;
    int64_t boundaryFrame_ = 0;     // the last track's frame 0
    std::deque<Held> tail_;
    double tailSeconds_ = 0.0;
    unsigned tailChannels_ = 0, tailRate_ = 0, tailConfig_ = 0;

    std::optional<LoopAction> pending_;
    uint64_t epoch_ = 0;
    uint64_t version_ = 0;
    uint64_t boundArmId_ = 0;
    uint64_t lastActionId_ = 0;
    uint64_t rejectedId_ = 0;
    std::vector<LoopSegment> timeline_;
};

} // namespace waveseek
