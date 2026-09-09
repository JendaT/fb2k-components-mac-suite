# Design Review: Network Volume UUID Remapping Tool

**Reviewer**: Principal Engineer (Automated)
**Date**: 2026-01-13
**Review Type**: Architecture & Implementation Review (Iteration 3 of 5)

## Executive Summary

This is a well-structured design document that addresses a real user pain point with network volumes. Previous review iterations have significantly improved the document. This review focuses on network volume edge cases, macOS filesystem nuances, and subtle UX issues that may have been overlooked in earlier passes.

## Critical Issues (Must Fix)

### 1. Race Condition Between Scan and Apply Not Fully Mitigated
**Location**: Section 3.1 User Experience, Step 8
**Problem**: The current design re-validates volume state before apply, but only verifies that target UUIDs are still active. It does not re-verify that the orphaned UUIDs still need remapping. If the user reconnects a volume between scan and apply, entries that were "orphaned" may now resolve correctly, and remapping them would be incorrect.
**Impact**: Could cause data corruption by remapping entries that no longer need remapping, pointing them to the wrong volume.
**Recommendation**: Step 8 should also verify that source UUIDs are still orphaned. If a source UUID is now active, it should be removed from the pending remapping set with a notification to the user: "UUID X-X-X-X is now active and will be skipped."

### 2. No Handling for Volume Unmounting During Apply
**Location**: Section 4.3 File Modification Strategy
**Problem**: If the target volume unmounts mid-apply (network hiccup, user ejects, NAS restart), the design doesn't specify behavior. The file writes would succeed (they don't depend on the volume), but the resulting playlist would point to a now-unmounted volume.
**Impact**: User might not realize the target volume disappeared, and playlists would be modified to point to an unavailable destination.
**Recommendation**: After applying all changes, verify target volumes are still mounted. If not, show a warning: "Target volume `/Volumes/music.hq` is no longer mounted. Changes were applied but may not work until the volume is reconnected."

## Important Issues (Should Fix)

### 3. Ambiguity Around Multiple Active Volumes With Same Mount Point
**Location**: Section 5.1 Edge Cases table
**Problem**: The table says "Warn user, require explicit selection" but doesn't explain what the user is selecting or how. This scenario is common with network volumes: same SMB share mounted at different mount points, or mounted by different users.
**Recommendation**: Add a concrete UI mockup or description. Suggest: "When multiple active volumes share a mount point name, display them with their full mount paths (e.g., `/Volumes/music.hq` vs `/Volumes/music.hq-1`) and require the user to choose which represents the canonical location."

### 4. No Mention of Sandbox Restrictions
**Location**: Section 5.4 Security
**Problem**: foobar2000 macOS components may run in a sandboxed environment. The design assumes unrestricted filesystem access to `~/Library/foobar2000-v2/`. This needs verification.
**Recommendation**: Add a note to investigate sandbox entitlements. If sandboxed, the backup directory location may need to be within the app's container, or the tool may need to request special permissions.

### 5. Case Sensitivity of Mount Point Names Not Addressed
**Location**: Section 3.2 Technical Approach - Matching Logic
**Problem**: macOS filesystems are typically case-insensitive but case-preserving. A mount point name `Music.hq` and `music.hq` might refer to the same volume, but the current grouping logic would treat them as separate.
**Recommendation**: Specify case-insensitive comparison for mount point name grouping, similar to how UUID comparison is already specified as case-insensitive.

### 6. Insufficient Handling of Symbolic Links in Mount Paths
**Location**: Section 3.2 Technical Approach
**Problem**: `/Volumes/music.hq` could be a symlink to another location (e.g., user-created symlinks for convenience). The design doesn't specify whether to resolve symlinks before comparison.
**Recommendation**: Resolve symlinks using `[NSURL fileReferenceURL]` or `realpath()` before comparing mount paths to ensure consistent matching.

## Minor Issues (Nice to Fix)

### 7. Backup Directory Name Inconsistency
**Suggestion**: The backup path uses `playlists-v2.0-backup` while the source is `playlists-v2.0`. Consider using `playlists-v2.0.backup` (dot notation) to keep them visually adjacent in Finder sorting, or at minimum ensure the naming is documented as intentional.

### 8. Progress Bar Granularity
**Suggestion**: Section 3.1 shows progress as "42/100" files, but Section 5.3 Performance mentions ~50K entries. Consider showing entry count progress for large playlists during the apply phase: "Updating entries... (12,345/50,000)" provides better feedback on large operations.

### 9. "Show in Finder" Button Accessibility
**Suggestion**: The summary dialog's "Show in Finder" button should use `NSWorkspace.shared.selectFile(_:inFileViewerRootedAtPath:)` to highlight the backup directory, not just reveal its parent. Small but improves UX.

### 10. Malformed URL Warning Verbosity
**Suggestion**: Section 3.2 says malformed entries are "skipped with a logged warning." Consider also showing a count of skipped malformed entries in the summary dialog so users know some entries couldn't be processed.

## Open Questions

### Does foobar2000 use file-level locking on playlist files?
**Context**: The design uses `NSFileCoordinator` for safe access, but this only helps if foobar2000 also participates in the coordination protocol. If foobar2000 uses `flock()` or POSIX advisory locks instead, `NSFileCoordinator` won't help. This could result in corrupted playlist files if writes interleave. The open questions list asks about unsaved modifications but not about the file locking mechanism itself.

### What happens with AFP vs SMB vs NFS volume UUIDs?
**Context**: The document mentions "SMB/AFP/NFS" but treats them uniformly. AFP is deprecated since macOS Ventura. NFS mounts may not always have UUIDs visible through `NSURLVolumeUUIDStringKey`. This should be empirically tested to ensure the tool works across all network filesystem types still in use.

### Should read-only playlist directories be detected?
**Context**: If the playlist directory is on a read-only volume or has restrictive permissions (perhaps due to enterprise MDM policies), the tool will fail. Should this be detected upfront during the scan phase rather than failing at apply time?

## Positive Observations

What's done well:
- The workflow is user-friendly with clear preview-before-apply pattern
- Backup retention policy (5 versions) balances safety with disk usage
- Partial failure handling is thoughtfully designed to continue and report
- Prior art reference to PathMappingWindowController provides clear implementation guidance
- Open questions section is honest about unknowns that need investigation
- Data structures are well-defined with clear property semantics
- Error handling table covers most common scenarios

## Verdict

[ ] Not Approved - Critical issues must be addressed
[X] Conditional - Approve after important issues addressed
[ ] Approved - Minor issues can be fixed during implementation

The design is solid and the previous reviews have improved it significantly. The critical issue around the scan-to-apply race condition (now bidirectional - both target and source UUIDs can change) must be addressed before implementation. The important issues around multiple active volumes UI, sandbox restrictions, and case sensitivity should be clarified in the design, though they could potentially be resolved during implementation if time is constrained.

---
## Incorporation Footer

**Processed**: 2026-01-13
**By**: Main agent (iteration 3)

### Actions Taken
- Addressed Critical #1: Added source UUID validation to pre-apply checks (verify still orphaned, auto-remove if now active)
- Addressed Critical #2: Added post-apply verification step with warning if target volume unmounted
- Addressed Important #3: Updated edge case handling with explicit UI guidance for multiple active volumes
- Addressed Important #4: Added sandbox consideration note to security section
- Addressed Important #5: Added case-insensitive comparison for mount point name grouping
- Addressed Important #6: Added symlink resolution using realpath() to matching logic
- Addressed Minor #9: Added note about NSWorkspace.selectFile for Show in Finder
- Addressed Minor #10: Added malformed entries count to summary dialog
- Added new open questions about file locking, AFP/SMB/NFS UUID support, and read-only directory detection
