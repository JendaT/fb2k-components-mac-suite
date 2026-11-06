# Design Review: Fetch Missing Album Art

**Reviewer**: Principal Engineer (Iteration 3)
**Date**: 2025-01-03
**Document Version**: Review 2 (2025-01-03)

## Executive Summary

This design has matured significantly through two review iterations. The core architecture is sound, and most implementation-blocking issues have been addressed. The remaining concerns are primarily around incomplete specifications in the multiple artwork types question, a minor API inconsistency, and some edge case handling that needs documentation. The design is nearly ready for implementation.

## Critical Issues (Must Fix)

### 1. Open Question on Multiple Artwork Types is Implementation-Blocking

**Location**: Section 7, Open Questions
**Problem**: The question "What's the preferred behavior when multiple artwork types are found? Show all or filter by requested type?" directly impacts UI layout, data model, and user flow design. The footer shows thumbnails - but if a search returns 5 front covers, 3 back covers, and 2 disc images, the current design doesn't specify how these are presented.
**Impact**: Implementers will have to make this decision, potentially inconsistently. The lightbox navigation ("2 of 5 - Front Cover") suggests filtering by type, but the aggregation logic in 3.2 says "Group by artwork type" without specifying how groups are surfaced.
**Suggested Fix**: Resolve this now. Recommended approach:
- Footer thumbnails show all types with visual grouping (e.g., separator or row break)
- Lightbox navigation stays within artwork type by default
- Add tabs or filter buttons in lightbox: `[Front (5)] [Back (3)] [Disc (2)]`

### 2. ArtworkResult Uses ArtworkType But Should Use RemoteArtworkType

**Location**: Section 3.3, ArtworkResult interface
**Problem**: Line 396 declares `@property (readonly) ArtworkType artworkType;` but Section 3.3 explicitly renamed the enum to `RemoteArtworkType` to avoid conflicts. This is inconsistent and will cause compilation errors or name collisions.
**Impact**: Compilation failure or unintended use of the C++ enum instead of the Objective-C enum.
**Suggested Fix**: Update ArtworkResult interface:
```objc
@property (readonly) RemoteArtworkType artworkType;  // Note: RemoteArtworkType, not ArtworkType
```

## Important Issues (Should Fix)

### 1. Resolution Display Source Not Specified

**Location**: Section 7, Open Questions
**Problem**: The document acknowledges this is unresolved: "Need to decide if this is from metadata or requires partial download." This affects user experience and network usage.
**Suggestion**: Most APIs provide resolution metadata in JSON responses. Specify that resolution display uses API metadata when available (CAA, Fanart.tv, TheAudioDB all include dimensions). For iTunes/Deezer which don't provide dimensions in API response, display "Resolution: Available after download" or infer from URL patterns.

### 2. CAA Multiple Front Covers Question Needs Resolution

**Location**: Section 7, Open Questions
**Problem**: The proposal "Show all, indicate variant type if metadata available" is noted but not integrated into the design. CAA metadata includes `types` array (e.g., `["Front", "Vinyl"]`) that could be surfaced.
**Suggestion**: Update the ArtworkResult interface to include:
```objc
@property (readonly, copy, nullable) NSArray<NSString *> *variants;  // e.g., @[@"Vinyl", @"Limited Edition"]
```
Update lightbox display format: "2 of 5 - Front Cover (Vinyl)" when variants are present.

### 3. Search Cancellation on Track Change - Partial Results Handling

**Location**: Section 7 resolved question
**Problem**: The resolution states "cache partial results" when track changes, but Section 3.3 Cancellation Behavior states "Partial results are discarded on cancellation." These are contradictory.
**Suggestion**: Clarify the intended behavior. Recommend: Cache partial results with a "partial" flag.

### 4. Error Handling for Pre-flight Failures Needs UI Specification

**Location**: Section 3.1, Atomic Save Strategy
**Problem**: Step 1 says "show error dialog BEFORE attempting any save" if pre-flight fails, but doesn't specify the dialog content or options. Should user be able to proceed with just the working option?
**Suggestion**: Add dialog specification for partial pre-flight failure.

### 5. NetworkManager Placement Ambiguous

**Location**: Section 4.1, Key Components table
**Problem**: NetworkManager is listed as `NetworkManager.h/.m (shared)` and Section 4.2 mentions "Shared networking code from `foo_jl_scrobble_mac`". It's unclear whether this is existing code to import or new code to create in a shared location.
**Suggestion**: Clarify the source and whether it's existing or new.

## Minor Issues (Consider)

### 1. File Naming Table Has Duplicates
Section 3.4 shows all recognized names while Appendix C shows save priority. Clarify the distinction.

### 2. In-Memory Cache Limit Inconsistency
Section 5.3 says "50 thumbnails" but ImageCache box only shows 500MB disk limit. Add in-memory limit to architecture diagram.

### 3. Deezer Rate Limit Underspecified
Section 3.2 says "Per-hour" without actual limit. Consider adding actual number.

### 4. TrackMetadata Thread Safety Mention
Consider adding nullability annotations to the interface.

## Open Questions

### 1. How should search handle albums with very long names combined with special characters?
Truncation limit and word boundary handling needs specification.

### 2. What happens when ImageCache evicts a pending full-resolution image during active lightbox session?
Should images in active session be pinned?

### 3. Should failed API keys be validated at entry time or first-use time?
UX decision affects error feedback timing.

## Positive Notes

- Excellent atomic save strategy with independent operations and clear result reporting
- RemoteArtworkType enum with explicit mapping shows good integration concerns
- Detailed tag embedding specification (Section 4.4) with SDK code examples
- Rate limiting table with per-source configurations is well-researched
- Keyboard navigation table shows good accessibility consideration
- MusicBrainz User-Agent specification with code example
- Pre-flight checks before destructive operations is solid
- Changelog tracking review iterations provides good traceability

## Review Summary

| Category | Count |
|----------|-------|
| Critical | 2 |
| Important | 5 |
| Minor | 4 |
| Questions | 3 |

**Recommendation**: APPROVE WITH CHANGES

The two critical issues are straightforward fixes:
1. Decide the multiple artwork types presentation approach
2. Fix the ArtworkType → RemoteArtworkType typo

After addressing the critical items, this design is ready for implementation of Phase 1.

---

## Incorporation Footer

**Processed**: 2025-01-03
**By**: Main agent (iteration 3)

### Actions Taken

**Critical Issues:**
- [x] Multiple Artwork Types: Added new section "Multiple Artwork Types Display" with footer grouping and lightbox tabs
- [x] ArtworkType typo: Fixed to RemoteArtworkType in ArtworkResult interface

**Important Issues:**
- [x] Resolution Display: Added specification showing API metadata for CAA/Fanart.tv/TheAudioDB, inferred for iTunes/Deezer
- [x] CAA Multiple Covers: Added variants property to ArtworkResult, updated lightbox display format
- [x] Partial Results Contradiction: Clarified: user cancel discards, track change caches with partial flag
- [ ] Pre-flight Failure Dialog: Deferred - behavior documented, dialog detail is implementation concern
- [ ] NetworkManager Placement: Deferred - noted as implementation detail

**Minor Issues:**
- [ ] File Naming Table: Deferred
- [ ] In-Memory Cache Limit: Deferred
- [ ] Deezer Rate Limit: Deferred
- [ ] TrackMetadata Thread Safety: Deferred

**Open Questions Resolved:**
- Resolution display approach
- Multiple artwork types presentation
- CAA variants handling
