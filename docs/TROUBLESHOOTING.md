# Troubleshooting Guide

## Quick Diagnostic Tools

### fb2k-debug - Component Toggle Tool

Interactive tool to quickly enable/disable components for debugging:

```bash
fb2k-debug
```

**Features:**
- Lists components sorted by modification time (newest first - most likely culprit)
- Green `●` = active, Red `○` = disabled
- Enter number to toggle, `a` to enable all, `q` to quit

**Example:**
```
=== foobar2000 Component Debugger ===

  ●  1) foo_jl_simplaylist              31 Dec 17:18
  ●  2) foo_jl_album_art.component      30 Dec 22:59
  ...
  ○ 12) foo_jl_cloud_streamer           30 Dec 19:16 DISABLED

Commands:  [1-12] toggle    [a] enable all    [q] quit
```

### View Crash Reports

```bash
# List recent crashes
ls -lt ~/Library/Logs/DiagnosticReports/foobar2000-*.ips | head -5

# View most recent
head -200 "$(ls -t ~/Library/Logs/DiagnosticReports/foobar2000-*.ips | head -1)"
```

### Console Logging

```bash
# Run foobar2000 with console output
/Applications/foobar2000.app/Contents/MacOS/foobar2000 2>&1 | tee /tmp/fb2k.log
```

**What to look for:**
- `Component : <name>` - component loading
- `Components loaded in:` - successful initialization
- Last component before hang is likely the culprit

---

## Common Issues

### foobar2000 Won't Start / Hangs on Launch

**Symptoms:** App opens but shows no window, or beach balls indefinitely.

**Cause:** A component crashes during initialization or first UI draw.

**Solution:**
1. Run `fb2k-debug`
2. Disable newest components first (top of list)
3. Try starting foobar2000
4. Binary search until culprit found

**Quick disable all custom components:**
```bash
mkdir -p ~/Library/foobar2000-v2/user-components-disabled
mv ~/Library/foobar2000-v2/user-components/foo_jl_* ~/Library/foobar2000-v2/user-components-disabled/
```

### Component Not Loading

**Symptoms:** Component doesn't appear in foobar2000.

**Check structure:**
```bash
# Should see Contents/ folder
ls ~/Library/foobar2000-v2/user-components/<component>/
```

**Valid structures:**

1. Flat (preferred):
   ```
   foo_jl_album_art.component/
     Contents/
       MacOS/foo_jl_album_art
       Info.plist
   ```

2. Nested (also works):
   ```
   foo_jl_plorg/
     foo_jl_plorg.component/
       Contents/
         MacOS/foo_jl_plorg
         Info.plist
   ```

**Invalid:** Having BOTH for the same component (causes duplicate loading).

### Duplicate Class Warning

**Symptoms:** Console shows `objc: Class X is implemented in both...`

**Cause:** Same Objective-C class name in multiple components.

**Solution:** Each component needs unique class prefixes:
- SimPlaylist: `SimPlaylist*`, `SP*`
- Plorg: `Plorg*`, `PO*`
- Waveform: `Waveform*`, `WS*`

### Component Crashes During Use

**Symptoms:** foobar2000 crashes when using a specific feature.

**Debug steps:**
1. Check crash report for source file (`.mm`, `.cpp`)
2. Look for null pointer access (`KERN_INVALID_ADDRESS at 0x0`)
3. Check the function name in stack trace

**Common crash causes:**
- Nil track metadata in drawing code
- Accessing deallocated objects
- Main thread blocked by I/O
- Uncaught exceptions in callbacks

---

## Directory Reference

### foobar2000 v2 (Current)

| Purpose | Location |
|---------|----------|
| Components | `~/Library/foobar2000-v2/user-components/` |
| Configuration | `~/Library/foobar2000-v2/configuration/` |
| Crash Reports | `~/Library/Logs/DiagnosticReports/foobar2000-*.ips` |

### Legacy v1 (Don't Use)

| Purpose | Location |
|---------|----------|
| Components | `~/Library/Application Support/foobar2000/user-components/` |

**Note:** Legacy location can cause conflicts. Move any components there to v2 location.

---

## Recovery Procedures

### Disable Single Component

```bash
mv ~/Library/foobar2000-v2/user-components/foo_jl_<name> \
   ~/Library/foobar2000-v2/user-components-disabled/
```

### Re-enable Component

```bash
mv ~/Library/foobar2000-v2/user-components-disabled/foo_jl_<name> \
   ~/Library/foobar2000-v2/user-components/
```

### Reset Component Configuration

```bash
# Backup first
cp -r ~/Library/foobar2000-v2/configuration ~/Library/foobar2000-v2/configuration.bak

# Remove specific component config
rm ~/Library/foobar2000-v2/configuration/*<component>*
```

### Full Reset (Nuclear Option)

```bash
# Backup everything
mv ~/Library/foobar2000-v2 ~/Library/foobar2000-v2.bak

# Start foobar2000 - creates fresh config
open /Applications/foobar2000.app

# Restore components only (not config)
cp -r ~/Library/foobar2000-v2.bak/user-components/* ~/Library/foobar2000-v2/user-components/
```

---

## Prevention Best Practices

### 1. Null-Safe Drawing Code

```objc
// BAD - crashes if title is nil
NSString *title = track.title;
[title drawInRect:rect];

// GOOD - handles nil safely
NSString *title = track.title ?: @"";
if (title.length > 0) {
    [title drawInRect:rect];
}
```

### 2. Guard Initialization

```objc
- (void)onInit {
    @try {
        // initialization code
    } @catch (NSException *e) {
        NSLog(@"[%@] Init failed: %@", self.class, e);
    }
}
```

### 3. Background Thread for Heavy Work

```objc
// BAD - blocks UI
NSData *data = [NSData dataWithContentsOfFile:path];

// GOOD - async loading
dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData *data = [NSData dataWithContentsOfFile:path];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self processData:data];
    });
});
```

### 4. Test After Every Build

```bash
# Build
./Scripts/generate_xcode_project.rb && xcodebuild ...

# Install
./Scripts/install.sh

# Test immediately
/Applications/foobar2000.app/Contents/MacOS/foobar2000 2>&1 | head -50
```

### 5. Keep fb2k-debug Handy

When something breaks, newest component is usually the culprit. `fb2k-debug` sorts by modification time for exactly this reason.

---

## Incident History

| Date | Issue | Cause | Resolution |
|------|-------|-------|------------|
| 2025-12-31 | App won't start | SimPlaylist crash in `drawSparseTrackRow:` + duplicate biography component | Disabled SimPlaylist, removed duplicate |

See `docs/DEBUG_REPORT_2025-12-31.md` for full analysis.
