//
//  LibVancedController.mm
//  foo_jl_libvanced
//

#import "LibVancedController.h"
#import "LibraryOutlineView.h"
#import "LibVancedCellView.h"
#import "../Core/LibraryDataSource.h"
#import "../Core/LibraryTreeNode.h"
#import "../Core/LibraryAlbumArtCache.h"
#import "../Core/ConfigHelper.h"
#import "../Integration/LibraryCallbacks.h"
#import "../../../../shared/UIStyles.h"
#import "../../../../shared/PreferencesCommon.h"

// Pasteboard type matching SimPlaylist for cross-component drag compatibility
static NSPasteboardType const SimPlaylistPasteboardType = @"com.foobar2000.simplaylist.rows";

@interface LibVancedController () <NSOutlineViewDataSource, NSOutlineViewDelegate,
                                    NSDraggingSource, LibraryOutlineViewDelegate,
                                    LibraryDataSourceDelegate, NSSearchFieldDelegate>
@end

@implementation LibVancedController {
    LibraryOutlineView *_outlineView;
    NSScrollView *_scrollView;
    NSSearchField *_searchField;
    NSTextField *_statusLabel;
    NSView *_containerView;

    LibraryDataSource *_dataSource;
    NSString *_currentFilter;
    BOOL _isLoading;
    NSTimer *_searchDebounceTimer;

    // Context menu state
    contextmenu_manager_v2::ptr _contextMenuManager;
    contextmenu_manager::ptr _contextMenuManagerV1;
    metadb_handle_list _contextMenuHandles;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _dataSource = [[LibraryDataSource alloc] init];
        _dataSource.delegate = self;

        NSString *savedGroup = [NSString stringWithUTF8String:
            libvanced_config::getConfigString(
                libvanced_config::kGroupPattern,
                libvanced_config::getDefaultGroupPattern().c_str()).c_str()];
        NSString *savedSort = [NSString stringWithUTF8String:
            libvanced_config::getConfigString(
                libvanced_config::kSortPattern,
                libvanced_config::getDefaultSortPattern().c_str()).c_str()];
        _dataSource.groupPattern = savedGroup;
        _dataSource.sortPattern = savedSort;
    }
    return self;
}

- (void)dealloc {
    [_searchDebounceTimer invalidate];
    LibVancedCallbackManager_unregisterController(self);
}

static const CGFloat kSearchFieldHeight = 24.0;
static const CGFloat kStatusBarHeight = 18.0;
static const CGFloat kPadding = 4.0;
static const CGFloat kSearchTopMargin = 4.0;
static const CGFloat kSearchScrollGap = 2.0;
static const CGFloat kStatusBottomMargin = 2.0;

- (void)loadView {
    BOOL glass = libvanced_config::getConfigBool(
        libvanced_config::kGlassBackground,
        libvanced_config::kDefaultGlassBackground);

    if (glass) {
        _containerView = fb2k_ui::createGlassContainer(NSMakeRect(0, 0, 250, 400));
    } else {
        _containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 400)];
        _containerView.wantsLayer = YES;
    }
    _containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = _containerView;

    [self setupSearchField];
    [self setupOutlineView:glass];
    [self setupStatusBar];
    [self layoutAllSubviews];

    LibVancedCallbackManager_registerController(self);

    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_dataSource rebuildTree];
    });
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self layoutAllSubviews];
}

- (void)layoutAllSubviews {
    NSRect bounds = _containerView.bounds;
    CGFloat w = bounds.size.width;
    CGFloat h = bounds.size.height;

    CGFloat searchY = h - kSearchTopMargin - kSearchFieldHeight;
    _searchField.frame = NSMakeRect(kPadding, searchY, w - kPadding * 2, kSearchFieldHeight);

    CGFloat statusY = kStatusBottomMargin;
    _statusLabel.frame = NSMakeRect(kPadding, statusY, w - kPadding * 2, kStatusBarHeight);

    CGFloat scrollBottom = statusY + kStatusBarHeight;
    CGFloat scrollTop = searchY - kSearchScrollGap;
    CGFloat scrollHeight = scrollTop - scrollBottom;
    if (scrollHeight < 0) scrollHeight = 0;
    _scrollView.frame = NSMakeRect(0, scrollBottom, w, scrollHeight);
}

- (void)setupSearchField {
    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.placeholderString = @"Search library...";
    _searchField.delegate = self;
    _searchField.sendsSearchStringImmediately = NO;
    _searchField.sendsWholeSearchString = YES;
    _searchField.font = [NSFont systemFontOfSize:12];
    [_containerView addSubview:_searchField];
}

- (void)setupOutlineView:(BOOL)glass {
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;

    fb2k_ui::configureScrollViewForGlass(_scrollView, glass);

    _outlineView = [[LibraryOutlineView alloc] initWithFrame:NSZeroRect];
    _outlineView.actionDelegate = self;
    _outlineView.headerView = nil;
    _outlineView.floatsGroupRows = NO;
    _outlineView.indentationPerLevel = 16;
    _outlineView.autoresizesOutlineColumn = YES;
    _outlineView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    _outlineView.allowsMultipleSelection = YES;
    _outlineView.allowsEmptySelection = YES;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineView.target = self;
    _outlineView.doubleAction = @selector(outlineViewDoubleClicked:);
    _outlineView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.minWidth = 50;
    [_outlineView addTableColumn:column];
    _outlineView.outlineTableColumn = column;

    [_outlineView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [_outlineView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];

    _scrollView.documentView = _outlineView;
    [_containerView addSubview:_scrollView];
}

- (void)setupStatusBar {
    _statusLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusLabel.editable = NO;
    _statusLabel.selectable = NO;
    _statusLabel.bordered = NO;
    _statusLabel.drawsBackground = NO;
    _statusLabel.font = fb2k_ui::statusBarFont();
    _statusLabel.textColor = fb2k_ui::secondaryTextColor();
    _statusLabel.alignment = NSTextAlignmentCenter;
    [_containerView addSubview:_statusLabel];
}

#pragma mark - NSSearchFieldDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    [_searchDebounceTimer invalidate];
    _searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                           target:self
                                                         selector:@selector(debouncedSearch)
                                                         userInfo:nil
                                                          repeats:NO];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(insertNewline:)) {
        [_searchDebounceTimer invalidate];
        [self performSearch];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [_searchDebounceTimer invalidate];
        _searchField.stringValue = @"";
        [self performSearch];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    [self performSearch];
}

- (void)searchFieldDidEndSearching:(NSSearchField *)sender {
    [_searchDebounceTimer invalidate];
    _currentFilter = nil;
    [_dataSource rebuildTree];
}

- (void)debouncedSearch {
    [self performSearch];
}

- (void)performSearch {
    NSString *query = _searchField.stringValue;
    if (query.length == 0) {
        _currentFilter = nil;
        [_dataSource rebuildTree];
    } else {
        _currentFilter = query;
        [_dataSource rebuildTreeWithFilter:query];
    }
}

#pragma mark - NSOutlineViewDataSource

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(nullable id)item {
    LibraryTreeNode *node = item ?: _dataSource.rootNode;
    if (node.nodeType == LibraryNodeTypeTrack) return 0;
    return node.children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(nullable id)item {
    LibraryTreeNode *node = item ?: _dataSource.rootNode;
    return node.children[index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    LibraryTreeNode *node = item;
    return node.nodeType != LibraryNodeTypeTrack && node.children.count > 0;
}

#pragma mark - Drag & Drop DataSource

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)outlineView
              pasteboardWriterForItem:(id)item {
    LibraryTreeNode *node = item;
    if (!node) return nil;

    NSArray<NSString *> *paths = [node allTrackPaths];
    if (paths.count == 0) return nil;

    NSDictionary *simData = @{
        @"sourcePlaylist": @(-1),
        @"indices": @[],
        @"paths": paths
    };
    NSData *simDataArchive = [NSKeyedArchiver archivedDataWithRootObject:simData
                                                   requiringSecureCoding:NO
                                                                  error:nil];

    NSPasteboardItem *pbItem = [[NSPasteboardItem alloc] init];
    [pbItem setData:simDataArchive forType:SimPlaylistPasteboardType];
    return pbItem;
}

- (void)outlineView:(NSOutlineView *)outlineView
    draggingSession:(NSDraggingSession *)session
   willBeginAtPoint:(NSPoint)screenPoint
           forItems:(NSArray *)draggedItems {
    // Consolidate all dragged items into a single SimPlaylist-compatible payload
    // on the session pasteboard (the per-row items above get the drag started,
    // but the drop target reads the session pasteboard).
    NSMutableArray<NSString *> *allPaths = [NSMutableArray array];
    for (LibraryTreeNode *node in draggedItems) {
        [allPaths addObjectsFromArray:[node allTrackPaths]];
    }
    if (allPaths.count == 0) return;

    NSDictionary *simData = @{
        @"sourcePlaylist": @(-1),
        @"indices": @[],
        @"paths": allPaths
    };
    NSData *simDataArchive = [NSKeyedArchiver archivedDataWithRootObject:simData
                                                   requiringSecureCoding:NO
                                                                  error:nil];
    [session.draggingPasteboard setData:simDataArchive forType:SimPlaylistPasteboardType];

    // Also write file URLs for Finder interop
    NSMutableArray<NSURL *> *fileURLs = [NSMutableArray array];
    for (NSString *path in allPaths) {
        pfc::string8 nativePath;
        try {
            filesystem::g_get_native_path([path UTF8String], nativePath);
            NSString *nsPath = [NSString stringWithUTF8String:nativePath.c_str()];
            NSURL *url = [NSURL fileURLWithPath:nsPath];
            if (url) [fileURLs addObject:url];
        } catch (...) {}
    }
    if (fileURLs.count > 0) {
        [session.draggingPasteboard writeObjects:fileURLs];
    }
}

#pragma mark - NSOutlineViewDelegate

- (NSView *)outlineView:(NSOutlineView *)outlineView
      viewForTableColumn:(NSTableColumn *)tableColumn
                    item:(id)item {
    LibraryTreeNode *node = item;

    NSString *identifier = (node.nodeType == LibraryNodeTypeTrack) ? @"TrackCell" : @"GroupCell";
    LibVancedCellView *cellView = [outlineView makeViewWithIdentifier:identifier owner:self];

    if (!cellView) {
        cellView = [[LibVancedCellView alloc] initWithFrame:NSZeroRect];
        cellView.identifier = identifier;
    }

    BOOL showArt = libvanced_config::getConfigBool(
        libvanced_config::kShowAlbumArt,
        libvanced_config::kDefaultShowAlbumArt);
    BOOL showCount = libvanced_config::getConfigBool(
        libvanced_config::kShowTrackCount,
        libvanced_config::kDefaultShowTrackCount);

    [cellView configureWithNode:node showAlbumArt:showArt showTrackCount:showCount];

    return cellView;
}

- (CGFloat)outlineView:(NSOutlineView *)outlineView heightOfRowByItem:(id)item {
    LibraryTreeNode *node = item;
    BOOL showArt = libvanced_config::getConfigBool(
        libvanced_config::kShowAlbumArt,
        libvanced_config::kDefaultShowAlbumArt);

    if (node.nodeType == LibraryNodeTypeTrack) {
        return 20.0;
    }

    // Group rows are taller when showing album art
    return showArt ? 32.0 : 22.0;
}

#pragma mark - Double Click

- (void)outlineViewDoubleClicked:(id)sender {
    NSInteger row = _outlineView.clickedRow;
    if (row < 0) return;

    LibraryTreeNode *node = [_outlineView itemAtRow:row];
    if (!node) return;

    if (node.nodeType == LibraryNodeTypeTrack || node.nodeType == LibraryNodeTypeGroup) {
        [self sendNodesToCurrentPlaylist:@[node]];
    }
}

#pragma mark - LibraryOutlineViewDelegate

- (void)libraryView:(LibraryOutlineView *)view didRequestQueueNodes:(NSArray<LibraryTreeNode *> *)nodes {
    [self addNodesToQueue:nodes];
}

- (void)libraryView:(LibraryOutlineView *)view didRequestPlayNodes:(NSArray<LibraryTreeNode *> *)nodes {
    [self sendNodesToCurrentPlaylist:nodes];
}

- (void)libraryView:(LibraryOutlineView *)view didRequestSendToPlaylistNodes:(NSArray<LibraryTreeNode *> *)nodes {
    [self sendNodesToCurrentPlaylist:nodes];
}

- (void)libraryView:(LibraryOutlineView *)view didRequestSendToNewPlaylistNodes:(NSArray<LibraryTreeNode *> *)nodes {
    [self sendNodesToNewPlaylist:nodes];
}

- (void)libraryView:(LibraryOutlineView *)view requestContextMenuForNodes:(NSArray<LibraryTreeNode *> *)nodes atPoint:(NSPoint)point {
    [self showContextMenuForNodes:nodes atPoint:point];
}

#pragma mark - Actions

- (void)collectHandlesFromNodes:(NSArray<LibraryTreeNode *> *)nodes into:(metadb_handle_list &)outHandles {
    for (LibraryTreeNode *node in nodes) {
        NSArray<LibraryTreeNode *> *trackNodes = [node allTrackNodes];
        auto db = metadb::get();
        for (LibraryTreeNode *trackNode in trackNodes) {
            if (!trackNode.trackPath) continue;
            try {
                metadb_handle_ptr handle = db->handle_create(
                    [trackNode.trackPath UTF8String],
                    (t_uint32)trackNode.trackSubsong);
                if (handle.is_valid()) {
                    outHandles.add_item(handle);
                }
            } catch (...) {}
        }
    }
}

- (void)addNodesToQueue:(NSArray<LibraryTreeNode *> *)nodes {
    metadb_handle_list handles;
    [self collectHandlesFromNodes:nodes into:handles];
    if (handles.get_count() == 0) return;

    auto pm = playlist_manager::get();
    auto pc = playback_control::get();

    bool queueWasEmpty = (pm->queue_get_count() == 0);
    bool isStopped = !pc->is_playing() && !pc->is_paused();

    for (size_t i = 0; i < handles.get_count(); i++) {
        pm->queue_add_item(handles[i]);
    }

    if (queueWasEmpty && isStopped && handles.get_count() > 0) {
        pc->start(playback_control::track_command_play);
    }
}

- (void)sendNodesToCurrentPlaylist:(NSArray<LibraryTreeNode *> *)nodes {
    metadb_handle_list handles;
    [self collectHandlesFromNodes:nodes into:handles];
    if (handles.get_count() == 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) {
        activePlaylist = pm->create_playlist_autoname(0);
        pm->set_active_playlist(activePlaylist);
    }

    pm->playlist_undo_backup(activePlaylist);
    t_size base = pm->playlist_get_item_count(activePlaylist);
    pm->playlist_insert_items(activePlaylist, base, handles, pfc::bit_array_false());
}

- (void)sendNodesToNewPlaylist:(NSArray<LibraryTreeNode *> *)nodes {
    metadb_handle_list handles;
    [self collectHandlesFromNodes:nodes into:handles];
    if (handles.get_count() == 0) return;

    auto pm = playlist_manager::get();

    NSString *name = @"Library Selection";
    if (nodes.count == 1) {
        name = nodes.firstObject.displayName;
    }

    t_size newPlaylist = pm->create_playlist([name UTF8String], SIZE_MAX, SIZE_MAX);
    pm->set_active_playlist(newPlaylist);
    pm->playlist_insert_items(newPlaylist, 0, handles, pfc::bit_array_false());
}

#pragma mark - Context Menu

- (void)showContextMenuForNodes:(NSArray<LibraryTreeNode *> *)nodes atPoint:(NSPoint)point {
    metadb_handle_list allHandles;
    [self collectHandlesFromNodes:nodes into:allHandles];

    if (allHandles.get_count() == 0) return;

    @try {
        _contextMenuManager.release();
        _contextMenuManagerV1.release();
        _contextMenuHandles = allHandles;

        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        [menu setAutoenablesItems:NO];

        // Custom actions at the top
        NSMenuItem *sendToPlaylistItem = [[NSMenuItem alloc]
            initWithTitle:@"Send to Current Playlist"
                   action:@selector(contextSendToPlaylist:)
            keyEquivalent:@""];
        sendToPlaylistItem.target = self;
        [menu addItem:sendToPlaylistItem];

        NSMenuItem *addToPlaylistItem = [[NSMenuItem alloc]
            initWithTitle:@"Add to Current Playlist"
                   action:@selector(contextAddToPlaylist:)
            keyEquivalent:@""];
        addToPlaylistItem.target = self;
        [menu addItem:addToPlaylistItem];

        NSMenuItem *sendToNewPlaylistItem = [[NSMenuItem alloc]
            initWithTitle:@"Send to New Playlist"
                   action:@selector(contextSendToNewPlaylist:)
            keyEquivalent:@""];
        sendToNewPlaylistItem.target = self;
        [menu addItem:sendToNewPlaylistItem];

        [menu addItem:[NSMenuItem separatorItem]];

        NSMenuItem *addToQueueItem = [[NSMenuItem alloc]
            initWithTitle:@"Add to Playback Queue"
                   action:@selector(contextAddToQueue:)
            keyEquivalent:@"q"];
        addToQueueItem.target = self;
        [menu addItem:addToQueueItem];

        [menu addItem:[NSMenuItem separatorItem]];

        // foobar2000 SDK context menu
        auto cmm = contextmenu_manager_v2::tryGet();
        if (cmm.is_valid()) {
            _contextMenuManager = cmm;
            _contextMenuManager->init_context(allHandles, 0);
            menu_tree_item::ptr root = _contextMenuManager->build_menu();
            if (root.is_valid()) {
                [self buildNSMenu:menu fromMenuItem:root contextManager:_contextMenuManager];
            }
        } else {
            _contextMenuManagerV1 = contextmenu_manager::g_create();
            _contextMenuManagerV1->init_context(allHandles, 0);
            // v1 menu building (simplified)
        }

        NSPoint screenPoint = [_outlineView.window convertPointToScreen:
                               [_outlineView convertPoint:point toView:nil]];
        [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];

    } @catch (NSException *exception) {
        FB2K_console_formatter() << "[LibVanced] Context menu error: "
            << [[exception description] UTF8String];
    }
}

- (void)buildNSMenu:(NSMenu *)menu
      fromMenuItem:(menu_tree_item::ptr)item
    contextManager:(contextmenu_manager_v2::ptr)manager {
    if (!item.is_valid()) return;

    size_t count = item->childCount();
    for (size_t i = 0; i < count; i++) {
        menu_tree_item::ptr child = item->childAt(i);
        if (!child.is_valid()) continue;

        if (child->isSeparator()) {
            [menu addItem:[NSMenuItem separatorItem]];
        } else if (child->isCommand()) {
            const char *itemName = child->name();
            NSString *title = itemName ? [NSString stringWithUTF8String:itemName] : @"";

            NSMenuItem *menuItem = [[NSMenuItem alloc]
                initWithTitle:title
                       action:@selector(contextMenuItemClicked:)
                keyEquivalent:@""];
            menuItem.target = self;
            menuItem.tag = (NSInteger)child->commandID();
            menuItem.enabled = !(child->flags() & menu_flags::disabled);
            [menu addItem:menuItem];
        } else if (child->isSubmenu()) {
            const char *itemName = child->name();
            NSString *title = itemName ? [NSString stringWithUTF8String:itemName] : @"";

            NSMenuItem *submenuItem = [[NSMenuItem alloc]
                initWithTitle:title
                       action:nil
                keyEquivalent:@""];
            NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
            [self buildNSMenu:submenu fromMenuItem:child contextManager:manager];
            submenuItem.submenu = submenu;
            [menu addItem:submenuItem];
        }
    }
}

- (void)contextMenuItemClicked:(NSMenuItem *)sender {
    if (_contextMenuManager.is_valid()) {
        try {
            _contextMenuManager->execute_by_id((unsigned)sender.tag);
        } catch (...) {
            FB2K_console_formatter() << "[LibVanced] Context menu execution error";
        }
    }
}

- (void)contextSendToPlaylist:(id)sender {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) {
        activePlaylist = pm->create_playlist_autoname(0);
        pm->set_active_playlist(activePlaylist);
    }

    // Clear and replace
    pm->playlist_undo_backup(activePlaylist);
    pm->playlist_clear(activePlaylist);
    pm->playlist_insert_items(activePlaylist, 0, _contextMenuHandles, pfc::bit_array_false());
}

- (void)contextAddToPlaylist:(id)sender {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) {
        activePlaylist = pm->create_playlist_autoname(0);
        pm->set_active_playlist(activePlaylist);
    }

    pm->playlist_undo_backup(activePlaylist);
    t_size base = pm->playlist_get_item_count(activePlaylist);
    pm->playlist_insert_items(activePlaylist, base, _contextMenuHandles, pfc::bit_array_false());
}

- (void)contextSendToNewPlaylist:(id)sender {
    auto pm = playlist_manager::get();
    t_size newPlaylist = pm->create_playlist_autoname(0);
    pm->set_active_playlist(newPlaylist);
    pm->playlist_insert_items(newPlaylist, 0, _contextMenuHandles, pfc::bit_array_false());
}

- (void)contextAddToQueue:(id)sender {
    if (_contextMenuHandles.get_count() == 0) return;

    auto pm = playlist_manager::get();
    auto pc = playback_control::get();

    bool queueWasEmpty = (pm->queue_get_count() == 0);
    bool isStopped = !pc->is_playing() && !pc->is_paused();

    for (size_t i = 0; i < _contextMenuHandles.get_count(); i++) {
        pm->queue_add_item(_contextMenuHandles[i]);
    }

    if (queueWasEmpty && isStopped) {
        pc->start(playback_control::track_command_play);
    }
}

#pragma mark - LibraryDataSourceDelegate

- (void)libraryDataSourceDidBeginUpdate {
    _isLoading = YES;
    _statusLabel.stringValue = @"Loading library...";
}

- (void)libraryDataSourceDidUpdate {
    _isLoading = NO;

    // Save expanded node names before reloading
    NSMutableSet<NSString *> *expandedNames = [NSMutableSet set];
    for (NSInteger row = 0; row < _outlineView.numberOfRows; row++) {
        id item = [_outlineView itemAtRow:row];
        if ([_outlineView isItemExpanded:item]) {
            LibraryTreeNode *node = item;
            if (node.displayName) {
                [expandedNames addObject:node.displayName];
            }
        }
    }

    [_outlineView reloadData];

    // Restore expansion state by matching node names
    for (NSInteger row = 0; row < _outlineView.numberOfRows; row++) {
        id item = [_outlineView itemAtRow:row];
        LibraryTreeNode *node = item;
        if (node.displayName && [expandedNames containsObject:node.displayName]) {
            [_outlineView expandItem:item];
        }
    }

    NSInteger count = _dataSource.totalTrackCount;
    NSInteger groupCount = _dataSource.rootNode.children.count;

    if (_currentFilter) {
        _statusLabel.stringValue = [NSString stringWithFormat:
            @"%ld items in %ld groups (filtered)", (long)count, (long)groupCount];
    } else {
        _statusLabel.stringValue = [NSString stringWithFormat:
            @"%ld items in %ld groups", (long)count, (long)groupCount];
    }
}

#pragma mark - Library Event Handlers

- (void)handleLibraryItemsAdded {
    [self scheduleTreeRebuild];
}

- (void)handleLibraryItemsRemoved {
    [self scheduleTreeRebuild];
}

- (void)handleLibraryItemsModified {
    [self scheduleTreeRebuild];
}

- (void)scheduleTreeRebuild {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(doTreeRebuild)
                                               object:nil];
    [self performSelector:@selector(doTreeRebuild)
               withObject:nil
               afterDelay:0.5];
}

- (void)doTreeRebuild {
    if (_currentFilter) {
        [_dataSource rebuildTreeWithFilter:_currentFilter];
    } else {
        [_dataSource rebuildTree];
    }
}

#pragma mark - Playback Handlers

- (void)handlePlaybackNewTrack:(metadb_handle_ptr)track {
    // Could highlight the now-playing track in the tree
}

- (void)handlePlaybackStopped {
    // Could clear now-playing highlight
}

@end
