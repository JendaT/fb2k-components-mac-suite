//
//  StreakWalker.h
//  foo_jl_scrobble_mac
//
//  Pure streak-discovery state machine, extracted from LastFmClient's
//  async traversal so the walk/retry/complete logic is unit-testable.
//  No SDK, no Foundation: the host feeds day-check results and errors,
//  the walker answers with the next action. The host owns networking,
//  timers (rate-limit interval and retry delays), cancellation, and
//  progress/completion callbacks.
//
//  Walk order: today is decided at begin(); every later check is
//  daysBack() days before today, advancing one day per confirmed day
//  until a gap or retry exhaustion. (The pre-extraction code derived
//  the day from daysChecked and double-counted yesterday when the user
//  had not scrobbled today; the walker tracks the next day explicitly.)
//

#pragma once

#include <cmath>

namespace scrobble {

class StreakWalker {
public:
    enum class Action {
        CheckDay,     // check daysBack() days before today, report the result
        Retry,        // re-check the same day after retryDelay() seconds
        GapFound,     // day without scrobbles: streak is final and complete
        Exhausted,    // 3rd consecutive error: stop with partial results
    };

    /// Start the walk. When the user already scrobbled today, today is
    /// day one of the streak; otherwise the streak (if any) ends yesterday.
    /// Either way the first day to CHECK is yesterday.
    Action begin(bool scrobbledToday) {
        m_scrobbledToday = scrobbledToday;
        m_currentStreak = scrobbledToday ? 1 : 0;
        m_daysChecked = scrobbledToday ? 1 : 0;
        m_nextDaysBack = 1;
        m_retryCount = 0;
        return Action::CheckDay;
    }

    /// The day-check succeeded (no transport error)
    Action onDayResult(bool hasScrobbles) {
        m_retryCount = 0;
        m_daysChecked++;

        if (!hasScrobbles) {
            return Action::GapFound;
        }
        m_currentStreak++;
        m_nextDaysBack++;
        return Action::CheckDay;
    }

    /// The day-check failed (network/API error); same day is retried
    /// with exponential backoff, giving up after the 3rd failure
    Action onDayError() {
        m_retryCount++;
        if (m_retryCount >= 3) {
            return Action::Exhausted;
        }
        return Action::Retry;
    }

    /// Days before today of the day to check next (valid after CheckDay/Retry)
    long daysBack() const { return m_nextDaysBack; }

    /// Backoff before re-checking after an error: 2s, then 4s
    double retryDelay() const { return pow(2, m_retryCount); }

    long currentStreak() const { return m_currentStreak; }
    long daysChecked() const { return m_daysChecked; }
    bool scrobbledToday() const { return m_scrobbledToday; }

private:
    bool m_scrobbledToday = false;
    long m_currentStreak = 0;
    long m_daysChecked = 0;
    long m_nextDaysBack = 1;
    int m_retryCount = 0;
};

}  // namespace scrobble
