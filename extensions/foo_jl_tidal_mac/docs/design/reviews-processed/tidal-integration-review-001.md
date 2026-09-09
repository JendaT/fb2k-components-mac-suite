# Design Review: Tidal Integration for foobar2000 macOS

**Reviewer**: Principal Engineer (Automated)
**Date**: 2026-01-07
**Document Version**: Initial Draft

## Executive Summary

This is a well-structured and comprehensive design document that demonstrates strong familiarity with the existing codebase patterns (Cloud Streamer, Scrobbler, plorg). The design is technically sound for the controllable aspects. However, **the single biggest concern is the unresolved DRM situation** - the document acknowledges HiFi+ content may require Widevine but doesn't provide a clear decision framework or fallback plan, which could render the entire integration value proposition questionable if HiFi streaming fails.

## Critical Issues (Must Fix)

### 🔴 Issue 1: DRM Strategy is Underspecified
**Location**: Section 5.5 (DRM Considerations), Section 7 (Open Questions)
**Problem**: The document defers DRM investigation to "during implementation" but DRM is a go/no-go blocker for the core value proposition. Many Tidal users subscribe specifically for lossless/HiFi quality - if that tier is DRM-protected and unplayable, the integration loses significant value.
**Impact**: Could result in significant wasted development effort if DRM blocks HiFi playback. Users may abandon the feature if limited to AAC 320k when they're paying for HiFi subscriptions.
**Recommendation**: Before proceeding to implementation:
1. Conduct a spike investigation (1-2 days) to test actual API responses for HiFi content
2. Document the decision matrix: If DRM present → fallback to High quality with clear user messaging, or investigate official SDK partnership
3. Add to MVP acceptance criteria: "Define supported quality tiers with documented limitations"

### 🔴 Issue 2: API Access Legitimacy Unresolved
**Location**: Section 7 (Open Questions), Section 2 (Background)
**Problem**: The document references using "discovered credentials" (from python-tidal/Tidal-Media-Downloader) but doesn't address the legal/ToS implications. Using unofficial API keys could result in API key revocation, breaking the integration for all users.
**Impact**: Tidal could revoke API access at any time, causing a complete feature outage with no recourse. This also exposes the project to potential legal risk.
**Recommendation**:
1. Add a "Legal & API Access" section explicitly addressing this risk
2. Investigate official developer program at developer.tidal.com
3. Define a contingency plan if API keys are revoked
4. Consider whether this feature should be labeled as "experimental/unofficial" to set user expectations

### 🔴 Issue 3: Stream Expiration Handling During Seek is Race-Prone
**Location**: Section 3.5 (Input Decoder Implementation)
**Problem**: The `run()` implementation catches `exception_io_denied` and attempts re-resolution, but the code pattern shown doesn't properly handle concurrent seek operations or gapless playback. The `m_lastPosition` variable is set but the seek-to-position logic after re-resolution isn't shown.
**Impact**: Could cause audio glitches, position loss, or crashes during stream URL expiration events, especially for long tracks or continuous playback sessions.
**Recommendation**:
1. Show the complete re-resolution flow including position restoration
2. Address thread safety for `m_lastPosition` (currently not atomic)
3. Consider prefetch strategy mentioned in 5.3 but not integrated into decoder design
4. Reference how Cloud Streamer's `tryReopen()` handles this (the existing code is available as a pattern)

## Important Improvements (Should Fix)

### 🟡 Issue 1: Missing Graceful Degradation for Network Issues
**Location**: Section 5.2 (Error Handling), Section 5.1 (Edge Cases)
**Current**: Network disconnection handling says "Pause playback, retry with backoff" but there's no detail on buffering strategy or offline resilience.
**Suggested**:
- Define minimum buffer size before playback starts (e.g., 10 seconds)
- Specify behavior when buffer drains during network interruption
- Consider pre-buffering next track (referenced in 5.3 but not integrated into decoder flow)
**Rationale**: Network reliability is unpredictable; users expect audio apps to handle brief interruptions gracefully without stopping playback.

### 🟡 Issue 2: Playlist Organizer Integration Details Missing
**Location**: Section 3.7 (Playlist Synchronization)
**Current**: The YAML example shows a `synced: tidal` flag but doesn't explain how the TreeNode model (which has only `TreeNodeTypeFolder` and `TreeNodeTypePlaylist`) would be extended.
**Suggested**:
- Define whether plorg modifications are needed (new node type? metadata on existing type?)
- Specify the inter-component communication mechanism (notifications? delegate pattern?)
- Address whether this requires plorg versioning/migration
**Rationale**: The existing TreeNode class (reviewed in codebase) has no concept of sync sources. This integration point needs explicit design.

### 🟡 Issue 3: No Cancellation Propagation in Auth Flow
**Location**: Section 3.2 (Authentication Flow)
**Current**: Polling for device code approval is described but cancellation isn't addressed in detail.
**Suggested**:
- Specify how the polling loop respects user cancellation
- Define timeout for the entire device code flow (RFC 8628 specifies `expires_in`)
- Address what happens if user closes preferences during auth
**Rationale**: Existing LastFmAuth has `cancelAuthentication` method; Tidal auth should match this pattern with clear state machine transitions.

### 🟡 Issue 4: Testing Strategy Absent
**Location**: Throughout document
**Current**: No mention of how this will be tested.
**Suggested**: Add a testing section covering:
- Unit test strategy for TidalAPI, caching, URL parsing
- Integration test approach (mock API vs. real API with test account)
- Manual test plan for auth flows, playback, error scenarios
- How to test without a Tidal subscription
**Rationale**: Complex integrations with external APIs are notoriously difficult to test. Without a strategy, regression risk is high.

### 🟡 Issue 5: Configuration Migration Not Addressed
**Location**: Section 4.4 (Configuration Options)
**Current**: Lists config options but doesn't address versioning or migration.
**Suggested**: Define how config format changes will be handled in future versions (e.g., user upgrades from 1.0 to 2.0 with changed settings schema).
**Rationale**: The existing components use fb2k::configStore which has limited migration support. This should be considered upfront.

## Minor Suggestions (Consider)

- **Section 3.1**: The proposed directory structure is comprehensive but consider whether `TidalAuthService` and `TidalAuthView` could be consolidated - the pattern in LastFmAuth combines both.
- **Section 3.3**: URL detection functions use `NSString*` but the codebase shows preference for `std::string` in core logic with ObjC at boundaries. Consider consistency with Cloud Streamer's `URLUtils`.
- **Section 3.6**: The browser panel mockup shows emoji icons - the project CLAUDE.md explicitly forbids emoji in code. Use SF Symbols or custom assets instead.
- **Section 3.8**: The metadata mapping table could include `%codec%` for quality transparency in playlist columns.
- **Appendix**: The API endpoint reference would benefit from documenting required vs. optional query parameters.

## Open Questions

- ❓ How will this integration interact with existing Cloud Streamer URLs in mixed playlists? Is there potential for URL scheme collision?
- ❓ What happens when a user's Tidal subscription expires mid-session? The document mentions "subscription downgrade" but not full expiration.
- ❓ Has the prefetch strategy (mentioned in 5.3) been proven in Cloud Streamer? If not, it may add untested complexity.
- ❓ For Phase 3 two-way sync, what's the conflict resolution model when both Tidal and foobar2000 modify the same playlist offline?
- ❓ Will the component auto-disable itself if Tidal API becomes unavailable, or will it spam errors?

## Positive Observations

- ✅ **Strong codebase familiarity**: The design correctly references existing patterns from Cloud Streamer (StreamCache, input_decoder), Scrobbler (Keychain, OAuth), and plorg (TreeModel), demonstrating that the author has studied the codebase.
- ✅ **Appropriate phasing**: The 5-phase breakdown is pragmatic, with MVP focused on core playback before adding complexity like two-way sync or facets integration.
- ✅ **Thorough error taxonomy**: The `JLTidalError` enum covers a comprehensive set of error conditions including region restrictions and DRM.
- ✅ **Non-goals are clearly stated**: Explicitly calling out DRM bypass, downloading, and Tidal Connect as out-of-scope prevents scope creep.
- ✅ **API reference in Appendix**: Having the endpoint reference and quality mapping tables is useful for implementers.
- ✅ **Rate limiting awareness**: The document shows understanding of API constraints (429 handling, random jitter) that many streaming integrations overlook.

## Verdict

[ ] 🔴 **Not Ready** — Critical issues must be addressed before implementation
[X] 🟡 **Conditionally Ready** — Can proceed if important issues are addressed
[ ] 🟢 **Ready** — Approved for implementation with minor suggestions optional

---

**Condition for approval**: Before beginning Phase 1 implementation:
1. Complete a 1-2 day DRM investigation spike and document findings
2. Make a clear decision on API access approach (official vs. unofficial) with documented risk acceptance
3. Add a testing strategy section

The design is solid architecturally and shows good judgment in leveraging existing patterns. The primary concern is proceeding with significant development effort before validating that the core use case (HiFi streaming) is technically achievable.

---
## Incorporation Footer

**Processed**: 2026-01-07
**By**: Main agent (iteration 1)

### Actions Taken

**Critical Issues:**
- DRM Strategy: Added comprehensive Section 5.5 with pre-implementation spike requirement, decision matrix, and fallback strategy
- API Access Legitimacy: Added new Section 5.6 "Legal & API Access" with risk assessment, mitigation strategies, and contingency plan
- Stream Expiration Handling: Expanded Section 3.5 with complete `tryResolveAndReopen()` implementation, thread-safe position tracking, and prefetch integration

**Important Improvements:**
- Network Resilience: Added Section 5.2 with buffering strategy, retry configuration, and prefetch for gapless playback
- Playlist Organizer Integration: Expanded Section 3.7 with TreeNode model extension, YAML format changes, and inter-component communication patterns
- Auth Flow Cancellation: Added complete auth state machine and polling loop with cancellation support to Section 3.2
- Testing Strategy: Added Section 4.4 with unit tests, integration tests, and manual test plan
- Configuration Migration: Added Section 4.5 with version strategy and migration pattern

**Minor Suggestions:**
- Removed emoji from browser UI mockup, added SF Symbol references
- Added %codec% field to metadata mapping table
- Deferred: Auth service consolidation (keep separate for clarity in initial implementation)
