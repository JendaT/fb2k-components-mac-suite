# foobar2000 Startup Failure Debug Report

**Date:** 2025-12-31
**Issue:** foobar2000 would not load (hung indefinitely)
**Resolution:** SimPlaylist component crash + duplicate component cleanup

---

## Root Cause Analysis

### Primary Issue: SimPlaylist Crash

The crash report (`foobar2000-2025-12-31-151717.ips`) revealed:

```
Exception Type: EXC_BAD_ACCESS (SIGSEGV)
Exception Subtype: KERN_INVALID_ADDRESS at 0x0000000000000000
```

**Crash locations in SimPlaylist:**

1. **Thread 0 (Main/UI Thread):**
   - `SimPlaylistView.mm:1031` in `-[SimPlaylistView drawSparseTrackRow:inRect:selected:playing:]`
   - Null pointer dereference during text drawing operations
   - Related to `NSRLEArray objectAtIndex:effectiveRange:` (text layout)

2. **Thread 12 (Background/Drag-Drop):**
   - `SimPlaylistController.mm:2066` in `didReceiveDroppedURLs:atRow:`
   - `playlist.cpp:296` in `playlist_incoming_item_filter::process_location`

**Probable cause:** Corrupted playlist state or null track metadata being accessed during drawing/drag operations.

### Secondary Issue: Duplicate Components

Found duplicate biography component:
- `foo_jl_biography/` (nested structure - WRONG)
- `foo_jl_biography.component/` (flat structure - correct)

Both were being loaded, potentially causing conflicts.

### Tertiary Issue: Legacy v1 Components

Old components in legacy location could cause conflicts:
```
~/Library/Application Support/foobar2000/user-components/
  foo_jl_scrobble.component
  foo_plorg.component
  foo_wave_seekbar.component
```

---

## Component Directory Structure

foobar2000 v2 expects components at:
```
~/Library/foobar2000-v2/user-components/<name>/<name>.component/Contents/
```

**Two valid structures:**

1. **Flat (preferred):**
   ```
   user-components/
     foo_jl_album_art.component/
       Contents/
         MacOS/
         Info.plist
   ```

2. **Nested (also works):**
   ```
   user-components/
     foo_jl_plorg/
       foo_jl_plorg.component/
         Contents/
           MacOS/
           Info.plist
   ```

**Invalid:** Having BOTH structures for the same component.

---

## How foobar2000 Can Become "Unloadable"

### 1. Component Crash During Initialization
If a component crashes during `initquit` callbacks or early service registration, foobar2000 may hang or crash before the UI appears.

### 2. Component Crash During Layout Restoration
foobar2000 restores the previous UI layout on startup. If a UI component (like SimPlaylist) crashes during its first draw, the app hangs.

### 3. Infinite Loop in Component
A component bug causing an infinite loop blocks the main thread.

### 4. Deadlock Between Components
Multiple components competing for shared resources can deadlock.

### 5. Corrupted Configuration
If `~/Library/foobar2000-v2/configuration/` has corrupted data for a component, loading that data may crash.

---

## Debugging Procedure

### Quick Diagnosis

1. **Check crash reports:**
   ```bash
   ls -lt ~/Library/Logs/DiagnosticReports/foobar2000-*.ips | head -5
   ```

2. **View most recent crash:**
   ```bash
   head -200 ~/Library/Logs/DiagnosticReports/foobar2000-YYYY-MM-DD-*.ips
   ```

3. **Look for component name in crash:**
   - Search for `.mm` or `.cpp` files (your components)
   - Check `imageIndex` to identify which binary crashed

### Using fb2k-debug

```bash
fb2k-debug
```

- Lists components sorted by modification time (newest first)
- Toggle components on/off by number
- Newest components are most likely culprits after updates

### Binary Search Method

1. Disable half of all components
2. Test if foobar2000 starts
3. If yes: problem is in disabled half
4. If no: problem is in enabled half
5. Repeat until single component identified

### Console Log Method

```bash
# Terminal 1: Start foobar2000 with logging
/Applications/foobar2000.app/Contents/MacOS/foobar2000 2>&1 | tee /tmp/fb2k.log

# Terminal 2: Watch for issues
tail -f /tmp/fb2k.log
```

Look for:
- Last "Component : <name>" before hang
- "Components loaded in:" (if reached, init succeeded)
- Error messages or exceptions

---

## Prevention Strategies

### 1. Test Components Individually
After building a component, test it in isolation before adding to full suite.

### 2. Null-Safety in Drawing Code
Always check for nil before accessing:
- Track metadata
- Album art data
- Playlist items

```objc
// BAD
NSString *title = track.title;
[title drawInRect:rect];

// GOOD
NSString *title = track.title ?: @"";
if (title.length > 0) {
    [title drawInRect:rect];
}
```

### 3. Guard initquit Callbacks
```objc
- (void)onInit {
    @try {
        // initialization code
    } @catch (NSException *e) {
        NSLog(@"Component init failed: %@", e);
    }
}
```

### 4. Avoid Blocking Main Thread
Heavy operations (file I/O, network, database) must be on background threads.

### 5. Version Your Configurations
If config format changes, handle migration gracefully:
```objc
int version = [config integerForKey:@"config_version"];
if (version < CURRENT_VERSION) {
    [self migrateConfigFrom:version];
}
```

### 6. Clean Component Directory Structure
- Use consistent naming: `foo_jl_<name>_mac/` for source
- Use consistent output: `foo_jl_<name>.component` or `foo_jl_<name>.fb2k-component`
- Never have both nested and flat structures

---

## Recovery Commands

### Disable All Custom Components
```bash
mkdir -p ~/Library/foobar2000-v2/user-components-disabled
mv ~/Library/foobar2000-v2/user-components/foo_jl_* ~/Library/foobar2000-v2/user-components-disabled/
```

### Re-enable All
```bash
mv ~/Library/foobar2000-v2/user-components-disabled/* ~/Library/foobar2000-v2/user-components/
```

### Reset Component Configuration
```bash
# Backup first
cp -r ~/Library/foobar2000-v2/configuration ~/Library/foobar2000-v2/configuration.bak

# Then selectively delete component configs (example for simplaylist)
rm ~/Library/foobar2000-v2/configuration/*simplaylist*
```

### Full Reset (Nuclear Option)
```bash
mv ~/Library/foobar2000-v2 ~/Library/foobar2000-v2.bak
# Restart foobar2000 - creates fresh config
```

---

## Current State After Fix

**Working (Active):**
- foo_jl_album_art.component
- foo_jl_biography.component
- foo_jl_playback_controls
- foo_jl_plorg
- foo_jl_queue_manager
- foo_jl_scrobble
- foo_jl_wave_seekbar
- foo_input_gme
- foo_openmpt54

**Disabled (Needs Fix):**
- foo_jl_simplaylist - crash in drawing code
- foo_jl_cloud_streamer - disabled during testing

**Backed Up (Legacy):**
- `~/Library/Application Support/foobar2000/user-components-backup/`

---

## SimPlaylist Fix Required

The crash at `SimPlaylistView.mm:1031` needs investigation:

1. Check what `drawSparseTrackRow:` is doing at that line
2. Add null checks for track data
3. Handle empty playlist state gracefully
4. Test with corrupted/empty playlist configurations

Until fixed, SimPlaylist should remain disabled.
