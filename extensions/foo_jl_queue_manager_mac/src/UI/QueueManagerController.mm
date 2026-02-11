//
//  QueueManagerController.mm
//  foo_jl_queue_manager
//
//  Main view controller for Queue Manager UI element
//

#import "QueueManagerController.h"
#import "QueueItemWrapper.h"
#import "QueueRowView.h"
#import "../Integration/QueueCallbackManager.h"
#import "../Core/QueueOperations.h"
#import "../Core/QueueConfig.h"
#import "../Core/ConfigHelper.h"
#import "../../../../shared/UIStyles.h"

// Column identifiers
static NSString* const kColumnIdQueueIndex = @"queue_index";
static NSString* const kColumnIdArtistTitle = @"artist_title";
static NSString* const kColumnIdDuration = @"duration";

// Pasteboard type for internal drag & drop
static NSPasteboardType const QueueItemPasteboardType = @"com.foobar2000.queue-manager.queue-item";

// External pasteboard types we accept
static NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.rows";

// Notify class for async track URL import (adds to playlist + queues)
class QueueDropNotify : public process_locations_notify {
public:
    t_size m_playlistIndex;
    t_size m_insertAt;
    pfc::string_list_impl m_paths;

    QueueDropNotify(t_size playlistIndex, t_size insertAt)
        : m_playlistIndex(playlistIndex), m_insertAt(insertAt) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            if (m_playlistIndex < pm->get_playlist_count()) {
                pm->playlist_undo_backup(m_playlistIndex);
                pm->playlist_insert_items(m_playlistIndex, m_insertAt, items, pfc::bit_array_val(true));

                // Queue each inserted item
                for (t_size i = 0; i < items.get_count(); i++) {
                    pm->queue_add_item_playlist(m_playlistIndex, m_insertAt + i);
                }
            }
        }
    }

    void on_aborted() override {}

    void startImport() {
        if (m_paths.get_count() == 0) return;

        pfc::list_t<const char*> pathPtrs;
        for (t_size i = 0; i < m_paths.get_count(); i++) {
            pathPtrs.add_item(m_paths[i]);
        }

        playlist_incoming_item_filter_v2::get()->process_locations_async(
            pathPtrs,
            playlist_incoming_item_filter_v2::op_flag_no_filter |
            playlist_incoming_item_filter_v2::op_flag_delay_ui,
            nullptr, nullptr, nullptr,
            this
        );
    }
};

@implementation QueueManagerController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _queueItems = [NSMutableArray array];
        _isReorderingInProgress = NO;
        _transparentBackground = queue_config::getConfigBool(
            queue_config::kKeyTransparentBackground,
            queue_config::kDefaultTransparentBackground);
    }
    return self;
}

- (void)dealloc {
    // Unregister from callback manager
    QueueCallbackManager::instance().unregisterController(self);
}

- (void)loadView {
    // Create root view
    NSView* rootView;

    if (_transparentBackground) {
        // Use NSVisualEffectView for true transparency/vibrancy
        NSVisualEffectView* effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
        effectView.material = NSVisualEffectMaterialSidebar;
        effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effectView.state = NSVisualEffectStateFollowsWindowActiveState;
        rootView = effectView;
    } else {
        rootView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 200)];
        rootView.wantsLayer = YES;
        rootView.layer.backgroundColor = fb2k_ui::backgroundColor().CGColor;
    }
    rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = rootView;

    // Create scroll view for table
    _scrollView = [[NSScrollView alloc] initWithFrame:rootView.bounds];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.borderType = NSNoBorder;
    _scrollView.drawsBackground = !_transparentBackground;
    if (!_transparentBackground) {
        _scrollView.backgroundColor = fb2k_ui::backgroundColor();
    }
    [rootView addSubview:_scrollView];

    // Create table view with SimPlaylist-matching appearance
    _tableView = [[NSTableView alloc] initWithFrame:_scrollView.bounds];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = fb2k_ui::rowHeight(fb2k_ui::SizeVariant::Normal);
    _tableView.allowsMultipleSelection = YES;
    _tableView.allowsEmptySelection = YES;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.backgroundColor = _transparentBackground ? [NSColor clearColor] : fb2k_ui::backgroundColor();
    _tableView.doubleAction = @selector(tableViewDoubleClick:);
    _tableView.target = self;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.gridStyleMask = NSTableViewGridNone;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    // Set up columns (hardcoded for Phase 1)
    [self setupColumns];

    // Configure header view with SimPlaylist-matching style and height
    NSTableHeaderView* headerView = [[NSTableHeaderView alloc] init];
    NSRect headerFrame = headerView.frame;
    headerFrame.size.height = fb2k_ui::headerHeight(fb2k_ui::SizeVariant::Normal);
    headerView.frame = headerFrame;
    _tableView.headerView = headerView;

    _scrollView.documentView = _tableView;

    // Set clip view background to match (this fills the empty area below rows)
    if (_transparentBackground) {
        _scrollView.contentView.drawsBackground = NO;
    } else {
        _scrollView.contentView.drawsBackground = YES;
        _scrollView.contentView.backgroundColor = fb2k_ui::backgroundColor();
    }

    // Create status bar
    [self setupStatusBar];

    // Set up drag & drop
    [self setupDragAndDrop];

    // Set up keyboard handling
    [self setupKeyboardHandling];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Register with callback manager
    QueueCallbackManager::instance().registerController(self);

    // Initial load
    [self reloadQueueContents];
}

#pragma mark - Setup

- (void)setupColumns {
    // Column 1: Queue # (narrow, fixed width)
    NSTableColumn* indexColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnIdQueueIndex];
    indexColumn.title = @"#";
    indexColumn.width = 30;
    indexColumn.minWidth = 30;
    indexColumn.maxWidth = 50;
    indexColumn.resizingMask = NSTableColumnUserResizingMask;
    indexColumn.headerCell = [[NSTableHeaderCell alloc] initTextCell:@"#"];
    [_tableView addTableColumn:indexColumn];

    // Column 2: Artist - Title (flex width)
    NSTableColumn* titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnIdArtistTitle];
    titleColumn.title = @"Artist - Title";
    titleColumn.width = 200;
    titleColumn.minWidth = 100;
    titleColumn.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    titleColumn.headerCell = [[NSTableHeaderCell alloc] initTextCell:@"Artist - Title"];
    [_tableView addTableColumn:titleColumn];

    // Column 3: Duration (narrow, fixed width)
    NSTableColumn* durationColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnIdDuration];
    durationColumn.title = @"Duration";
    durationColumn.width = 60;
    durationColumn.minWidth = 50;
    durationColumn.maxWidth = 80;
    durationColumn.resizingMask = NSTableColumnUserResizingMask;
    durationColumn.headerCell = [[NSTableHeaderCell alloc] initTextCell:@"Duration"];
    [_tableView addTableColumn:durationColumn];
}

- (void)setupStatusBar {
    CGFloat statusHeight = fb2k_ui::headerHeight(fb2k_ui::SizeVariant::Normal);
    CGFloat leftPadding = fb2k_ui::kHeaderTextPadding;
    NSRect statusFrame = NSMakeRect(leftPadding, 0, self.view.bounds.size.width - leftPadding, statusHeight);

    _statusBar = [[NSTextField alloc] initWithFrame:statusFrame];
    _statusBar.editable = NO;
    _statusBar.selectable = NO;
    _statusBar.bordered = NO;
    _statusBar.drawsBackground = !_transparentBackground;
    if (!_transparentBackground) {
        _statusBar.backgroundColor = fb2k_ui::backgroundColor();
    }
    _statusBar.font = fb2k_ui::statusBarFont();
    _statusBar.textColor = fb2k_ui::secondaryTextColor();
    _statusBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [self.view addSubview:_statusBar];

    // Adjust scroll view to leave room for status bar
    NSRect scrollFrame = _scrollView.frame;
    scrollFrame.origin.y = statusHeight;
    scrollFrame.size.height -= statusHeight;
    _scrollView.frame = scrollFrame;
}

- (void)setupDragAndDrop {
    // Register for drag types
    [_tableView registerForDraggedTypes:@[
        QueueItemPasteboardType,      // Internal reorder
        SimPlaylistPasteboardType,    // From SimPlaylist component
        NSPasteboardTypeFileURL,      // From Finder
        NSPasteboardTypeString        // Track URLs from Tidal browser etc.
    ]];

    // Enable dragging
    [_tableView setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
}

- (void)setupKeyboardHandling {
    // The table view handles Delete key via keyDown
}

#pragma mark - Data Loading

- (void)reloadQueueContents {
    // Fetch current queue from SDK
    auto contents = queue_ops::getContentsVector();

    // Clear and rebuild wrappers
    [_queueItems removeAllObjects];

    for (size_t i = 0; i < contents.size(); i++) {
        QueueItemWrapper* wrapper = [[QueueItemWrapper alloc]
                                     initWithQueueItem:contents[i]
                                     queueIndex:i];
        [_queueItems addObject:wrapper];
    }

    // Reload table
    [_tableView reloadData];

    // Update status bar
    [self updateStatusBar];
}

- (void)updateStatusBar {
    NSUInteger count = _queueItems.count;
    if (count == 0) {
        _statusBar.stringValue = @"";
    } else if (count == 1) {
        _statusBar.stringValue = @"1 item in queue";
    } else {
        _statusBar.stringValue = [NSString stringWithFormat:@"%lu items in queue",
                                  (unsigned long)count];
    }
}

#pragma mark - Actions

- (void)removeSelectedItems {
    NSIndexSet* selection = _tableView.selectedRowIndexes;
    if (selection.count == 0) return;

    // Build list of indices to remove (in ascending order)
    __block std::vector<size_t> indices;
    [selection enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL* stop) {
        indices.push_back(idx);
    }];

    // Remove from queue via SDK
    queue_ops::removeItems(indices);

    // Table will be reloaded by callback
}

- (void)playSelectedItem {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_queueItems.count) return;

    QueueItemWrapper* item = _queueItems[row];

    // Build a t_playback_queue_item for playItem
    t_playback_queue_item queueItem;
    queueItem.m_handle = [item handle];
    queueItem.m_playlist = item.isOrphan ? ~(size_t)0 : item.sourcePlaylist;
    queueItem.m_item = item.isOrphan ? ~(size_t)0 : item.sourceItem;

    queue_ops::playItem(queueItem);
}

- (void)tableViewDoubleClick:(id)sender {
    [self playSelectedItem];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return _queueItems.count;
}

#pragma mark - Drag & Drop (NSTableViewDataSource)

// Provide data for dragging
- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView
              pasteboardWriterForRow:(NSInteger)row {
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)row]
            forType:QueueItemPasteboardType];
    return item;
}

// Validate drop operation
- (NSDragOperation)tableView:(NSTableView*)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)dropOperation {
    // Only allow drops between rows, not on rows
    if (dropOperation == NSTableViewDropOn) {
        [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    }

    NSPasteboard* pb = info.draggingPasteboard;

    // Internal reordering
    if ([pb.types containsObject:QueueItemPasteboardType]) {
        return NSDragOperationMove;
    }

    // From SimPlaylist
    if ([pb.types containsObject:SimPlaylistPasteboardType]) {
        return NSDragOperationCopy;
    }

    // From Finder (file URLs)
    if ([pb.types containsObject:NSPasteboardTypeFileURL]) {
        return NSDragOperationCopy;
    }

    // Track URLs as plain text (e.g., tidal:// from Tidal browser)
    if ([pb.types containsObject:NSPasteboardTypeString]) {
        NSString *text = [pb stringForType:NSPasteboardTypeString];
        if (text && [text containsString:@"tidal://track/"]) {
            return NSDragOperationCopy;
        }
    }

    return NSDragOperationNone;
}

// Accept drop
- (BOOL)tableView:(NSTableView*)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)dropOperation {

    NSPasteboard* pasteboard = info.draggingPasteboard;

    // Handle internal reordering
    if ([pasteboard.types containsObject:QueueItemPasteboardType]) {
        return [self handleInternalDropAtRow:row fromPasteboard:pasteboard];
    }

    // Handle drop from SimPlaylist
    if ([pasteboard.types containsObject:SimPlaylistPasteboardType]) {
        return [self handleSimPlaylistDropFromPasteboard:pasteboard];
    }

    // Handle file URL drop from Finder
    if ([pasteboard.types containsObject:NSPasteboardTypeFileURL]) {
        return [self handleFileURLDropFromPasteboard:pasteboard];
    }

    // Handle track URL drop (e.g., tidal:// from Tidal browser)
    if ([pasteboard.types containsObject:NSPasteboardTypeString]) {
        return [self handleTrackURLDropFromPasteboard:pasteboard];
    }

    return NO;
}

// Handle internal queue reordering
- (BOOL)handleInternalDropAtRow:(NSInteger)targetRow fromPasteboard:(NSPasteboard*)pasteboard {
    NSString* rowString = [pasteboard stringForType:QueueItemPasteboardType];
    if (!rowString) return NO;

    NSInteger sourceRow = [rowString integerValue];
    if (sourceRow < 0 || sourceRow >= (NSInteger)_queueItems.count) return NO;
    if (targetRow < 0) targetRow = 0;
    if (targetRow > (NSInteger)_queueItems.count) targetRow = _queueItems.count;

    // If dropping at the same position or the position right after, no change needed
    if (sourceRow == targetRow || sourceRow + 1 == targetRow) return NO;

    // Set flag to prevent callback storm
    _isReorderingInProgress = YES;

    // Get current queue contents
    auto contents = queue_ops::getContentsVector();
    if (sourceRow >= (NSInteger)contents.size()) {
        _isReorderingInProgress = NO;
        return NO;
    }

    // Capture the item being moved
    t_playback_queue_item movingItem = contents[sourceRow];

    // Clear the queue
    queue_ops::clear();

    // Rebuild in new order
    // Adjust target if source was before target
    NSInteger adjustedTarget = targetRow;
    if (sourceRow < targetRow) {
        adjustedTarget--;
    }

    for (NSInteger i = 0; i < (NSInteger)contents.size(); i++) {
        if (i == sourceRow) continue; // Skip source position

        // Insert the moved item at target position
        if (i == adjustedTarget || (i == 0 && adjustedTarget == 0 && sourceRow != 0)) {
            // Actually we need a different approach - rebuild properly
        }
    }

    // Simpler approach: build new order array
    std::vector<t_playback_queue_item> newOrder;
    newOrder.reserve(contents.size());

    for (NSInteger i = 0; i < (NSInteger)contents.size(); i++) {
        if (i == sourceRow) continue;

        // Insert moved item at correct position
        if ((NSInteger)newOrder.size() == adjustedTarget) {
            newOrder.push_back(movingItem);
        }
        newOrder.push_back(contents[i]);
    }

    // If target is at the end
    if (adjustedTarget >= (NSInteger)newOrder.size()) {
        newOrder.push_back(movingItem);
    }

    // Add all items back to queue
    for (const auto& item : newOrder) {
        if (item.m_playlist != ~(size_t)0) {
            queue_ops::addItemFromPlaylist(item.m_playlist, item.m_item);
        } else {
            queue_ops::addOrphanItem(item.m_handle);
        }
    }

    _isReorderingInProgress = NO;

    // Manually reload since we suppressed callbacks
    [self reloadQueueContents];

    return YES;
}

// Handle drop from SimPlaylist component
- (BOOL)handleSimPlaylistDropFromPasteboard:(NSPasteboard*)pasteboard {
    NSData* data = [pasteboard dataForType:SimPlaylistPasteboardType];
    if (!data) return NO;

    // SimPlaylist now sends a dictionary with:
    // - @"sourcePlaylist": NSNumber (playlist index)
    // - @"indices": NSArray of NSNumber (row indices)
    // - @"paths": (optional) NSArray of NSString (file paths)
    NSError* error = nil;
    NSSet* classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class],
                      [NSNumber class], [NSString class], nil];
    NSDictionary* dragData = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes
                                                                 fromData:data
                                                                    error:&error];
    if (!dragData || ![dragData isKindOfClass:[NSDictionary class]]) {
        console::error("[Queue Manager] Failed to decode SimPlaylist drag data");
        return NO;
    }

    // Extract source playlist and indices
    NSNumber* sourcePlaylistNum = dragData[@"sourcePlaylist"];
    NSArray<NSNumber*>* rowNumbers = dragData[@"indices"];

    if (!rowNumbers || rowNumbers.count == 0) {
        console::error("[Queue Manager] No indices in SimPlaylist drag data");
        return NO;
    }

    // Use the source playlist from the drag data, not the active playlist
    // This ensures correct behavior even if active playlist changes during drag
    size_t sourcePlaylist;
    if (sourcePlaylistNum) {
        sourcePlaylist = [sourcePlaylistNum unsignedLongValue];
    } else {
        // Fallback to active playlist if not specified
        auto pm = playlist_manager::get();
        sourcePlaylist = pm->get_active_playlist();
        if (sourcePlaylist == SIZE_MAX) {
            return NO;
        }
    }

    auto pm = playlist_manager::get();
    size_t playlistItemCount = pm->playlist_get_item_count(sourcePlaylist);

    // Add each item to the queue
    for (NSNumber* rowNum in rowNumbers) {
        size_t row = [rowNum unsignedLongValue];
        if (row < playlistItemCount) {
            queue_ops::addItemFromPlaylist(sourcePlaylist, row);
        }
    }

    return YES;
}

// Handle file URL drop from Finder
- (BOOL)handleFileURLDropFromPasteboard:(NSPasteboard*)pasteboard {
    NSArray* urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                              options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    if (!urls || urls.count == 0) {
        return NO;
    }

    // For file drops, we need to get metadb handles for the files
    // This is complex - we'd need to use metadb_io to look up or add files
    // For now, log that this is not yet implemented
    console::info("[Queue Manager] File drop not yet implemented - use 'Add to Playback Queue' from context menu");

    return NO;
}

// Handle track URL drop (e.g., tidal:// URLs from Tidal browser)
- (BOOL)handleTrackURLDropFromPasteboard:(NSPasteboard*)pasteboard {
    NSString* text = [pasteboard stringForType:NSPasteboardTypeString];
    if (!text || text.length == 0) return NO;

    // Parse newline-separated URLs, filter for tidal:// tracks
    NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString*>* trackURLs = [NSMutableArray array];
    for (NSString* line in lines) {
        NSString* trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"tidal://track/"]) {
            [trackURLs addObject:trimmed];
        }
    }

    if (trackURLs.count == 0) return NO;

    // Add to active playlist and queue
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) {
        activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
        pm->set_active_playlist(activePlaylist);
    }

    t_size insertAt = pm->playlist_get_item_count(activePlaylist);
    auto notify = new service_impl_t<QueueDropNotify>(activePlaylist, insertAt);

    for (NSString* url in trackURLs) {
        notify->m_paths.add_item([url UTF8String]);
    }
    notify->startImport();

    console::printf("[Queue Manager] Queuing %lu track(s) from Tidal", (unsigned long)trackURLs.count);
    return YES;
}

#pragma mark - NSTableViewDelegate

- (NSTableRowView*)tableView:(NSTableView*)tableView rowViewForRow:(NSInteger)row {
    // Use custom row view with SimPlaylist-matching selection style
    QueueRowView* rowView = [tableView makeViewWithIdentifier:@"QueueRowView" owner:self];
    if (!rowView) {
        rowView = [[QueueRowView alloc] init];
        rowView.identifier = @"QueueRowView";
    }
    return rowView;
}

- (NSView*)tableView:(NSTableView*)tableView
  viewForTableColumn:(NSTableColumn*)tableColumn
                 row:(NSInteger)row {

    if (row < 0 || row >= (NSInteger)_queueItems.count) {
        return nil;
    }

    QueueItemWrapper* item = _queueItems[row];
    NSString* identifier = tableColumn.identifier;

    // Get or create cell view - use NSTableCellView for proper centering
    NSTableCellView* cellView = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cellView) {
        cellView = [[NSTableCellView alloc] init];
        cellView.identifier = identifier;

        // Create text field inside cell view
        NSTextField* textField = [[NSTextField alloc] init];
        textField.bordered = NO;
        textField.editable = NO;
        textField.selectable = NO;
        textField.drawsBackground = NO;
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        textField.translatesAutoresizingMaskIntoConstraints = NO;

        [cellView addSubview:textField];
        cellView.textField = textField;

        // Center vertically, fill horizontally with padding
        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:fb2k_ui::kCellTextPadding],
            [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor constant:-fb2k_ui::kCellTextPadding],
            [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
        ]];
    }

    NSTextField* cell = cellView.textField;

    // Set cell content based on column
    if ([identifier isEqualToString:kColumnIdQueueIndex]) {
        cell.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)(row + 1)];
        cell.alignment = NSTextAlignmentRight;
        cell.font = fb2k_ui::monospacedDigitFont();
        cell.textColor = fb2k_ui::secondaryTextColor();
    } else if ([identifier isEqualToString:kColumnIdArtistTitle]) {
        cell.stringValue = item.cachedArtistTitle ?: @"";
        cell.alignment = NSTextAlignmentLeft;
        cell.font = fb2k_ui::rowFont();
        cell.textColor = fb2k_ui::textColor();
    } else if ([identifier isEqualToString:kColumnIdDuration]) {
        cell.stringValue = item.cachedDuration ?: @"";
        cell.alignment = NSTextAlignmentRight;
        cell.font = fb2k_ui::monospacedDigitFont();
        cell.textColor = fb2k_ui::textColor();
    }

    return cellView;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    // Update text colors for all visible rows based on selection state
    NSIndexSet* selectedRows = _tableView.selectedRowIndexes;

    for (NSInteger row = 0; row < (NSInteger)_queueItems.count; row++) {
        NSTableRowView* rowView = [_tableView rowViewAtRow:row makeIfNecessary:NO];
        if (!rowView) continue;

        BOOL isSelected = [selectedRows containsIndex:row];
        NSColor* textColor = isSelected ? fb2k_ui::selectedTextColor() : fb2k_ui::textColor();
        NSColor* secondaryColor = isSelected ? fb2k_ui::selectedTextColor() : fb2k_ui::secondaryTextColor();

        // Update each column's text color
        for (NSInteger col = 0; col < (NSInteger)_tableView.numberOfColumns; col++) {
            NSTableCellView* cellView = [_tableView viewAtColumn:col row:row makeIfNecessary:NO];
            if (cellView && cellView.textField) {
                NSTableColumn* column = _tableView.tableColumns[col];
                if ([column.identifier isEqualToString:kColumnIdQueueIndex]) {
                    cellView.textField.textColor = secondaryColor;
                } else {
                    cellView.textField.textColor = textColor;
                }
            }
        }
    }
}

#pragma mark - Keyboard Handling

- (void)keyDown:(NSEvent*)event {
    NSString *chars = [event charactersIgnoringModifiers];
    if (chars.length == 0) {
        [super keyDown:event];
        return;
    }
    unichar key = [chars characterAtIndex:0];

    if (key == NSDeleteCharacter || key == NSBackspaceCharacter) {
        [self removeSelectedItems];
    } else if (key == NSCarriageReturnCharacter || key == NSEnterCharacter) {
        [self playSelectedItem];
    } else {
        [super keyDown:event];
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

#pragma mark - Accessibility

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityListRole;
}

- (NSString*)accessibilityLabel {
    return [NSString stringWithFormat:@"Playback queue with %lu items",
            (unsigned long)_queueItems.count];
}

@end
