# foo_jl_plorg

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/plorg.md)** | **[Changelog](CHANGELOG.md)**

---

Hierarchical playlist organization with folders for foobar2000 macOS.

## Requirements

- macOS 12.0 (Monterey) or later
- Xcode 15 or later
- foobar2000 SDK 2026-10-01 (at the repository root, see the [main README](../../README.md#building-from-source))

## Building

1. Build the SDK libraries once, as described in [Building from Source](../../README.md#building-from-source) in the main README.

2. Build and install (generates the Xcode project on the first run):
   ```bash
   ./Scripts/build.sh --install
   ```

   Don't build from Xcode: it writes to DerivedData, and `install.sh` copies `build/Release`.

3. Restart foobar2000.

## Usage

1. Open **View → Layout → Edit Layout...**, add a line with `plorg` inside a splitter where you want the panel, and click **Apply**
2. Right-click in the panel to create folders and playlists
3. Drag & drop to reorder

## Configuration

Settings are stored via `fb2k::configStore` and persist automatically.

### Node Format

The Node Format field in the preferences (default `%node_name%`) is saved but not applied yet: the tree shows plain names, with item counts in their own column.

## Project Structure

```
foo_jl_plorg_mac/
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
