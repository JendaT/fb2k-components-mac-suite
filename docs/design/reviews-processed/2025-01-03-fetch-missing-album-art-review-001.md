# Design Review: Fetch Missing Album Art

**Reviewer**: Principal Engineer (Iteration 1)
**Date**: 2025-01-03
**Document Version**: Initial Draft

## Executive Summary

This is a well-structured design document with clear problem statement, thoughtful UX flows, and good API research. However, the design has several critical gaps that would block implementation: no specification for ID3 tag embedding (listed as Phase 3 but needs API detail), ambiguous handling of multi-track albums, and the TrackMetadata interface is referenced but never defined. The biggest concern is the undefined save-to-file behavior when the album spans multiple folders.

## Critical Issues (Must Fix)

### 1. TrackMetadata Interface Not Defined
**Location**: Section 3.2 (Search Strategy) and 3.3 (API/Interface)
**Problem**: `TrackMetadata` is used in `searchForArtworkWithMetadata:` and throughout the source providers but is never defined. Implementers won't know what fields to extract or how to populate this structure.
**Impact**: Cannot implement the core search functionality without this definition.
**Suggested Fix**: Add a complete `TrackMetadata` interface definition:
```objc
@interface TrackMetadata : NSObject
@property (readonly) NSString *artist;
@property (readonly) NSString *albumArtist;
@property (readonly) NSString *album;
@property (readonly, nullable) NSString *musicBrainzReleaseID;
@property (readonly, nullable) NSString *musicBrainzReleaseGroupID;
@property (readonly) NSURL *fileURL;  // For determining save location
@end
```

### 2. Multi-Track Album Save Behavior Undefined
**Location**: Section 3.1 (Save Confirmation modal)
**Problem**: The modal shows "Save as file in folder (front.jpg next to files)" but albums can span multiple folders (multi-disc, different encodings). The design doesn't specify which folder, or whether to save to all folders containing the album.
**Impact**: Incorrect implementation could save to wrong location or cause user confusion.
**Suggested Fix**: Specify behavior:
- Option A: Save to the folder of the currently focused track only
- Option B: Save to all folders containing tracks with the same album tag
- Recommend Option A with clear UI indication ("Save to: /path/to/album/")

### 3. "Embed in music file(s)" Scope Unclear
**Location**: Section 3.1 (Save Confirmation modal)
**Problem**: The checkbox says "Embed in music file(s)" with note "(ID3 tag of focused track)" but the plural "(s)" creates ambiguity. Is it just the focused track? All tracks in the album? What about read-only files?
**Impact**: Users expect consistent behavior; implementers need clear requirements.
**Suggested Fix**: Define explicitly:
- "Embed in current track" (single file) - simpler, safer default
- Or add a separate "Embed in all album tracks" checkbox with warning about file modifications
- Document handling of read-only/protected files

### 4. MusicBrainz User-Agent Requirement
**Location**: Section 5.4 (Security) mentions User-Agent requirement but no specification
**Problem**: MusicBrainz requires a specific User-Agent format that identifies the application. Without this, requests will be rejected.
**Impact**: CAA lookups via MusicBrainz will fail.
**Suggested Fix**: Add explicit User-Agent format requirement:
```
User-Agent: foo_jl_album_art_mac/1.0.0 ( contact@example.com )
```

### 5. imageHash Generation Not Specified
**Location**: Section 3.3 (`ArtworkResult.imageHash`)
**Problem**: Property exists for deduplication but no specification of how to generate it. Is it MD5 of image data? perceptual hash? URL hash?
**Impact**: Deduplication will either not work or behave inconsistently across sources.
**Suggested Fix**: Specify algorithm:
- For deduplication during search: SHA-256 of thumbnail data
- Consider perceptual hashing (pHash) for cross-resolution deduplication, but note computational cost

## Important Issues (Should Fix)

### 1. No Cancellation Propagation
**Location**: Section 3.3 (ArtworkFetchController)
**Problem**: The controller has a `cancel` method but the design doesn't specify:
- How cancellation propagates to parallel source providers
- Whether partial results are kept or discarded
- How to handle in-flight HTTP requests
**Suggestion**: Add state diagram showing cancellation flow and specify `NSURLSessionTask` cancellation behavior.

### 2. Rate Limiting Implementation Missing
**Location**: Section 3.2 (NetworkManager)
**Problem**: The architecture shows "Rate limiting per source" but doesn't specify the implementation. The project has `BiographyRateLimiter` (token bucket) that could be reused, but this isn't mentioned.
**Suggestion**: Reference the existing `BiographyRateLimiter` pattern or specify a shared `RateLimiter` in the shared/ directory. Include rate limits per source:
- MusicBrainz: 1 req/sec (strict)
- iTunes: ~20 req/min (soft)
- Deezer: hourly limit (requires tracking)

### 3. Cache Invalidation Not Addressed
**Location**: Section 3.4 (Cache Structure)
**Problem**: Specifies TTL (7 days results, 30 days thumbnails) but doesn't address:
- How to force refresh if user wants to re-search
- How to clear cache for a specific album
- Cache size limits
**Suggestion**: Add cache management strategy including manual clear option and maximum cache size (e.g., 500MB thumbnails).

### 4. Lightbox Keyboard Navigation
**Location**: Section 3.1 (Lightbox Features)
**Problem**: Only mentions Escape to close. Standard lightbox behavior includes arrow keys for navigation, but this isn't specified.
**Suggestion**: Add keyboard navigation: Left/Right arrows for prev/next, Enter/Space for "Use This Image".

### 5. Search Timeout Not Specified
**Location**: Section 5.2 (Error Handling)
**Problem**: Mentions "Network timeout" but doesn't specify duration or per-source vs. aggregate timeout.
**Suggestion**: Specify:
- Per-request timeout: 15 seconds
- Aggregate search timeout: 30 seconds (move on to results even if some sources haven't responded)

### 6. Existing AlbumArtFetcher Collision
**Location**: Section 4.1 (Key Components)
**Problem**: The existing codebase has `AlbumArtFetcher.h` which handles local artwork fetching. The new `ArtworkFetchController` name is close but different. The relationship/integration is unclear.
**Suggestion**: Clarify naming to avoid confusion:
- Rename to `RemoteArtworkFetchController` or `ArtworkSearchController`
- Or document how it integrates with existing `AlbumArtFetcher`

## Minor Issues (Consider)

### 1. iTunes Search API Link Outdated
**Location**: Appendix A
The Apple Music API/iTunes Search API documentation link may redirect. Consider using the direct Search API documentation link.

### 2. TheAudioDB Public Key
**Location**: Appendix A (Tier 2 sources)
Notes "Public key '123'" - this should be clarified as a known test key, not something users should configure.

### 3. NSUserDefaults Key Naming
**Location**: Section 3.4
Keys use dot notation (`artwork.save.toFolder`) which is unconventional for NSUserDefaults. Consider using `ArtworkSaveToFolder` or document why dot notation is preferred.

### 4. JPEG Quality 95%
**Location**: Section 3.4 (File Naming Convention)
95% JPEG quality is quite high. Consider 85-90% for better file size with imperceptible quality loss, or make it configurable.

### 5. Footer Progress Display
**Location**: Section 3.1
The design assumes the album art component has a footer area. This should be validated against the current `AlbumArtView` implementation (which appears to be a simple image view).

## Open Questions

### 1. How does this integrate with the existing AlbumArtFetcher?
The current `AlbumArtFetcher` retrieves local artwork. The design should clarify whether remote fetch results go through this class or bypass it entirely.

### 2. What happens if the user changes tracks while a search is in progress?
Should the search be cancelled? Should results be cached for the original track? This isn't addressed.

### 3. Should downloaded images be cached separately from search results?
The design shows "pending/" for full-res pending save, but what if user dismisses without saving? Is the downloaded full-res image cached for potential reuse?

### 4. How does "Remember choice" interact with multiple albums?
If user selects "Remember and don't ask again" with "Save as file" checked, does this apply to all future saves? Can they ever get the dialog back?

### 5. What's the behavior when Cover Art Archive returns multiple versions?
CAA can return multiple front covers for the same release (vinyl vs CD, regional variations). How are these presented to the user?

## Positive Notes

- The UX flow diagrams are clear and well-thought-out
- Multi-source strategy with tiered authentication is practical
- The API research in Appendix A is thorough and current
- Error handling table covers common scenarios well
- Phased implementation approach allows early value delivery
- Open questions section shows good self-awareness of design gaps
- File naming conventions follow established standards

## Review Summary

| Category | Count |
|----------|-------|
| Critical | 5 |
| Important | 6 |
| Minor | 5 |
| Questions | 5 |

**Recommendation**: REQUEST REVISIONS

The design is fundamentally sound but has several critical gaps that would cause implementation to stall. The most important fixes are:
1. Define the `TrackMetadata` interface
2. Clarify multi-track/multi-folder save behavior
3. Specify the image hash algorithm
4. Add MusicBrainz User-Agent format

Once these critical issues are addressed, this design would be ready for implementation. The architecture is well-considered and the phased approach is appropriate for the scope.

---

## Incorporation Footer

**Processed**: 2025-01-03
**By**: Main agent (iteration 1)

### Actions Taken

**Critical Issues:**
- [x] TrackMetadata Interface Not Defined: Added complete interface with all fields including fileURL, folderURL, and factory method
- [x] Multi-Track Album Save Behavior Undefined: Clarified as "focused track only" with explicit path shown in UI
- [x] "Embed in music file(s)" Scope Unclear: Changed to "Embed in current track" with single file scope
- [x] MusicBrainz User-Agent Requirement: Added full specification with format and implementation code
- [x] imageHash Generation Not Specified: Added SHA-256 algorithm with implementation code

**Important Issues:**
- [x] No Cancellation Propagation: Added cancellation behavior documentation
- [x] Rate Limiting Implementation Missing: Added per-source rate limit table and token bucket reference
- [x] Cache Invalidation Not Addressed: Added cache management section with clear/refresh options
- [x] Lightbox Keyboard Navigation: Added keyboard navigation table
- [x] Search Timeout Not Specified: Added per-request and aggregate timeout specs
- [x] Existing AlbumArtFetcher Collision: Renamed to RemoteArtworkSearchController

**Minor Issues:**
- [ ] iTunes Search API Link: Deferred - link still works
- [ ] TheAudioDB Public Key: Noted in Appendix, acceptable as-is
- [ ] NSUserDefaults Key Naming: Deferred - dot notation is valid
- [ ] JPEG Quality 95%: Deferred - can be revisited during implementation
- [ ] Footer Progress Display: Implementation concern, design assumption documented

**Open Questions Added:**
- Track change during search behavior
- Multiple CAA front covers handling
