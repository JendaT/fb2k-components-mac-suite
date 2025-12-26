# foo_plorg_mac - Playlist Organizer for macOS foobar2000

Hierarchical playlist organization with folders for foobar2000 on macOS.

## Features

- Organize playlists into folders with unlimited nesting
- Drag & drop to reorder playlists and folders
- Customizable node display formatting
- Auto-sync with foobar2000 playlist changes
- Native macOS UI (NSOutlineView)
- Dark mode support

## Requirements

- macOS 11.0 (Big Sur) or later
- Xcode 14.0 or later
- foobar2000 SDK 2025-03-07

## Building

### 1. Build SDK Libraries

First, build the foobar2000 SDK libraries if not already done:

```bash
cd ../SDK-2025-03-07/foobar2000
xcodebuild -workspace foobar2000.xcworkspace -scheme "foobar2000 SDK" -configuration Release build
```

### 2. Generate Xcode Project

```bash
cd foo_plorg_mac
ruby Scripts/generate_xcode_project.rb
```

### 3. Build

Using script:
```bash
./Scripts/build.sh Release
```

Or open in Xcode:
```bash
open foo_plorg.xcodeproj
```

Then build with Cmd+B.

### 4. Install

```bash
./Scripts/install.sh
```

Or manually copy `build/Release/foo_plorg.component` to:
- `~/Library/foobar2000-v2/user-components/foo_plorg/`

## Usage

1. In foobar2000, go to View menu
2. Add "Playlist Organizer" panel to your layout
3. Right-click to create folders and organize playlists
4. Drag & drop to reorder

## Configuration

Settings are stored via `fb2k::configStore` and persist automatically.

### Node Format

Customize how nodes are displayed using the node format pattern:
- `%node_name%` - Name of folder or playlist
- `%is_folder%` - "1" for folders, empty for playlists
- `%count%` - Number of children (folders) or tracks (playlists)

Default format: `%node_name%$if(%is_folder%,' ['%count%']',)`

## Project Structure

```
foo_plorg_mac/
├── src/
│   ├── Core/
│   │   ├── TreeNode.h/.mm      # Tree node model
│   │   ├── TreeModel.h/.mm     # Tree management
│   │   └── ConfigHelper.h      # Configuration storage
│   ├── UI/
│   │   ├── PlaylistOrganizerController.h/.mm  # Main controller
│   ├── Integration/
│   │   ├── Main.mm             # Component registration
│   │   └── PlaylistCallbacks.mm # Playlist sync
│   ├── fb2k_sdk.h
│   └── Prefix.pch
├── Resources/
│   └── Info.plist
├── Scripts/
│   ├── generate_xcode_project.rb
│   ├── build.sh
│   └── install.sh
├── FOUNDATION.md               # Technical design document
└── README.md
```

## Development Notes

### macOS Coordinate System (Common Gotcha)

macOS uses a **bottom-up coordinate system** where `y=0` is at the BOTTOM of the view, not the top. This is opposite to most other platforms and can cause UI elements to appear aligned to the bottom instead of the top.

**Problem:**
```objc
// BAD: This will place content at the bottom!
CGFloat y = containerHeight - 20;  // Start from "top"
label.frame = NSMakeRect(20, y, 200, 20);
y -= 30;  // Move "down"... actually moves up in the coordinate system
```

**Solution:** Use Auto Layout with constraints pinned to the TOP of the container:
```objc
// GOOD: Pin views to top using Auto Layout
view.translatesAutoresizingMaskIntoConstraints = NO;
[container addSubview:view];
[NSLayoutConstraint activateConstraints:@[
    [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
    [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
]];
```

This ensures content flows from top to bottom regardless of container size.

### NSScrollView/NSOutlineView Column Sizing (Critical)

When embedding an NSScrollView with NSOutlineView/NSTableView in a foobar2000 component (or any host app container), **you MUST set `autoresizingMask` on the scroll view** for columns to resize properly:

**Problem:** Columns appear clipped, content extends beyond visible area, or columns don't expand to fill available width.

**Solution:**
```objc
// CRITICAL: Set autoresizingMask on scroll view!
self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

// Outline view also needs autoresizing
self.outlineView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

// For two columns (name expands, count fixed):
NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"NameColumn"];
nameColumn.resizingMask = NSTableColumnAutoresizingMask;

NSTableColumn *countColumn = [[NSTableColumn alloc] initWithIdentifier:@"CountColumn"];
countColumn.resizingMask = NSTableColumnNoResizing;
countColumn.width = 40;
countColumn.minWidth = 40;
countColumn.maxWidth = 40;

// First column expands to fill available space
self.outlineView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

// After view loads, call sizeLastColumnToFit
dispatch_async(dispatch_get_main_queue(), ^{
    [self.outlineView sizeLastColumnToFit];
});
```

Without the `autoresizingMask` on the scroll view, the view won't receive proper size updates from the parent container, causing column width calculations to fail.

### Configuration Storage

The tree structure is stored as a human-editable YAML file at:
```
~/Library/foobar2000-v2/foo_plorg.yaml
```

Example:
```yaml
# Playlist Organizer Configuration
node_format: "%node_name%$if(%is_folder%, [%count%],)"

tree:
  - folder: "Rock"
    expanded: true
    items:
      - playlist: "Classic Rock"
      - playlist: "Metal"
  - playlist: "All Music"
```

## License

MIT License

## Acknowledgments

- Based on foo_plorg by Holger Stenger
- foobar2000 by Peter Pawlowski
