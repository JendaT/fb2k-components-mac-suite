# Design Review: Tidal Integration for foobar2000 macOS

**Reviewer**: Principal Engineer (via Claude Code)
**Review Date**: 2026-01-07
**Document Version**: Iteration 3 complete
**Review Iteration**: 4 of 5

---

## Executive Summary

The design document has matured significantly through three review iterations. The architecture aligns well with established patterns from Cloud Streamer (CloudInputDecoder, StreamCache) and demonstrates solid understanding of foobar2000 SDK patterns. The DRM spike requirement is appropriately positioned as a go/no-go gate. Remaining issues are primarily around code example inconsistencies, a few ambiguous edge cases, and minor gaps in the security model.

---

## Critical Issues (Must Fix)

### 1. Inconsistent Service Factory Pattern in TidalInputEntry

**Location**: Section 3.5, TidalInputEntry code block

**Issue**: The code shows `FB2K_SERVICE_FACTORY(tidal_input_entry)` but CloudInputDecoder uses `service_factory_single_t<CloudInputEntry>`. These are different registration mechanisms.

**Current**:
```cpp
FB2K_SERVICE_FACTORY(tidal_input_entry);
```

**CloudInputDecoder pattern**:
```cpp
static service_factory_single_t<CloudInputEntry> g_cloudInputFactory;
```

**Recommendation**: Use `service_factory_single_t` to match the proven Cloud Streamer pattern. The `FB2K_SERVICE_FACTORY` macro may not exist in the macOS SDK or may have different semantics.

### 2. Missing `initialize()` Method in TidalInputDecoder

**Location**: Section 3.5

**Issue**: The `tidal_input_decoder` class shows `open()`, `run()`, and `seek()` but omits `initialize()` which is required by the SDK and called between `open()` and `run()`. CloudInputDecoder implements this method and stores subsong/flags for use in `tryReopen()`.

**Impact**: Without `initialize()`, the decoder will fail at runtime.

**Recommendation**: Add `initialize()` method following CloudInputDecoder pattern:
```cpp
void initialize(t_uint32 p_subsong, unsigned p_flags, abort_callback& abort) override {
    m_subsong = p_subsong;
    m_flags = p_flags;
    if (m_decoder.is_valid()) {
        m_decoder->initialize(p_subsong, p_flags, abort);
    }
}
```

### 3. Incomplete Error Handling in `tryReopen()`

**Location**: Section 3.5, simplified `tryReopen()` implementation

**Issue**: The simplified version catches `exception_io_denied` in `run()` but the 403 detection pattern in CloudInputDecoder actually checks the error message string for "403" or "Forbidden". The design doc's `exception_io_denied` catch may not trigger for HTTP 403 errors depending on how the underlying HTTP decoder surfaces them.

**CloudInputDecoder actual pattern**:
```cpp
catch (const exception_io& e) {
    const char* msg = e.what();
    if (msg && (strstr(msg, "403") || strstr(msg, "Forbidden"))) {
        if (tryReopen(p_abort)) { ... }
    }
    throw;
}
```

**Recommendation**: Update the design to use the proven string-based detection pattern from CloudInputDecoder, not exception type matching.

---

## Important Improvements (Should Fix)

### 4. Thread Safety Gap in Prefetch Trigger

**Location**: Section 3.5, Prefetch Integration

**Issue**: The prefetch code shows `std::atomic<bool> m_prefetchTriggered` being used with `exchange()`, but the `on_playback_time` callback context isn't specified. If this runs on the main thread and `prefetchNextTrack()` does network I/O, it could block the UI.

**Recommendation**: Explicitly state that `prefetchNextTrack()` must dispatch to a background queue:
```cpp
void prefetchNextTrack() {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [[JLTidalStreamResolver shared] prefetchURL:nextTrackURL];
    });
}
```

### 5. Missing `open_for_info_write` Implementation

**Location**: Section 3.5

**Issue**: The `TidalInputEntry` code block shows `open_for_decoding` and `open_for_info_read` but omits `open_for_info_write`. While Tidal streams are read-only, the method must be implemented to throw an appropriate exception.

**CloudInputDecoder pattern**:
```cpp
void open_for_info_write(service_ptr_t<input_info_writer>& p_instance, ...) {
    pfc::throw_exception_with_message<exception_io_unsupported_format>("Tidal streams are read-only");
}
```

**Recommendation**: Add the method to the design for completeness.

### 6. Keychain Service Name Inconsistency

**Location**: Section 3.2 vs Section 4.7

**Issue**: Section 3.2 specifies Keychain service as `"foobar2000.tidal"`, but Section 4.7 comments reference `"foobar2000.tidal.access"` and `"foobar2000.tidal.refresh"`.

**Clarification needed**: Is the pattern:
- Service: `foobar2000.tidal`, Account: `access_token` / `refresh_token`
- Or Service: `foobar2000.tidal.access` / `foobar2000.tidal.refresh`, Account: username

**Recommendation**: Specify the exact Keychain schema:
```
Service: "com.foobar2000.tidal"
Account (access token): "access_token"
Account (refresh token): "refresh_token"
```

### 7. Rate Limiting Implementation Gap

**Location**: Sections 3.10 and 5.2

**Issue**: The document mentions exponential backoff (20s base, up to 5 minutes) for rate limiting but doesn't specify how this state is tracked across requests. Is there a shared rate limiter, or per-request backoff?

**Recommendation**: Add a `JLTidalRateLimiter` class specification:
```objc
@interface JLTidalRateLimiter : NSObject
@property (nonatomic) NSDate *rateLimitedUntil;
@property (nonatomic) NSInteger consecutiveRateLimits;
- (BOOL)shouldDelay;
- (NSTimeInterval)currentDelay;
- (void)recordRateLimit;
- (void)recordSuccess;
@end
```

### 8. Missing `get_extended_data` Implementation

**Location**: Section 3.5

**Issue**: CloudInputEntry implements `get_extended_data` (empty, but present). The TidalInputEntry design should explicitly mention this for SDK compliance.

---

## Minor Suggestions (Consider)

### 9. Console Logging Verbosity

**Location**: Section 3.5, CloudInputDecoder comparison

**Issue**: CloudInputDecoder has extensive `console::info()` calls for debugging. The Tidal design mentions debug logging but doesn't show the actual log points in the code examples.

**Suggestion**: Add logging calls to code examples for consistency, or reference the "Enable verbose logging" preference clearly.

### 10. URL Scheme Validation Strictness

**Location**: Section 3.3

**Issue**: `JLIsTidalURL` accepts `tidal://` prefix but doesn't validate the path structure. A URL like `tidal://invalid` would pass the check but fail later.

**Suggestion**: Consider stricter validation:
```objc
BOOL JLIsTidalURL(NSString *url) {
    if (![url hasPrefix:@"tidal://"]) return NO;
    JLTidalURLType type = JLParseTidalURLType(url);
    return type != JLTidalURLTypeUnknown;
}
```

### 11. Device Code Expiry Display

**Location**: Section 3.2

**Issue**: The auth flow shows the user code but doesn't mention displaying the time remaining before the device code expires. This is useful UX for long approval flows.

**Suggestion**: Add countdown display in the auth UI: "Code expires in X:XX"

### 12. Subsong Handling Clarification

**Location**: Section 3.5

**Issue**: `get_subsong_count()` returns 1, which is correct for single tracks. But the design doesn't clarify handling for Tidal albums added via `tidal://album/{id}`. Are albums expanded to individual track URLs by the link_resolver, or does the input_decoder handle multi-subsong?

**Suggestion**: Explicitly state that album/playlist URLs are expanded by link_resolver to individual `tidal://track/{id}` URLs, and the input_decoder only handles single tracks.

### 13. Cache Invalidation on Logout

**Location**: Section 5.1, "User logs out" edge case

**Issue**: States "clear caches" but doesn't specify which caches. StreamCache? MetadataCache? ThumbnailCache? All?

**Suggestion**: Be explicit: "Clear StreamCache (stream URLs require re-auth), clear ThumbnailCache, retain MetadataCache (track info remains valid)"

### 14. `tidal.metrics` Console Command Registration

**Location**: Section 4.5

**Issue**: Mentions a `tidal.metrics` console command but doesn't show how it's registered with the foobar2000 console system.

**Suggestion**: Add brief registration pattern or reference to SDK console command API.

---

## Positive Observations

1. **Strong SDK Alignment**: The design correctly follows CloudInputDecoder patterns for `input_entry`, info reader separation, and stream caching. The simplified decoder approach in Phase 1 is pragmatic.

2. **DRM Spike Positioning**: Placing the DRM investigation as a blocker before Phase 1 implementation is the right call. The decision matrix is clear and actionable.

3. **Comprehensive Error Model**: The `JLTidalError` enum with spaced error codes and the error-to-exception mapping table are well thought out.

4. **Thorough Threading Documentation**: Section 3.10 clearly identifies thread contexts and synchronization strategies for each component.

5. **Phased Implementation**: The phase breakdown is realistic, with MVP focused on core playback and progressive enhancement.

6. **Legal Risk Acknowledgment**: Section 5.6 honestly addresses the unofficial API access risks and provides mitigation strategies.

7. **Resolved Open Questions**: The document shows good iteration progress with clear decisions documented (account switching, prefetch timing, DASH handling, etc.).

8. **plorg Integration Design**: The YAML schema extension and NotificationCenter approach for inter-component communication is clean and backward-compatible.

9. **Network Resilience**: The retry configuration and prefetch strategy are well-specified with concrete values.

10. **Observability**: The metrics collection design enables debugging without telemetry, respecting user privacy.

---

## Verdict: **Conditionally Ready**

The design is close to implementation-ready. The three critical issues (service factory pattern, missing `initialize()`, and 403 detection pattern) must be addressed as they would cause runtime failures. The important improvements should be addressed for robustness but are not blocking.

**Recommended Actions Before Implementation**:
1. Fix the three critical issues
2. Address the Keychain schema ambiguity (item 6)
3. Clarify the rate limiter implementation (item 7)
4. Run the DRM spike as specified

**Estimated Effort to Address**: 1-2 hours for document updates.

---

## Appendix: CloudInputDecoder Pattern Verification

The following patterns from CloudInputDecoder.mm should be explicitly matched in the Tidal implementation:

| Pattern | CloudInputDecoder | TidalInputDecoder Design | Status |
|---------|-------------------|--------------------------|--------|
| Service factory type | `service_factory_single_t` | `FB2K_SERVICE_FACTORY` | Mismatch - fix |
| `initialize()` method | Present, stores subsong/flags | Missing | Missing - fix |
| 403 detection | String match in `exception_io` | `exception_io_denied` catch | Mismatch - fix |
| Info reader separation | `CloudInfoReader` class | `tidal_info_reader` class | Aligned |
| Cache bypass on retry | `resolveBypassCache()` | `invalidateKey()` + resolve | Aligned |
| Position recovery on retry | Not implemented ("start fresh") | Deferred to Phase 2 | Aligned |
| Stream URL logging | Truncated (first 80 chars) | Not specified | Consider adding |
| `get_file_stats` | Returns invalid stats | Returns invalid stats | Aligned |

---

*Review completed: 2026-01-07*

---

## Incorporation Status

**Incorporated**: 2026-01-07

All feedback from this review has been addressed:

### Critical Issues
- [x] **Issue 1**: Fixed service factory pattern - now uses `service_factory_single_t<tidal_input_entry>` matching CloudInputEntry
- [x] **Issue 2**: Added `initialize()` method storing subsong/flags for use in tryReopen()
- [x] **Issue 3**: Fixed 403 detection to use string matching pattern (`strstr(msg, "403") || strstr(msg, "Forbidden")`)

### Important Improvements
- [x] **Issue 4**: Added background dispatch for prefetch (`dispatch_async` to QOS_CLASS_UTILITY queue)
- [x] **Issue 5**: Added `open_for_info_write()` throwing `exception_io_unsupported_format`
- [x] **Issue 6**: Fixed Keychain schema - service: `"com.foobar2000.tidal"`, accounts: `"access_token"`/`"refresh_token"`
- [x] **Issue 7**: Added `JLTidalRateLimiter` class with backoff calculation
- [x] **Issue 8**: Added `get_extended_data()` method (empty implementation)

### Minor Suggestions Addressed
- [x] Added URL expansion clarification (album/playlist URLs expanded by link_resolver)
- [x] Specified cache invalidation on logout (StreamCache + ThumbnailCache cleared, MetadataCache retained)
