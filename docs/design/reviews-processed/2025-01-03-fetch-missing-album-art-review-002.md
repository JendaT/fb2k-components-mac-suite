# Design Review: Fetch Missing Album Art

**Reviewer**: Principal Engineer (Iteration 2)
**Date**: 2025-01-03
**Document Version**: Review 1 (2025-01-03)

## Executive Summary

This design has been significantly improved in Review 1 with added details on rate limiting, cancellation, caching, and the MusicBrainz User-Agent requirement. However, several important gaps remain that would block implementation: the ID3 embedding strategy lacks technical detail, there's no error recovery for partial saves, and the ArtworkType enum conflicts with existing code. The design is close to implementation-ready but needs these issues addressed.

## Critical Issues (Must Fix)

### 1. ArtworkType Enum Conflicts with Existing Code

**Location**: Section 3.3 - ArtworkType Enum

**Problem**: The proposed `ArtworkType` Objective-C enum conflicts with the existing `albumart_config::ArtworkType` C++ enum in `AlbumArtConfig.h`. The existing enum has 5 values (including Icon) while the proposed enum has 6 (including Booklet). The values also don't align:
- Existing: Front=0, Back=1, Disc=2, Icon=3, Artist=4
- Proposed: Front=0, Back=1, Disc=2, Artist=3, Booklet=4, Other=5

**Impact**: Compile-time conflicts, runtime mismatches when mapping between systems, broken artwork type selection.

**Suggested Fix**: Either:
1. Reuse the existing `albumart_config::ArtworkType` and extend it if needed, or
2. Create a clearly distinct type (e.g., `RemoteArtworkType`) with explicit mapping functions to/from the existing enum

### 2. ID3/Tag Embedding Lacks Technical Specification

**Location**: Section 4.3 Phase 3 and Section 3.1

**Problem**: The design mentions "ID3 tag embedding" and "uses appropriate tag format (ID3v2.4 for MP3, Vorbis for FLAC, etc.)" but provides no technical detail. The foobar2000 SDK has specific APIs for writing artwork to files (`album_art_editor` service), and the implementation is non-trivial. No code or interface is specified.

**Impact**: Phase 3 is unimplementable as specified. Tag writing is destructive (modifies user files) and requires careful implementation.

**Suggested Fix**: Add a new section specifying:
- The SDK API to use (likely `album_art_editor_instance`)
- `ArtworkSaveController` interface for tag embedding
- Backup strategy (or explicit note that foobar2000 handles this)
- Supported file formats and limitations

### 3. No Atomic Save / Rollback Strategy

**Location**: Section 3.1 - Save Behavior

**Problem**: Users can select both "Save as file in folder" AND "Embed in music file". If the folder save succeeds but the file embed fails (e.g., file is read-only), there's no rollback. The user ends up with partial state.

**Impact**: Confusing UX where save appears to fail but artwork file exists, or conversely, user thinks it succeeded but embedding didn't happen.

**Suggested Fix**: Define explicit behavior:
1. Attempt all selected operations
2. Report success/failure for each independently in the result dialog
3. Consider a transactional approach: verify both are possible before starting either

## Important Issues (Should Fix)

### 1. RateLimiter Code Duplication

**Location**: Section 3.2 Architecture

**Problem**: The document says "Reuse `RateLimiter` pattern from `shared/` directory" but the codebase shows two separate RateLimiter implementations: `foo_jl_biography_mac/src/Core/RateLimiter.h` (named `BiographyRateLimiter`) and `foo_jl_scrobble_mac/src/Services/RateLimiter.h` (named `RateLimiter`). Neither is in a shared directory.

**Suggestion**: Either:
1. Move one implementation to actual `shared/` and use it, or
2. Create a new `AlbumArtRateLimiter` and document why code sharing isn't feasible, or
3. Update the document to reference the correct source location for copying

### 2. TrackMetadata Interface Mismatch with Existing Patterns

**Location**: Section 3.3 - TrackMetadata

**Problem**: The existing codebase uses `metadb_handle_ptr` directly with `track->get_info(info)` for metadata access (as shown in `AlbumArtFetcher.h`). The proposed `TrackMetadata` wrapper adds indirection. While this is reasonable for Objective-C code, the static factory method `+metadataFromTrack:` implies this is called once and cached, but metadata can change during playback.

**Suggestion**: Add documentation clarifying:
- When `TrackMetadata` should be captured (at search start)
- Whether stale metadata is acceptable (yes, for search purposes)
- Thread safety (is this called on main thread or background?)

### 3. Missing NetworkManager Interface

**Location**: Section 3.2 Architecture and 4.1 Key Components

**Problem**: `NetworkManager` is mentioned as handling HTTP with rate limiting, but no interface is defined. The document claims it's in `shared/` but no `NetworkManager.h/.m` exists in the codebase.

**Suggestion**: Either:
1. Define the `NetworkManager` interface (at least the key methods for HTTP requests with rate limiting), or
2. Clarify that each provider handles its own networking via `NSURLSession` and rate limiting is per-provider

### 4. Deduplication Hash Computed on Thumbnail, Not Full Image

**Location**: Section 3.3 - Image Hash Algorithm

**Problem**: The hash is computed on the 500px thumbnail, but different sources may serve different thumbnail sizes or qualities. Two identical full-res images could have different thumbnail hashes due to different compression or resizing algorithms.

**Suggestion**: Consider:
1. Using perceptual hashing (dHash, pHash) instead of SHA-256
2. Computing hash on the full-resolution image (at save time, not search time)
3. Accept some duplicate display as a minor UX issue vs. complexity trade-off
4. Document the limitation explicitly

### 5. Unresolved Open Question: Track Change During Search

**Location**: Section 7 - Open Questions

**Problem**: The question "What happens if user changes tracks while search is in progress?" has only a proposal, not a resolution. This is a common UX scenario that needs a definitive answer.

**Suggestion**: Mark this as resolved with the proposed behavior (cancel, cache partial, start new search) or document an alternative.

## Minor Issues (Consider)

### 1. File Naming Priority Inconsistency

The file naming table in Appendix C shows `cover.jpg` as priority 1 for front cover, but Section 3.4 shows `front.jpg` first. Align these.

### 2. Cache Directory Location Not Validated

The cache path `~/Library/Application Support/foobar2000-v2/artwork_cache/` assumes foobar2000 v2 app support directory structure. Should confirm this matches actual installation or use a dynamic lookup.

### 3. Missing Offline Mode Detection

Footer states include "Offline" state but the document doesn't specify how offline mode is detected. Consider using `SCNetworkReachability` or similar, and document the detection mechanism.

### 4. Lightbox Escape Key Handling

Keyboard navigation table shows Escape closes lightbox. Should also document behavior if user presses Escape during save dialog (cancel save but keep lightbox? close both?).

### 5. JPEG Quality 95% Justification

Specifies "JPEG quality 95%". This is reasonable but should note the trade-off (higher quality = larger files). Consider making this configurable in Phase 3.

## Open Questions

### 1. What SDK API is used for writing album art to files?

The document mentions tag embedding but doesn't specify the SDK interface. Is `album_art_editor` the correct service? What are its limitations?

### 2. How are compilation albums handled when both artist images and album art are missing?

The document says "Use album artist if available, fall back to first artist" for compilations. But for artist images specifically, should it fetch the primary/first artist or show "Artist images not available for compilations"?

### 3. Is there a plan for handling covers from sources that require attribution?

Some sources may require attribution or have terms of service. The document shows source name in lightbox but doesn't discuss whether attribution needs to be preserved in saved files (EXIF, separate text file, etc.).

### 4. What is the minimum macOS version target?

The design uses `NSURLSession` and modern APIs. Should document minimum supported macOS version to ensure API availability.

## Positive Notes

- The multi-tier source architecture is well-designed, prioritizing no-auth sources first
- The MusicBrainz User-Agent requirement is explicitly documented with implementation code
- Rate limiting table per source is comprehensive and realistic
- The lightbox UX flow is clear and user-friendly
- Cancellation behavior is well-specified with proper cleanup
- The phased implementation approach is pragmatic, deferring OAuth complexity
- Appendices provide excellent reference material for API details

## Review Summary

| Category | Count |
|----------|-------|
| Critical | 3 |
| Important | 5 |
| Minor | 5 |
| Questions | 4 |

**Recommendation**: APPROVE WITH CHANGES

The design is fundamentally sound and well-structured. Address the three critical issues (enum conflict, ID3 specification, atomic save strategy) and this will be ready for implementation. The important issues should be addressed before Phase 2/3 begins at latest.

---

## Incorporation Footer

**Processed**: 2025-01-03
**By**: Main agent (iteration 2)

### Actions Taken

**Critical Issues:**
- [x] ArtworkType Enum Conflicts: Renamed to RemoteArtworkType with explicit mapping function to existing enum
- [x] ID3/Tag Embedding Lacks Specification: Added Section 4.4 with full SDK API, interface, format support table
- [x] No Atomic Save / Rollback Strategy: Added pre-flight check and result reporting dialog specification

**Important Issues:**
- [ ] RateLimiter Code Duplication: Deferred - implementation detail, current reference acceptable
- [x] TrackMetadata Interface: Added usage notes (threading, capture timing, stale data handling)
- [ ] Missing NetworkManager Interface: Deferred - each provider handles own networking
- [ ] Deduplication Hash on Thumbnail: Documented limitation, deferred perceptual hashing
- [x] Track Change During Search: Resolved open question

**Minor Issues:**
- [ ] File Naming Priority: Deferred - minor inconsistency
- [ ] Cache Directory Location: Deferred - implementation concern
- [ ] Offline Mode Detection: Deferred - implementation detail
- [ ] Lightbox Escape Key: Deferred - minor UX detail
- [ ] JPEG Quality: Deferred - can revisit

**Open Questions from Reviewer:**
- SDK API for tag embedding: Answered in Section 4.4
- Compilation artist images: Not resolved (edge case)
- Attribution requirements: Not resolved (low priority)
- Minimum macOS version: Not resolved (needs verification)
