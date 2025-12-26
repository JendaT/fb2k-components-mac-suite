# foo_simplaylist_mac - SimPlaylist for macOS foobar2000

**Project:** Migration of SimPlaylist (foo_simplaylist) to macOS foobar2000
**Research Date:** December 2025
**Status:** Foundation Document - Research Complete

---

## Executive Summary

SimPlaylist is a playlist view component offering multiple grouping levels, album art display, smart column resizing, smooth scrolling, and clickable rating columns. Its unique **subgrouping** feature distinguishes it from other playlist views.

### Key Challenge

The original SimPlaylist source code is **not publicly available** and the author (Frank Bicking) has been inactive for years. This will be a clean-room reimplementation based on documented behavior and feature analysis.

### Unique Value Proposition

SimPlaylist's **subgrouping** capability is not available in any other foobar2000 playlist component, including the default UI playlist. This allows creating nested groups within groups (e.g., Album > Disc Number).

---

## Original Component Analysis

### Source: [Hydrogenaudio Wiki](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Components/SimPlaylist_(foo_simplaylist))

### Developer
- **Author:** Frank Bicking
- **Initial Release:** May 2, 2011
- **Last Stable:** v1.0 (August 18, 2011)
- **Status:** Abandoned (author MIA, no x64 version)

### Core Features

1. **Hierarchical Grouping System**
   - **Headers:** Top-level group identifiers with optional images
   - **Group Columns:** Display alongside track rows (album art, text)
   - **Subgroups:** Nested grouping within main groups (unique feature!)

2. **Album Art Integration**
   - Display in headers, columns, or subgroups
   - Image types: artist, front, back, disc
   - Resizable via Ctrl+mouse wheel
   - Sources: embedded images + file-based images

3. **Column System**
   - Default columns: Album, Artist, Codec, Date, Duration, Playing, Rating, Title, Track
   - Custom columns via title formatting
   - Smart auto-resizing (prioritizes album, artist, title columns)
   - Column color markup with `<` and `>` characters

4. **Group Statistics**
   - Standard: bitrate, file size, dates, item count, length, lossless ratio, rating, ReplayGain
   - Playback Stats (foo_playcount): play counts, timestamps, average ratings

5. **Search Functionality**
   - Embedded search UI element
   - Accessible via Edit > Search (F3)

### Technical Requirements (Original)
- foobar2000 v1.1+
- Windows
- Default UI only
- Last version: 1.0

---

## Groups Configuration (From Screenshot + Windows Config Analysis)

The user-provided screenshot shows the Groups preferences page structure, and analysis of the actual Windows `foo_simplaylist.dll.cfg` file reveals the complete preset data:

### Discovered Presets (from Windows config)

**Preset 1: "Artist - album / cover"**
| Component | Pattern | Display |
|-----------|---------|---------|
| Sorting | `%path_sort%` | - |
| Header | `[%album artist% - ]['['%date%']' ][%album%]` | Text |
| Column | `[%album%]` | Front (album art) |
| Subgroup | `[Disc %discnumber%]` | Text |

**Preset 2: "Artist / cover + album info"**
| Component | Pattern | Display |
|-----------|---------|---------|
| Sorting | `%path_sort%` | - |
| Header | `[%album artist%]` | Text |
| Column | `[%album%\|][%date%\|][%genre%]` | Front (album art) |
| Subgroup | `[Disc %discnumber%]` | Text |

**Preset 3: "Artist / cover / album"**
| Component | Pattern | Display |
|-----------|---------|---------|
| Sorting | `%path_sort%` | - |
| Header | `[%album artist%]` | Text |
| Column | `[%album%]` | Front (album art) |
| Subgroup 1 | `['['%date%']' ][%album%]` | Text |
| Subgroup 2 | `[Disc %discnumber%]` | Text |

**Preset 4: "Album"**
| Component | Pattern | Display |
|-----------|---------|---------|
| Sorting | `%path_sort%` | - |
| Header | `[%album%]` | Text |
| Column | `[%album%]` | Front (album art) |
| Subgroup | `[Disc %discnumber%]` | Text |

### Discovered Column Definitions (from Windows config)

Custom columns found in configuration:
| Name | Pattern |
|------|---------|
| BPM | `[%BPM%]` |
| Key | `[%INITIALKEY%][%INITIAL KEY%]` |
| bitrate | `[%bitrate%] k` |
| profile | `[%codec_profile%]` |
| channels | `[%channels%]` |
| sample | `[%samplerate% Hz][, %__bitspersample%-bit]` |
| Codec | `[%codec%]` |
| Date | `[%date%]` |
| Artist / track | `[%artist%] \n [%title%]` |
| Date added | `$cut(%last_modified%,10)\|%directoryname%\|%filename_ext%` |
| played | `$if2(%play_count%,0)` |

### Configuration Binary Format Notes

The config file contains:
1. Binary headers with GUIDs for each config section
2. String lengths prefixed as 4-byte integers
3. Preset names stored as length-prefixed strings
4. Patterns stored with length prefix followed by UTF-8 text

---

## Visual Layout Model

### Track List with Grouping

```
+--------+------------------------------------------+--------+--------+
|        |                                          | Length | Rating |
+--------+------------------------------------------+--------+--------+
| [ALBUM | [2020] Dark Side of the Moon             |        |        |  <- HEADER
| COVER] |------------------------------------------|--------|--------|
|        | Disc 1                                   |        |        |  <- SUBGROUP
|        |   1. Speak to Me                         |  1:05  |   4    |
|        |   2. Breathe                             |  2:49  |   5    |
|        |   3. On the Run                          |  3:50  |   4    |
|        | Disc 2                                   |        |        |  <- SUBGROUP
|        |   1. Any Colour You Like                 |  3:26  |   4    |
|        |   2. Brain Damage                        |  3:48  |   5    |
|        |   3. Eclipse                             |  2:10  |   5    |
+--------+------------------------------------------+--------+--------+
| [ALBUM | [1973] The Wall                          |        |        |  <- NEXT GROUP
| COVER] |------------------------------------------|--------|--------|
|        | Disc 1                                   |        |        |
|        |   1. In the Flesh?                       |  3:16  |   4    |
```

### Layout Components

1. **Header Row**
   - Spans full width
   - Contains group title (formatted text)
   - Can include header image

2. **Group Column**
   - Fixed position on left side
   - Contains album art or text
   - Spans multiple track rows vertically

3. **Subgroup Row**
   - Indented within group
   - Text label (e.g., "Disc 1")
   - Separates tracks within same group

4. **Track Rows**
   - Standard columns (track number, title, duration, etc.)
   - Indented under subgroups if present

---

## macOS Implementation Architecture

### UI Strategy: Custom NSView (Recommended)

Due to the complex layout requirements (group columns spanning rows, subgroups), a standard NSTableView won't suffice. Options:

1. **Custom NSView with manual layout** (Recommended)
   - Full control over rendering
   - Similar to existing waveform seekbar approach
   - Can implement exact SimPlaylist layout

2. **NSCollectionView with custom layout**
   - Modern approach
   - Complex to get spanning behavior right

3. **NSTableView with row grouping**
   - Limited grouping support
   - Can't achieve group column spanning

### Component Structure

```
foo_simplaylist_mac/
├── src/
│   ├── Core/
│   │   ├── GroupModel.h              # Grouping logic
│   │   ├── GroupModel.mm
│   │   ├── GroupNode.h               # Header/subgroup/track node
│   │   ├── GroupNode.mm
│   │   ├── ColumnDefinition.h        # Column configuration
│   │   ├── ColumnDefinition.mm
│   │   ├── TitleFormatHelper.h       # THIN wrapper for SDK titleformat_compiler
│   │   ├── TitleFormatHelper.mm
│   │   ├── GroupCalculator.h         # Compute groups from playlist
│   │   └── GroupCalculator.mm
│   ├── UI/
│   │   ├── SimPlaylistView.h         # Main custom view
│   │   ├── SimPlaylistView.mm
│   │   ├── SimPlaylistController.h
│   │   ├── SimPlaylistController.mm
│   │   ├── GroupColumnView.h         # Rendered group column (album art)
│   │   ├── GroupColumnView.mm
│   │   ├── HeaderRowView.h           # Header row rendering
│   │   ├── HeaderRowView.mm
│   │   ├── TrackRowView.h            # Track row rendering
│   │   ├── TrackRowView.mm
│   │   ├── SimPlaylistPreferences.h  # Main preferences
│   │   ├── SimPlaylistPreferences.mm
│   │   ├── GroupsPreferences.h       # Groups sub-preferences
│   │   └── GroupsPreferences.mm
│   ├── Integration/
│   │   ├── Main.mm                   # Service registration
│   │   ├── PlaylistCallbacks.h
│   │   ├── PlaylistCallbacks.mm
│   │   ├── AlbumArtLoader.h          # Async album art loading
│   │   └── AlbumArtLoader.mm
│   └── fb2k_sdk.h
├── Resources/
│   └── Assets.xcassets
└── FOUNDATION.md
```

### Data Model

#### GroupNode Hierarchy

```objc
typedef NS_ENUM(NSInteger, GroupNodeType) {
    GroupNodeTypeHeader,      // Group header row
    GroupNodeTypeSubgroup,    // Subgroup separator
    GroupNodeTypeTrack        // Individual track
};

@interface GroupNode : NSObject
@property (nonatomic, assign) GroupNodeType type;
@property (nonatomic, strong) NSString *displayText;      // Formatted text
@property (nonatomic, strong) NSImage *image;             // Album art
@property (nonatomic, assign) NSInteger playlistIndex;    // Track index in playlist
@property (nonatomic, assign) NSInteger indentLevel;      // Nesting depth
@property (nonatomic, strong) NSArray<GroupNode *> *children;  // For headers/subgroups
@end
```

#### GroupModel

```objc
@interface GroupModel : NSObject
@property (nonatomic, strong) NSArray<GroupNode *> *rootNodes;  // Flattened display list
@property (nonatomic, strong) GroupConfiguration *config;

- (void)rebuildFromPlaylist:(NSInteger)playlistIndex;
- (GroupNode *)nodeAtDisplayRow:(NSInteger)row;
- (NSInteger)displayRowCount;
- (NSRect)groupColumnRectForHeaderAtRow:(NSInteger)row;
@end
```

### Grouping Algorithm

```objc
// Pseudocode for grouping logic
- (void)rebuildFromPlaylist:(NSInteger)playlistIndex {
    // 1. Get all tracks from playlist
    NSArray *tracks = [self tracksFromPlaylist:playlistIndex];

    // 2. Sort by sorting pattern
    tracks = [self sortTracks:tracks byPattern:self.config.sortingPattern];

    // 3. Build groups by header pattern
    NSMutableArray *groups = [NSMutableArray array];
    NSString *currentHeaderValue = nil;
    NSMutableArray *currentGroup = nil;

    for (Track *track in tracks) {
        NSString *headerValue = [self formatTrack:track withPattern:self.config.headerPattern];

        if (![headerValue isEqualToString:currentHeaderValue]) {
            // New group
            if (currentGroup) {
                [groups addObject:currentGroup];
            }
            currentGroup = [NSMutableArray array];
            currentHeaderValue = headerValue;

            // Add header node
            GroupNode *header = [GroupNode headerWithText:headerValue];
            [currentGroup addObject:header];
        }

        // 4. Apply subgroup patterns within group
        for (SubgroupConfig *subconfig in self.config.subgroups) {
            NSString *subgroupValue = [self formatTrack:track withPattern:subconfig.pattern];
            // Insert subgroup separators when value changes
        }

        // Add track node
        GroupNode *trackNode = [GroupNode trackWithIndex:track.index];
        [currentGroup addObject:trackNode];
    }

    // 5. Flatten to display list
    self.rootNodes = [self flattenGroups:groups];
}
```

---

## Album Art Loading

### SDK Integration

```cpp
// Using album_art_manager_v3 from SDK
class album_art_loader {
public:
    void load_art_async(metadb_handle_ptr track, album_art_data::ptr* out_data) {
        auto art_mgr = album_art_manager_v3::get();

        // Query album art sources
        album_art_extractor_instance_v2::ptr extractor;
        art_mgr->open(extractor, track->get_location(), abort_callback_dummy());

        if (extractor.is_valid()) {
            album_art_data_ptr data;
            if (extractor->query(album_art_ids::cover_front, data, abort_callback_dummy())) {
                *out_data = data;
            }
        }
    }
};
```

### Caching Strategy

```objc
@interface AlbumArtCache : NSObject
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *imageCache;
@property (nonatomic, strong) NSOperationQueue *loadQueue;

- (void)loadImageForTrack:(metadb_handle_ptr)track
               completion:(void (^)(NSImage *image))completion;
- (void)clearCache;
@end
```

---

## Column System

### Default Columns

| Name | Pattern | Width | Alignment |
|------|---------|-------|-----------|
| Playing | `$if(%isplaying%,>,)` | 20 | Center |
| Track | `%tracknumber%` | 30 | Right |
| Title | `%title%` | Auto | Left |
| Artist | `%artist%` | Auto | Left |
| Album | `%album%` | Auto | Left |
| Duration | `%length%` | 50 | Right |
| Rating | `%rating%` | 60 | Center |

### Column Color Markup

Original SimPlaylist supported dimming/highlighting with `<` and `>` characters:

```
"<dimmed text>"       -> Dimmed (level 1)
"<<more dimmed>>"     -> Dimmed (level 2)
"<<<most dimmed>>>"   -> Dimmed (level 3)
">highlighted<"       -> Highlighted
```

Text in parentheses, brackets, braces is automatically dimmed.

### Auto-Resizing Logic

Columns named `album`, `artist`, or `title` get priority for auto-expansion when window resizes.

---

## Preferences UI Design

### Groups Preferences Page (Match Screenshot)

```
+--------------------------------------------------+
| Presets                                          |
| +----------------------------------------------+ |
| | [x] Artist - album / cover                   | |
| | [x] Artist / cover + album info              | |
| | [x] Artist / cover / album                   | |
| | [x] Album                                    | |
| +----------------------------------------------+ |
|                                                  |
| Headers                                     Disp.|
| +----------------------------------------------+ |
| | [%album artist%]                       | Text | |
| +----------------------------------------------+ |
|                                                  |
| Columns                                    Disp. |
| +----------------------------------------------+ |
| | [%album%]                             | Front | |
| +----------------------------------------------+ |
|                                                  |
| Sorting pattern: [%path_sort%          ] [v]    |
|                                                  |
| Subgroups                                  Disp. |
| +----------------------------------------------+ |
| | ['['%date%']' ][%album%]              | Text | |
| | [Disc %discnumber%]                   | Text | |
| +----------------------------------------------+ |
|                                                  |
| [Syntax help]                                    |
|                                                  |
| [Reset all]  [Reset page]    [OK] [Cancel] [Apply] |
+--------------------------------------------------+
```

### Display Types for Groups

| Type | Description |
|------|-------------|
| Text | Formatted text only |
| Front | Front cover album art |
| Back | Back cover album art |
| Disc | Disc image |
| Artist | Artist image |

### Main Preferences Page

```
+--------------------------------------------------+
| SimPlaylist Settings                             |
+--------------------------------------------------+
|                                                  |
| [x] Show row numbers                             |
| [x] Enable smooth scrolling                      |
| [x] Auto-expand all groups                       |
|                                                  |
| Row height: [24] px                              |
| Header height: [32] px                           |
| Group column width: [80] px                      |
|                                                  |
| Default group preset: [Artist - album / cover v] |
|                                                  |
| Columns: [Configure...]                          |
| Groups: [Configure...]                           |
|                                                  |
| [Reset to Defaults]                              |
+--------------------------------------------------+
```

---

## Configuration Storage

### Config Keys

```cpp
namespace simplaylist_config {
    static const char* const kConfigPrefix = "foo_simplaylist_mac.";

    // Groups
    static const char* const kGroupPresets = "group_presets";      // JSON array
    static const char* const kActivePreset = "active_preset";
    static const char* const kHeaderPattern = "header_pattern";
    static const char* const kHeaderDisplay = "header_display";
    static const char* const kColumnPattern = "column_pattern";
    static const char* const kColumnDisplay = "column_display";
    static const char* const kSubgroups = "subgroups";             // JSON array
    static const char* const kSortingPattern = "sorting_pattern";

    // Columns
    static const char* const kColumns = "columns";                 // JSON array

    // Appearance
    static const char* const kRowHeight = "row_height";
    static const char* const kHeaderHeight = "header_height";
    static const char* const kGroupColumnWidth = "group_column_width";
    static const char* const kShowRowNumbers = "show_row_numbers";
    static const char* const kSmoothScrolling = "smooth_scrolling";
    static const char* const kAutoExpand = "auto_expand";
}
```

### Preset Storage Format (JSON)

```json
{
  "presets": [
    {
      "name": "Artist - album / cover",
      "header": {
        "pattern": "[%album artist%]",
        "display": "text"
      },
      "column": {
        "pattern": "[%album%]",
        "display": "front"
      },
      "subgroups": [
        {"pattern": "['['%date%']' ][%album%]", "display": "text"},
        {"pattern": "[Disc %discnumber%]", "display": "text"}
      ],
      "sorting": "%path_sort%"
    }
  ]
}
```

---

## SDK Integration Points

### ui_element_mac Implementation

```cpp
class simplaylist_ui_element : public ui_element_mac {
public:
    service_ptr instantiate(service_ptr arg) override {
        return fb2k::wrapNSObject([[SimPlaylistController alloc] init]);
    }

    bool match_name(const char* name) override {
        return strcmp(name, "SimPlaylist") == 0 ||
               strcmp(name, "simplaylist") == 0 ||
               strcmp(name, "sim_playlist") == 0;
    }

    fb2k::stringRef get_name() override {
        return fb2k::makeString("SimPlaylist");
    }

    GUID get_guid() override {
        // Unique GUID for SimPlaylist
        return { 0xB2C3D4E5, 0xF6A7, 0x8901, {0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A} };
    }

    FB2K_MAKE_SERVICE_INTERFACE_ENTRYPOINT(ui_element_mac);
};
```

### Playlist Content Access

```cpp
// Get tracks from active playlist
void get_playlist_tracks(std::vector<metadb_handle_ptr>& out) {
    auto pm = playlist_manager::get();
    t_size playlist_idx = pm->get_active_playlist();
    t_size count = pm->playlist_get_item_count(playlist_idx);

    out.reserve(count);
    for (t_size i = 0; i < count; i++) {
        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, playlist_idx, i)) {
            out.push_back(handle);
        }
    }
}
```

### Title Formatting (SDK Exclusive)

**CRITICAL:** Always use SDK's titleformat_compiler. Never implement custom parsing.

```cpp
// TitleFormatHelper.h - Thin wrapper ONLY
class TitleFormatHelper {
public:
    // Compile pattern (with fallback on error)
    static titleformat_object::ptr compile(const char* pattern) {
        titleformat_object::ptr tf;
        titleformat_compiler::get()->compile_safe_ex(tf, pattern, "%filename%");
        return tf;
    }

    // Format a track
    static std::string format(metadb_handle_ptr track, titleformat_object::ptr script) {
        pfc::string8 out;
        track->format_title(nullptr, out, script, nullptr);
        return std::string(out.c_str());
    }
};

// Usage in GroupCalculator
void GroupCalculator::calculateGroups() {
    auto headerScript = TitleFormatHelper::compile(m_config.headerPattern.c_str());

    for (auto& track : m_tracks) {
        std::string headerValue = TitleFormatHelper::format(track, headerScript);
        // Compare headerValue to determine group boundaries
    }
}
```

---

## Integration with Default View Columns

Per user request, SimPlaylist should adopt column settings from the default playlist view where applicable:

1. **Column Definitions**
   - Read default UI column configuration via SDK (if exposed)
   - Fall back to sensible defaults if not accessible

2. **Title Formatting Compatibility**
   - Use same title formatting syntax as default UI
   - Support all standard fields and functions

3. **Groups-Only Configuration**
   - Primary custom configuration is for groups
   - Columns can optionally be configured separately or inherited

---

## Scope Limitations (v1.0)

**IMPORTANT:** These scope limitations are binding for v1.0 implementation.

### Instance Model
- **Single instance only** following active playlist
- Multiple SimPlaylist panels will all display the same playlist (active)
- Uses `playlist_callback_single_impl_base` (not full `playlist_callback`)
- Multi-instance with per-panel playlist binding is **NOT in v1.0 scope**

### Title Formatting
- **MUST use SDK's `titleformat_compiler` exclusively**
- Do NOT implement custom title formatting parser
- SDK handles all 200+ fields, 100+ functions, plugin-provided fields
- TitleFormatHelper is a thin wrapper only

### Deferred Features (Post-v1.0)

The following features from the original SimPlaylist are explicitly deferred:

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

---

## Implementation Phases

**Note:** See AMENDMENTS.md for detailed "done when" criteria. Phase dependency graph:

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

### Phase 1: Foundation (INCLUDES Virtual Scrolling)

1. **Project Setup**
   - Create Xcode project
   - SDK linking
   - Basic component registration

2. **Data Models**
   - `GroupNode` class
   - `GroupModel` class
   - `ColumnDefinition` class
   - TitleFormatHelper (thin SDK wrapper only)

3. **Core View with Virtual Scrolling**
   - Custom `SimPlaylistView` (NSView subclass)
   - **Virtual scrolling from day one** (render only visible rows)
   - Flat track list rendering (no grouping yet)
   - Selection and focus handling
   - Basic keyboard navigation

### Phase 2: Grouping

1. **Group Calculation**
   - Header grouping by pattern (using SDK titleformat)
   - Subgroup support
   - Sorting by pattern

2. **Group Rendering**
   - Header rows
   - Subgroup separators
   - Indented track rows

3. **Group Column**
   - Album art loading (async)
   - Group column spanning multiple rows
   - Image caching with directory-qualified keys

### Phase 3: Album Art (Can run parallel with Phase 4)

1. **Album Art System**
   - AlbumArtCache with collision-resistant keys
   - Async loading via album_art_manager_v3
   - Placeholder for missing art
   - Ctrl+scroll resizing

### Phase 4: Column System (Can run parallel with Phase 3)

1. **Column Rendering**
   - Multiple columns
   - Auto-resizing (album/artist/title priority)
   - Column reordering (drag headers)
   - Horizontal scroll sync with header bar

2. **Column Formatting**
   - Color markup (`<` `>`)
   - Text dimming for parentheses/brackets

### Phase 5: Interactive Features

1. **Playback Integration**
   - Double-click to play
   - Now playing indicator
   - Duration column toggle

2. **Context Menu**
   - Full context menu via contextmenu_manager_v2
   - NSMenu building from menu_tree_item

3. **Drag & Drop**
   - Reorder within playlist (with undo backup)
   - Import from Finder

### Phase 6: Polish

1. **Preferences**
   - Groups preferences page
   - Main preferences page
   - Columns configuration

2. **Quality**
   - Dark mode support
   - Accessibility labels
   - Performance profiling
   - Memory leak checking
   - Documentation

---

## Technical Challenges

### 1. Group Column Spanning

The group column (album art) must span multiple track rows. This requires:
- Calculating row ranges for each group
- Clipping drawing to group bounds
- Handling partial visibility during scrolling

### 2. Efficient Rendering

For large playlists (10k+ tracks):
- Use `NSView` drawing with dirty rect optimization
- Cache formatted strings
- Lazy-load album art
- Only render visible rows

### 3. Title Formatting (RESOLVED)

**Use SDK's `titleformat_compiler` exclusively.** This is mandatory, not optional.

```cpp
titleformat_object::ptr tf;
titleformat_compiler::get()->compile_safe_ex(tf, pattern, "%filename%");
track->format_title(nullptr, out, tf, nullptr);
```

Benefits:
- Full compatibility with all 200+ fields and 100+ functions
- Plugin-provided fields work automatically (foo_playcount, etc.)
- Playback context fields (%isplaying%, etc.) handled correctly
- No maintenance burden

### 4. Sync with Playlist Changes

When playlist content changes:
- Recalculate groups efficiently
- Preserve scroll position where possible
- Update selection state

---

## References

### Documentation
- [Hydrogenaudio Wiki - SimPlaylist](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Components/SimPlaylist_(foo_simplaylist))
- [foobar2000 SDK](https://www.foobar2000.org/SDK)
- [foobar2000 Title Formatting Reference](https://wiki.hydrogenaudio.org/index.php?title=Foobar2000:Title_Formatting_Reference)

### Related Components
- [foobar2000 Components - SimPlaylist](https://www.foobar2000.org/components/view/foo_simplaylist)
- [ELPlaylist (similar concept)](https://wiki.hydrogenaud.io/index.php?title=Foobar2000:Components_0.9/ELplaylist_panel_(foo_uie_elplaylist))

### macOS Development
- [Apple NSView Documentation](https://developer.apple.com/documentation/appkit/nsview)
- [Custom Drawing Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaDrawingGuide)

---

## Document History

| Date | Version | Changes |
|------|---------|---------|
| 2025-12-22 | 1.0 | Initial foundation document |
| 2025-12-22 | 1.1 | Added scope limitations, updated phases per amendments |

---

## Related Documents

- **IMPLEMENTATION_SPEC.md** - Detailed implementation specification
- **AMENDMENTS.md** - Critical amendments and corrections

---

**Next Steps:** Begin Phase 1 implementation with basic view, virtual scrolling, and SDK title formatting wrapper.
