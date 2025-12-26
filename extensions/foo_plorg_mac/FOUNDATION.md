# foo_plorg_mac - Playlist Organizer for macOS foobar2000

**Project:** Migration of Playlist Organizer (foo_plorg) to macOS foobar2000
**Research Date:** December 2025
**Version:** 1.1
**Status:** Foundation Complete - Ready for Implementation

---

## Executive Summary

foo_plorg (Playlist Organizer) is a foobar2000 component that provides hierarchical playlist organization using a tree view with folders. This document outlines the research and technical approach for migrating this functionality to macOS foobar2000.

### Key Challenge

The original foo_plorg source code is **not publicly available**. This will be a clean-room reimplementation based on documented behavior and feature analysis.

---

## Original Component Analysis

### Source: [Hydrogenaudio Wiki](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Components/Playlist_Organizer_(foo_plorg))

### Core Features

1. **Tree View Organization**
   - Playlists and folders in hierarchical tree structure
   - Multiple nesting levels supported
   - Visual indicators for selected, active, and playing playlists
   - Folder child counts displayed via title formatting

2. **Drag & Drop**
   - Internal: Move playlists/folders within tree; add playlist contents to others
   - Export: Drag to Windows folders as `.fpl` files; Ctrl+drag copies track files
   - Import: Accept playlists, tracks, and `.fpl` files with intelligent naming

3. **Configuration**
   - Single-click activation option
   - Double-click to play next track
   - Auto-reveal playing playlists
   - Customizable node formatting using title formatting patterns

4. **Title Formatting Variables**
   - `%node_name%` - folder or playlist name
   - `%is_folder%` - boolean folder identifier
   - `%count%` - child count for folders, item count for playlists
   - `%playlist_duration%` - total duration
   - `%playlist_size%` - total file size

5. **Context Menu Operations**
   - Activate, rename, delete items
   - Sort folder contents alphabetically
   - Access autoplaylist properties
   - View playlist contents
   - Customize appearance and colors
   - Restore previously deleted playlists
   - Create new playlists and folders

### Technical Requirements (Original)
- foobar2000 v1.3+
- Windows 32-bit
- Last version: 2.6 (October 2015)

---

## foobar2000 Playlist Architecture

### Playlist Storage Model

foobar2000 stores playlists in a flat list internally via the `playlist_manager` service. **There is no native tree/folder structure** - foo_plorg implements the tree organization as an overlay on top of the flat playlist list.

### Key SDK Classes

```cpp
// Core playlist management
class playlist_manager : public service_base {
    // Get number of playlists
    virtual t_size get_playlist_count() = 0;

    // Create new playlist, returns index
    virtual t_size create_playlist(const char* name, t_size count, t_size idx) = 0;

    // Get/set playlist name
    virtual bool playlist_get_name(t_size idx, pfc::string_base& out) = 0;
    virtual bool playlist_rename(t_size idx, const char* name, t_size len) = 0;

    // Get playlist item count
    virtual t_size playlist_get_item_count(t_size idx) = 0;

    // Activate playlist
    virtual void set_active_playlist(t_size idx) = 0;
    virtual t_size get_active_playlist() = 0;

    // Playing playlist
    virtual t_size get_playing_playlist() = 0;

    // Remove playlists
    virtual bool remove_playlists(const pfc::bit_array& mask) = 0;

    // Reorder playlists
    virtual bool reorder(const t_size* order, t_size count) = 0;
};

// Extended playlist manager (v2)
class playlist_manager_v2 : public playlist_manager {
    // Persistent properties - survive restart
    virtual void playlist_set_property(t_size idx, const GUID& key,
                                       stream_reader* data, abort_callback&) = 0;
    virtual bool playlist_get_property(t_size idx, const GUID& key,
                                       stream_writer* out, abort_callback&) = 0;
};
```

### Playlist Callbacks

```cpp
class playlist_callback {
    // Playlist structure changes
    virtual void on_playlists_reorder(const t_size* order, t_size count) {}
    virtual void on_playlists_removing(const pfc::bit_array& mask, t_size old_count, t_size new_count) {}
    virtual void on_playlists_removed(const pfc::bit_array& mask, t_size old_count, t_size new_count) {}
    virtual void on_playlist_created(t_size idx, const char* name, t_size len) {}
    virtual void on_playlist_renamed(t_size idx, const char* name, t_size len) {}

    // Active/playing changes
    virtual void on_playlist_activate(t_size old_idx, t_size new_idx) {}
    virtual void on_playback_starting(t_size playlist_idx, t_size item_idx) {}
};
```

---

## Tree Structure Implementation Strategy

### Discovered Format: Simple Text Markup (from Windows foo_plorg.dll.cfg)

**Analysis of actual Windows configuration revealed the storage format:**

The original foo_plorg stores its tree structure using a simple newline-delimited text format with XML-like tags:

```
<F>E-klidek
<P>5-liquid/space
<P>7-ambient
<P>8-berlin electro
<P>4-psychill
<P>9-electronic/world
<P>20-ambient/space komplet
</F>
<F>E-elektro narezek
<P>3-goa
<P>1-psytrance (full-on, klasika)
<P>0-darkpsy
<P>2-progressive
<P>10-electronica
<P>12-IDM
</F>
<F>N-jiny veci
<P>6-psychedelia
<P>21-Povidani
<P>19-TO DEWAL WITH
<P>15-jazz
<P>16-reggae/dub
<P>13-classical
<P>14-art/alt/rock
<P>11-darkwave
</F>
<P>17-local/temp
<P>24-plugged/temp
<P>18-Zuzanka
<P>22-Library view
<P>23-Filter Results
```

**Format Specification:**
| Tag | Meaning |
|-----|---------|
| `<F>name` | Start a folder with given name |
| `</F>` | Close the current folder |
| `<P>name` | Reference a playlist by its display name |

**Key Observations:**
1. Folders can be nested (though this example shows only one level)
2. Playlist references use the **display name** shown in the playlist manager
3. Playlists outside folders appear at root level
4. The format supports UTF-8 (Czech characters visible in original)

### Configuration File Structure

The `.cfg` file contains:
1. **Binary header** with GUIDs (16 bytes + component identifiers)
2. **Title format pattern**: `%node_name%$if(%is_folder%,' ['%count%']',)`
3. **Tree structure** in text markup format
4. **Binary footer** with color settings and flags

### Playlist Index Reference

foobar2000 v2.0 stores playlists in `playlists-v2.0/index.txt`:
```
GUID:PlaylistName
021477DD-595C-4D96-9A22-EEFBE7547F4D:psychedelia/space rock
73FE9E2C-AAC7-4E55-934C-6C4989879036:psychill
BA4D06C3-3BA6-4E89-B496-F7B3F719079F:psychill mp3 all
```

### Recommended macOS Implementation: YAML

For macOS, we'll use YAML format via [Yams](https://github.com/jpsim/Yams) library for human-readable configuration:

```yaml
version: 1
nodeFormat: "%node_name%$if(%is_folder%,' ['%count%']',)"

tree:
  - folder: Jádro Pudla
    items:
      - playlist: CEEL Legendus inspired by pudl
      - playlist: Jádro pudla 2 years
      - playlist: Jádro Pudla 7
      - folder: koncepty
        items:
          - playlist: kazdej track s akustickou vlozkou
      - playlist: neco
  - folder: ambient
    items:
      - playlist: festien ambival
      - playlist: psychedelicious ambient
      - playlist: liquid/space
  - folder: chillout
    items:
      - folder: ">- selekce"
        items:
          - playlist: dub tech sel
          - playlist: Good times
      - playlist: other playlist
  - playlist: local/temp
  - playlist: Filter Results
```

**Schema Rules:**
- `folder:` - folder name, requires `items:` with contents
- `playlist:` - playlist name (leaf node)
- `items:` - list of children (folders or playlists)
- Unlimited nesting depth supported

**Advantages of YAML:**
- Human-readable and editable
- Supports comments for documentation
- Yams library is mature, fast (built on LibYAML), Codable-compatible
- Clear visual hierarchy matches tree structure

**Dependency:**
```swift
// Package.swift
.package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
```

**Swift Parsing with Yams + Codable:**

```swift
import Yams

// MARK: - Data Model

enum TreeNode: Codable {
    case folder(name: String, items: [TreeNode])
    case playlist(name: String)

    private enum CodingKeys: String, CodingKey {
        case folder, playlist, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let folderName = try container.decodeIfPresent(String.self, forKey: .folder) {
            let items = try container.decode([TreeNode].self, forKey: .items)
            self = .folder(name: folderName, items: items)
        } else if let playlistName = try container.decodeIfPresent(String.self, forKey: .playlist) {
            self = .playlist(name: playlistName)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "Expected 'folder' or 'playlist' key"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let name, let items):
            try container.encode(name, forKey: .folder)
            try container.encode(items, forKey: .items)
        case .playlist(let name):
            try container.encode(name, forKey: .playlist)
        }
    }
}

struct TreeConfig: Codable {
    let version: Int
    let nodeFormat: String
    let tree: [TreeNode]
}

// MARK: - Loading/Saving

func loadTree(from yaml: String) throws -> TreeConfig {
    let decoder = YAMLDecoder()
    return try decoder.decode(TreeConfig.self, from: yaml)
}

func saveTree(_ config: TreeConfig) throws -> String {
    let encoder = YAMLEncoder()
    return try encoder.encode(config)
}
```

**Sync Strategy:**
1. Store tree in `fb2k::configStore` as YAML string
2. Match playlists by name (same as original)
3. When playlist renamed: update reference in tree
4. When playlist deleted: remove from tree (or mark as missing)

---

## macOS Implementation Architecture

### Component Structure

```
foo_plorg_mac/
├── src/
│   ├── Core/
│   │   ├── TreeNode.swift           # TreeNode enum (folder/playlist)
│   │   ├── TreeConfig.swift         # TreeConfig struct + Codable
│   │   ├── TreeModel.swift          # Tree operations, search, sync
│   │   ├── PlaylistBridge.h         # C++ ↔ Swift bridge for playlist_manager
│   │   ├── PlaylistBridge.mm
│   │   ├── ConfigHelper.h           # fb2k::configStore wrapper
│   │   └── ConfigHelper.mm
│   ├── UI/
│   │   ├── PlaylistOrganizerView.swift    # NSOutlineView subclass
│   │   ├── PlaylistOrganizerController.swift
│   │   ├── TreeCellView.swift       # Custom cell for icons/formatting
│   │   ├── OrganizerPreferences.swift     # Preferences page
│   │   └── OrganizerPreferences.xib
│   ├── Integration/
│   │   ├── Main.mm                  # Service registration (C++)
│   │   ├── PlaylistCallbacks.h      # playlist_callback implementation
│   │   ├── PlaylistCallbacks.mm
│   │   └── foo_plorg_mac-Bridging-Header.h
│   └── fb2k_sdk.h
├── Resources/
│   └── Assets.xcassets              # Folder/playlist icons (SF Symbols)
├── Dependencies/
│   └── Yams/                        # YAML parsing (SPM or embedded)
└── FOUNDATION.md
```

**Language Strategy:**
- **Swift** for UI and tree model (modern, safe, NSOutlineView integration)
- **Objective-C++** for SDK integration (playlist_manager, callbacks)
- **Bridging Header** connects Swift ↔ Objective-C++

### Key Cocoa Classes

#### NSOutlineView for Tree Display

```objc
@interface PlaylistOrganizerView : NSOutlineView <NSOutlineViewDataSource, NSOutlineViewDelegate>
@property (nonatomic, strong) TreeModel *treeModel;
@end

// NSOutlineViewDataSource
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item;
- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item;

// NSOutlineViewDelegate
- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item;
- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item;
```

#### Drag & Drop Support

```objc
// Register drag types
[outlineView registerForDraggedTypes:@[
    @"com.foobar2000.playlist",       // Internal playlist node
    @"com.foobar2000.folder",         // Internal folder node
    NSPasteboardTypeFileURL,          // External files/playlists
    @"public.audio"                   // Audio files
]];

// Drag source
- (BOOL)outlineView:(NSOutlineView *)outlineView writeItems:(NSArray *)items toPasteboard:(NSPasteboard *)pboard;
- (NSDragOperation)outlineView:(NSOutlineView *)outlineView draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context;

// Drop target
- (NSDragOperation)outlineView:(NSOutlineView *)outlineView validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index;
- (BOOL)outlineView:(NSOutlineView *)outlineView acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index;
```

### SDK Integration Points

#### ui_element_mac Implementation

```cpp
class playlist_organizer_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        return fb2k::wrapNSObject([[PlaylistOrganizerController alloc] init]);
    }

    bool match_name(const char* name) override {
        return strcmp(name, "Playlist Organizer") == 0 ||
               strcmp(name, "playlist_organizer") == 0 ||
               strcmp(name, "foo_plorg") == 0;
    }

    fb2k::stringRef get_name() override {
        return fb2k::makeString("Playlist Organizer");
    }

    GUID get_guid() override {
        // {A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
        return { 0xA1B2C3D4, 0xE5F6, 0x7890, {0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90} };
    }

    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(ui_element_mac);
};
```

#### playlist_callback Implementation

```cpp
class organizer_playlist_callback : public playlist_callback {
public:
    void on_playlist_created(t_size idx, const char* name, t_size len) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TreeModel shared] handlePlaylistCreated:idx name:@(name)];
        });
    }

    void on_playlists_removed(const pfc::bit_array& mask, t_size old_count, t_size new_count) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TreeModel shared] handlePlaylistsRemoved];
        });
    }

    void on_playlist_renamed(t_size idx, const char* name, t_size len) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TreeModel shared] handlePlaylistRenamed:idx name:@(name)];
        });
    }

    void on_playlist_activate(t_size old_idx, t_size new_idx) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[TreeModel shared] handlePlaylistActivated:new_idx];
        });
    }
};
```

---

## Configuration Storage

### Tree Structure Storage

```cpp
namespace plorg_config {
    static const char* const kConfigPrefix = "foo_plorg_mac.";
    static const char* const kTreeStructure = "tree_structure";
    static const char* const kExpandedNodes = "expanded_nodes";

    // Behavior settings
    static const char* const kSingleClickActivate = "single_click_activate";
    static const char* const kDoubleClickPlay = "double_click_play";
    static const char* const kAutoRevealPlaying = "auto_reveal_playing";

    // Appearance
    static const char* const kNodeFormat = "node_format";
    static const char* const kShowIcons = "show_icons";
}
```

### Default Values

```cpp
// Default node format
static const char* kDefaultNodeFormat = "$if(%is_folder%,%node_name% (%count%),%node_name%)";

// Default behavior
static const bool kDefaultSingleClickActivate = false;
static const bool kDefaultDoubleClickPlay = true;
static const bool kDefaultAutoRevealPlaying = true;
```

---

## User Interface Design

### Main Tree View

```
+------------------------------------------+
| [+] Rock                         (15)    |
|     [>] Heavy Metal              (7)     |
|         Metallica Favorites              |  <- playlist
|         Iron Maiden Collection           |
|     [>] Classic Rock             (8)     |
|         Led Zeppelin                     |
|         Pink Floyd                       |
| [+] Jazz                         (12)    |
|     Miles Davis                          |
|     John Coltrane                        |
| [>] Electronic                   (23)    |
| [*] Now Playing: My Mix          (45)    |  <- playing indicator
+------------------------------------------+
```

### Context Menu

```
+------------------------+
| New Folder             |
| New Playlist           |
| ---                    |
| Rename                 |
| Delete                 |
| ---                    |
| Sort A-Z               |
| Sort Z-A               |
| ---                    |
| Expand All             |
| Collapse All           |
| ---                    |
| Properties...          |
+------------------------+
```

### Preferences Page

```
+------------------------------------------+
| Playlist Organizer Settings              |
+------------------------------------------+
|                                          |
| Behavior:                                |
|   [ ] Activate playlist on single click  |
|   [x] Play next track on double-click    |
|   [x] Auto-reveal currently playing      |
|                                          |
| Appearance:                              |
|   [x] Show folder/playlist icons         |
|   Node format:                           |
|   +------------------------------------+ |
|   | $if(%is_folder%,%node_name%...    | |
|   +------------------------------------+ |
|   [Syntax Help]                          |
|                                          |
| [Reset to Defaults]                      |
+------------------------------------------+
```

---

## Scope Limitations (v1.0)

**IMPORTANT:** These scope limitations are binding for v1.0 implementation.

### Title Formatting for Nodes

The original foo_plorg supported title formatting variables for node display:
- `%node_name%`, `%is_folder%`, `%count%`, `%playlist_duration%`, `%playlist_size%`

**v1.0 Approach:**
- Implement **simple variable substitution** (not full title formatting parser)
- Support only: `%node_name%`, `%is_folder%`, `%count%`
- `%playlist_duration%` and `%playlist_size%` require iterating all tracks - **deferred**
- Do NOT use SDK's titleformat_compiler (it's for track metadata, not tree nodes)

### Instance Model
- **Single shared tree** across all Playlist Organizer panels
- Multiple panels show the same tree (synced via NotificationCenter)
- This matches original foo_plorg behavior

### Deferred Features (Post-v1.0)

1. **Deleted Playlist Recovery** - Session-based undo for deleted playlists
2. **FPL Export via Drag** - Export playlists by dragging to Finder
3. **Playlist Duration/Size** - Calculating total duration/size for display
4. **Custom Colors** - Per-folder color customization
5. **Autoplaylist Properties** - Edit autoplaylist queries from context menu

---

## Implementation Phases

**Phase Dependency Graph:**
```
Phase 1 (Foundation)
    |
    v
Phase 2 (Tree UI)
    |
    v
Phase 3 (Playlist Integration)
    |
    v
Phase 4 (Drag & Drop)
    |
    v
Phase 5 (Preferences & Polish)
```

### Phase 1: Foundation

**Goal:** Project compiles, component loads, YAML parsing works.

**Tasks:**
1. Create Xcode project with SDK linking
2. Add Yams dependency (SPM or embedded source)
3. Implement `TreeNode` enum and `TreeConfig` struct with Codable
4. Implement `ConfigHelper` for fb2k::configStore access
5. Basic `Main.mm` with component registration
6. Verify component loads in foobar2000

**Done When:**
- [ ] Component appears in foobar2000 View menu
- [ ] Can load/save YAML tree config via configStore
- [ ] Unit tests pass for TreeNode encoding/decoding

**Deliverables:**
- `TreeNode.swift`, `TreeConfig.swift`
- `ConfigHelper.h/.mm`
- `Main.mm` with ui_element_mac registration
- Working Xcode project

---

### Phase 2: Tree UI

**Goal:** NSOutlineView displays tree, expand/collapse works.

**Tasks:**
1. Create `PlaylistOrganizerController` (NSViewController)
2. Create `PlaylistOrganizerView` (NSOutlineView subclass)
3. Implement NSOutlineViewDataSource for TreeModel
4. Implement NSOutlineViewDelegate for cell rendering
5. Create `TreeCellView` with folder/playlist icons
6. Add expand/collapse state persistence

**Done When:**
- [ ] Tree displays folders and playlists from YAML config
- [ ] Folders expand/collapse with disclosure triangles
- [ ] Expand state persists across app restart
- [ ] SF Symbols display for folder/playlist icons

**Deliverables:**
- `PlaylistOrganizerController.swift`
- `PlaylistOrganizerView.swift`
- `TreeCellView.swift`
- Icon assets in Assets.xcassets

---

### Phase 3: Playlist Integration

**Goal:** Tree interacts with foobar2000 playlists.

**Tasks:**
1. Implement `PlaylistBridge` (C++ ↔ Swift)
   - Get playlist count, names, indices
   - Activate playlist by index
   - Create/delete/rename playlists
2. Implement `playlist_callback` for live updates
   - on_playlist_created → add to "Unfiled" or prompt
   - on_playlist_renamed → update tree reference
   - on_playlists_removed → remove from tree
   - on_playlist_activate → highlight in tree
3. Single-click to select, double-click to activate
4. Visual indicators for active/playing playlist
5. Auto-reveal currently playing playlist

**Done When:**
- [ ] Clicking playlist activates it in foobar2000
- [ ] Creating playlist in foobar2000 appears in tree
- [ ] Renaming playlist updates tree display
- [ ] Deleting playlist removes from tree
- [ ] Active playlist highlighted
- [ ] Playing playlist has distinct indicator

**Deliverables:**
- `PlaylistBridge.h/.mm`
- `PlaylistCallbacks.h/.mm`
- Updated TreeModel with sync logic

---

### Phase 4: Drag & Drop

**Goal:** Reorder tree via drag & drop.

**Tasks:**
1. Register drag types for internal reordering
2. Implement drag source (writeItems to pasteboard)
3. Implement drop validation (validateDrop)
4. Implement drop acceptance (acceptDrop)
5. Support moving playlists between folders
6. Support moving folders (with children)
7. Support reordering within same folder
8. Auto-save tree after drag operations

**Done When:**
- [ ] Can drag playlist to different folder
- [ ] Can drag folder to different location
- [ ] Can reorder items within folder
- [ ] Tree persists after drag operations
- [ ] Visual feedback during drag (insertion marker)

**Deliverables:**
- Drag & drop implementation in PlaylistOrganizerView
- Updated TreeModel with move operations

---

### Phase 5: Context Menu & Preferences

**Goal:** Full context menu, preferences page.

**Tasks:**
1. Implement context menu:
   - New Folder / New Playlist
   - Rename / Delete
   - Sort A-Z / Sort Z-A
   - Expand All / Collapse All
2. Create preferences page:
   - Behavior: single-click activate, double-click play, auto-reveal
   - Appearance: show icons, node format pattern
3. Implement node format variable substitution
4. Dark mode support
5. Keyboard shortcuts (Delete, Enter to rename, arrows)

**Done When:**
- [ ] Right-click shows context menu
- [ ] Can create new folder via context menu
- [ ] Can rename items (inline editing or dialog)
- [ ] Can delete items with confirmation
- [ ] Preferences page appears in foobar2000 Preferences
- [ ] Settings persist and apply immediately
- [ ] Works correctly in dark mode

**Deliverables:**
- Context menu implementation
- `OrganizerPreferences.swift` + XIB
- Preferences page registration in Main.mm

---

### Phase 6: Polish & Testing

**Goal:** Production-ready quality.

**Tasks:**
1. Performance testing with 500+ playlists
2. Memory leak checking (Instruments)
3. Edge case handling:
   - Empty tree
   - Playlist names with special characters
   - Very long playlist names
   - Unicode playlist names
4. Accessibility labels for VoiceOver
5. Documentation and README
6. Final code review and cleanup

**Done When:**
- [ ] No memory leaks detected
- [ ] Handles 500+ playlists smoothly
- [ ] All edge cases handled gracefully
- [ ] VoiceOver can navigate tree
- [ ] README with installation instructions

---

## Technical Challenges

### 1. Swift ↔ C++ Bridge

The SDK is C++, but NSOutlineView works best with Swift/Objective-C.

**Solution:** Create `PlaylistBridge` class in Objective-C++ that:
- Wraps playlist_manager calls
- Converts between C++ strings (pfc::string8) and NSString
- Posts notifications for playlist changes

```objc
// PlaylistBridge.h
@interface PlaylistBridge : NSObject
+ (instancetype)shared;
- (NSInteger)playlistCount;
- (NSString *)playlistNameAtIndex:(NSInteger)index;
- (void)activatePlaylistAtIndex:(NSInteger)index;
- (void)createPlaylistWithName:(NSString *)name;
- (void)deletePlaylistAtIndex:(NSInteger)index;
@end
```

### 2. Tree ↔ Playlist Sync

Playlists can be created/deleted outside the organizer. Tree must stay in sync.

**Solution:**
- Implement full `playlist_callback`
- On playlist created: Add to root level or "Unfiled" folder
- On playlist renamed: Find by old name, update reference
- On playlist deleted: Remove from tree, save immediately
- Use playlist **name** as identifier (same as original foo_plorg)

**Edge Case:** Two playlists with same name
- Original foo_plorg allows this (references first match)
- We'll do the same, but log a warning

### 3. Expand State Persistence

Users expect folders to stay expanded/collapsed across sessions.

**Solution:**
- Store expanded folder paths as array in configStore
- On load: expand folders matching stored paths
- On expand/collapse: update stored paths

```swift
// Stored as: ["Jádro Pudla", "Jádro Pudla/koncepty", "ambient"]
func saveExpandedState() {
    let paths = expandedFolderPaths()
    ConfigHelper.setStringArray("expanded_folders", paths)
}
```

### 4. Node Format Variables

Original foo_plorg uses title formatting syntax but with custom variables.

**Solution:** Simple string replacement (not full parser):

```swift
func formatNode(_ node: TreeNode, format: String) -> String {
    var result = format

    switch node {
    case .folder(let name, let items):
        result = result.replacingOccurrences(of: "%node_name%", with: name)
        result = result.replacingOccurrences(of: "%is_folder%", with: "1")
        result = result.replacingOccurrences(of: "%count%", with: "\(items.count)")
    case .playlist(let name):
        result = result.replacingOccurrences(of: "%node_name%", with: name)
        result = result.replacingOccurrences(of: "%is_folder%", with: "")
        result = result.replacingOccurrences(of: "%count%", with: getPlaylistItemCount(name))
    }

    // Handle $if() - simple version
    // $if(%is_folder%,text_if_true,text_if_false)
    result = evaluateSimpleIf(result)

    return result
}
```

### 5. Yams Integration in Component Bundle

foobar2000 components are bundles, not apps. Need to embed Yams correctly.

**Solution:**
- Use SPM to fetch Yams
- Build Yams as static library
- Link into component bundle
- OR: Embed Yams source files directly (it's ~10 files)

---

## Known Limitations & Decisions

### Will NOT Implement (Initially)

1. **Deleted Playlist History** - Original kept deleted playlists recoverable during session. This adds complexity; may add later.

2. **FPL Export via Drag** - macOS drag-to-Finder export behavior differs from Windows. Will evaluate feasibility.

3. **Column UI Support** - Original supported Column UI panel. macOS foobar2000 uses different UI paradigm. Focus on Default UI element only.

### Platform Differences

| Feature | Windows foo_plorg | macOS foo_plorg_mac |
|---------|-------------------|---------------------|
| Tree Control | Win32 TreeView | NSOutlineView |
| Icons | Custom GDI | SF Symbols / Assets |
| Drag & Drop | OLE D&D | Cocoa NSDragging |
| Config Storage | cfg_var | fb2k::configStore |
| UI Integration | CUI Panel / DUI Element | ui_element_mac |

---

## References

### Documentation
- [Hydrogenaudio Wiki - foo_plorg](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Components/Playlist_Organizer_(foo_plorg))
- [foobar2000 SDK](https://www.foobar2000.org/SDK)
- [Playlist Manager API](http://foosion.foobar2000.org/doxygen/latest/classplaylist__manager.html)

### Reverse Engineering Resources
- [foobar2000 index.dat format](https://darekkay.com/blog/foobar2000-playlist-index-format/)
- [FPL Parser](https://github.com/yellowcrescent/fplreader)

### Related Projects
- [Playlist-Manager-SMP](https://github.com/regorxxx/Playlist-Manager-SMP) - Spider Monkey Panel script with similar functionality

---

## Document History

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-22 | 1.0 | Initial foundation document |
| 2025-12-22 | 1.1 | Finalized with implementation phases, technical challenges, scope limitations |

---

## Appendix A: Quick Reference

### Key Files to Create (Phase 1)

```
src/Core/TreeNode.swift         # TreeNode enum
src/Core/TreeConfig.swift       # TreeConfig struct + Codable
src/Core/ConfigHelper.h         # fb2k::configStore C++ wrapper
src/Core/ConfigHelper.mm
src/Integration/Main.mm         # Component entry point
```

### Essential SDK Headers

```cpp
#include <foobar2000/SDK/playlist.h>      // playlist_manager, playlist_callback
#include <foobar2000/SDK/ui_element.h>    // ui_element_mac
#include <foobar2000/SDK/config.h>        // fb2k::configStore
```

### Build Settings Checklist

- [ ] Deployment target: macOS 11.0+
- [ ] C++ Language Dialect: C++17
- [ ] Swift Language Version: Swift 5
- [ ] Header Search Paths: `$(SDK_PATH)/SDK-2025-03-07/**`
- [ ] Library Search Paths: `$(SDK_PATH)/SDK-2025-03-07/build/Release`
- [ ] Other Linker Flags: `-lfoobar2000_SDK -lpfc`
- [ ] Product Extension: `component`

---

**Status:** ✅ Foundation Complete - Ready for Phase 1 Implementation
