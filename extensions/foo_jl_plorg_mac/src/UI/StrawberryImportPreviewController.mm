//
//  StrawberryImportPreviewController.mm
//  foo_jl_plorg
//

#import "StrawberryImportPreviewController.h"
#import "../Core/TreeNode.h"
#import <sqlite3.h>

#include "../fb2k_sdk.h"

#pragma mark - StrawberryPlaylistItem

@implementation StrawberryPlaylistItem

- (instancetype)init {
    self = [super init];
    if (self) {
        _isSelected = YES;  // Selected by default
        _trackPaths = [NSMutableArray array];
    }
    return self;
}

@end

#pragma mark - StrawberryPreviewFolder

@implementation StrawberryPreviewFolder

- (instancetype)init {
    self = [super init];
    if (self) {
        _children = [NSMutableArray array];
        _isExpanded = YES;
    }
    return self;
}

- (BOOL)isFolder {
    return YES;
}

- (NSInteger)totalTrackCount {
    NSInteger count = 0;
    for (id child in self.children) {
        if ([child isKindOfClass:[StrawberryPreviewFolder class]]) {
            count += [(StrawberryPreviewFolder *)child totalTrackCount];
        } else {
            count += [(StrawberryPlaylistItem *)child trackCount];
        }
    }
    return count;
}

- (BOOL)hasSelectedItems {
    for (id child in self.children) {
        if ([child isKindOfClass:[StrawberryPreviewFolder class]]) {
            if ([(StrawberryPreviewFolder *)child hasSelectedItems]) return YES;
        } else {
            if ([(StrawberryPlaylistItem *)child isSelected]) return YES;
        }
    }
    return NO;
}

- (BOOL)allItemsSelected {
    for (id child in self.children) {
        if ([child isKindOfClass:[StrawberryPreviewFolder class]]) {
            if (![(StrawberryPreviewFolder *)child allItemsSelected]) return NO;
        } else {
            if (![(StrawberryPlaylistItem *)child isSelected]) return NO;
        }
    }
    return self.children.count > 0;
}

- (void)setAllSelected:(BOOL)selected {
    for (id child in self.children) {
        if ([child isKindOfClass:[StrawberryPreviewFolder class]]) {
            [(StrawberryPreviewFolder *)child setAllSelected:selected];
        } else {
            [(StrawberryPlaylistItem *)child setIsSelected:selected];
        }
    }
}

@end

#pragma mark - StrawberryImportPreviewController

@interface StrawberryImportPreviewController ()
@property (nonatomic, strong) NSOutlineView *outlineView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *importButton;
@property (nonatomic, strong) NSButton *selectAllButton;
@property (nonatomic, strong) NSMutableArray *rootItems;  // StrawberryPreviewFolder or StrawberryPlaylistItem
@property (nonatomic, strong) NSMutableArray<StrawberryPlaylistItem *> *allPlaylists;
@end

@implementation StrawberryImportPreviewController

- (instancetype)init {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 450)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Import from Strawberry";
    window.minSize = NSMakeSize(400, 350);

    self = [super initWithWindow:window];
    if (self) {
        _rootItems = [NSMutableArray array];
        _allPlaylists = [NSMutableArray array];
        [self setupUI];
    }
    return self;
}

- (void)setupUI {
    NSView *contentView = self.window.contentView;

    // Create scroll view for outline view
    self.scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 60, 460, 340)];
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSBezelBorder;
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Create outline view
    self.outlineView = [[NSOutlineView alloc] initWithFrame:self.scrollView.bounds];
    self.outlineView.dataSource = self;
    self.outlineView.delegate = self;
    self.outlineView.headerView = nil;
    self.outlineView.floatsGroupRows = NO;
    self.outlineView.allowsMultipleSelection = NO;
    self.outlineView.indentationPerLevel = 16.0;
    self.outlineView.rowHeight = 20.0;
    self.outlineView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // Checkbox column
    NSTableColumn *checkColumn = [[NSTableColumn alloc] initWithIdentifier:@"CheckColumn"];
    checkColumn.width = 24;
    checkColumn.minWidth = 24;
    checkColumn.maxWidth = 24;
    checkColumn.resizingMask = NSTableColumnNoResizing;
    [self.outlineView addTableColumn:checkColumn];

    // Name column
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"NameColumn"];
    nameColumn.resizingMask = NSTableColumnAutoresizingMask;
    [self.outlineView addTableColumn:nameColumn];
    self.outlineView.outlineTableColumn = nameColumn;

    // Count column
    NSTableColumn *countColumn = [[NSTableColumn alloc] initWithIdentifier:@"CountColumn"];
    countColumn.width = 50;
    countColumn.minWidth = 50;
    countColumn.maxWidth = 80;
    countColumn.resizingMask = NSTableColumnNoResizing;
    [self.outlineView addTableColumn:countColumn];

    self.outlineView.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.scrollView.documentView = self.outlineView;
    [contentView addSubview:self.scrollView];

    // Status label
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 30, 300, 20)];
    self.statusLabel.stringValue = @"Loading...";
    self.statusLabel.bordered = NO;
    self.statusLabel.drawsBackground = NO;
    self.statusLabel.editable = NO;
    self.statusLabel.selectable = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    self.statusLabel.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [contentView addSubview:self.statusLabel];

    // Select All / Deselect All button
    self.selectAllButton = [[NSButton alloc] initWithFrame:NSMakeRect(20, 410, 100, 24)];
    self.selectAllButton.title = @"Select All";
    self.selectAllButton.bezelStyle = NSBezelStyleRounded;
    self.selectAllButton.target = self;
    self.selectAllButton.action = @selector(toggleSelectAll:);
    self.selectAllButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [contentView addSubview:self.selectAllButton];

    // Cancel button
    NSButton *cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(310, 15, 90, 32)];
    cancelButton.title = @"Cancel";
    cancelButton.bezelStyle = NSBezelStyleRounded;
    cancelButton.target = self;
    cancelButton.action = @selector(cancelImport:);
    cancelButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [contentView addSubview:cancelButton];

    // Import button
    self.importButton = [[NSButton alloc] initWithFrame:NSMakeRect(405, 15, 90, 32)];
    self.importButton.title = @"Import";
    self.importButton.bezelStyle = NSBezelStyleRounded;
    self.importButton.keyEquivalent = @"\r";  // Default button
    self.importButton.target = self;
    self.importButton.action = @selector(performImport:);
    self.importButton.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [contentView addSubview:self.importButton];

    [self.window center];
}

- (void)loadFromStrawberryDatabase {
    NSString *dbPath = [@"~/Library/Application Support/Strawberry/Strawberry/strawberry.db" stringByExpandingTildeInPath];

    if (![[NSFileManager defaultManager] fileExistsAtPath:dbPath]) {
        self.statusLabel.stringValue = @"Strawberry database not found";
        self.importButton.enabled = NO;
        return;
    }

    sqlite3 *db;
    if (sqlite3_open([dbPath UTF8String], &db) != SQLITE_OK) {
        self.statusLabel.stringValue = @"Failed to open database";
        self.importButton.enabled = NO;
        return;
    }

    // Get existing foobar2000 playlists to skip
    NSMutableSet<NSString *> *existingPlaylists = [NSMutableSet set];
    @try {
        auto pm = playlist_manager::get();
        t_size count = pm->get_playlist_count();
        for (t_size i = 0; i < count; i++) {
            pfc::string8 name;
            pm->playlist_get_name(i, name);
            [existingPlaylists addObject:[NSString stringWithUTF8String:name.c_str()]];
        }
    } @catch (...) {}

    // Build folder structure from ui_path
    NSMutableDictionary<NSString *, StrawberryPreviewFolder *> *folders = [NSMutableDictionary dictionary];
    NSInteger totalTracks = 0;
    NSInteger skipped = 0;

    // Get playlists with their rowid
    const char *sql = "SELECT rowid, name, ui_path FROM playlists WHERE name != '' ORDER BY ui_order";
    sqlite3_stmt *stmt;

    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int64_t playlistId = sqlite3_column_int64(stmt, 0);
            const char *namePtr = (const char *)sqlite3_column_text(stmt, 1);
            if (!namePtr) continue;

            NSString *name = [NSString stringWithUTF8String:namePtr];
            if (!name || name.length == 0) continue;

            // Skip if playlist already exists in foobar2000
            if ([existingPlaylists containsObject:name]) {
                skipped++;
                continue;
            }

            const char *pathPtr = (const char *)sqlite3_column_text(stmt, 2);
            NSString *path = pathPtr ? [NSString stringWithUTF8String:pathPtr] : @"";

            // Get track count and paths for this playlist
            StrawberryPlaylistItem *item = [[StrawberryPlaylistItem alloc] init];
            item.name = name;
            item.uiPath = path;
            item.playlistId = playlistId;

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
                        if ([url hasPrefix:@"file://"]) {
                            NSString *encodedPath = [url substringFromIndex:7];
                            NSString *trackPath = [encodedPath stringByRemovingPercentEncoding];
                            if (trackPath && trackPath.length > 0) {
                                [item.trackPaths addObject:trackPath];
                            }
                        } else if ([url hasPrefix:@"/"]) {
                            [item.trackPaths addObject:url];
                        }
                    }
                }
                sqlite3_finalize(trackStmt);
            }

            item.trackCount = item.trackPaths.count;
            totalTracks += item.trackCount;

            [self.allPlaylists addObject:item];

            // Add to tree structure
            if (path.length > 0) {
                StrawberryPreviewFolder *parentFolder = [self getOrCreateFolderPath:path folders:folders];
                [parentFolder.children addObject:item];
            } else {
                [self.rootItems addObject:item];
            }
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);

    // Update UI
    [self.outlineView reloadData];
    [self.outlineView expandItem:nil expandChildren:YES];

    NSMutableString *status = [NSMutableString stringWithFormat:@"%ld playlists, %ld tracks",
                               (long)self.allPlaylists.count, (long)totalTracks];
    if (skipped > 0) {
        [status appendFormat:@" (%ld already exist)", (long)skipped];
    }
    self.statusLabel.stringValue = status;

    self.importButton.enabled = self.allPlaylists.count > 0;
    [self updateSelectAllButtonTitle];
}

- (StrawberryPreviewFolder *)getOrCreateFolderPath:(NSString *)path
                                           folders:(NSMutableDictionary<NSString *, StrawberryPreviewFolder *> *)folders {
    if (folders[path]) {
        return folders[path];
    }

    NSArray *components = [path componentsSeparatedByString:@"/"];
    StrawberryPreviewFolder *current = nil;
    NSString *currentPath = @"";

    for (NSString *component in components) {
        if (component.length == 0) continue;

        currentPath = currentPath.length > 0 ?
            [currentPath stringByAppendingFormat:@"/%@", component] : component;

        if (folders[currentPath]) {
            current = folders[currentPath];
        } else {
            StrawberryPreviewFolder *folder = [[StrawberryPreviewFolder alloc] init];
            folder.name = component;
            folders[currentPath] = folder;

            if (current) {
                [current.children addObject:folder];
            } else {
                [self.rootItems addObject:folder];
            }
            current = folder;
        }
    }

    return current;
}

- (void)updateStatusLabel {
    NSInteger selectedCount = 0;
    NSInteger selectedTracks = 0;

    for (StrawberryPlaylistItem *item in self.allPlaylists) {
        if (item.isSelected) {
            selectedCount++;
            selectedTracks += item.trackCount;
        }
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"%ld of %ld playlists selected (%ld tracks)",
                                    (long)selectedCount, (long)self.allPlaylists.count, (long)selectedTracks];
    self.importButton.enabled = selectedCount > 0;
}

- (void)updateSelectAllButtonTitle {
    BOOL allSelected = YES;
    for (StrawberryPlaylistItem *item in self.allPlaylists) {
        if (!item.isSelected) {
            allSelected = NO;
            break;
        }
    }
    self.selectAllButton.title = allSelected ? @"Deselect All" : @"Select All";
}

#pragma mark - Actions

- (void)toggleSelectAll:(id)sender {
    BOOL allSelected = YES;
    for (StrawberryPlaylistItem *item in self.allPlaylists) {
        if (!item.isSelected) {
            allSelected = NO;
            break;
        }
    }

    // Toggle all
    BOOL newState = !allSelected;
    for (StrawberryPlaylistItem *item in self.allPlaylists) {
        item.isSelected = newState;
    }

    [self.outlineView reloadData];
    [self updateStatusLabel];
    [self updateSelectAllButtonTitle];
}

- (void)cancelImport:(id)sender {
    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseCancel];
    [self.delegate strawberryImportDidCancel];
}

- (void)performImport:(id)sender {
    NSMutableArray<StrawberryPlaylistItem *> *selected = [NSMutableArray array];
    for (StrawberryPlaylistItem *item in self.allPlaylists) {
        if (item.isSelected) {
            [selected addObject:item];
        }
    }

    [self.window.sheetParent endSheet:self.window returnCode:NSModalResponseOK];
    [self.delegate strawberryImportDidComplete:selected targetFolder:self.targetFolder];
}

- (void)checkboxClicked:(NSButton *)checkbox {
    NSInteger row = [self.outlineView rowForView:checkbox];
    if (row < 0) return;

    id item = [self.outlineView itemAtRow:row];

    if ([item isKindOfClass:[StrawberryPreviewFolder class]]) {
        StrawberryPreviewFolder *folder = item;
        BOOL newState = checkbox.state == NSControlStateValueOn;
        [folder setAllSelected:newState];
    } else if ([item isKindOfClass:[StrawberryPlaylistItem class]]) {
        StrawberryPlaylistItem *playlist = item;
        playlist.isSelected = checkbox.state == NSControlStateValueOn;
    }

    [self.outlineView reloadData];
    [self updateStatusLabel];
    [self updateSelectAllButtonTitle];
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (!item) {
        return self.rootItems.count;
    }
    if ([item isKindOfClass:[StrawberryPreviewFolder class]]) {
        return [(StrawberryPreviewFolder *)item children].count;
    }
    return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (!item) {
        return self.rootItems[index];
    }
    if ([item isKindOfClass:[StrawberryPreviewFolder class]]) {
        return [(StrawberryPreviewFolder *)item children][index];
    }
    return nil;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return [item isKindOfClass:[StrawberryPreviewFolder class]];
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    BOOL isFolder = [item isKindOfClass:[StrawberryPreviewFolder class]];

    // Checkbox column
    if ([tableColumn.identifier isEqualToString:@"CheckColumn"]) {
        NSButton *checkbox = [outlineView makeViewWithIdentifier:@"CheckCell" owner:self];
        if (!checkbox) {
            checkbox = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 18, 18)];
            checkbox.identifier = @"CheckCell";
            checkbox.buttonType = NSButtonTypeSwitch;
            checkbox.title = @"";
            checkbox.target = self;
            checkbox.action = @selector(checkboxClicked:);
        }

        if (isFolder) {
            StrawberryPreviewFolder *folder = item;
            if ([folder allItemsSelected]) {
                checkbox.state = NSControlStateValueOn;
            } else if ([folder hasSelectedItems]) {
                checkbox.state = NSControlStateValueMixed;
                checkbox.allowsMixedState = YES;
            } else {
                checkbox.state = NSControlStateValueOff;
                checkbox.allowsMixedState = NO;
            }
        } else {
            checkbox.allowsMixedState = NO;
            checkbox.state = [(StrawberryPlaylistItem *)item isSelected] ? NSControlStateValueOn : NSControlStateValueOff;
        }

        return checkbox;
    }

    // Name column
    if ([tableColumn.identifier isEqualToString:@"NameColumn"]) {
        NSTableCellView *cellView = [outlineView makeViewWithIdentifier:@"NameCell" owner:self];
        if (!cellView) {
            cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
            cellView.identifier = @"NameCell";

            NSImageView *imageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
            imageView.translatesAutoresizingMaskIntoConstraints = NO;
            imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
            [cellView addSubview:imageView];
            cellView.imageView = imageView;

            NSTextField *textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
            textField.translatesAutoresizingMaskIntoConstraints = NO;
            textField.bordered = NO;
            textField.drawsBackground = NO;
            textField.editable = NO;
            textField.selectable = NO;
            textField.font = [NSFont systemFontOfSize:[NSFont systemFontSize]];
            textField.lineBreakMode = NSLineBreakByTruncatingTail;
            [cellView addSubview:textField];
            cellView.textField = textField;

            [NSLayoutConstraint activateConstraints:@[
                [imageView.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor],
                [imageView.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor],
                [imageView.widthAnchor constraintEqualToConstant:16],
                [imageView.heightAnchor constraintEqualToConstant:16],
                [textField.leadingAnchor constraintEqualToAnchor:imageView.trailingAnchor constant:4],
                [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor],
                [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
            ]];
        }

        if (isFolder) {
            StrawberryPreviewFolder *folder = item;
            cellView.textField.stringValue = folder.name;
            cellView.imageView.image = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:@"Folder"];
        } else {
            StrawberryPlaylistItem *playlist = item;
            cellView.textField.stringValue = playlist.name;
            cellView.imageView.image = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:@"Playlist"];
        }

        return cellView;
    }

    // Count column
    if ([tableColumn.identifier isEqualToString:@"CountColumn"]) {
        NSTextField *textField = [outlineView makeViewWithIdentifier:@"CountCell" owner:self];
        if (!textField) {
            textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 50, 20)];
            textField.identifier = @"CountCell";
            textField.bordered = NO;
            textField.drawsBackground = NO;
            textField.editable = NO;
            textField.selectable = NO;
            textField.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
            textField.textColor = [NSColor secondaryLabelColor];
            textField.alignment = NSTextAlignmentRight;
        }

        NSInteger count = 0;
        if (isFolder) {
            count = [(StrawberryPreviewFolder *)item totalTrackCount];
        } else {
            count = [(StrawberryPlaylistItem *)item trackCount];
        }

        textField.stringValue = count > 0 ? [NSString stringWithFormat:@"%ld", (long)count] : @"";
        return textField;
    }

    return nil;
}

@end
