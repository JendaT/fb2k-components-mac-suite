# Design Review: Tidal Integration for foobar2000 macOS

**Reviewer**: Principal Engineer (Automated)
**Date**: 2026-01-07
**Document Version**: Review 1 (Post first revision)

## Executive Summary

The document has improved substantially from its initial state, with excellent additions around DRM investigation, legal risk assessment, authentication cancellation, and network resilience. The design is now largely implementable. The primary remaining concern is the absence of thread safety specifications for the multi-threaded components, particularly around the metadata cache and session management.

## Critical Issues (Must Fix)

### 1. Thread Safety Model Not Specified
**Location**: Sections 3.4 (StreamCache), 3.8 (MetadataCache), 3.2 (TidalSession)
**Problem**: The document mentions "thread-safe cache using dispatch_queue isolation" for StreamCache but doesn't specify threading models for MetadataCache or TidalSession. The input_decoder runs on playback threads, TidalAPI requests happen on networking threads, and UI updates need main thread dispatch. The interaction model between these isn't defined.
**Impact**: Race conditions, crashes, or data corruption during concurrent operations (e.g., multiple tracks loading metadata simultaneously, token refresh during playback).
**Recommendation**: Add a "3.10 Threading Model" section specifying:
- Which operations happen on which threads/queues
- How shared state (session tokens, caches) is protected
- Main thread requirements for UI updates
- Callback dispatch guarantees for API consumers

### 2. Decoder Resource Lifecycle Unclear
**Location**: Section 3.5 (Input Decoder Implementation)
**Problem**: The `tryResolveAndReopen` method closes and reopens the underlying decoder, but the lifecycle of `m_decoder` isn't specified. When the outer decoder is closed/destroyed, what happens to pending async operations? The `@autoreleasepool` suggests Objective-C bridging but ARC ownership of the decoder reference isn't clear.
**Impact**: Memory leaks or use-after-free if the decoder is destroyed while async operations (like stream resolution) are in flight.
**Recommendation**: Specify:
- Ownership model for `m_decoder` (does it hold a strong reference?)
- Cancellation mechanism for pending stream resolution when decoder closes
- Cleanup sequence in destructor

## Important Improvements (Should Fix)

### 1. Missing Metric Collection for Observability
**Location**: Section 4.4 (Testing Strategy)
**Current**: Testing strategy covers unit, integration, and manual tests.
**Suggested**: Add lightweight metrics collection for post-release observability:
- Authentication success/failure rates
- Stream resolution latency percentiles
- Cache hit rates
- Error type distribution
This doesn't need to phone home—just expose via a debug preference or console command.
**Rationale**: The DRM spike and API access risks mean issues may only surface in production. Without observability, debugging user-reported issues will be difficult.

### 2. Prefetch Logic Has Race Condition Window
**Location**: Section 3.5 (Prefetch Integration)
**Current**: Prefetch triggers at `currentTrackDuration - 30.0` seconds.
**Suggested**: The prefetch check happens in `on_playback_time`, but there's no guard against triggering multiple prefetches if the callback fires multiple times in the last 30 seconds. Add a flag:
```cpp
std::atomic<bool> m_prefetchTriggered{false};
if (time > duration - 30.0 && !m_prefetchTriggered.exchange(true)) {
    prefetchNextTrack();
}
```
Reset the flag when track changes.
**Rationale**: Without this, rapid playback_time callbacks could queue multiple redundant prefetch requests.

### 3. Keychain Access Pattern May Block Main Thread
**Location**: Section 3.2 (Token Storage)
**Current**: Token storage/retrieval uses Keychain, but no threading context is specified.
**Suggested**: Keychain operations can block if keychain is locked or requires user interaction. Specify that Keychain access happens off-main-thread, or document that tokens are cached in memory after first load.
**Rationale**: Blocking main thread on Keychain access causes UI freezes, especially on first launch after reboot.

### 4. No Timeout on Device Code Polling
**Location**: Section 3.2 (Authentication Flow)
**Current**: Polling checks device_code expiry from the RFC 8628 `expires_in` field.
**Suggested**: Also specify maximum polling duration as a safety valve (e.g., 10 minutes) independent of server-provided expiry. Servers can be misconfigured.
**Rationale**: Defense in depth against infinite polling if server returns bad expiry values.

### 5. StreamCache TTL Estimation Needs Validation Strategy
**Location**: Section 3.4 (Stream URL Caching)
**Current**: "Cache stream URLs with TTL (estimated 30-60 minutes based on similar services)"
**Suggested**: Add plan to validate/adjust TTL based on actual 403 response patterns during DRM spike and early testing. Consider starting with conservative 15-minute TTL.
**Rationale**: Incorrect TTL causes either excessive API calls (too short) or playback interruptions (too long). The estimate is speculative.

### 6. Error Enum Values Have Gap
**Location**: Section 3.9 (Error Types)
**Current**: Error codes jump from 2 to 10, 10 to 20, 20 to 30, etc.
**Suggested**: Document that gaps are intentional for future expansion, or compact the enum. As-is, a reader might think there are missing error types.
**Rationale**: Clarity for future maintainers.

## Minor Suggestions (Consider)

- Section 3.6 (Browser UI): Consider adding keyboard shortcut documentation (Space to play/pause, Cmd+F for search focus) in the implementation, not just the design doc.

- Section 3.7 (Playlist Sync): The Swift code for `TreeNode` is inconsistent with the rest of the codebase which uses Objective-C++. Either note this is pseudocode or align with actual implementation language.

- Section 4.3 (Dependencies): Consider listing minimum macOS version requirement (e.g., macOS 12+ for async/await if used, or 10.15+ for Combine).

- Section 5.5 (DRM Considerations): The decision matrix could include a timeline—if DRM investigation takes longer than 2 days, what's the escalation path?

- Appendix (API Endpoints): Consider adding expected response shapes for critical endpoints to reduce ambiguity during implementation.

## Open Questions

- What happens if a user has multiple Tidal accounts and wants to switch? Is there a "switch account" flow or must they logout/login?

- The document mentions `%tidal_error%` metadata field—is this ephemeral (cleared on retry) or persistent (stays until track is removed from playlist)?

- For the plorg integration via NotificationCenter: what happens if plorg isn't installed? Does the Tidal component check for observer presence or just fire-and-forget?

- The retry configuration (1s initial, 60s max, 5 retries) sums to potentially 127 seconds of retrying. Is this acceptable UX, or should there be a user-visible indicator during retry?

## Positive Observations

- **DRM Spike Requirement**: Making this a blocker before implementation is exactly right. This could save weeks of wasted effort.

- **Legal Risk Assessment**: The risk matrix with likelihood/impact/mitigation is professional-grade documentation. The contingency plan for API blocking is thoughtful.

- **Stream Re-resolution Flow**: The detailed `tryResolveAndReopen` implementation with position tracking shows this edge case was carefully considered.

- **Authentication Cancellation**: The state machine with explicit cancelled state and cleanup is well-designed.

- **Config Migration Strategy**: The versioned migration with fallthrough pattern is a proven approach that will prevent future headaches.

- **Phase Breakdown**: Clear progression from MVP through advanced features allows shipping value early.

- **Network Resilience Section**: The state diagram for network interruption behavior is clear and the retry parameters are reasonable.

## Verdict

[x] **Conditionally Ready** — Can proceed if important issues are addressed

The critical threading model issue should be addressed before implementation begins, as retrofitting thread safety is significantly harder than designing it in. The decoder lifecycle issue should be clarified at minimum in code comments during Phase 1. The important improvements can be addressed during implementation but should be tracked.

---
## Incorporation Footer

**Processed**: 2026-01-07
**By**: Main agent (iteration 2)

### Actions Taken

**Critical Issues:**
- Thread Safety Model: Added Section 3.10 "Threading Model" with complete thread context table, dispatch queue isolation patterns, session token management, and callback dispatch guarantees
- Decoder Resource Lifecycle: Added lifecycle management code with atomic flags, destructor cleanup, and cancellation mechanism for pending operations

**Important Improvements:**
- Observability: Added Section 4.5 "Observability & Metrics" with JLTidalMetrics class, console command, and debug logging
- Prefetch Race Condition: Fixed with atomic test-and-set pattern and reset on new track
- Keychain Threading: Documented in threading model - cached in memory after first load, accessed off-main-thread
- Auth Polling Timeout: Added 10-minute safety valve independent of server expiry
- StreamCache TTL: Added validation strategy with conservative 15-minute initial TTL and adaptive adjustment
- Error Enum Gaps: Added comment documenting intentional spacing for future expansion

**Minor Suggestions:**
- Noted Swift code in plorg section is pseudocode (actual implementation in Obj-C++)
- Deferred: macOS version requirement, DRM spike escalation timeline, API response shapes

**Open Questions Resolved:**
- Account switching: logout/login required
- Error field persistence: ephemeral, cleared on success
- plorg dependency: fire-and-forget notifications
- Retry UX: spinner with "Reconnecting..." text
