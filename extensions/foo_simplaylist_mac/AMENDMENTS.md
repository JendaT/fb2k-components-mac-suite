# foo_simplaylist_mac - Implementation Amendments

**Document Version:** 1.1
**Date:** December 2025
**Status:** Amendments Applied Based on Principal Review

This document records critical amendments to `IMPLEMENTATION_SPEC.md` based on architectural review. All items here supersede corresponding sections in the original spec.

---

## Critical Amendments (Must Apply Before Implementation)

### A1: Title Formatting - SDK Exclusive (CRITICAL)

**Original:** Spec mentioned "Consider using SDK's built-in titleformat_compiler" as optional.

**Amendment:** SDK's `titleformat_compiler` is the **ONLY** viable path. Do NOT implement custom title formatting.

**Rationale:**
- Foobar2000 title formatting has 200+ built-in fields
- 100+ functions (`$if()`, `$if2()`, `$get()`, `$put()`, `$meta()`, etc.)
- Context-dependent fields (`%isplaying%`, `%playback_time%`)
- Plugin-provided fields (foo_playcount: `%play_count%`, `%last_played%`, etc.)
- Reimplementing would take months and never achieve compatibility

**Required Pattern:**

```cpp
// TitleFormatHelper.h - THIN wrapper only, NO custom parsing
#pragma once
#include "../fb2k_sdk.h"

namespace simplaylist {

class TitleFormatHelper {
public:
    // Compile a pattern (caches for reuse)
    static titleformat_object::ptr compile(const char* pattern) {
        titleformat_object::ptr tf;
        titleformat_compiler::get()->compile_safe_ex(tf, pattern, "%filename%");
        return tf;
    }

    // Format a track
    static std::string format(metadb_handle_ptr track,
                              titleformat_object::ptr script) {
        pfc::string8 out;
        track->format_title(nullptr, out, script, nullptr);
        return std::string(out.c_str());
    }

    // Format with playback context (for %isplaying%, %playback_time%, etc.)
    static std::string formatWithPlayback(
        metadb_handle_ptr track,
        titleformat_object::ptr script,
        playback_control::t_display_level level = playback_control::display_level_all
    ) {
        pfc::string8 out;
        auto pc = playback_control::get();
        // The SDK handles playback context automatically when track matches
        track->format_title(nullptr, out, script, nullptr);
        return std::string(out.c_str());
    }
};

} // namespace
```

**Delete from Architecture:** Remove any `TitleFormatter` class that does custom parsing.

---

### A2: Virtual Scrolling - Move to Phase 1 (CRITICAL)

**Original:** Virtual scrolling was placed in Phase 6 (Polish).

**Amendment:** Virtual scrolling must be in **Phase 1** as foundational requirement.

**Rationale:**
- Without virtual scrolling, testing with 1000+ track playlists is impossible
- Trying to layout 10k NSView instances will crash or hang
- Development requires realistic test data from day one

**Revised Phase 1 Deliverables:**
1. Project setup and SDK linking
2. Basic service registration
3. SimPlaylistView with **virtual scrolling** (`drawRect:` only renders visible rows)
4. Flat track list (no grouping yet)
5. Selection and focus handling
6. Basic playlist callbacks

**Core Virtual Scrolling Implementation (Phase 1):**

```objc
// SimPlaylistContentView.mm

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect visibleRect = [self visibleRect];

    // Binary search for first visible row (O(log n))
    NSInteger firstRow = [self rowIndexAtY:NSMinY(visibleRect)];
    NSInteger lastRow = [self rowIndexAtY:NSMaxY(visibleRect)];

    // Clamp and add buffer
    firstRow = MAX(0, firstRow - 2);
    lastRow = MIN(_totalRowCount - 1, lastRow + 2);

    // Render only visible rows
    for (NSInteger row = firstRow; row <= lastRow; row++) {
        NSRect rowRect = [self rectForRow:row];
        if (NSIntersectsRect(rowRect, dirtyRect)) {
            [self drawRow:row inRect:rowRect];
        }
    }
}

- (NSInteger)rowIndexAtY:(CGFloat)y {
    // For fixed row height, simple division
    return (NSInteger)(y / _rowHeight);

    // For variable heights, use accumulated heights array
    // return [self binarySearchForY:y];
}

- (NSRect)rectForRow:(NSInteger)row {
    // For fixed height
    return NSMakeRect(0, row * _rowHeight, self.bounds.size.width, _rowHeight);
}
```

---

### A3: Album Art Cache Key - Directory Qualified (CRITICAL)

**Original:** Album art cache key strategy was undefined, implying album name only.

**Amendment:** Cache key **MUST** include directory path to prevent collisions.

**Collision Example:**
- "Greatest Hits" by Artist A at `/Music/ArtistA/Greatest Hits/`
- "Greatest Hits" by Artist B at `/Music/ArtistB/Greatest Hits/`
- Using `%album%` alone = same key = wrong art displayed

**Required Key Format:**

```objc
// Generate collision-resistant album art key
- (NSString *)albumArtKeyForTrack:(metadb_handle_ptr)track {
    file_info_impl info;
    if (!track->get_info_async(info)) {
        return nil;
    }

    // Get directory from path
    const char* path = track->get_path();
    pfc::string8 directory;
    pfc::string8 filename;
    pfc::splitFilePath(path, directory, filename);

    // Build key: directory + album artist + album
    const char* albumArtist = info.meta_get("album artist", 0);
    if (!albumArtist) albumArtist = info.meta_get("artist", 0);
    if (!albumArtist) albumArtist = "";

    const char* album = info.meta_get("album", 0);
    if (!album) album = "";

    return [NSString stringWithFormat:@"%s|%s|%s",
            directory.c_str(), albumArtist, album];
}
```

---

### A4: Callback Thread Safety - Lock Before Dispatch (CRITICAL)

**Original:**
```objc
- (void)notifyControllersOnMainThread:(void(^)(SimPlaylistController*))block {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);  // WRONG: locks on main thread
        // ...
    });
}
```

**Issue:** Locking inside `dispatch_async` causes main thread to block waiting for mutex if callbacks fire rapidly.

**Amendment:**

```objc
- (void)notifyControllersOnMainThread:(void(^)(SimPlaylistController*))block {
    // Snapshot controllers while holding lock (on callback thread)
    std::vector<SimPlaylistController*> snapshot;
    {
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (auto& weak : g_controllers) {
            SimPlaylistController* strong = weak;
            if (strong) {
                snapshot.push_back(strong);
            }
        }
    }
    // Lock released - dispatch without blocking

    dispatch_async(dispatch_get_main_queue(), ^{
        for (SimPlaylistController* ctrl : snapshot) {
            // Check controller still valid (might have been deallocated)
            if (ctrl) {
                block(ctrl);
            }
        }
    });
}
```

---

## High Priority Amendments

### A5: Single Instance Following Active Playlist

**Addition:** Explicitly document scope limitation for v1.0.

**Documented Behavior:**
- SimPlaylist v1.0 is **single instance only**
- Always follows the **active playlist** (same as Default UI)
- Uses `playlist_callback_single_impl_base` (not `playlist_callback`)
- Multiple SimPlaylist instances will all show the same playlist

**Future Scope (NOT v1.0):**
- Multi-instance with per-panel playlist binding
- Playlist tabs within SimPlaylist panel
- This would require `playlist_callback` (full) instead of `_single`

Add to FOUNDATION.md:
```
## Scope Limitations (v1.0)

This implementation targets feature parity with the active-playlist-tracking
behavior of the Default UI. Specifically:

- Single instance following active playlist
- Multiple panels show same content
- Multi-instance with playlist binding is Phase 7+ (post-v1.0)
```

---

### A6: Keyboard Navigation Implementation

**Addition:** Full keyboard handler specification.

```objc
// SimPlaylistView+Keyboard.mm

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    NSUInteger modifiers = event.modifierFlags;
    BOOL hasCmd = (modifiers & NSEventModifierFlagCommand) != 0;
    BOOL hasShift = (modifiers & NSEventModifierFlagShift) != 0;

    if (chars.length == 0) {
        [super keyDown:event];
        return;
    }

    unichar key = [chars characterAtIndex:0];

    switch (key) {
        case NSUpArrowFunctionKey:
            [self moveFocusBy:-1 extendSelection:hasShift];
            break;

        case NSDownArrowFunctionKey:
            [self moveFocusBy:1 extendSelection:hasShift];
            break;

        case NSPageUpFunctionKey:
            [self moveFocusBy:-[self visibleRowCount] extendSelection:hasShift];
            break;

        case NSPageDownFunctionKey:
            [self moveFocusBy:[self visibleRowCount] extendSelection:hasShift];
            break;

        case NSHomeFunctionKey:
            [self moveFocusTo:0 extendSelection:hasShift];
            break;

        case NSEndFunctionKey:
            [self moveFocusTo:_totalRowCount - 1 extendSelection:hasShift];
            break;

        case ' ':  // Space - toggle selection
            [self toggleSelectionAtFocus];
            break;

        case '\r':  // Enter - execute default action
            [self executeDefaultActionOnFocus];
            break;

        case NSDeleteCharacter:
        case NSBackspaceCharacter:
            [self removeSelectedItems];
            break;

        default:
            if (hasCmd && key == 'a') {
                [self selectAll:nil];
            } else {
                [super keyDown:event];
            }
            break;
    }
}

- (void)moveFocusBy:(NSInteger)delta extendSelection:(BOOL)extend {
    NSInteger newFocus = MAX(0, MIN(_totalRowCount - 1, _focusIndex + delta));

    if (extend) {
        // Shift+arrow: extend selection from anchor to new focus
        [self extendSelectionTo:newFocus];
    } else {
        // Arrow only: move focus and select only that item
        [self setFocusIndex:newFocus];
        [self selectOnlyIndex:newFocus];
    }

    [self scrollRowToVisible:newFocus];
}
```

---

### A7: Undo/Redo Integration

**Addition:** All playlist modifications must call `playlist_undo_backup()` first.

```objc
// Pattern for playlist modifications

- (void)removeSelectedItems {
    auto pm = playlist_manager::get();
    t_size playlist = pm->get_active_playlist();

    if (playlist == SIZE_MAX) return;
    if (pm->playlist_lock_is_present(playlist)) {
        // Playlist is locked, show indicator or message
        return;
    }

    // Create undo point BEFORE modification
    pm->playlist_undo_backup(playlist);

    // Build removal mask
    bit_array_bittable mask(pm->playlist_get_item_count(playlist));
    for (NSInteger idx : _selectedIndices) {
        mask.set(idx, true);
    }

    // Perform removal
    pm->playlist_remove_items(playlist, mask);
}

- (void)reorderItemsByDrag:(NSArray<NSNumber *> *)sourceIndices
                  toIndex:(NSInteger)targetIndex {
    auto pm = playlist_manager::get();
    t_size playlist = pm->get_active_playlist();

    if (playlist == SIZE_MAX) return;

    // Create undo point
    pm->playlist_undo_backup(playlist);

    // ... perform reorder via playlist_reorder_items()
}
```

---

### A8: Context Menu Integration (macOS)

**Addition:** Full context menu pattern using SDK's `contextmenu_manager_v2`.

```objc
// SimPlaylistView+ContextMenu.mm

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint locationInView = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger clickedRow = [self rowIndexAtY:locationInView.y];

    // If clicked row not in selection, select it
    if (clickedRow >= 0 && ![_selectedIndices containsObject:@(clickedRow)]) {
        [self selectOnlyIndex:clickedRow];
    }

    [self showContextMenuAtPoint:locationInView];
}

- (void)showContextMenuAtPoint:(NSPoint)point {
    // Get selected handles
    metadb_handle_list handles;
    [self getSelectedHandles:handles];

    if (handles.get_count() == 0) return;

    // Create context menu manager
    auto cm = contextmenu_manager_v2::g_create();
    cm->init_context(handles, contextmenu_manager::flag_view_full);

    // Build menu tree
    menu_tree_item::ptr root = cm->build_menu();
    if (!root) return;

    // Convert to NSMenu
    NSMenu *menu = [self buildNSMenuFromTree:root contextManager:cm];

    // Show menu
    [NSMenu popUpContextMenu:menu withEvent:[NSApp currentEvent] forView:self];
}

- (NSMenu *)buildNSMenuFromTree:(menu_tree_item::ptr)item
                 contextManager:(service_ptr_t<contextmenu_manager_v2>)cm {
    NSMenu *menu = [[NSMenu alloc] init];

    for (size_t i = 0; i < item->childCount(); i++) {
        menu_tree_item::ptr child = item->childAt(i);

        switch (child->type()) {
            case menu_tree_item::itemSeparator:
                [menu addItem:[NSMenuItem separatorItem]];
                break;

            case menu_tree_item::itemCommand: {
                NSString *title = [NSString stringWithUTF8String:child->name()];
                NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                  action:@selector(contextMenuItemClicked:)
                                                           keyEquivalent:@""];
                menuItem.target = self;
                menuItem.tag = child->commandID();  // Store command ID
                menuItem.representedObject = (__bridge id)(void*)cm.get_ptr();  // Store manager

                // Handle flags
                menu_flags_t flags = child->flags();
                if (flags & menu_flags::disabled) {
                    menuItem.enabled = NO;
                }
                if (flags & menu_flags::checked) {
                    menuItem.state = NSControlStateValueOn;
                }

                [menu addItem:menuItem];
                break;
            }

            case menu_tree_item::itemSubmenu: {
                NSString *title = [NSString stringWithUTF8String:child->name()];
                NSMenu *submenu = [self buildNSMenuFromTree:child contextManager:cm];
                NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                  action:nil
                                                           keyEquivalent:@""];
                menuItem.submenu = submenu;
                [menu addItem:menuItem];
                break;
            }
        }
    }

    return menu;
}

- (void)contextMenuItemClicked:(NSMenuItem *)sender {
    contextmenu_manager* cm = (__bridge contextmenu_manager*)sender.representedObject;
    if (cm) {
        cm->execute_by_id((unsigned)sender.tag);
    }
}
```

---

### A9: Remove Time Estimates

**Amendment:** Per CLAUDE.md, remove all week estimates from phases.

**Revised Phase Structure:**

```
Phase 1: Foundation
  Dependencies: None
  Done When:
    - Component loads in foobar2000
    - Flat track list renders with virtual scrolling
    - Selection sync works with playlist_manager
    - Focus and keyboard navigation functional
    - Basic callbacks respond to playlist changes

Phase 2: Grouping
  Dependencies: Phase 1
  Done When:
    - Tracks group by configurable pattern
    - Headers render correctly
    - Subgroups render correctly
    - Group boundaries update on playlist changes
    - Basic Groups preferences page exists

Phase 3: Album Art
  Dependencies: Phase 2
  Can Start In Parallel With: Phase 4
  Done When:
    - Group column renders spanning album art
    - Album art loads asynchronously
    - Cache prevents redundant loads
    - Placeholder displays for missing art
    - Ctrl+scroll resizes art

Phase 4: Columns
  Dependencies: Phase 2
  Can Start In Parallel With: Phase 3
  Done When:
    - Multiple columns render
    - Columns reorderable via drag
    - Auto-resize works (album/artist/title priority)
    - Column config persists
    - Columns preferences page exists

Phase 5: Interactive Features
  Dependencies: Phase 3, Phase 4
  Done When:
    - Double-click plays track
    - Context menu fully functional
    - Drag-drop reorder works (with undo)
    - Drag-drop import works
    - Now playing indicator works

Phase 6: Polish
  Dependencies: Phase 5
  Done When:
    - Dark mode fully supported
    - Accessibility labels complete
    - Memory usage profiled and optimized
    - All edge cases handled
    - Documentation complete
```

**Phase Dependency Graph:**
```
Phase 1 (Foundation + Virtual Scroll)
        |
        v
Phase 2 (Grouping)
        |
   +----+----+
   |         |
   v         v
Phase 3   Phase 4
(Art)     (Columns)
   |         |
   +----+----+
        |
        v
Phase 5 (Interactive)
        |
        v
Phase 6 (Polish)
```

---

## Medium Priority Amendments

### A10: Group Collapse/Expand - Explicitly Deferred

**Amendment:** Group collapse/expand is **NOT in v1.0 scope**.

Add to FOUNDATION.md:
```
## Deferred Features (Post v1.0)

The following features from the original SimPlaylist are deferred:

1. **Group Collapse/Expand**
   - Clicking group header to collapse
   - Persistence of collapse state
   - Memory across playlist switches

2. **Multi-Instance Playlist Binding**
   - Per-panel playlist selection
   - Independent playlist tracking

3. **Search/Filter Overlay**
   - F3 search functionality
   - Embedded search element

These may be added in future versions.
```

---

### A11: Test Framework Specification

**Amendment:** Specify XCTest as testing framework.

**Project Structure:**
```
foo_simplaylist_mac/
  src/
  tests/
    Core/
      GroupModelTests.mm
      TitleFormatHelperTests.mm
      AlbumArtCacheTests.mm
    Integration/
      PlaylistCallbackTests.mm
      SelectionSyncTests.mm
  foo_simplaylist_tests.xcodeproj
```

**XCTest Target Setup:**
- Link against same SDK libraries as main target
- Add `TESTING=1` preprocessor macro
- Include mock implementations for SDK services where needed

---

### A12: Horizontal Scroll Sync for Header Bar

**Amendment:** Header bar must synchronize with content scroll.

```objc
// SimPlaylistView.mm

- (void)setupScrollView {
    // ... scroll view setup ...

    // Register for scroll notifications
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(contentDidScroll:)
               name:NSViewBoundsDidChangeNotification
             object:_scrollView.contentView];

    _scrollView.contentView.postsBoundsChangedNotifications = YES;
}

- (void)contentDidScroll:(NSNotification *)notification {
    // Sync header horizontal position with content
    NSPoint contentOrigin = _scrollView.contentView.bounds.origin;
    NSRect headerFrame = _headerBar.frame;
    headerFrame.origin.x = -contentOrigin.x;
    _headerBar.frame = headerFrame;
}
```

---

### A13: Album Art Manager Safe Access

**Amendment:** Use `tryGet()` pattern for optional services.

```objc
- (void)loadAlbumArtForKey:(NSString *)key path:(const char *)path {
    // Safe access - service might not exist
    auto art_mgr = album_art_manager_v3::tryGet();
    if (!art_mgr) {
        // Service not available - use placeholder
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setPlaceholderForKey:key];
        });
        return;
    }

    // Proceed with album art loading...
}
```

---

## Low Priority Amendments

### A14: Memory Warning - Nuanced Response

**Amendment:** Don't clear entire cache on memory warning.

```objc
- (void)handleMemoryWarning:(NSNotification *)notification {
    // Keep visible items, clear rest
    NSRect visibleRect = [_contentView visibleRect];
    NSMutableSet<NSString *> *keysToKeep = [NSMutableSet set];

    // Identify keys for visible groups
    for (GroupInfo *group in _groups) {
        NSRect groupRect = [self rectForGroup:group];
        if (NSIntersectsRect(groupRect, visibleRect)) {
            [keysToKeep addObject:group.albumArtKey];
        }
    }

    // Evict only non-visible items
    [_albumArtCache evictAllExcept:keysToKeep];

    // Clear formatted string cache for non-visible rows
    [_formattedStringCache trimToCount:1000];  // Keep recent
}
```

---

### A15: playlist_callback_single Behavior Documentation

**Amendment:** Document callback scope explicitly.

Add to Section 3.1 (SDK Hooks & Callbacks):
```
### Callback Scope Note

This implementation uses `playlist_callback_single` which ONLY receives
callbacks for the ACTIVE playlist. This means:

1. If user views Playlist A in SimPlaylist
2. Then switches to Playlist B in the playlist manager
3. Any modifications to Playlist A happen in the background
4. SimPlaylist does NOT receive these callbacks

This is intentional - it matches Default UI behavior. For full multi-playlist
awareness, would need to use `playlist_callback` (full) instead.
```

---

## Implementation Checklist

Before starting Phase 1, verify:

- [ ] TitleFormatHelper uses SDK `titleformat_compiler` exclusively
- [ ] Virtual scrolling is in Phase 1 design
- [ ] Album art cache key includes directory path
- [ ] Callback manager locks before dispatch
- [ ] Single-instance assumption documented in FOUNDATION.md
- [ ] Time estimates removed from all phases
- [ ] Keyboard navigation handlers specified
- [ ] Undo backup pattern documented
- [ ] Context menu integration pattern exists
- [ ] Group collapse/expand explicitly deferred

---

### A16: NSView Flipped Coordinates - Critical macOS Pattern (CRITICAL)

**Issue:** NSView by default uses a non-flipped coordinate system where y=0 is at the **BOTTOM**, not the top. This causes views positioned at y=0 to appear at the bottom of their container.

**Symptoms:**
- Header bars appearing at bottom instead of top
- Preferences content appearing at bottom of window
- Content layouts inverted

**Solution:** Create a flipped view subclass for any container that needs top-to-bottom layout:

```objc
// FlippedView.h
@interface FlippedView : NSView
@end

@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// Usage - for preferences, dialogs, any top-to-bottom container
NSView *container = [[FlippedView alloc] initWithFrame:frame];
```

**Alternative:** For non-flipped containers (like the main view), calculate y from top:
```objc
// Position header at TOP in non-flipped container
CGFloat headerHeight = 22;
CGFloat containerHeight = container.bounds.size.height;
headerBar.frame = NSMakeRect(0, containerHeight - headerHeight, width, headerHeight);
headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
```

**Affected Code:**
- SimPlaylistController.mm - Main view container (non-flipped, header positioned at containerHeight - headerHeight)
- SimPlaylistPreferences.mm - Preferences view (uses FlippedView for natural top-to-bottom layout)
- Any modal dialogs or custom panels

---

## Document History

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-22 | 1.0 | Original IMPLEMENTATION_SPEC.md |
| 2025-12-22 | 1.1 | Amendments based on principal review |
| 2025-12-23 | 1.2 | Added A16: NSView flipped coordinates pattern |
