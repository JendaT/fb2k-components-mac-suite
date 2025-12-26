//
//  PlaylistOrganizerController.mm
//  foo_plorg_mac
//

#import "PlaylistOrganizerController.h"
#import "PathMappingWindowController.h"
#import "../Core/TreeModel.h"
#import "../Core/TreeNode.h"
#import "../Core/ConfigHelper.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sqlite3.h>

// For playlist_manager access
#include "../fb2k_sdk.h"

static const char *kTreeNodeKey = "treeNode";


@interface PlaylistOrganizerController () <NSTextFieldDelegate, PathMappingWindowDelegate>
@property (nonatomic, strong) NSOutlineView *outlineView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) TreeModel *treeModel;
@property (nonatomic, weak) TreeNode *editingNode;  // Node currently being edited inline
@property (nonatomic, strong) PathMappingWindowController *pathMappingController;
@property (nonatomic, copy) NSString *pendingThemePath;
@property (nonatomic, copy) NSString *pendingPlaylistsDir;
@property (nonatomic, copy) NSString *activePlaylistName;  // Currently active playlist in foobar2000
@end

@implementation PlaylistOrganizerController

#pragma mark - Lifecycle

- (instancetype)init {
    console::info("[Plorg] Controller init");
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _treeModel = [TreeModel shared];
        console::info("[Plorg] Controller init completed");
    }
    return self;
}

- (void)loadView {
    // Create scroll view
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 250, 400)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Create outline view
    self.outlineView = [[NSOutlineView alloc] initWithFrame:self.scrollView.bounds];
    self.outlineView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.outlineView.dataSource = self;
    self.outlineView.delegate = self;
    self.outlineView.headerView = nil;  // No header
    self.outlineView.floatsGroupRows = NO;
    self.outlineView.allowsMultipleSelection = YES;  // Enable shift/cmd-click selection
    self.outlineView.indentationPerLevel = 13.0;  // Match native sidebar indentation
    self.outlineView.rowHeight = 15.0;  // Compact row height
    self.outlineView.intercellSpacing = NSMakeSize(0, 0);  // Remove gaps between cells

    // Enable drag & drop
    [self.outlineView registerForDraggedTypes:@[
        @"com.foobar2000.plorg.node",  // Internal drag
    ]];
    self.outlineView.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleSourceList;

    // Name column - main content
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"NameColumn"];
    nameColumn.resizingMask = NSTableColumnAutoresizingMask;
    [self.outlineView addTableColumn:nameColumn];
    self.outlineView.outlineTableColumn = nameColumn;

    // Count column - fixed width (just enough for 4-5 digits)
    NSTableColumn *countColumn = [[NSTableColumn alloc] initWithIdentifier:@"CountColumn"];
    countColumn.resizingMask = NSTableColumnNoResizing;
    countColumn.width = 35;
    countColumn.minWidth = 35;
    countColumn.maxWidth = 35;
    [self.outlineView addTableColumn:countColumn];

    // First column expands to fill available space
    self.outlineView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;

    // Style as source list
    self.outlineView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;

    self.scrollView.documentView = self.outlineView;
    self.view = self.scrollView;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Load tree from config
    [self.treeModel loadFromConfig];

    // Get initial active playlist
    [self refreshActivePlaylist];

    // Sync any missing playlists from foobar2000 (delayed to not block startup)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.treeModel syncWithFoobarPlaylists];
    });

    // Register for tree changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(treeModelDidChange:)
                                                 name:TreeModelDidChangeNotification
                                               object:nil];

    // Register for settings changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(settingsDidChange:)
                                                 name:@"PlorgSettingsChanged"
                                               object:nil];

    // Register for active playlist changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(activePlaylistDidChange:)
                                                 name:@"PlorgActivePlaylistChanged"
                                               object:nil];

    // Size columns after layout (delayed to ensure proper bounds)
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.outlineView sizeLastColumnToFit];
    });

    // Set up context menu
    [self setupContextMenu];

    // Initial reload
    [self reloadTree];

    // Select and reveal active playlist on startup (delayed to ensure view is ready)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self selectActivePlaylist];
    });
}

- (void)selectActivePlaylist {
    if (!self.activePlaylistName) return;

    TreeNode *node = [self.treeModel findPlaylistWithName:self.activePlaylistName];
    if (!node) return;

    // Expand parent folders to make it visible
    TreeNode *parent = node.parent;
    while (parent) {
        parent.isExpanded = YES;
        [self.outlineView expandItem:parent];
        parent = parent.parent;
    }

    // Select and scroll to the playlist
    NSInteger row = [self.outlineView rowForItem:node];
    if (row >= 0) {
        [self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self.outlineView scrollRowToVisible:row];
    }
}

- (void)refreshActivePlaylist {
    @try {
        auto pm = playlist_manager::get();
        t_size activeIndex = pm->get_active_playlist();
        if (activeIndex != pfc_infinite) {
            pfc::string8 name;
            pm->playlist_get_name(activeIndex, name);
            self.activePlaylistName = [NSString stringWithUTF8String:name.c_str()];
        } else {
            self.activePlaylistName = nil;
        }
    } @catch (...) {
        self.activePlaylistName = nil;
    }
}

- (void)activePlaylistDidChange:(NSNotification *)notification {
    NSString *newName = notification.userInfo[@"playlistName"];
    if (![self.activePlaylistName isEqualToString:newName]) {
        // Find old and new active playlist nodes to refresh only those rows
        TreeNode *oldActiveNode = self.activePlaylistName ? [self.treeModel findPlaylistWithName:self.activePlaylistName] : nil;
        TreeNode *newActiveNode = newName ? [self.treeModel findPlaylistWithName:newName] : nil;

        self.activePlaylistName = newName;

        // Refresh only the affected rows (preserves selection)
        if (oldActiveNode) {
            NSInteger row = [self.outlineView rowForItem:oldActiveNode];
            if (row >= 0) {
                [self.outlineView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                           columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.outlineView.numberOfColumns)]];
            }
        }
        if (newActiveNode) {
            NSInteger row = [self.outlineView rowForItem:newActiveNode];
            if (row >= 0) {
                [self.outlineView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                                           columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.outlineView.numberOfColumns)]];
            }
        }
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Context Menu

- (void)setupContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Context"];

    [menu addItemWithTitle:@"New Folder" action:@selector(createFolder:) keyEquivalent:@""];
    [menu addItemWithTitle:@"New Playlist" action:@selector(createPlaylist:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Rename" action:@selector(renameItem:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Delete" action:@selector(deleteItem:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Sort A-Z" action:@selector(sortAscending:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Sort Z-A" action:@selector(sortDescending:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Expand All" action:@selector(expandAll) keyEquivalent:@""];
    [menu addItemWithTitle:@"Collapse All" action:@selector(collapseAll) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    // Import submenu
    NSMenuItem *importItem = [[NSMenuItem alloc] initWithTitle:@"Import" action:nil keyEquivalent:@""];
    NSMenu *importMenu = [[NSMenu alloc] initWithTitle:@"Import"];
    [importMenu addItemWithTitle:@"From YAML File..." action:@selector(importFromYAML:) keyEquivalent:@""];
    [importMenu addItemWithTitle:@"From Strawberry Player..." action:@selector(importFromStrawberry:) keyEquivalent:@""];
    [importMenu addItemWithTitle:@"From DeaDBeeF Player..." action:@selector(importFromDeaDBeeF:) keyEquivalent:@""];
    [importMenu addItemWithTitle:@"From Vox Player..." action:@selector(importFromVox:) keyEquivalent:@""];
    [importMenu addItemWithTitle:@"From Old foo_plorg (theme.fth)..." action:@selector(importFromOldPlorg:) keyEquivalent:@""];
    [importMenu addItem:[NSMenuItem separatorItem]];
    [importMenu addItemWithTitle:@"Add Missing foobar2000 Playlists" action:@selector(importMissingPlaylists:) keyEquivalent:@""];
    importItem.submenu = importMenu;
    [menu addItem:importItem];

    [menu addItemWithTitle:@"Export Tree..." action:@selector(exportTree:) keyEquivalent:@""];

    self.outlineView.menu = menu;
}

#pragma mark - Actions

- (void)reloadTree {
    [self.outlineView reloadData];

    // Restore expanded state
    for (TreeNode *node in self.treeModel.rootNodes) {
        [self restoreExpandedStateForNode:node];
    }
}

- (void)restoreExpandedStateForNode:(TreeNode *)node {
    if (node.isFolder) {
        if (node.isExpanded) {
            [self.outlineView expandItem:node];
        }
        for (TreeNode *child in node.children) {
            [self restoreExpandedStateForNode:child];
        }
    }
}

- (void)expandAll {
    [self.outlineView expandItem:nil expandChildren:YES];
}

- (void)collapseAll {
    [self.outlineView collapseItem:nil collapseChildren:YES];
}

- (void)revealPlaylist:(NSString *)playlistName {
    TreeNode *node = [self.treeModel findPlaylistWithName:playlistName];
    if (!node) return;

    // Expand all parent folders
    TreeNode *parent = node.parent;
    while (parent) {
        parent.isExpanded = YES;
        [self.outlineView expandItem:parent];
        parent = parent.parent;
    }

    // Select and scroll to the playlist
    NSInteger row = [self.outlineView rowForItem:node];
    if (row >= 0) {
        [self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self.outlineView scrollRowToVisible:row];
    }
}

#pragma mark - Context Menu Actions

- (IBAction)createFolder:(id)sender {
    NSInteger row = self.outlineView.clickedRow;
    TreeNode *targetNode = row >= 0 ? [self.outlineView itemAtRow:row] : nil;

    TreeNode *newFolder = [TreeNode folderWithName:@"New Folder"];

    if (targetNode && targetNode.isFolder) {
        // Add inside clicked folder (at end)
        [targetNode addChild:newFolder];
        [self.outlineView expandItem:targetNode];
        [self.treeModel saveToConfig];
    } else if (targetNode && targetNode.parent) {
        // Add as sibling AFTER the clicked item
        NSInteger idx = [targetNode.parent.children indexOfObject:targetNode];
        [targetNode.parent insertChild:newFolder atIndex:idx + 1];
        [self.treeModel saveToConfig];
    } else if (targetNode) {
        // Clicked item is at root level - insert after it
        NSInteger idx = [self.treeModel.rootNodes indexOfObject:targetNode];
        [self.treeModel insertRootNode:newFolder atIndex:idx + 1];
    } else {
        // Add at root (addRootNode saves automatically)
        [self.treeModel addRootNode:newFolder];
    }

    [self.outlineView reloadData];

    // Start inline editing after a brief delay to let the view update
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startEditingNode:newFolder];
    });
}

- (IBAction)createPlaylist:(id)sender {
    NSInteger row = self.outlineView.clickedRow;
    TreeNode *targetNode = row >= 0 ? [self.outlineView itemAtRow:row] : nil;
    TreeNode *targetFolder = nil;
    NSInteger insertAfterIndex = -1;  // Index to insert after (-1 = append)

    // Determine target folder and insertion position
    if (targetNode && targetNode.isFolder) {
        targetFolder = targetNode;
        // Insert at end of folder
    } else if (targetNode && targetNode.parent) {
        targetFolder = targetNode.parent;
        // Insert after clicked item
        insertAfterIndex = [targetFolder.children indexOfObject:targetNode];
    } else if (targetNode) {
        // Root level item - insert after it
        insertAfterIndex = [self.treeModel.rootNodes indexOfObject:targetNode];
    }

    // Create playlist in foobar2000 first
    @try {
        auto pm = playlist_manager::get();
        pfc::string8 name = "New Playlist";

        // Find unique name
        int suffix = 1;
        while (true) {
            bool found = false;
            t_size count = pm->get_playlist_count();
            for (t_size i = 0; i < count; i++) {
                pfc::string8 existingName;
                pm->playlist_get_name(i, existingName);
                if (existingName == name) {
                    found = true;
                    break;
                }
            }
            if (!found) break;
            name.reset();
            name << "New Playlist " << suffix++;
        }

        // Create the playlist in foobar2000
        pm->create_playlist(name.c_str(), name.get_length(), pfc::infinite_size);

        // Create node and add to target location (bypass playlist_callback adding to root)
        NSString *playlistName = [NSString stringWithUTF8String:name.c_str()];
        TreeNode *newPlaylist = [TreeNode playlistWithName:playlistName];

        if (targetFolder) {
            if (insertAfterIndex >= 0) {
                [targetFolder insertChild:newPlaylist atIndex:insertAfterIndex + 1];
            } else {
                [targetFolder addChild:newPlaylist];
            }
            [self.outlineView expandItem:targetFolder];
            [self.treeModel saveToConfig];
        } else if (insertAfterIndex >= 0) {
            [self.treeModel insertRootNode:newPlaylist atIndex:insertAfterIndex + 1];
        } else {
            [self.treeModel addRootNode:newPlaylist];
        }

        [self.outlineView reloadData];

        // Start inline editing after a brief delay to let the view update
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startEditingNode:newPlaylist];
        });
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Failed to create playlist";
    }
}

- (IBAction)renameItem:(id)sender {
    NSInteger row = self.outlineView.clickedRow;
    if (row < 0) return;

    TreeNode *node = [self.outlineView itemAtRow:row];
    if (!node) return;

    // Use inline editing
    [self startEditingNode:node];
}

- (IBAction)deleteItem:(id)sender {
    // Collect all selected nodes
    NSIndexSet *selectedIndexes = self.outlineView.selectedRowIndexes;
    if (selectedIndexes.count == 0) return;

    NSMutableArray<TreeNode *> *nodesToDelete = [NSMutableArray array];
    [selectedIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        TreeNode *node = [self.outlineView itemAtRow:idx];
        if (node) {
            [nodesToDelete addObject:node];
        }
    }];

    if (nodesToDelete.count == 0) return;

    // Count folders and playlists
    NSInteger folderCount = 0;
    NSInteger playlistCount = 0;
    BOOL hasNonEmptyFolders = NO;

    for (TreeNode *node in nodesToDelete) {
        if (node.isFolder) {
            folderCount++;
            if (node.children.count > 0) {
                hasNonEmptyFolders = YES;
            }
        } else {
            playlistCount++;
        }
    }

    // Confirm deletion
    NSAlert *alert = [[NSAlert alloc] init];
    NSButton *deleteContentsCheckbox = nil;
    NSButton *keepInFoobarCheckbox = nil;

    if (nodesToDelete.count == 1) {
        TreeNode *node = nodesToDelete.firstObject;
        if (node.isFolder) {
            alert.messageText = [NSString stringWithFormat:@"Delete folder \"%@\"?", node.name];
            if (node.children.count > 0) {
                alert.informativeText = @"By default, playlists inside will be moved to root and deleted from foobar2000.";
            } else {
                alert.informativeText = @"The folder is empty.";
            }
        } else {
            alert.messageText = [NSString stringWithFormat:@"Delete \"%@\"?", node.name];
            alert.informativeText = @"The playlist will be deleted from foobar2000.";
        }
    } else {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        if (folderCount > 0) {
            [parts addObject:[NSString stringWithFormat:@"%ld folder%@", (long)folderCount, folderCount == 1 ? @"" : @"s"]];
        }
        if (playlistCount > 0) {
            [parts addObject:[NSString stringWithFormat:@"%ld playlist%@", (long)playlistCount, playlistCount == 1 ? @"" : @"s"]];
        }
        alert.messageText = [NSString stringWithFormat:@"Delete %@?", [parts componentsJoinedByString:@" and "]];
        alert.informativeText = @"Playlists will be deleted from foobar2000.";
    }

    // Add checkboxes if needed
    if (hasNonEmptyFolders || playlistCount > 0) {
        NSView *accessoryView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, hasNonEmptyFolders ? 44 : 22)];
        CGFloat y = 0;

        keepInFoobarCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(0, y, 300, 18)];
        keepInFoobarCheckbox.buttonType = NSButtonTypeSwitch;
        keepInFoobarCheckbox.title = @"Keep playlists in foobar2000";
        keepInFoobarCheckbox.state = NSControlStateValueOff;
        [accessoryView addSubview:keepInFoobarCheckbox];
        y += 22;

        if (hasNonEmptyFolders) {
            deleteContentsCheckbox = [[NSButton alloc] initWithFrame:NSMakeRect(0, y, 300, 18)];
            deleteContentsCheckbox.buttonType = NSButtonTypeSwitch;
            deleteContentsCheckbox.title = @"Also delete all playlists inside folders";
            deleteContentsCheckbox.state = NSControlStateValueOff;
            [accessoryView addSubview:deleteContentsCheckbox];
        }

        alert.accessoryView = accessoryView;
    }

    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    BOOL deleteContents = deleteContentsCheckbox && (deleteContentsCheckbox.state == NSControlStateValueOn);
    BOOL keepInFoobar = keepInFoobarCheckbox && (keepInFoobarCheckbox.state == NSControlStateValueOn);

    // Delete all selected nodes (process in reverse to avoid index issues)
    for (TreeNode *node in [nodesToDelete reverseObjectEnumerator]) {
        TreeNode *parent = node.parent;

        // Delete playlists from foobar2000 if not keeping
        if (!keepInFoobar) {
            [self deletePlaylistsFromFoobar:node recursive:deleteContents];
        }

        if (node.isFolder && !deleteContents) {
            // Move children to parent or root
            NSArray *children = [node.children copy];
            for (TreeNode *child in children) {
                [node removeChild:child];
                if (parent) {
                    [parent addChild:child];
                } else {
                    child.parent = nil;
                    [[self.treeModel valueForKey:@"mutableRootNodes"] addObject:child];
                }
            }
        }

        // Remove the node
        if (parent) {
            [parent removeChild:node];
        } else {
            [self.treeModel removeRootNode:node];
        }
    }

    [self.outlineView reloadData];
    [self.treeModel saveToConfig];
}

- (void)deletePlaylistsFromFoobar:(TreeNode *)node recursive:(BOOL)recursive {
    @try {
        auto pm = playlist_manager::get();

        if (!node.isFolder) {
            // Find and delete this playlist
            t_size count = pm->get_playlist_count();
            for (t_size i = 0; i < count; i++) {
                pfc::string8 name;
                pm->playlist_get_name(i, name);
                if ([node.name isEqualToString:[NSString stringWithUTF8String:name.c_str()]]) {
                    pm->remove_playlist(i);
                    FB2K_console_formatter() << "[Plorg] Deleted playlist: " << name.c_str();
                    break;
                }
            }
        } else if (recursive) {
            // Delete all playlists in folder recursively
            for (TreeNode *child in node.children) {
                [self deletePlaylistsFromFoobar:child recursive:YES];
            }
        }
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Failed to delete playlist from foobar2000";
    }
}

- (IBAction)sortAscending:(id)sender {
    [self sortSelectedFolderAscending:YES];
}

- (IBAction)sortDescending:(id)sender {
    [self sortSelectedFolderAscending:NO];
}

- (void)sortSelectedFolderAscending:(BOOL)ascending {
    NSInteger row = self.outlineView.clickedRow;
    TreeNode *targetNode = row >= 0 ? [self.outlineView itemAtRow:row] : nil;

    NSMutableArray *nodesToSort;
    if (targetNode && targetNode.isFolder) {
        nodesToSort = targetNode.children;
    } else {
        // Can't sort root from here easily - would need access to mutableRootNodes
        return;
    }

    [nodesToSort sortUsingComparator:^NSComparisonResult(TreeNode *a, TreeNode *b) {
        NSComparisonResult result = [a.name localizedStandardCompare:b.name];
        if (!ascending) {
            if (result == NSOrderedAscending) return NSOrderedDescending;
            if (result == NSOrderedDescending) return NSOrderedAscending;
        }
        return result;
    }];

    [self.outlineView reloadItem:targetNode reloadChildren:YES];
    [self.treeModel saveToConfig];
}

#pragma mark - Tree Model Notifications

- (void)treeModelDidChange:(NSNotification *)notification {
    TreeModelChangeType type = (TreeModelChangeType)[notification.userInfo[TreeModelChangeTypeKey] integerValue];

    switch (type) {
        case TreeModelChangeTypeReload:
            [self reloadTree];
            break;
        case TreeModelChangeTypeInsert:
        case TreeModelChangeTypeRemove:
        case TreeModelChangeTypeUpdate:
        case TreeModelChangeTypeMove:
            [self.outlineView reloadData];
            break;
    }
}

- (void)settingsDidChange:(NSNotification *)notification {
    [self.outlineView reloadData];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (!item) {
        return self.treeModel.rootNodes.count;
    }
    TreeNode *node = (TreeNode *)item;
    return node.childCount;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (!item) {
        return self.treeModel.rootNodes[index];
    }
    TreeNode *node = (TreeNode *)item;
    return [node childAtIndex:index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    TreeNode *node = (TreeNode *)item;
    return node.isFolder;
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    TreeNode *node = (TreeNode *)item;

    // Count column - simple right-aligned text
    if ([tableColumn.identifier isEqualToString:@"CountColumn"]) {
        NSTableCellView *cellView = [outlineView makeViewWithIdentifier:@"CountCell" owner:self];
        if (!cellView) {
            cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 35, 17)];
            cellView.identifier = @"CountCell";

            NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
            textField.translatesAutoresizingMaskIntoConstraints = NO;
            textField.bordered = NO;
            textField.drawsBackground = NO;
            textField.editable = NO;
            textField.selectable = NO;
            textField.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
            textField.textColor = [NSColor secondaryLabelColor];
            textField.alignment = NSTextAlignmentRight;
            [cellView addSubview:textField];
            cellView.textField = textField;

            // Auto Layout for vertical centering
            [NSLayoutConstraint activateConstraints:@[
                [textField.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor],
                [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor],
                [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
            ]];
        }

        NSInteger count = node.isFolder ? node.childCount : [self getPlaylistItemCount:node.name];
        cellView.textField.stringValue = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : @"";
        return cellView;
    }

    // Name column
    BOOL showIcons = plorg_config::getConfigBool(plorg_config::kShowIcons, true);
    NSString *cellId = showIcons ? @"IconCell" : @"TextCell";
    NSTableCellView *cellView = [outlineView makeViewWithIdentifier:cellId owner:self];

    if (!cellView) {
        cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 17)];
        cellView.identifier = cellId;

        CGFloat textLeading = showIcons ? 17 : 0;  // Icon 13px + 4px gap

        if (showIcons) {
            NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
            imageView.translatesAutoresizingMaskIntoConstraints = NO;
            imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
            [cellView addSubview:imageView];
            cellView.imageView = imageView;

            // Auto Layout - center icon vertically, fixed size 13x13
            [NSLayoutConstraint activateConstraints:@[
                [imageView.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor],
                [imageView.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor],
                [imageView.widthAnchor constraintEqualToConstant:13],
                [imageView.heightAnchor constraintEqualToConstant:13]
            ]];
        }

        NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.bordered = NO;
        textField.drawsBackground = NO;
        textField.editable = YES;
        textField.selectable = YES;
        textField.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        textField.focusRingType = NSFocusRingTypeNone;
        [cellView addSubview:textField];
        cellView.textField = textField;

        // Auto Layout - center text vertically, fill width
        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:textLeading],
            [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor],
            [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
        ]];
    }

    // Store node reference in text field for delegate callbacks
    cellView.textField.delegate = self;
    objc_setAssociatedObject(cellView.textField, kTreeNodeKey, node, OBJC_ASSOCIATION_ASSIGN);

    // Check if this is the active playlist
    BOOL isActivePlaylist = !node.isFolder && self.activePlaylistName &&
                            [node.name isEqualToString:self.activePlaylistName];

    // Set icon if showing
    if (showIcons && cellView.imageView) {
        if (node.isFolder) {
            cellView.imageView.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:@"Folder"];
        } else if (isActivePlaylist) {
            // Use a different icon for active playlist (playing indicator)
            cellView.imageView.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:@"Active Playlist"];
        } else {
            cellView.imageView.image = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:@"Playlist"];
        }
    }

    // Set text with bold for active playlist
    cellView.textField.stringValue = node.name;
    if (isActivePlaylist) {
        cellView.textField.font = [NSFont boldSystemFontOfSize:[NSFont systemFontSize]];
    } else {
        cellView.textField.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
    }

    return cellView;
}

- (NSString *)formattedNameForNode:(TreeNode *)node {
    NSString *format = self.treeModel.nodeFormat;
    if (!format || format.length == 0) {
        return node.name;
    }

    // Get count: child count for folders, track count for playlists
    NSInteger count = 0;
    if (node.isFolder) {
        count = node.childCount;
    } else {
        // Get playlist track count from foobar2000
        count = [self getPlaylistItemCount:node.name];
    }

    // Use TreeNode's formatting method
    return [node formattedNameWithFormat:format playlistItemCount:count];
}

- (NSInteger)getPlaylistItemCount:(NSString *)playlistName {
    @try {
        auto pm = playlist_manager::get();
        t_size playlistCount = pm->get_playlist_count();
        for (t_size i = 0; i < playlistCount; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            if ([playlistName isEqualToString:[NSString stringWithUTF8String:name.c_str()]]) {
                return (NSInteger)pm->playlist_get_item_count(i);
            }
        }
    } @catch (...) {
        // Silently fail
    }
    return 0;
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    TreeNode *node = notification.userInfo[@"NSObject"];
    if (node.isFolder) {
        node.isExpanded = YES;
        [self.treeModel saveToConfig];
    }
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
    TreeNode *node = notification.userInfo[@"NSObject"];
    if (node.isFolder) {
        node.isExpanded = NO;
        [self.treeModel saveToConfig];
    }
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.outlineView.selectedRow;
    if (row < 0) return;

    TreeNode *node = [self.outlineView itemAtRow:row];
    if (!node || node.isFolder) return;

    // Activate the playlist in foobar2000
    @try {
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            if (strcmp(name.c_str(), [node.name UTF8String]) == 0) {
                pm->set_active_playlist(i);
                break;
            }
        }
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Failed to activate playlist";
    }
}

#pragma mark - Drag & Drop

- (BOOL)outlineView:(NSOutlineView *)outlineView writeItems:(NSArray *)items toPasteboard:(NSPasteboard *)pasteboard {
    [pasteboard declareTypes:@[@"com.foobar2000.plorg.node"] owner:self];

    // Store the dragged items (we'll retrieve them in acceptDrop)
    NSMutableArray *paths = [NSMutableArray array];
    for (TreeNode *node in items) {
        [paths addObject:node.path];
    }

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:paths requiringSecureCoding:NO error:nil];
    [pasteboard setData:data forType:@"com.foobar2000.plorg.node"];

    return YES;
}

- (NSDragOperation)outlineView:(NSOutlineView *)outlineView validateDrop:(id<NSDraggingInfo>)info proposedItem:(id)item proposedChildIndex:(NSInteger)index {
    // Only allow drops on folders or at root
    if (item && ![(TreeNode *)item isFolder]) {
        return NSDragOperationNone;
    }

    return NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index {
    NSPasteboard *pasteboard = info.draggingPasteboard;
    NSData *data = [pasteboard dataForType:@"com.foobar2000.plorg.node"];
    if (!data) return NO;

    NSArray *paths = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSArray class] fromData:data error:nil];
    if (!paths || paths.count == 0) return NO;

    TreeNode *targetFolder = (TreeNode *)item;  // nil means root
    NSInteger targetIndex = (index == NSOutlineViewDropOnItemIndex) ? 0 : index;

    // Find and move each dragged node
    for (NSString *path in paths) {
        TreeNode *node = [self findNodeByPath:path];
        if (!node) continue;

        // Don't allow dropping a folder into itself or its descendants
        if (node.isFolder && targetFolder) {
            TreeNode *check = targetFolder;
            BOOL isDescendant = NO;
            while (check) {
                if (check == node) {
                    isDescendant = YES;
                    break;
                }
                check = check.parent;
            }
            if (isDescendant) continue;
        }

        [self.treeModel moveNode:node toParent:targetFolder atIndex:targetIndex];
        targetIndex++;  // Adjust for next item
    }

    [self.outlineView reloadData];
    return YES;
}

- (TreeNode *)findNodeByPath:(NSString *)path {
    return [self findNodeByPath:path inNodes:self.treeModel.rootNodes];
}

- (TreeNode *)findNodeByPath:(NSString *)path inNodes:(NSArray<TreeNode *> *)nodes {
    for (TreeNode *node in nodes) {
        if ([node.path isEqualToString:path]) {
            return node;
        }
        if (node.isFolder && node.children.count > 0) {
            TreeNode *found = [self findNodeByPath:path inNodes:node.children];
            if (found) return found;
        }
    }
    return nil;
}

#pragma mark - Inline Editing

- (void)startEditingNode:(TreeNode *)node {
    NSInteger row = [self.outlineView rowForItem:node];
    if (row < 0) return;

    self.editingNode = node;
    NSTableCellView *cellView = [self.outlineView viewAtColumn:0 row:row makeIfNecessary:NO];
    if (cellView && cellView.textField) {
        cellView.textField.stringValue = node.name;
        [cellView.textField becomeFirstResponder];
        // Select all text for easy replacement
        [cellView.textField selectText:nil];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *textField = notification.object;
    TreeNode *node = objc_getAssociatedObject(textField, kTreeNodeKey);
    if (!node) return;

    NSString *newName = [textField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Validate name
    if (newName.length == 0) {
        // Restore original name
        textField.stringValue = node.name;
        return;
    }

    if ([newName isEqualToString:node.name]) {
        // No change
        self.editingNode = nil;
        return;
    }

    NSString *oldName = node.name;
    node.name = newName;

    // If it's a playlist, rename in foobar2000 too
    if (!node.isFolder) {
        @try {
            auto pm = playlist_manager::get();
            t_size count = pm->get_playlist_count();
            for (t_size i = 0; i < count; i++) {
                pfc::string8 name;
                pm->playlist_get_name(i, name);
                if (strcmp(name.c_str(), [oldName UTF8String]) == 0) {
                    pm->playlist_rename(i, [newName UTF8String], [newName lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                    break;
                }
            }
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Failed to rename playlist";
        }
    }

    [self.treeModel saveToConfig];
    self.editingNode = nil;
}

- (BOOL)control:(NSControl *)control textShouldEndEditing:(NSText *)fieldEditor {
    return YES;  // Always allow ending edit
}

#pragma mark - Import/Export

- (IBAction)importFromYAML:(id)sender {
    // Capture selected item before opening panel
    TreeNode *selectedNode = [self.outlineView itemAtRow:self.outlineView.clickedRow];
    if (!selectedNode) {
        selectedNode = [self.outlineView itemAtRow:self.outlineView.selectedRow];
    }

    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"yaml"], [UTType typeWithFilenameExtension:@"yml"]];
    openPanel.title = @"Import Playlist Tree from YAML";
    openPanel.message = @"Select a YAML file exported from foo_plorg";

    [openPanel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        @try {
            NSError *error = nil;
            NSString *yaml = [NSString stringWithContentsOfURL:openPanel.URL encoding:NSUTF8StringEncoding error:&error];
            if (error) {
                FB2K_console_formatter() << "[Plorg] Failed to read YAML file: " << [[error localizedDescription] UTF8String];
                return;
            }

            FB2K_console_formatter() << "[Plorg] Reading YAML file: " << [[openPanel.URL path] UTF8String];
            FB2K_console_formatter() << "[Plorg] YAML length: " << yaml.length << " chars";

            // Parse YAML into nodes
            NSArray<TreeNode *> *parsedNodes = [self parseYamlToNodes:yaml];
            FB2K_console_formatter() << "[Plorg] Parsed " << parsedNodes.count << " root nodes from YAML";

            if (parsedNodes.count == 0) {
                FB2K_console_formatter() << "[Plorg] No nodes parsed from YAML";
                return;
            }

            // Insert at appropriate location
            NSInteger imported = 0;
            if (selectedNode && selectedNode.isFolder) {
                // Insert inside folder
                for (TreeNode *node in parsedNodes) {
                    [selectedNode addChild:node];
                    imported++;
                }
            } else if (selectedNode) {
                // Insert after selected item
                TreeNode *parent = selectedNode.parent;
                NSInteger index = parent ? [parent.children indexOfObject:selectedNode] : [self.treeModel.rootNodes indexOfObject:selectedNode];
                if (index != NSNotFound) {
                    for (NSInteger i = parsedNodes.count - 1; i >= 0; i--) {
                        TreeNode *node = parsedNodes[i];
                        if (parent) {
                            [parent insertChild:node atIndex:index + 1];
                        } else {
                            [self.treeModel insertRootNode:node atIndex:index + 1];
                        }
                        imported++;
                    }
                }
            } else {
                // No selection - add to root
                for (TreeNode *node in parsedNodes) {
                    [self.treeModel addRootNode:node];
                    imported++;
                }
            }

            [self.treeModel saveToConfig];
            [self.outlineView reloadData];
            [self reloadTree];

            FB2K_console_formatter() << "[Plorg] Imported " << imported << " items from YAML";
        } @catch (NSException *e) {
            FB2K_console_formatter() << "[Plorg] Failed to import from YAML: " << [[e reason] UTF8String];
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Failed to import from YAML (unknown error)";
        }
    }];
}

- (NSArray<TreeNode *> *)parseYamlToNodes:(NSString *)yaml {
    if (!yaml || yaml.length == 0) return @[];

    NSMutableArray<TreeNode *> *parsedRoots = [NSMutableArray array];
    NSMutableArray<TreeNode *> *nodeStack = [NSMutableArray array];
    NSMutableArray<NSNumber *> *indentStack = [NSMutableArray array];

    NSArray *lines = [yaml componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL inTree = NO;

    for (NSString *rawLine in lines) {
        if (rawLine.length == 0 || [rawLine hasPrefix:@"#"]) continue;

        NSInteger indent = 0;
        while (indent < rawLine.length && [rawLine characterAtIndex:indent] == ' ') {
            indent++;
        }

        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([line hasPrefix:@"tree:"]) {
            inTree = YES;
            continue;
        }

        if (!inTree) continue;

        while (indentStack.count > 0 && indent <= indentStack.lastObject.integerValue) {
            [nodeStack removeLastObject];
            [indentStack removeLastObject];
        }

        TreeNode *newNode = nil;

        if ([line hasPrefix:@"- folder:"]) {
            NSString *name = [self extractQuotedYamlValue:line afterPrefix:@"- folder:"];
            if (name) {
                newNode = [TreeNode folderWithName:name];
            }
        } else if ([line hasPrefix:@"- playlist:"]) {
            NSString *name = [self extractQuotedYamlValue:line afterPrefix:@"- playlist:"];
            if (name) {
                newNode = [TreeNode playlistWithName:name];
            }
        } else if ([line hasPrefix:@"expanded:"]) {
            if (nodeStack.count > 0 && nodeStack.lastObject.isFolder) {
                BOOL expanded = [line containsString:@"true"];
                nodeStack.lastObject.isExpanded = expanded;
            }
            continue;
        } else if ([line hasPrefix:@"items:"]) {
            continue;
        }

        if (newNode) {
            if (nodeStack.count > 0) {
                [nodeStack.lastObject addChild:newNode];
            } else {
                [parsedRoots addObject:newNode];
            }

            if (newNode.isFolder) {
                [nodeStack addObject:newNode];
                [indentStack addObject:@(indent)];
            }
        }
    }

    return parsedRoots;
}

- (NSString *)extractQuotedYamlValue:(NSString *)line afterPrefix:(NSString *)prefix {
    NSRange range = [line rangeOfString:prefix];
    if (range.location == NSNotFound) return nil;

    NSString *value = [line substringFromIndex:range.location + range.length];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    if ([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        // Unescape
        value = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        value = [value stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
    }

    return value;
}

- (IBAction)importFromStrawberry:(id)sender {
    // Capture selected folder before any operations
    TreeNode *selectedNode = [self.outlineView itemAtRow:self.outlineView.clickedRow];
    if (!selectedNode) {
        selectedNode = [self.outlineView itemAtRow:self.outlineView.selectedRow];
    }
    TreeNode *targetFolder = (selectedNode && selectedNode.isFolder) ? selectedNode : nil;

    NSString *dbPath = [@"~/Library/Application Support/Strawberry/Strawberry/strawberry.db" stringByExpandingTildeInPath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Strawberry Not Found";
        alert.informativeText = @"Could not find Strawberry database at the expected location.";
        [alert runModal];
        return;
    }

    @try {
        sqlite3 *db;
        if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) {
            FB2K_console_formatter() << "[Plorg] Failed to open Strawberry database";
            return;
        }

        // Build folder structure from ui_path
        NSMutableDictionary<NSString *, TreeNode *> *folders = [NSMutableDictionary dictionary];
        NSInteger imported = 0;
        NSInteger tracksImported = 0;

        auto pm = playlist_manager::get();

        // Get playlists with their rowid
        const char *sql = "SELECT rowid, name, ui_path FROM playlists WHERE name != '' ORDER BY ui_order";
        sqlite3_stmt *stmt;

        if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                int64_t playlistId = sqlite3_column_int64(stmt, 0);
                const char *namePtr = (const char *)sqlite3_column_text(stmt, 1);
                if (!namePtr) continue;  // Skip rows with NULL name
                NSString *name = [NSString stringWithUTF8String:namePtr];
                if (!name || name.length == 0) continue;

                const char *pathPtr = (const char *)sqlite3_column_text(stmt, 2);
                NSString *path = pathPtr ? [NSString stringWithUTF8String:pathPtr] : @"";

                // Skip if playlist already exists in foobar2000
                BOOL existsInFoobar = NO;
                t_size existingCount = pm->get_playlist_count();
                for (t_size i = 0; i < existingCount; i++) {
                    pfc::string8 existingName;
                    pm->playlist_get_name(i, existingName);
                    if ([name isEqualToString:[NSString stringWithUTF8String:existingName.c_str()]]) {
                        existsInFoobar = YES;
                        break;
                    }
                }
                if (existsInFoobar) {
                    continue;
                }

                // Get tracks for this playlist
                NSMutableArray<NSString *> *trackPaths = [NSMutableArray array];
                sqlite3_stmt *trackStmt;
                const char *trackSql = "SELECT s.url FROM playlist_items pi "
                                       "JOIN songs s ON s.rowid = pi.collection_id "
                                       "WHERE pi.playlist = ? ORDER BY pi.rowid";

                if (sqlite3_prepare_v2(db, trackSql, -1, &trackStmt, NULL) == SQLITE_OK) {
                    sqlite3_bind_int64(trackStmt, 1, playlistId);
                    while (sqlite3_step(trackStmt) == SQLITE_ROW) {
                        const char *urlStr = (const char *)sqlite3_column_text(trackStmt, 0);
                        if (urlStr) {
                            NSString *url = [NSString stringWithUTF8String:urlStr];
                            // Convert file:// URL to path
                            if ([url hasPrefix:@"file://"]) {
                                // Handle URL-encoded paths
                                NSURL *fileURL = [NSURL URLWithString:url];
                                if (!fileURL) {
                                    // URL might have unescaped characters, try percent-encoding
                                    NSString *encoded = [url stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                                    fileURL = [NSURL URLWithString:encoded];
                                }
                                if (fileURL && fileURL.path) {
                                    [trackPaths addObject:fileURL.path];
                                }
                            } else if ([url hasPrefix:@"/"]) {
                                // Already a path
                                [trackPaths addObject:url];
                            }
                        }
                    }
                    sqlite3_finalize(trackStmt);
                }

                // Create foobar2000 playlist with tracks
                FB2K_console_formatter() << "[Plorg] Creating playlist: " << [name UTF8String] << " with " << trackPaths.count << " tracks";

                t_size newPlaylistIndex = pfc_infinite;
                try {
                    newPlaylistIndex = pm->create_playlist([name UTF8String], pfc_infinite, pfc_infinite);
                } catch (const std::exception& e) {
                    FB2K_console_formatter() << "[Plorg] Exception creating playlist: " << e.what();
                    continue;
                } catch (...) {
                    FB2K_console_formatter() << "[Plorg] Unknown exception creating playlist";
                    continue;
                }

                if (newPlaylistIndex != pfc_infinite && trackPaths.count > 0) {
                    // Add tracks to playlist using file paths
                    pfc::list_t<const char*> pathList;
                    std::vector<std::string> pathStrings;  // Keep strings alive
                    pathStrings.reserve(trackPaths.count);  // Prevent reallocation that would invalidate pointers
                    for (NSString *trackPath in trackPaths) {
                        pathStrings.push_back([trackPath UTF8String]);
                        pathList.add_item(pathStrings.back().c_str());
                    }
                    if (pathList.get_count() > 0) {
                        FB2K_console_formatter() << "[Plorg] Adding " << pathList.get_count() << " tracks to playlist index " << newPlaylistIndex;
                        try {
                            pm->playlist_add_locations(newPlaylistIndex, pathList, false, nullptr);
                            tracksImported += pathList.get_count();
                        } catch (const std::exception& e) {
                            FB2K_console_formatter() << "[Plorg] Exception adding tracks: " << e.what();
                        } catch (...) {
                            FB2K_console_formatter() << "[Plorg] Unknown exception adding tracks";
                        }
                    }
                }

                // Add to plorg tree
                TreeNode *playlist = [TreeNode playlistWithName:name];

                if (path.length > 0) {
                    // Create folder hierarchy if needed (inside target folder if selected)
                    TreeNode *parentFolder = [self getOrCreateFolderPath:path folders:folders baseFolder:targetFolder];
                    [parentFolder addChild:playlist];
                } else {
                    // No path - add to target folder or root
                    if (targetFolder) {
                        [targetFolder addChild:playlist];
                    } else {
                        [self.treeModel addRootNode:playlist];
                    }
                }
                imported++;

                // Log progress for large imports
                if (imported % 10 == 0) {
                    FB2K_console_formatter() << "[Plorg] Importing... " << imported << " playlists";
                }
            }
            sqlite3_finalize(stmt);
        }

        sqlite3_close(db);

        [self.outlineView reloadData];
        [self reloadTree];
        [self.treeModel saveToConfig];

        FB2K_console_formatter() << "[Plorg] Imported " << imported << " playlists with " << tracksImported << " tracks from Strawberry";
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Failed to import from Strawberry";
    }
}

- (TreeNode *)getOrCreateFolderPath:(NSString *)path folders:(NSMutableDictionary<NSString *, TreeNode *> *)folders baseFolder:(TreeNode *)baseFolder {
    if (folders[path]) {
        return folders[path];
    }

    NSArray *components = [path componentsSeparatedByString:@"/"];
    TreeNode *current = baseFolder;  // Start from base folder if provided
    NSString *currentPath = @"";

    for (NSString *component in components) {
        if (component.length == 0) continue;

        currentPath = currentPath.length > 0 ?
            [currentPath stringByAppendingFormat:@"/%@", component] : component;

        if (folders[currentPath]) {
            current = folders[currentPath];
        } else {
            TreeNode *folder = [TreeNode folderWithName:component];
            folder.isExpanded = YES;
            folders[currentPath] = folder;

            if (current) {
                // Check if folder already exists in current
                TreeNode *existing = nil;
                for (TreeNode *child in current.children) {
                    if (child.isFolder && [child.name isEqualToString:component]) {
                        existing = child;
                        break;
                    }
                }
                if (existing) {
                    folders[currentPath] = existing;
                    current = existing;
                    continue;
                }
                [current addChild:folder];
            } else {
                // Check if folder already exists at root
                TreeNode *existing = nil;
                for (TreeNode *node in self.treeModel.rootNodes) {
                    if (node.isFolder && [node.name isEqualToString:component]) {
                        existing = node;
                        break;
                    }
                }
                if (existing) {
                    folders[currentPath] = existing;
                    current = existing;
                    continue;
                }
                [self.treeModel addRootNode:folder];
            }
            current = folder;
        }
    }

    return current;
}

#pragma mark - DeaDBeeF Import

- (IBAction)importFromDeaDBeeF:(id)sender {
    // Capture insertion point before showing alert
    NSInteger clickedRow = [self.outlineView clickedRow];
    NSInteger selectedRow = clickedRow >= 0 ? clickedRow : [self.outlineView selectedRow];
    TreeNode *targetFolder = nil;

    if (selectedRow >= 0) {
        TreeNode *node = [self.outlineView itemAtRow:selectedRow];
        if (node.isFolder) {
            targetFolder = node;
        } else if (node.parent) {
            targetFolder = node.parent;
        }
    }

    NSString *deadbeefPath = [@"~/Library/Preferences/deadbeef" stringByExpandingTildeInPath];
    NSString *playlistsPath = [deadbeefPath stringByAppendingPathComponent:@"playlists"];
    NSString *configPath = [deadbeefPath stringByAppendingPathComponent:@"config"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:playlistsPath]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"DeaDBeeF Not Found";
        alert.informativeText = @"Could not find DeaDBeeF playlists at ~/Library/Preferences/deadbeef/playlists";
        [alert runModal];
        return;
    }

    // Load playlist names from config
    NSMutableDictionary<NSNumber *, NSString *> *playlistNames = [NSMutableDictionary dictionary];
    NSString *config = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:nil];
    if (config) {
        for (NSString *line in [config componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            // Format: playlist.tab.00000 Name
            if ([line hasPrefix:@"playlist.tab."]) {
                NSRange spaceRange = [line rangeOfString:@" "];
                if (spaceRange.location != NSNotFound) {
                    NSString *key = [line substringWithRange:NSMakeRange(13, spaceRange.location - 13)];
                    NSString *name = [line substringFromIndex:spaceRange.location + 1];
                    NSInteger index = [key integerValue];
                    playlistNames[@(index)] = name;
                }
            }
        }
    }

    FB2K_console_formatter() << "[Plorg] Found " << playlistNames.count << " DeaDBeeF playlist names";

    // Find all .dbpl files
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:playlistsPath error:nil];
    NSMutableArray<NSString *> *dbplFiles = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file hasSuffix:@".dbpl"]) {
            [dbplFiles addObject:file];
        }
    }

    FB2K_console_formatter() << "[Plorg] Found " << dbplFiles.count << " DeaDBeeF playlist files";

    auto pm = playlist_manager::get();
    NSInteger imported = 0;
    NSInteger tracksImported = 0;

    for (NSString *dbplFile in dbplFiles) {
        NSString *baseName = [dbplFile stringByDeletingPathExtension];
        NSInteger playlistIndex = [baseName integerValue];
        NSString *playlistName = playlistNames[@(playlistIndex)];
        if (!playlistName) {
            playlistName = [NSString stringWithFormat:@"DeaDBeeF Playlist %ld", (long)playlistIndex];
        }

        // Check if playlist already exists in foobar2000
        BOOL existsInFoobar = NO;
        t_size existingCount = pm->get_playlist_count();
        for (t_size i = 0; i < existingCount; i++) {
            pfc::string8 existingName;
            pm->playlist_get_name(i, existingName);
            if ([playlistName isEqualToString:[NSString stringWithUTF8String:existingName.c_str()]]) {
                existsInFoobar = YES;
                break;
            }
        }

        if (existsInFoobar) {
            FB2K_console_formatter() << "[Plorg] Skipping existing playlist: " << [playlistName UTF8String];
            continue;
        }

        NSString *dbplPath = [playlistsPath stringByAppendingPathComponent:dbplFile];
        NSArray<NSString *> *paths = [self parseDeaDBeeF:dbplPath];

        if (paths.count > 0) {
            // Create foobar2000 playlist
            t_size newPlaylistIndex = pm->create_playlist([playlistName UTF8String], pfc_infinite, pfc_infinite);
            if (newPlaylistIndex != pfc_infinite) {
                pfc::list_t<const char*> pathList;
                std::vector<std::string> pathStrings;
                pathStrings.reserve(paths.count);  // Prevent reallocation

                for (NSString *path in paths) {
                    pathStrings.push_back([path UTF8String]);
                    pathList.add_item(pathStrings.back().c_str());
                }

                pm->playlist_add_locations(newPlaylistIndex, pathList, false, nullptr);
                tracksImported += paths.count;
            }
        }

        // Add to tree if not already there
        if (![self.treeModel findPlaylistWithName:playlistName]) {
            TreeNode *playlist = [TreeNode playlistWithName:playlistName];
            if (targetFolder) {
                [targetFolder addChild:playlist];
            } else {
                [self.treeModel addRootNode:playlist];
            }
            imported++;
        }
    }

    [self.outlineView reloadData];
    [self reloadTree];
    [self.treeModel saveToConfig];

    FB2K_console_formatter() << "[Plorg] Imported " << imported << " playlists with " << tracksImported << " tracks from DeaDBeeF";
}

- (NSArray<NSString *> *)parseDeaDBeeF:(NSString *)dbplPath {
    NSData *data = [NSData dataWithContentsOfFile:dbplPath];
    if (!data || data.length < 8) return @[];

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = data.length;

    // Check magic "DBPL"
    if (bytes[0] != 'D' || bytes[1] != 'B' || bytes[2] != 'P' || bytes[3] != 'L') {
        return @[];
    }

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSUInteger pos = 4;  // Skip magic

    // Skip version bytes (2 bytes typically)
    pos += 2;

    // Parse entries - looking for paths starting with /
    while (pos < length - 1) {
        // Look for length byte followed by path starting with /
        uint8_t len = bytes[pos];
        if (len > 0 && pos + 1 + len <= length) {
            if (bytes[pos + 1] == '/') {
                // This looks like a path
                NSString *path = [[NSString alloc] initWithBytes:&bytes[pos + 1]
                                                          length:len
                                                        encoding:NSUTF8StringEncoding];
                if (path && [path hasPrefix:@"/"] && ![path containsString:@":"]) {
                    // Avoid duplicates from metadata (:URI etc)
                    if (![paths containsObject:path]) {
                        [paths addObject:path];
                    }
                }
                pos += 1 + len;
            } else {
                pos++;
            }
        } else {
            pos++;
        }
    }

    return paths;
}

#pragma mark - Vox Import

- (IBAction)importFromVox:(id)sender {
    // Capture insertion point before showing alert
    NSInteger clickedRow = [self.outlineView clickedRow];
    NSInteger selectedRow = clickedRow >= 0 ? clickedRow : [self.outlineView selectedRow];
    TreeNode *targetFolder = nil;

    if (selectedRow >= 0) {
        TreeNode *node = [self.outlineView itemAtRow:selectedRow];
        if (node.isFolder) {
            targetFolder = node;
        } else if (node.parent) {
            targetFolder = node.parent;
        }
    }

    NSString *voxDbPath = [@"~/Library/Containers/com.coppertino.Vox/Data/Library/Application Support/Vox/voxdb.storedata" stringByExpandingTildeInPath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:voxDbPath]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Vox Not Found";
        alert.informativeText = @"Could not find Vox database at ~/Library/Containers/com.coppertino.Vox";
        [alert runModal];
        return;
    }

    sqlite3 *db;
    if (sqlite3_open([voxDbPath UTF8String], &db) != SQLITE_OK) {
        FB2K_console_formatter() << "[Plorg] Failed to open Vox database";
        return;
    }

    // Get playlists (Z_ENT=8, but skip generic "Playlist" names)
    sqlite3_stmt *stmt;
    const char *playlistQuery = "SELECT Z_PK, ZNAME FROM ZVXLOCALOBJECT WHERE Z_ENT = 8 AND ZNAME != 'Playlist'";

    if (sqlite3_prepare_v2(db, playlistQuery, -1, &stmt, NULL) != SQLITE_OK) {
        FB2K_console_formatter() << "[Plorg] Failed to query Vox playlists";
        sqlite3_close(db);
        return;
    }

    auto pm = playlist_manager::get();
    NSInteger imported = 0;
    NSInteger tracksImported = 0;

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        int playlistId = sqlite3_column_int(stmt, 0);
        const char *namePtr = (const char *)sqlite3_column_text(stmt, 1);
        if (!namePtr) continue;

        NSString *playlistName = [NSString stringWithUTF8String:namePtr];

        // Check if playlist already exists in foobar2000
        BOOL existsInFoobar = NO;
        t_size existingCount = pm->get_playlist_count();
        for (t_size i = 0; i < existingCount; i++) {
            pfc::string8 existingName;
            pm->playlist_get_name(i, existingName);
            if ([playlistName isEqualToString:[NSString stringWithUTF8String:existingName.c_str()]]) {
                existsInFoobar = YES;
                break;
            }
        }

        if (existsInFoobar) {
            FB2K_console_formatter() << "[Plorg] Skipping existing playlist: " << [playlistName UTF8String];
            continue;
        }

        // Get tracks for this playlist
        NSMutableArray<NSString *> *trackPaths = [NSMutableArray array];
        sqlite3_stmt *trackStmt;
        const char *trackQuery = "SELECT T.ZURL FROM ZVXLOCALOBJECT T JOIN Z_7TRACKS R ON T.Z_PK = R.Z_10TRACKS WHERE R.Z_7PLAYLISTS = ?";

        if (sqlite3_prepare_v2(db, trackQuery, -1, &trackStmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(trackStmt, 1, playlistId);

            while (sqlite3_step(trackStmt) == SQLITE_ROW) {
                const char *urlPtr = (const char *)sqlite3_column_text(trackStmt, 0);
                if (urlPtr) {
                    NSString *urlStr = [NSString stringWithUTF8String:urlPtr];
                    // Convert file:// URL to path
                    if ([urlStr hasPrefix:@"file://"]) {
                        NSString *path = [[NSURL URLWithString:urlStr] path];
                        if (path) {
                            [trackPaths addObject:path];
                        }
                    }
                }
            }
            sqlite3_finalize(trackStmt);
        }

        if (trackPaths.count > 0) {
            // Create foobar2000 playlist
            t_size newPlaylistIndex = pm->create_playlist([playlistName UTF8String], pfc_infinite, pfc_infinite);
            if (newPlaylistIndex != pfc_infinite) {
                pfc::list_t<const char*> pathList;
                std::vector<std::string> pathStrings;
                pathStrings.reserve(trackPaths.count);  // Prevent reallocation

                for (NSString *path in trackPaths) {
                    pathStrings.push_back([path UTF8String]);
                    pathList.add_item(pathStrings.back().c_str());
                }

                pm->playlist_add_locations(newPlaylistIndex, pathList, false, nullptr);
                tracksImported += trackPaths.count;
            }
        }

        // Add to tree if not already there
        if (![self.treeModel findPlaylistWithName:playlistName]) {
            TreeNode *playlist = [TreeNode playlistWithName:playlistName];
            if (targetFolder) {
                [targetFolder addChild:playlist];
            } else {
                [self.treeModel addRootNode:playlist];
            }
            imported++;
        }
    }

    sqlite3_finalize(stmt);
    sqlite3_close(db);

    [self.outlineView reloadData];
    [self reloadTree];
    [self.treeModel saveToConfig];

    FB2K_console_formatter() << "[Plorg] Imported " << imported << " playlists with " << tracksImported << " tracks from Vox";
}

- (IBAction)importFromOldPlorg:(id)sender {
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"fth"]];
    openPanel.title = @"Import from Old foo_plorg";
    openPanel.message = @"Select a Columns UI theme file (theme.fth) containing foo_plorg data";

    // Try to find Wine foobar location as default
    NSString *winePath = [@"~/Applications/Wine10-slim/drive_c/Programs/foobar2000" stringByExpandingTildeInPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:winePath]) {
        openPanel.directoryURL = [NSURL fileURLWithPath:winePath];
    }

    [openPanel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSString *foobarDir = [[openPanel.URL path] stringByDeletingLastPathComponent];
        NSString *playlistsDir = [foobarDir stringByAppendingPathComponent:@"playlists-v2.0"];

        FB2K_console_formatter() << "[Plorg] Selected theme file: " << [[openPanel.URL path] UTF8String];
        FB2K_console_formatter() << "[Plorg] Playlists directory: " << [playlistsDir UTF8String];

        // Store paths for after mapping completes
        self.pendingThemePath = [openPanel.URL path];
        self.pendingPlaylistsDir = playlistsDir;

        // Show path mapping window
        self.pathMappingController = [[PathMappingWindowController alloc] init];
        self.pathMappingController.delegate = self;
        [self.pathMappingController beginScanningWithPlaylistsDir:playlistsDir
                                                    themeFilePath:[openPanel.URL path]];
    }];
}

#pragma mark - PathMappingWindowDelegate

- (void)pathMappingDidComplete:(PathMappingWindowController *)controller
                      mappings:(NSDictionary<NSString *, NSString *> *)mappings
                 defaultMapping:(NSString *)defaultMapping {
    FB2K_console_formatter() << "[Plorg] Path mapping complete with " << mappings.count << " drive mappings";

    @try {
        NSData *data = [NSData dataWithContentsOfFile:self.pendingThemePath];
        if (!data) {
            FB2K_console_formatter() << "[Plorg] Failed to read theme.fth file";
            return;
        }

        FB2K_console_formatter() << "[Plorg] Theme file size: " << data.length << " bytes";

        NSInteger imported = [self parseOldPlorgFromTheme:data
                                             playlistsDir:self.pendingPlaylistsDir
                                                 mappings:mappings
                                           defaultMapping:defaultMapping];
        [self.outlineView reloadData];
        [self reloadTree];
        [self.treeModel saveToConfig];

        FB2K_console_formatter() << "[Plorg] Imported " << imported << " items from old foo_plorg";
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Failed to import from old foo_plorg";
    }

    self.pathMappingController = nil;
    self.pendingThemePath = nil;
    self.pendingPlaylistsDir = nil;
}

- (void)pathMappingDidCancel:(PathMappingWindowController *)controller {
    FB2K_console_formatter() << "[Plorg] Path mapping cancelled";
    self.pathMappingController = nil;
    self.pendingThemePath = nil;
    self.pendingPlaylistsDir = nil;
}

// Legacy method for backward compatibility - uses default A: -> /Volumes/music mapping
- (NSInteger)parseOldPlorgFromTheme:(NSData *)data playlistsDir:(NSString *)playlistsDir {
    return [self parseOldPlorgFromTheme:data
                           playlistsDir:playlistsDir
                               mappings:@{@"A:": @"/Volumes/music"}
                         defaultMapping:@"/Volumes/music"];
}

- (NSInteger)parseOldPlorgFromTheme:(NSData *)data
                       playlistsDir:(NSString *)playlistsDir
                           mappings:(NSDictionary<NSString *, NSString *> *)mappings
                     defaultMapping:(NSString *)defaultMapping {
    // Load playlist index for UUID lookup
    NSMutableDictionary<NSString *, NSString *> *playlistIndex = [NSMutableDictionary dictionary];
    NSString *indexPath = [playlistsDir stringByAppendingPathComponent:@"index.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:indexPath]) {
        NSString *indexContent = [NSString stringWithContentsOfFile:indexPath encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [indexContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
            NSRange colonRange = [line rangeOfString:@":"];
            if (colonRange.location != NSNotFound) {
                NSString *uuid = [line substringToIndex:colonRange.location];
                NSString *name = [line substringFromIndex:colonRange.location + 1];
                playlistIndex[name] = uuid;
            }
        }
        FB2K_console_formatter() << "[Plorg] Loaded " << playlistIndex.count << " playlists from index.txt";
    }

    // Extract plorg markers from binary theme data
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content) {
        content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    }
    if (!content) {
        FB2K_console_formatter() << "[Plorg] Failed to decode theme file content";
        return 0;
    }

    // Find plorg tree markers using regex
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<[FP/][^<]*"
                                                                           options:0 error:&error];
    if (error) {
        FB2K_console_formatter() << "[Plorg] Regex error";
        return 0;
    }

    NSArray *matches = [regex matchesInString:content options:0 range:NSMakeRange(0, content.length)];
    FB2K_console_formatter() << "[Plorg] Found " << matches.count << " potential markers in theme file";

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSString *firstFolderName = nil;

    for (NSTextCheckingResult *match in matches) {
        NSString *line = [content substringWithRange:match.range];

        // Track first folder to detect tree repetition
        if ([line hasPrefix:@"<F>E-"] || [line hasPrefix:@"<F>N-"]) {
            NSString *folderName = [line substringFromIndex:5];
            if (!firstFolderName) {
                firstFolderName = folderName;
                FB2K_console_formatter() << "[Plorg] First folder: " << [folderName UTF8String];
            } else if ([folderName isEqualToString:firstFolderName]) {
                break;
            }
        }

        [lines addObject:line];
    }

    FB2K_console_formatter() << "[Plorg] Parsing " << lines.count << " tree markers";

    // Parse the tree structure
    NSMutableArray<TreeNode *> *stack = [NSMutableArray arrayWithObject:(id)[NSNull null]];
    NSInteger imported = 0;
    NSInteger tracksImported = 0;
    auto pm = playlist_manager::get();

    for (NSString *line in lines) {
        if ([line hasPrefix:@"<F>"]) {
            if (line.length < 5) continue;
            BOOL expanded = [line characterAtIndex:3] == 'E';
            NSString *name = [line substringFromIndex:5];

            TreeNode *folder = [TreeNode folderWithName:name];
            folder.isExpanded = expanded;

            if (stack.count == 1) {
                TreeNode *existing = nil;
                for (TreeNode *node in self.treeModel.rootNodes) {
                    if (node.isFolder && [node.name isEqualToString:name]) {
                        existing = node;
                        break;
                    }
                }
                if (existing) {
                    [stack addObject:existing];
                    continue;
                }
                [self.treeModel addRootNode:folder];
            } else {
                TreeNode *parent = stack.lastObject;
                if (parent && parent != (id)[NSNull null]) {
                    [parent addChild:folder];
                }
            }
            [stack addObject:folder];
            imported++;
        } else if ([line hasPrefix:@"</F>"]) {
            if (stack.count > 1) {
                [stack removeLastObject];
            }
        } else if ([line hasPrefix:@"<P>"]) {
            NSString *rest = [line substringFromIndex:3];
            NSRange dashRange = [rest rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                NSString *name = [rest substringFromIndex:dashRange.location + 1];

                // Check if playlist already exists in foobar2000
                BOOL existsInFoobar = NO;
                t_size existingCount = pm->get_playlist_count();
                for (t_size i = 0; i < existingCount; i++) {
                    pfc::string8 existingName;
                    pm->playlist_get_name(i, existingName);
                    if ([name isEqualToString:[NSString stringWithUTF8String:existingName.c_str()]]) {
                        existsInFoobar = YES;
                        break;
                    }
                }

                if (!existsInFoobar) {
                    // Try to import tracks from .fplite file
                    NSString *uuid = playlistIndex[name];
                    if (uuid) {
                        NSString *fplitePath = [playlistsDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"playlist-%@.fplite", uuid]];

                        if ([[NSFileManager defaultManager] fileExistsAtPath:fplitePath]) {
                            NSInteger trackCount = [self importPlaylistFromFplite:fplitePath
                                                                             name:name
                                                                         mappings:mappings
                                                                   defaultMapping:defaultMapping];
                            tracksImported += trackCount;
                        }
                    } else {
                        // No .fplite file, just create empty playlist
                        pm->create_playlist([name UTF8String], pfc_infinite, pfc_infinite);
                    }
                }

                // Add to tree if not already there
                if (![self.treeModel findPlaylistWithName:name]) {
                    TreeNode *playlist = [TreeNode playlistWithName:name];
                    if (stack.count == 1) {
                        [self.treeModel addRootNode:playlist];
                    } else {
                        TreeNode *parent = stack.lastObject;
                        if (parent && parent != (id)[NSNull null]) {
                            [parent addChild:playlist];
                        }
                    }
                    imported++;
                }
            }
        }
    }

    if (tracksImported > 0) {
        FB2K_console_formatter() << "[Plorg] Also imported " << tracksImported << " tracks";
    }

    return imported;
}

- (NSInteger)importPlaylistFromFplite:(NSString *)fplitePath
                                 name:(NSString *)name
                             mappings:(NSDictionary<NSString *, NSString *> *)mappings
                       defaultMapping:(NSString *)defaultMapping {
    NSString *content = [NSString stringWithContentsOfFile:fplitePath encoding:NSUTF8StringEncoding error:nil];
    if (!content) return 0;

    auto pm = playlist_manager::get();
    t_size newPlaylistIndex = pm->create_playlist([name UTF8String], pfc_infinite, pfc_infinite);
    if (newPlaylistIndex == pfc_infinite) return 0;

    NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    pfc::list_t<const char*> pathList;
    std::vector<std::string> pathStrings;
    pathStrings.reserve(lines.count);  // Prevent reallocation

    for (NSString *line in lines) {
        if (line.length == 0) continue;

        NSString *path = line;
        // Convert file:// URL to path
        if ([path hasPrefix:@"file://"]) {
            path = [path substringFromIndex:7];
            path = [path stringByRemovingPercentEncoding];
        }

        // Convert Windows path to macOS path using mappings
        if (path.length > 2 && [path characterAtIndex:1] == ':') {
            NSString *driveKey = [[path substringToIndex:2] uppercaseString]; // "A:", "C:", etc.
            NSString *restOfPath = [[path substringFromIndex:2] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];

            // Look up drive mapping
            NSString *basePath = mappings[driveKey];
            if (!basePath || basePath.length == 0) {
                basePath = defaultMapping;
            }
            if (basePath && basePath.length > 0) {
                path = [basePath stringByAppendingString:restOfPath];
            }
        } else if ([path hasPrefix:@"\\\\"]) {
            // UNC network path
            NSString *networkPath = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
            // Find matching network mapping
            for (NSString *key in mappings) {
                if ([key hasPrefix:@"\\\\"] || [key hasPrefix:@"//"]) {
                    NSString *normalizedKey = [key stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
                    if ([networkPath hasPrefix:normalizedKey]) {
                        NSString *restOfPath = [networkPath substringFromIndex:normalizedKey.length];
                        path = [mappings[key] stringByAppendingString:restOfPath];
                        break;
                    }
                }
            }
        }

        pathStrings.push_back([path UTF8String]);
        pathList.add_item(pathStrings.back().c_str());
    }

    if (pathList.get_count() > 0) {
        pm->playlist_add_locations(newPlaylistIndex, pathList, false, nullptr);
        return pathList.get_count();
    }

    return 0;
}

- (IBAction)importMissingPlaylists:(id)sender {
    // Import all playlists from foobar2000 that aren't already in the tree
    @try {
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        NSInteger imported = 0;

        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            NSString *playlistName = [NSString stringWithUTF8String:name.c_str()];

            // Check if already in tree
            if ([self.treeModel findPlaylistWithName:playlistName]) {
                continue;
            }

            // Add to root
            TreeNode *playlist = [TreeNode playlistWithName:playlistName];
            [self.treeModel addRootNode:playlist];
            imported++;
        }

        [self.outlineView reloadData];

        if (imported > 0) {
            FB2K_console_formatter() << "[Plorg] Imported " << imported << " playlists from foobar2000";
        } else {
            FB2K_console_formatter() << "[Plorg] No new playlists to import";
        }
    } @catch (...) {
        FB2K_console_formatter() << "[Plorg] Failed to import playlists";
    }
}

- (IBAction)exportTree:(id)sender {
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"yaml"]];
    savePanel.nameFieldStringValue = @"playlist_tree.yaml";
    savePanel.title = @"Export Playlist Tree";

    [savePanel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        @try {
            NSString *yaml = [self.treeModel toYaml];
            NSError *error = nil;
            [yaml writeToURL:savePanel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];

            if (error) {
                FB2K_console_formatter() << "[Plorg] Failed to export tree: " << [[error localizedDescription] UTF8String];
                return;
            }

            FB2K_console_formatter() << "[Plorg] Tree exported successfully";
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Failed to export tree";
        }
    }];
}

@end
