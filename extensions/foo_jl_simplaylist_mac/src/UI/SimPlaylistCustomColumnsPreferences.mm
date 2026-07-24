//
//  SimPlaylistCustomColumnsPreferences.mm
//  foo_simplaylist_mac
//
//  Custom Columns preferences page (child of SimPlaylist preferences)
//

#import "SimPlaylistCustomColumnsPreferences.h"
#import "../Core/ConfigHelper.h"
#import "../Core/ColumnDefinition.h"
#import "../fb2k_sdk.h"
#import "../../../../shared/PreferencesCommon.h"

// Flipped view for top-to-bottom layout
@interface CustomColumnsFlippedView : NSView
@end
@implementation CustomColumnsFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface SimPlaylistCustomColumnsController ()
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<ColumnDefinition *> *columns;
@property (nonatomic, strong) NSSegmentedControl *addRemoveControl;
@end

@implementation SimPlaylistCustomColumnsController

- (void)loadView {
    NSView *container = [[CustomColumnsFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
    self.view = container;

    CGFloat leftMargin = 20;
    CGFloat rightMargin = 20;
    CGFloat y = 20;

    // Title
    NSTextField *title = JLCreatePreferencesTitle(@"Custom Columns");
    title.frame = NSMakeRect(leftMargin, y, 300, 20);
    [container addSubview:title];

    // +/- segmented control in top right (matches foobar style)
    _addRemoveControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(container.bounds.size.width - rightMargin - 48, y - 2, 48, 24)];
    _addRemoveControl.segmentCount = 2;
    [_addRemoveControl setLabel:@"+" forSegment:0];
    [_addRemoveControl setLabel:@"-" forSegment:1];
    [_addRemoveControl setWidth:24 forSegment:0];
    [_addRemoveControl setWidth:24 forSegment:1];
    _addRemoveControl.segmentStyle = NSSegmentStyleSmallSquare;
    _addRemoveControl.target = self;
    _addRemoveControl.action = @selector(addRemoveClicked:);
    [_addRemoveControl setEnabled:YES forSegment:0];
    [_addRemoveControl setEnabled:NO forSegment:1];
    _addRemoveControl.autoresizingMask = NSViewMinXMargin;  // Pin to right
    [container addSubview:_addRemoveControl];

    y += 30;

    // Scroll view with table - fills width
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(leftMargin, y, container.bounds.size.width - leftMargin - rightMargin, 340)];
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSLineBorder;
    scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _tableView = [[NSTableView alloc] initWithFrame:scrollView.bounds];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 20;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.allowsColumnReordering = NO;
    _tableView.allowsMultipleSelection = NO;
    _tableView.gridStyleMask = NSTableViewSolidVerticalGridLineMask;
    _tableView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;

    // Name column
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameColumn.title = @"Name";
    nameColumn.width = 120;
    nameColumn.minWidth = 60;
    [_tableView addTableColumn:nameColumn];

    // Align column
    NSTableColumn *alignColumn = [[NSTableColumn alloc] initWithIdentifier:@"align"];
    alignColumn.title = @"Align";
    alignColumn.width = 65;
    alignColumn.minWidth = 65;
    alignColumn.maxWidth = 65;
    [_tableView addTableColumn:alignColumn];

    // Pattern column (auto-resize to fill)
    NSTableColumn *patternColumn = [[NSTableColumn alloc] initWithIdentifier:@"pattern"];
    patternColumn.title = @"Pattern";
    patternColumn.width = 273;
    patternColumn.minWidth = 100;
    [_tableView addTableColumn:patternColumn];

    scrollView.documentView = _tableView;
    [container addSubview:scrollView];

    // Load data
    [self loadColumns];
}

- (void)loadColumns {
    _columns = [[ColumnDefinition customColumns] mutableCopy];
    if (!_columns) {
        _columns = [NSMutableArray array];
    }
    [_tableView reloadData];
    [self updateButtonStates];
}

- (void)saveColumns {
    [ColumnDefinition saveCustomColumns:_columns];

    // Post notification so SimPlaylist can update
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SimPlaylistCustomColumnsChanged" object:nil];
}

- (void)updateButtonStates {
    [_addRemoveControl setEnabled:(_tableView.selectedRow >= 0) forSegment:1];
}

#pragma mark - Actions

- (void)addRemoveClicked:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 0) {
        [self addColumn];
    } else {
        [self removeColumn];
    }
}

- (void)addColumn {
    ColumnDefinition *newCol = [ColumnDefinition columnWithName:@"New Column"
                                                        pattern:@"%field%"
                                                          width:100
                                                      alignment:ColumnAlignmentLeft];
    [_columns addObject:newCol];
    [_tableView reloadData];

    // Select and edit the new row
    NSInteger newRow = _columns.count - 1;
    [_tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:newRow] byExtendingSelection:NO];
    [_tableView scrollRowToVisible:newRow];

    [self saveColumns];
    [self updateButtonStates];
}

- (void)removeColumn {
    NSInteger row = _tableView.selectedRow;
    if (row >= 0 && row < (NSInteger)_columns.count) {
        [_columns removeObjectAtIndex:row];
        [_tableView reloadData];
        [self saveColumns];
        [self updateButtonStates];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _columns.count;
}

#pragma mark - NSTableViewDelegate

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_columns.count) return nil;

    ColumnDefinition *col = _columns[row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:@"name"]) {
        NSTableCellView *cellView = [tableView makeViewWithIdentifier:@"NameCell" owner:self];
        if (!cellView) {
            cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
            cellView.identifier = @"NameCell";

            NSTextField *textField = [[NSTextField alloc] initWithFrame:cellView.bounds];
            textField.bordered = NO;
            textField.drawsBackground = NO;
            textField.editable = YES;
            textField.font = [NSFont systemFontOfSize:13];
            textField.lineBreakMode = NSLineBreakByTruncatingTail;
            textField.autoresizingMask = NSViewWidthSizable;
            textField.target = self;
            textField.action = @selector(textFieldChanged:);
            cellView.textField = textField;
            [cellView addSubview:textField];
        }
        cellView.textField.stringValue = col.name ?: @"";
        cellView.objectValue = @(row);
        return cellView;
    }
    else if ([identifier isEqualToString:@"align"]) {
        NSTableCellView *cellView = [tableView makeViewWithIdentifier:@"AlignCell" owner:self];
        if (!cellView) {
            cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
            cellView.identifier = @"AlignCell";

            NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, -1, tableColumn.width, 22) pullsDown:NO];
            popup.bordered = NO;
            popup.font = [NSFont systemFontOfSize:13];
            [popup addItemsWithTitles:@[@"Left", @"Center", @"Right"]];
            popup.autoresizingMask = NSViewWidthSizable;
            popup.target = self;
            popup.action = @selector(alignmentChanged:);
            [cellView addSubview:popup];
        }
        NSPopUpButton *popup = cellView.subviews.firstObject;
        [popup selectItemAtIndex:(NSInteger)col.alignment];
        cellView.objectValue = @(row);
        return cellView;
    }
    else if ([identifier isEqualToString:@"pattern"]) {
        NSTableCellView *cellView = [tableView makeViewWithIdentifier:@"PatternCell" owner:self];
        if (!cellView) {
            cellView = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
            cellView.identifier = @"PatternCell";

            NSTextField *textField = [[NSTextField alloc] initWithFrame:cellView.bounds];
            textField.bordered = NO;
            textField.drawsBackground = NO;
            textField.editable = YES;
            textField.font = [NSFont systemFontOfSize:13];
            textField.lineBreakMode = NSLineBreakByTruncatingTail;
            textField.autoresizingMask = NSViewWidthSizable;
            textField.target = self;
            textField.action = @selector(textFieldChanged:);
            cellView.textField = textField;
            [cellView addSubview:textField];
        }
        cellView.textField.stringValue = col.pattern ?: @"";
        cellView.objectValue = @(row);
        return cellView;
    }

    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    [self updateButtonStates];
}

#pragma mark - Cell Editing

- (void)textFieldChanged:(NSTextField *)sender {
    // Resolve row/column at action time; the objectValue snapshot taken at
    // cell creation goes stale when rows are added or removed, and
    // columnForView: returns -1 for a detached view.
    NSInteger row = [_tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)_columns.count) return;

    NSInteger column = [_tableView columnForView:sender];
    if (column < 0) return;
    NSTableColumn *tableColumn = _tableView.tableColumns[column];

    if ([tableColumn.identifier isEqualToString:@"name"]) {
        NSString *oldName = _columns[row].name;
        NSString *newName = sender.stringValue;
        _columns[row].name = newName;
        // Sync rename to visible columns so they stay linked
        [ColumnDefinition syncCustomColumnRenameFrom:oldName to:newName];
    } else if ([tableColumn.identifier isEqualToString:@"pattern"]) {
        _columns[row].pattern = sender.stringValue;
    }
    [self saveColumns];
}

- (void)alignmentChanged:(NSPopUpButton *)sender {
    // Same stale-identity concern as textFieldChanged: above.
    NSInteger row = [_tableView rowForView:sender];
    if (row < 0 || row >= (NSInteger)_columns.count) return;

    _columns[row].alignment = (ColumnAlignment)sender.indexOfSelectedItem;
    [self saveColumns];
}

@end

// ==================== PREFERENCES PAGE REGISTRATION ====================

namespace {

// GUID for SimPlaylist main preferences (parent)
static const GUID guid_simplaylist_preferences =
    { 0x8a9e2c41, 0x3b7d, 0x4f52, { 0x9e, 0x1a, 0x5c, 0x8b, 0x3d, 0x6f, 0x4e, 0x2a } };

// GUID for custom columns preferences (child)
static const GUID guid_simplaylist_custom_columns =
    { 0x7b8e1c32, 0x4a6d, 0x5e43, { 0x8f, 0x2b, 0x6d, 0x9a, 0x4e, 0x7f, 0x5c, 0x3b } };

class simplaylist_custom_columns_page : public preferences_page_v2 {
public:
    const char* get_name() override {
        return "Custom Columns";
    }

    GUID get_guid() override {
        return guid_simplaylist_custom_columns;
    }

    GUID get_parent_guid() override {
        return guid_simplaylist_preferences;  // Child of SimPlaylist
    }

    double get_sort_priority() override {
        return 0;
    }

    service_ptr instantiate() override {
        SimPlaylistCustomColumnsController *vc = [[SimPlaylistCustomColumnsController alloc] init];
        return fb2k::wrapNSObject(vc);
    }
};

FB2K_SERVICE_FACTORY(simplaylist_custom_columns_page);

} // namespace
