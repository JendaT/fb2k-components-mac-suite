# Group and Subgroup Detection Architecture

This document describes the code flow for detecting album groups and disc subgroups in SimPlaylist.

## Overview

SimPlaylist can display playlist items grouped by album (or other metadata), with optional subgroup headers for multi-disc albums. The detection process must handle large playlists (10,000+ items) without blocking the UI.

## Key Data Structures

### Group Data (SimPlaylistView properties)
- `groupStarts: NSArray<NSNumber*>` - Playlist indices where each group starts
- `groupHeaders: NSArray<NSString*>` - Header text for each group (e.g., album name)
- `groupArtKeys: NSArray<NSString*>` - File paths for album art lookup
- `groupPaddingRows: NSArray<NSNumber*>` - Padding rows per group for album art

### Subgroup Data (SimPlaylistView properties)
- `subgroupStarts: NSArray<NSNumber*>` - Playlist indices where subgroups start
- `subgroupHeaders: NSArray<NSString*>` - Subgroup header text (e.g., "Disc 1")
- `subgroupCountPerGroup: NSArray<NSNumber*>` - Count of subgroups in each group
- `subgroupRowSet: NSSet<NSNumber*>` - Row numbers that are subgroup headers (O(1) lookup)
- `subgroupRowToIndex: NSDictionary<NSNumber*,NSNumber*>` - Map row -> subgroup index (O(1) lookup)

### Detection State (SimPlaylistController)
- `_groupDetectionGeneration: NSInteger` - Generation counter to cancel stale detections
- `_currentPlaylistInitialized: BOOL` - Whether full detection is complete
- `_scrollAnchorIndices: NSMutableDictionary` - Saved scroll positions per playlist
- `_scrollRestorePlaylistIndex: NSInteger` - Playlist awaiting scroll restore

## Entry Point: rebuildFromPlaylist

Called when:
- Switching to a different playlist
- Settings change (grouping pattern, album art size, etc.)
- Playlist content changes

```
rebuildFromPlaylist
    |
    +-- [ASYNC PATH] No saved scroll position (first visit)
    |       |
    |       +-- detectGroupsForPlaylist:itemCount:preset:
    |               |
    |               +-- Clear all group/subgroup data
    |               +-- Set flat list immediately (responsive UI)
    |               +-- dispatch_async to background queue
    |                       |
    |                       +-- Iterate ALL tracks (0 to itemCount)
    |                       +-- Detect groups and subgroups
    |                       +-- dispatch_async to main queue
    |                               |
    |                               +-- Set all data to view
    |                               +-- Rebuild caches
    |                               +-- Set _currentPlaylistInitialized = YES
    |
    +-- [SYNC PATH] Has saved scroll position
            |
            +-- detectGroupsForPlaylistSync:itemCount:preset:
                    |
                    +-- Iterate PARTIAL tracks (0 to anchorIndex+200)
                    +-- Set partial data to view
                    +-- Rebuild caches
                    +-- performScrollRestore (immediate)
                    +-- IF more tracks remain:
                    |       |
                    |       +-- dispatch_async to background queue
                    |               |
                    |               +-- Iterate REMAINING tracks (detectUpTo to end)
                    |               +-- Detect more groups and subgroups
                    |               +-- dispatch_async to main queue
                    |                       |
                    |                       +-- MERGE with existing data
                    |                       +-- Rebuild caches
                    |                       +-- Set _currentPlaylistInitialized = YES
                    |
                    +-- ELSE: Set _currentPlaylistInitialized = YES
```

## Three Code Paths for Subgroup Detection

### Path 1: Sync Initial Detection (Lines 524-564)
**When:** User switches to playlist with saved scroll position
**Processes:** Tracks 0 to MIN(itemCount, anchorIndex+200)
**Thread:** Main thread (synchronous)

```objc
// Variables
pfc::string8 currentHeader("");
pfc::string8 currentSubgroup("");

// Loop
for (t_size i = 0; i < detectUpTo; i++) {
    // Format header
    BOOL isNewGroup = (i == 0 || headerChanged);

    if (isNewGroup) {
        // Add group
        currentSubgroup = "";  // CLEAR subgroup for new group
    }

    // Subgroup detection
    if (formattedSubgroup.length > 0) {
        BOOL isFirstSubgroupInGroup = (currentSubgroup.length == 0);
        BOOL isDifferentSubgroup = (formattedSubgroup != currentSubgroup);

        if (isFirstSubgroupInGroup) {
            if (isNewGroup && showFirstSubgroup) {
                // ADD first subgroup at group start
            }
        } else if (isDifferentSubgroup) {
            // ADD real disc change
        }
        currentSubgroup = formattedSubgroup;  // UPDATE tracking
    }
}
```

### Path 2: Sync Background Continuation (Lines 658-699)
**When:** Sync path didn't process all tracks
**Processes:** Tracks detectUpTo to itemCount
**Thread:** Background thread (async)

```objc
// Variables - INITIALIZED FROM SYNC PORTION
pfc::string8 bgCurrentHeader([lastHeader UTF8String]);
pfc::string8 bgCurrentSubgroup([lastSubgroup UTF8String]);

// Loop - NO i==0 check since this is a continuation
for (t_size i = detectUpTo; i < itemCount; i++) {
    // Format header
    BOOL isNewGroup = (headerChanged);  // No i==0 check

    if (isNewGroup) {
        // Add group
        bgCurrentSubgroup = "";  // CLEAR subgroup for new group
    }

    // Subgroup detection - IDENTICAL LOGIC to Path 1
    ...
}
```

### Path 3: Async Full Detection (Lines 838-880)
**When:** First visit to playlist (no saved scroll position)
**Processes:** All tracks (0 to itemCount)
**Thread:** Background thread (async)

```objc
// Variables
pfc::string8 currentHeader("");
pfc::string8 currentSubgroup("");

// Loop
for (t_size i = 0; i < itemCount; i++) {
    // Format header
    BOOL isNewGroup = (i == 0 || headerChanged);

    if (isNewGroup) {
        // Add group
        currentSubgroup = "";  // CLEAR subgroup for new group
    }

    // Subgroup detection - IDENTICAL LOGIC to Path 1
    ...
}
```

## Subgroup Detection Logic

The subgroup detection uses this decision tree:

```
1. Is formattedSubgroup empty?
   |
   +-- YES: Skip (ignore tracks with missing disc tags)
   |
   +-- NO: Continue to step 2

2. Is this the FIRST non-empty subgroup in this group?
   (currentSubgroup.length == 0)
   |
   +-- YES: Is this the START of a new group? (isNewGroup == true)
   |   |
   |   +-- YES: Is showFirstSubgroup enabled?
   |   |   |
   |   |   +-- YES: ADD subgroup header (e.g., "Disc 1" at album start)
   |   |   +-- NO: Don't add (user doesn't want first disc headers)
   |   |
   |   +-- NO: Don't add (this is mid-album, not album start)
   |
   +-- NO: Is the subgroup DIFFERENT from current?
       |
       +-- YES: ADD subgroup header (real disc change: Disc 1 -> Disc 2)
       +-- NO: Don't add (same disc)

3. Update currentSubgroup = formattedSubgroup (track non-empty values)
```

### Critical Rule: "First Subgroup" Only at Group Start

The key insight is that "first subgroup in group" (`currentSubgroup.length == 0`) should ONLY trigger a header when:
1. We're at the START of a new album (`isNewGroup == true`), AND
2. The "Show First Subgroup Header" setting is enabled

This prevents the scenario where:
- Album starts with tracks WITHOUT discnumber tags (tracks 1-5)
- Mid-album, track 6 has discnumber=1
- We should NOT show "Disc 1" header between tracks 5 and 6

## SubgroupDetector Helper Struct

To ensure all three code paths use identical detection logic (DRY principle), a shared
helper struct encapsulates all subgroup detection logic:

```cpp
// SimPlaylistController.mm lines 28-146
struct SubgroupDetector {
    pfc::string8 currentSubgroup;
    bool showFirstSubgroup;
    bool debugEnabled;
    FILE* debugFile;

    // Constructor
    SubgroupDetector(bool showFirst, bool debug);
    ~SubgroupDetector();

    // Called when entering a new album group
    void enterNewGroup();

    // Core decision logic - returns true if subgroup header should be added
    bool shouldAddSubgroup(const pfc::string8& formattedSubgroup,
                           bool isNewGroup,
                           NSMutableArray<NSNumber*>* subgroupStarts,
                           NSMutableArray<NSString*>* subgroupHeaders,
                           t_size playlistIndex);

    // Initialize from existing state (for sync continuation)
    void initFromState(const char* existingSubgroup);

    // Get current state (for passing to continuation)
    const char* getCurrentSubgroup();
};
```

### Usage in All Three Paths

```objc
// Path 1 & 3: Create fresh detector
SubgroupDetector detector(showFirstSubgroup, g_subgroupDebugEnabled);

// Path 2: Initialize from sync portion's final state
SubgroupDetector bgDetector(showFirstSubgroup, g_subgroupDebugEnabled);
bgDetector.initFromState([lastSubgroup UTF8String]);

// In all paths:
if (isNewGroup) {
    detector.enterNewGroup();  // Clear state for new album
}
detector.shouldAddSubgroup(formattedSubgroup, isNewGroup, starts, headers, index);
```

### Debug Logging

When `g_subgroupDebugEnabled = true`, the detector writes to `/tmp/simplaylist_subgroup_debug.txt`:
- Each track's playlist index, subgroup value, current state, flags
- Decision outcome (ADD or SKIP) with reason
- Useful for diagnosing detection issues

## State Passing Between Sync and Continuation

When sync detection spawns background continuation:

```objc
// At end of sync portion - get actual state from detector:
NSString *lastSubgroup = [NSString stringWithUTF8String:subgroupDetector.getCurrentSubgroup()];

// At start of continuation - initialize from that state:
SubgroupDetector bgDetector(showFirstSubgroup, debugEnabled);
bgDetector.initFromState([lastSubgroup UTF8String]);
```

This preserves the tracking state so continuation can correctly detect:
- Disc changes that span the sync/continuation boundary
- First subgroups in groups that start in continuation

## Cache Rebuild Chain

After setting group/subgroup data, caches must be rebuilt **IN THE CORRECT ORDER**:

```
1. updateSubgroupCountPerGroup
   - Calculates how many subgroups are in each group
   - Used for row count calculations

2. Calculate and set groupPaddingRows
   - Padding depends on track count per group

3. rebuildPaddingCache
   - Calculates _totalPaddingRowsCached
   - Builds _cumulativePaddingCache
   - Enables O(1) row count calculation

4. rebuildSubgroupRowCache (MUST BE LAST)
   - Builds _subgroupRowSet (O(1) membership test)
   - Builds _subgroupRowToIndex (O(1) lookup)
   - Uses cumulativePaddingBeforeGroup() internally
   - CRITICAL: Must be called AFTER rebuildPaddingCache!
```

### Cache Ordering Bug (Fixed December 2025)

**Symptom:** Subgroup headers appeared at wrong row positions. The bug was intermittent
and non-deterministic - sometimes correct, sometimes off by varying amounts.

**Root Cause:** `rebuildSubgroupRowCache` was being called BEFORE padding was calculated
and `rebuildPaddingCache` was called. The subgroup row calculation uses
`cumulativePaddingBeforeGroup()` which reads from `_cumulativePaddingCache`.

When called prematurely:
- `_cumulativePaddingCache` was empty/stale (from previous detection or init)
- `cumulativePaddingBeforeGroup()` returned 0 or wrong values
- Subgroup rows were calculated with incorrect offsets
- UI displayed subgroup headers at wrong positions

**Why Intermittent:**
- On first load: padding cache empty -> rows off by full padding amount
- On playlist switch: previous detection's padding might still exist -> rows off by delta
- Sometimes old padding matched new -> appeared correct by accident

**Fix:** In all three code paths, moved `rebuildSubgroupRowCache` to AFTER `rebuildPaddingCache`:

```objc
// WRONG (original):
[self updateSubgroupCountPerGroup];
[_playlistView rebuildSubgroupRowCache];  // Uses stale padding!
// ... calculate padding ...
[_playlistView rebuildPaddingCache];

// CORRECT (fixed):
[self updateSubgroupCountPerGroup];
// ... calculate padding ...
[_playlistView rebuildPaddingCache];
[_playlistView rebuildSubgroupRowCache];  // Now has correct padding
```

## Generation Counter for Cancellation

The `_groupDetectionGeneration` counter prevents stale async results:

```objc
// At start of any detection:
NSInteger currentGeneration = ++_groupDetectionGeneration;

// Throughout background work:
if (_groupDetectionGeneration != currentGeneration) return;  // Cancelled
```

This ensures that if user switches playlists rapidly, old detections are discarded.

## Known Issues to Watch For

### Issue 1: Inconsistent Metadata
Albums where some tracks have discnumber and others don't can cause unexpected behavior.

**Expected:** No disc headers for albums without consistent discnumber metadata.

### Issue 2: Subgroup Pattern Format
- `[Disc %discnumber%]` - With brackets: returns empty if tag missing (CORRECT)
- `Disc %discnumber%` - Without brackets: returns "Disc " if tag missing (WRONG)

### Issue 3: State Initialization
All three code paths MUST:
1. Initialize currentSubgroup to empty string `""`
2. Clear currentSubgroup when entering new group
3. Only update currentSubgroup when formattedSubgroup is non-empty

### Issue 4: Cache Consistency
After ANY modification to subgroupStarts/subgroupHeaders, MUST call:
1. `updateSubgroupCountPerGroup`
2. `rebuildSubgroupRowCache`

After ANY modification to groupPaddingRows, MUST call:
1. `rebuildPaddingCache`

## Testing Checklist

- [ ] Album with NO discnumber tags: Should show NO disc headers
- [ ] Album with discnumber=1 on ALL tracks: Should show "Disc 1" only at album start (if showFirstSubgroup=YES)
- [ ] Album with Disc 1 + Disc 2: Should show both headers
- [ ] Album with PARTIAL discnumber (some tracks tagged, some not): Should NOT show mid-album headers
- [ ] Large playlist scrolling: No UI freeze
- [ ] Switching playlists: Scroll position preserved
- [ ] Settings change: Groups re-detected correctly
