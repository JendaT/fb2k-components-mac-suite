//
//  IntakeDebounce.h
//  foo_jl_intake
//
//  The watcher's debounce window (PLAN.md B4, 3.5), as a pure policy over
//  time points so it is unit-tested with a fake clock.
//
//  A window opens with the first event. It is due `quiet` after the latest
//  event (1 s in production), but never later than `maxWait` after the
//  first one (3 s), so a writer that never pauses (an execute run rewriting
//  many sidecars) still gets a reload every few seconds instead of none
//  until it stops. When the window fires it closes; the next event opens a
//  new one.
//
//  With FSEvents' 0.5 s latency, a single sidecar write reaches the loader
//  about 1.5 s after it happened, and the colours change about 2 s after it
//  (PLAN.md 1: "Colours update by themselves about 2 s after a change").
//
//  The caller arms one timer at due() when add() opens a window, and calls
//  fire() when it goes off: false means the due time moved later (more
//  events came), so it re-arms at due().
//
//  Thread-safety: none; one owner (the watcher's queue).
//

#pragma once

#include <chrono>

namespace intake {

class DebounceWindow {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;
    using Duration = Clock::duration;

    // Production values.
    static constexpr double kQuietSeconds = 1.0;
    static constexpr double kMaxWaitSeconds = 3.0;

    DebounceWindow(Duration quiet, Duration maxWait);
    DebounceWindow(double quietSeconds = kQuietSeconds, double maxWaitSeconds = kMaxWaitSeconds);

    // One event at `now`. True when it opened the window (arm the timer).
    bool add(TimePoint now);
    // A window is open.
    bool pending() const { return pending_; }
    // When the open window is due (meaningless when none is open).
    TimePoint due() const;
    // The timer went off at `now`. True when the window was due: it closes
    // and the batch goes out. False when none is open or it is not due yet.
    bool fire(TimePoint now);
    // Closes the window without firing.
    void reset() { pending_ = false; }

private:
    Duration quiet_;
    Duration maxWait_;
    bool pending_ = false;
    TimePoint first_{};
    TimePoint last_{};
};

} // namespace intake
