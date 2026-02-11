# Design Review: Tidal Integration for foobar2000 macOS

**Reviewer**: Principal Engineer (Automated)
**Date**: 2026-01-07
**Document Version**: Review 2 (Iteration 3 of 5)

## Executive Summary

This is a well-structured design document that has been substantially improved through two review iterations. The core architecture is sound, leveraging established patterns from the existing Cloud Streamer component. The primary remaining concern is the gap between the design's complexity (particularly the threading model and decoder lifecycle) and the actual implementation simplicity demonstrated in the existing `CloudInputDecoder`. The DRM spike is correctly identified as a prerequisite, but the document could be clearer about what happens if the spike fails.

## Critical Issues (Must Fix)

### Issue 1: Input Decoder Design Diverges Significantly from Working Pattern

**Location**: Section 3.5 (Input Decoder Implementation)

**Problem**: The proposed `tidal_input_decoder` introduces complexity not present in the working `CloudInputDecoder`:
- Atomic `m_closed` flag and separate `close()` method that doesn't exist in the SDK pattern
- Complex position tracking with `m_lastKnownPosition` atomic that may not be necessary
- The callback dispatch guard (`if (decoder->isClosed())`) implies async operations that aren't present in the existing sync model

Looking at the actual `CloudInputDecoder.mm` (lines 90-131), the `tryReopen` implementation is much simpler:
- It doesn't track position or attempt to seek after reopening
- Comment at line 122 explicitly says "Re-initialize at same position would be nice, but just start fresh"
- Single `m_403Retry` boolean prevents infinite loops

**Impact**: An engineer implementing from this design would build something more complex than needed, potentially introducing bugs in the process. The design promises position recovery that the existing component doesn't deliver.

**Recommendation**: Either:
1. Simplify the design to match the actual `CloudInputDecoder` pattern (simpler, tested), or
2. If position recovery is truly required for Tidal (longer tracks?), explicitly mark this as an enhancement over the Cloud Streamer pattern and estimate the additional effort

### Issue 2: Missing input_entry/input_decoder_v2 Registration Details

**Location**: Section 3.5

**Problem**: The design shows the decoder class but omits the critical `input_entry` implementation that actually registers the decoder with the SDK. Looking at `CloudInputEntry` (lines 362-459 in CloudInputDecoder.mm), this includes:
- `is_our_path()` for URL scheme detection
- `open_for_decoding()` / `open_for_info_read()` / `open_for_info_write()`
- GUID registration
- The distinction between `CloudInputDecoder` (full decoder) and `CloudInfoReader` (lightweight for playlist display)

The lightweight info reader is essential for playlist performance - without it, every track in a Tidal playlist would require stream resolution just to display metadata.

**Impact**: An engineer would not know they need to implement `CloudInfoReader` equivalent, leading to poor performance or a second implementation iteration.

**Recommendation**: Add a subsection covering:
- `TidalInputEntry` class with registration
- `TidalInfoReader` for lightweight metadata (from MetadataCache or URL parsing)
- Service factory registration pattern

## Important Improvements (Should Fix)

### Issue 3: plorg TreeNode Extension Shows Swift but Implementation is Obj-C

**Location**: Section 3.7 (Playlist Synchronization)

**Current**: Design shows Swift enum for `TreeNode`:
```swift
enum TreeNode: Codable {
    case folder(name: String, items: [TreeNode], syncSource: SyncSource?)
    ...
}
```

**Suggested**: The actual `TreeNode.h` is Objective-C. Show the extension in the actual implementation language:
```objc
typedef NS_ENUM(NSInteger, TreeNodeSyncSource) {
    TreeNodeSyncSourceLocal,
    TreeNodeSyncSourceTidal,
};

@interface TreeNode : NSObject
// ... existing properties ...
@property (nonatomic, assign) TreeNodeSyncSource syncSource;
@property (nonatomic, copy, nullable) NSString *syncId;  // Tidal UUID
@end
```

**Rationale**: Engineers should see exactly what changes are needed to existing code.

### Issue 4: Stream Cache TTL Strategy Is Over-Engineered for MVP

**Location**: Section 3.4 (TTL Validation Strategy)

**Current**: The design describes adaptive TTL with metrics tracking:
```objc
@interface JLStreamCacheMetrics : NSObject
@property (nonatomic) NSUInteger totalResolves;
@property (nonatomic) NSUInteger cacheHits;
@property (nonatomic) NSUInteger expiredBeforeTTL;
...
```

**Suggested**: For Phase 1, use a simple fixed TTL (like Cloud Streamer's approach):
```objc
static constexpr int kTidalStreamTTL = 15 * 60;  // 15 minutes, conservative
```
Move adaptive TTL to Phase 2 as documented, but remove the implementation details from the core design. The current wording ("Phase 2+") is buried in a comment inside the code block.

**Rationale**: The existing `StreamCache` (lines 36-39) uses fixed TTLs per service. Adaptive TTL is optimization that can wait.

### Issue 5: Missing Error-to-Exception Mapping for SDK Integration

**Location**: Section 3.9 (Error Handling)

**Current**: Defines `JLTidalError` enum but doesn't show how these map to SDK exceptions.

**Suggested**: Add mapping table:
```
JLTidalErrorNotAuthenticated → exception_io_denied
JLTidalErrorTrackUnavailable → exception_io_not_found
JLTidalErrorNetworkError → exception_io_network
JLTidalErrorRateLimited → exception_io_retry (with backoff hint)
JLTidalErrorStreamExpired → exception_io_denied (triggers retry)
```

**Rationale**: The existing `CloudInputDecoder::run()` catches `exception_io` and checks for "403" in the message string (line 227-234). The design should specify which exceptions trigger retry vs. user-visible error.

### Issue 6: Configuration Namespace Collision Risk

**Location**: Section 4.7 (Configuration Options)

**Current**: Uses `tidal_config` namespace with generic function names like `getPreferredQuality()`.

**Suggested**: Use component-prefixed config keys in fb2k::configStore:
```cpp
// Config keys
static const char* kConfigKeyQuality = "tidal.quality";
static const char* kConfigKeyAutoSync = "tidal.playlist.autosync";
static const char* kConfigKeyDebug = "tidal.debug";
```

**Rationale**: foobar2000's configStore is global. Without prefix, "quality" could collide with another component.

## Minor Suggestions (Consider)

- **Section 3.2**: The 10-minute polling safety timeout (`kMaxPollingDuration = 600.0`) is reasonable, but consider noting that RFC 8628 `expires_in` is typically 5-10 minutes, so this is effectively a backstop for malformed responses.

- **Section 3.3**: The `JLTidalURLType` enum and `JLTidalURLType()` function have the same name, which is valid but confusing. Consider `JLParseTidalURLType()` for the function.

- **Section 3.6**: UI mockup mentions SF Symbols but doesn't specify iOS version requirements. SF Symbols 3.0+ requires macOS 12+. Document minimum macOS version.

- **Section 4.4**: Testing strategy mentions "Mock API" integration tests but doesn't specify the mocking approach. Consider: Protocol-based injection, or NSURLProtocol interception?

- **Appendix API Endpoints**: Missing pagination parameters (`limit`, `offset`) that are essential for playlist/album track listing.

## Open Questions

- **Prefetch timing**: The design says prefetch "30s before track ends" (Section 3.5, line 471). Is this appropriate for short tracks (<1 minute)? Should there be a percentage-based fallback?

- **Concurrent stream limits**: Does Tidal enforce a limit on concurrent streams per account? This affects whether the user can have multiple instances/devices playing simultaneously.

- **DASH manifest handling**: Section 3.4 mentions `dash+xml` format but doesn't detail how DASH manifests would be parsed. Is there an existing DASH decoder in foobar2000, or would this require additional implementation?

- **Album art size selection**: Which Tidal image size (80x80, 160x160, 320x320, 640x640, 1280x1280) should be used for different contexts (playlist thumbnail vs. full display)?

## Positive Observations

- **DRM spike as prerequisite**: Correctly identifying this as a blocking investigation before implementation prevents wasted effort. The decision matrix (Section 5.5) with clear actions per outcome is particularly useful.

- **Legal risk acknowledgment**: Section 5.6 honestly addresses the unofficial API access risks and provides concrete mitigation strategies including a contingency plan for API blocking.

- **Threading model documentation**: Section 3.10 provides clear thread context for each operation, which is essential for this multi-threaded component.

- **Leverages existing patterns**: The design correctly references Cloud Streamer for caching, stream resolution, and decoder wrapping patterns. This reduces risk and ensures consistency.

- **Incremental phase breakdown**: The MVP focuses on playback (the core value), with browser and sync features in later phases. This de-risks the DRM unknown.

- **Observable metrics**: Section 4.5 provides diagnostic capabilities without requiring external telemetry, which is appropriate for a desktop application.

## Verdict

[x] **Conditionally Ready** — Can proceed if important issues are addressed

The design is mature and demonstrates thoughtful consideration of edge cases, security, and operational concerns. However, before implementation:

1. **Critical**: Reconcile the input decoder design with the actual working `CloudInputDecoder` pattern, or explicitly justify the additional complexity
2. **Critical**: Add `TidalInputEntry` and `TidalInfoReader` specifications
3. **Important**: Fix the Swift/Obj-C mismatch in plorg integration section

Once these are addressed, an engineer should be able to implement Phase 1 from this document with reasonable confidence.

---

## Incorporation Status

**Incorporated**: 2026-01-07

All feedback from this review has been addressed:

### Critical Issues
- [x] **Issue 1**: Reconciled input decoder with CloudInputDecoder pattern - simplified to use `m_403Retry` boolean, deferred position recovery to Phase 2
- [x] **Issue 2**: Added `TidalInputEntry` and `TidalInfoReader` specifications with service registration

### Important Improvements
- [x] **Issue 3**: Fixed plorg TreeNode to use Objective-C (`JLTreeNodeSyncSource` enum) instead of Swift
- [x] **Issue 4**: Simplified TTL strategy - fixed 15-minute TTL for Phase 1, adaptive TTL deferred to Phase 2
- [x] **Issue 5**: Added error-to-exception mapping table and `translateError()` implementation
- [x] **Issue 6**: Added `tidal.` prefix to all config keys to avoid namespace collision

### Minor Suggestions
- [x] Added RFC 8628 note for polling timeout
- [x] Renamed `JLTidalURLType()` function to `JLParseTidalURLType()`
- [x] Documented macOS 11+ requirement for SF Symbols
- [x] Specified NSURLProtocol mocking approach for integration tests
- [x] Added pagination parameters to API endpoint table

### Open Questions Resolved
- [x] Prefetch timing: percentage-based fallback for short tracks
- [x] Concurrent stream limits: documented as server-enforced, handled by error path
- [x] DASH manifest handling: request BTS format for MVP, defer DASH to Phase 2
- [x] Album art size selection: context-appropriate sizes documented
