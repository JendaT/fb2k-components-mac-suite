//
//  SimPlaylistController.mm
//  foo_simplaylist_mac
//
//  View controller for SimPlaylist UI element
//

#import "SimPlaylistController.h"
#import "SimPlaylistView.h"
#import "SimPlaylistHeaderBar.h"
#import "../Core/GroupNode.h"
#import "../Core/GroupBoundary.h"
#import "../Core/ColumnDefinition.h"
#import "../Core/GroupPreset.h"
#import "../Core/TitleFormatHelper.h"
#import "../Core/ConfigHelper.h"
#import "../Core/AlbumArtCache.h"

#include <set>
#include <vector>

// Forward declare callback manager
@class SimPlaylistController;
void SimPlaylistCallbackManager_registerController(SimPlaylistController* controller);
void SimPlaylistCallbackManager_unregisterController(SimPlaylistController* controller);

@interface SimPlaylistController () <SimPlaylistViewDelegate, SimPlaylistHeaderBarDelegate> {
    // Context menu manager - must be stored for execute_by_id to work
    contextmenu_manager_v2::ptr _contextMenuManager;
    contextmenu_manager::ptr _contextMenuManagerV1;
}
@property (nonatomic, strong) SimPlaylistView *playlistView;
@property (nonatomic, strong) SimPlaylistHeaderBar *headerBar;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSArray<ColumnDefinition *> *columns;
@property (nonatomic, strong) NSArray<ColumnDefinition *> *availableColumnTemplates;  // Combined hardcoded + SDK columns
@property (nonatomic, strong) NSArray<GroupPreset *> *groupPresets;
@property (nonatomic, assign) NSInteger activePresetIndex;
@property (nonatomic, assign) NSInteger currentPlaylistIndex;
@property (nonatomic, assign) NSInteger playingPlaylistIndex;  // Track which playlist item is playing
@property (nonatomic, assign) BOOL needsRedraw;  // Coalesced redraw flag
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *scrollPositions;  // Scroll position per playlist
@end

@implementation SimPlaylistController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _columns = [ColumnDefinition defaultColumns];
        _groupPresets = [GroupPreset defaultPresets];
        _activePresetIndex = 0;
        _currentPlaylistIndex = -1;
        _playingPlaylistIndex = -1;
        _scrollPositions = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)loadView {
    // Create container view
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = container;

    CGFloat headerHeight = 22;
    CGFloat containerHeight = 300;

    // Create header bar at TOP (in non-flipped view, y increases upward)
    _headerBar = [[SimPlaylistHeaderBar alloc] initWithFrame:NSMakeRect(0, containerHeight - headerHeight, 400, headerHeight)];
    _headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _headerBar.delegate = self;
    _headerBar.columns = _columns;
    _headerBar.groupColumnWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    [container addSubview:_headerBar];

    // Create scroll view BELOW header (from y=0 to y=containerHeight-headerHeight)
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, containerHeight - headerHeight)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.drawsBackground = YES;
    _scrollView.backgroundColor = [NSColor controlBackgroundColor];
    // Enable smooth scrolling optimizations
    _scrollView.wantsLayer = YES;

    // Create playlist view
    _playlistView = [[SimPlaylistView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    _playlistView.delegate = self;
    _playlistView.columns = _columns;
    _playlistView.groupColumnWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    _playlistView.albumArtSize = simplaylist_config::getConfigInt(
        simplaylist_config::kAlbumArtSize,
        simplaylist_config::kDefaultAlbumArtSize);
    _playlistView.wantsLayer = YES;  // Layer backing for smooth drawing

    // Configure scroll view
    _scrollView.documentView = _playlistView;
    [container addSubview:_scrollView];

    // Observe scroll changes to sync header
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrollViewDidScroll:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_scrollView.contentView];
    _scrollView.contentView.postsBoundsChangedNotifications = YES;

    // Observe frame changes for auto-resize columns
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrollViewFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_scrollView];
    _scrollView.postsFrameChangedNotifications = YES;

    // Observe settings changes from preferences
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:@"SimPlaylistSettingsChanged"
                                               object:nil];

    // Register for callbacks
    SimPlaylistCallbackManager_registerController(self);

    // Initial data load
    [self rebuildFromPlaylist];

    // Auto-resize columns to fit view
    [self autoResizeColumns];
}

- (void)scrollViewDidScroll:(NSNotification *)notification {
    // Sync header bar horizontal scroll with content
    NSClipView *clipView = _scrollView.contentView;
    [_headerBar setScrollOffset:clipView.bounds.origin.x];
}

- (void)scrollViewFrameDidChange:(NSNotification *)notification {
    [self autoResizeColumns];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    // Reload group presets from config
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kGroupPresets, "");
    if (!savedJSON.empty()) {
        NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
        _groupPresets = [GroupPreset presetsFromJSON:jsonString];
        _activePresetIndex = [GroupPreset activeIndexFromJSON:jsonString];
    } else {
        _groupPresets = [GroupPreset defaultPresets];
        _activePresetIndex = 0;
    }

    // Reload group column width
    CGFloat newWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    _playlistView.groupColumnWidth = newWidth;
    _headerBar.groupColumnWidth = newWidth;

    // Reload album art size
    CGFloat newArtSize = simplaylist_config::getConfigInt(
        simplaylist_config::kAlbumArtSize,
        simplaylist_config::kDefaultAlbumArtSize);
    _playlistView.albumArtSize = newArtSize;

    // Rebuild with new settings (recalculates group padding based on new album art size)
    [self rebuildFromPlaylist];
    [_headerBar setNeedsDisplay:YES];
}

- (void)autoResizeColumns {
    CGFloat availableWidth = _scrollView.bounds.size.width - _playlistView.groupColumnWidth;

    // Calculate fixed width (non-auto-resize columns)
    CGFloat fixedWidth = 0;
    NSMutableArray<ColumnDefinition *> *autoResizeCols = [NSMutableArray array];

    for (ColumnDefinition *col in _columns) {
        if (col.autoResize) {
            [autoResizeCols addObject:col];
        } else {
            fixedWidth += col.width;
        }
    }

    if (autoResizeCols.count == 0) return;

    // Distribute remaining space
    CGFloat remainingWidth = availableWidth - fixedWidth;
    if (remainingWidth < 0) return;

    CGFloat widthPerCol = remainingWidth / autoResizeCols.count;
    widthPerCol = MAX(widthPerCol, 50);  // Minimum 50px

    BOOL changed = NO;
    for (ColumnDefinition *col in autoResizeCols) {
        if (fabs(col.width - widthPerCol) > 1.0) {
            col.width = widthPerCol;
            changed = YES;
        }
    }

    if (changed) {
        [_playlistView reloadData];
        [_headerBar setNeedsDisplay:YES];
    }
}

- (void)dealloc {
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Unregister from callbacks
    SimPlaylistCallbackManager_unregisterController(self);
}

#pragma mark - Playlist Data Loading (SPARSE MODEL)

- (void)rebuildFromPlaylist {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    // Detect if we're switching to a different playlist (vs. refreshing the same one)
    BOOL isFirstLoad = (_currentPlaylistIndex < 0);
    BOOL isSwitchingPlaylist = (activePlaylist != SIZE_MAX &&
                                 (isFirstLoad || (NSInteger)activePlaylist != _currentPlaylistIndex));

    // Save scroll position of current playlist BEFORE switching to a different one
    if (!isFirstLoad && isSwitchingPlaylist && _scrollView) {
        NSPoint scrollPoint = _scrollView.contentView.bounds.origin;
        _scrollPositions[@(_currentPlaylistIndex)] = [NSValue valueWithPoint:scrollPoint];
    }

    // Clear cached data on any playlist change
    [_playlistView clearFormattedValuesCache];

    if (activePlaylist == SIZE_MAX) {
        _playlistView.itemCount = 0;
        _playlistView.groupStarts = @[];
        _playlistView.groupHeaders = @[];
        _playlistView.groupArtKeys = @[];
        _currentPlaylistIndex = -1;
        [_playlistView reloadData];
        return;
    }

    _currentPlaylistIndex = activePlaylist;
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);

    if (itemCount == 0) {
        _playlistView.itemCount = 0;
        _playlistView.groupStarts = @[];
        _playlistView.groupHeaders = @[];
        _playlistView.groupArtKeys = @[];
        [_playlistView reloadData];
        return;
    }

    // Check if grouping is enabled
    GroupPreset *activePreset = nil;
    if (_activePresetIndex >= 0 && _activePresetIndex < (NSInteger)_groupPresets.count) {
        activePreset = _groupPresets[_activePresetIndex];
    }

    BOOL useGrouping = (activePreset && activePreset.headerPattern.length > 0);

    if (useGrouping) {
        // EFFICIENT: Detect groups using batch handle retrieval
        [self detectGroupsForPlaylist:activePlaylist itemCount:itemCount preset:activePreset];
    } else {
        // No grouping - just set item count
        _playlistView.itemCount = itemCount;
        _playlistView.groupStarts = @[];
        _playlistView.groupHeaders = @[];
        _playlistView.groupArtKeys = @[];
        _playlistView.groupPaddingRows = @[];
    }

    // Set frame size
    CGFloat totalHeight = [_playlistView totalContentHeightCached];
    [_playlistView setFrameSize:NSMakeSize(_playlistView.frame.size.width, totalHeight)];

    // Sync selection
    [self syncSelectionFromPlaylist];

    // Set focus
    t_size focusItem = pm->playlist_get_focus_item(activePlaylist);
    _playlistView.focusIndex = (focusItem != SIZE_MAX) ? (NSInteger)focusItem : -1;

    // Update playing indicator
    [self updatePlayingIndicator];

    // Display
    [_playlistView reloadData];

    // Restore scroll position only when SWITCHING to a different playlist
    if (isSwitchingPlaylist) {
        NSValue *savedScrollValue = _scrollPositions[@(activePlaylist)];
        if (savedScrollValue) {
            NSPoint savedPoint = [savedScrollValue pointValue];
            // Clamp to valid range (in case playlist content changed)
            CGFloat maxY = MAX(0, _playlistView.frame.size.height - _scrollView.contentView.bounds.size.height);
            savedPoint.y = MAX(0, MIN(savedPoint.y, maxY));
            [_scrollView.contentView scrollToPoint:savedPoint];
            [_scrollView reflectScrolledClipView:_scrollView.contentView];
        } else if (_playlistView.focusIndex >= 0) {
            // No saved position - scroll to focus item (first time viewing this playlist)
            NSInteger focusRow = [_playlistView rowForPlaylistIndex:_playlistView.focusIndex];
            if (focusRow >= 0) {
                [_playlistView scrollRowToVisible:focusRow];
            }
        }
    }
    // When NOT switching (just refreshing same playlist), keep current scroll position
}

// Generation counter to cancel stale group detection
static NSInteger _groupDetectionGeneration = 0;

// PROGRESSIVE GROUP DETECTION: Shows UI immediately, detects groups without freezing
- (void)detectGroupsForPlaylist:(t_size)playlist itemCount:(t_size)itemCount preset:(GroupPreset *)preset {
    // Increment generation to cancel any in-progress detection
    NSInteger currentGeneration = ++_groupDetectionGeneration;

    // IMMEDIATE: Set item count and show flat list right away
    _playlistView.itemCount = itemCount;
    _playlistView.groupStarts = @[];
    _playlistView.groupHeaders = @[];
    _playlistView.groupArtKeys = @[];
    _playlistView.groupPaddingRows = @[];

    // Set frame size and display immediately
    CGFloat totalHeight = [_playlistView totalContentHeightCached];
    [_playlistView setFrameSize:NSMakeSize(_playlistView.frame.size.width, totalHeight)];
    [_playlistView setNeedsDisplay:YES];

    // Get all handles NOW (on main thread, this is fast as it's just pointer copies)
    auto pm = playlist_manager::get();
    metadb_handle_list handles;
    pm->playlist_get_all_items(playlist, handles);

    // Copy handles to a shared_ptr for thread safety
    auto handlesPtr = std::make_shared<metadb_handle_list>(std::move(handles));
    NSString *headerPattern = preset.headerPattern;

    // PROGRESSIVE: Detect groups in background without blocking UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (_groupDetectionGeneration != currentGeneration) return;

        // Compile header pattern
        titleformat_object::ptr headerScript;
        static_api_ptr_t<titleformat_compiler>()->compile_safe_ex(
            headerScript,
            [headerPattern UTF8String],
            nullptr
        );

        // Build group data
        NSMutableArray<NSNumber *> *groupStarts = [NSMutableArray array];
        NSMutableArray<NSString *> *groupHeaders = [NSMutableArray array];
        NSMutableArray<NSString *> *groupArtKeys = [NSMutableArray array];

        pfc::string8 currentHeader;
        pfc::string8 formattedHeader;

        for (t_size i = 0; i < handlesPtr->get_count(); i++) {
            if (_groupDetectionGeneration != currentGeneration) return;

            // format_title with metadb_handle is thread-safe for reading
            (*handlesPtr)[i]->format_title(nullptr, formattedHeader, headerScript, nullptr);

            if (i == 0 || strcmp(formattedHeader.c_str(), currentHeader.c_str()) != 0) {
                [groupStarts addObject:@(i)];
                [groupHeaders addObject:[NSString stringWithUTF8String:formattedHeader.c_str()]];
                [groupArtKeys addObject:[NSString stringWithUTF8String:(*handlesPtr)[i]->get_path()]];
                currentHeader = formattedHeader;
            }
        }

        if (_groupDetectionGeneration != currentGeneration) return;

        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_groupDetectionGeneration != currentGeneration) return;

            _playlistView.groupStarts = groupStarts;
            _playlistView.groupHeaders = groupHeaders;
            _playlistView.groupArtKeys = groupArtKeys;

            // Calculate padding rows for each group based on minimum height for album art
            CGFloat rowHeight = _playlistView.rowHeight;
            CGFloat albumArtSize = _playlistView.albumArtSize;
            CGFloat padding = 6.0;  // Same as in drawSparseGroupColumnInRect

            // Minimum rows needed below header to fit album art with padding
            NSInteger minContentRows = (NSInteger)ceil((albumArtSize + padding * 2) / rowHeight);

            NSMutableArray<NSNumber *> *paddingRows = [NSMutableArray arrayWithCapacity:groupStarts.count];
            NSInteger totalItems = _playlistView.itemCount;

            for (NSUInteger g = 0; g < groupStarts.count; g++) {
                NSInteger groupStart = [groupStarts[g] integerValue];
                NSInteger groupEnd = (g + 1 < groupStarts.count) ? [groupStarts[g + 1] integerValue] : totalItems;
                NSInteger trackCount = groupEnd - groupStart;

                // Padding = max(0, minContentRows - trackCount)
                NSInteger neededPadding = MAX(0, minContentRows - trackCount);
                [paddingRows addObject:@(neededPadding)];
            }

            _playlistView.groupPaddingRows = paddingRows;

            // Recalculate height with group headers and padding
            CGFloat newHeight = [_playlistView totalContentHeightCached];
            [_playlistView setFrameSize:NSMakeSize(_playlistView.frame.size.width, newHeight)];
            [_playlistView setNeedsDisplay:YES];
        });
    });
}

- (void)syncSelectionFromPlaylist {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) return;

    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    [_playlistView.selectedIndices removeAllIndexes];

    // Use batch selection query - ONE SDK call instead of N
    pfc::bit_array_bittable selectionMask(itemCount);
    pm->playlist_get_selection_mask(activePlaylist, selectionMask);

    // Efficiently iterate only set bits
    for (t_size i = selectionMask.find_first(true, 0, itemCount);
         i < itemCount;
         i = selectionMask.find_first(true, i + 1, itemCount)) {
        [_playlistView.selectedIndices addIndex:i];
    }
}

- (void)updatePlayingIndicator {
    auto pm = playlist_manager::get();
    t_size playingPlaylist, playingItem;

    _playlistView.playingIndex = -1;
    if (pm->get_playing_item_location(&playingPlaylist, &playingItem)) {
        if (playingPlaylist == (t_size)_currentPlaylistIndex) {
            // In both flat and sparse group mode, we can use playlist index directly
            // The view will handle the row mapping
            _playlistView.playingIndex = (NSInteger)playingItem;
        }
    }
}

#pragma mark - Playlist Event Handlers

- (void)handlePlaylistSwitched {
    [self rebuildFromPlaylist];
}

- (void)handleItemsAdded:(NSInteger)base count:(NSInteger)count {
    // For Phase 1, just rebuild everything
    // Later phases can do incremental updates
    [self rebuildFromPlaylist];
}

- (void)handleItemsRemoved {
    [self rebuildFromPlaylist];
}

- (void)handleItemsReordered {
    [self rebuildFromPlaylist];
}

- (void)handleSelectionChanged {
    // Sync selection from playlist_manager
    [self syncSelectionFromPlaylist];
    [_playlistView setNeedsDisplay:YES];
}

- (void)handleFocusChanged:(NSInteger)fromPlaylistIndex to:(NSInteger)toPlaylistIndex {
    // In flat mode, focus index = playlist index
    _playlistView.focusIndex = toPlaylistIndex;
    [_playlistView setNeedsDisplay:YES];
}

- (void)handleItemsModified {
    // Metadata changed - rebuild to update formatted values
    [self rebuildFromPlaylist];
}

#pragma mark - Playback Event Handlers

- (void)handlePlaybackNewTrack:(metadb_handle_ptr)track {
    [self updatePlayingIndicator];
}

- (void)handlePlaybackStopped {
    _playlistView.playingIndex = -1;
}

#pragma mark - SimPlaylistViewDelegate

- (void)playlistView:(SimPlaylistView *)view selectionDidChange:(NSIndexSet *)selectedPlaylistIndices {
    // Sync selection back to playlist_manager
    // selectedPlaylistIndices are now PLAYLIST indices (not row indices)
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) return;

    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    if (itemCount == 0) return;

    // Build state bit array - O(selection count)
    bit_array_bittable state(itemCount);

    // Collect indices to array first (can't mutate C++ objects in blocks)
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    [selectedPlaylistIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < itemCount) {
            [indices addObject:@(idx)];
        }
    }];

    // Now set the bits
    for (NSNumber *num in indices) {
        state.set((t_size)[num integerValue], true);
    }

    // Use bit_array_true() for affected - all items affected without iteration
    pm->playlist_set_selection(activePlaylist, bit_array_true(), state);
}

- (void)playlistView:(SimPlaylistView *)view didDoubleClickRow:(NSInteger)row {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) return;

    // Get playlist index using the view's row mapping
    NSInteger playlistIndex = [view playlistIndexForRow:row];
    if (playlistIndex < 0) return;  // Header row or invalid

    pm->playlist_execute_default_action(activePlaylist, playlistIndex);
}

- (void)playlistView:(SimPlaylistView *)view requestContextMenuForRows:(NSIndexSet *)playlistIndices atPoint:(NSPoint)point {
    if (_currentPlaylistIndex < 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);

    // Collect indices to array first (can't modify C++ objects in blocks)
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    [playlistIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < itemCount) {
            [indices addObject:@(idx)];
        }
    }];

    // Now collect handles
    metadb_handle_list handles;
    for (NSNumber *num in indices) {
        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, activePlaylist, (t_size)[num integerValue])) {
            handles.add_item(handle);
        }
    }

    if (handles.get_count() == 0) return;

    // Build context menu
    [self showContextMenuForHandles:handles atPoint:point inView:view];
}

- (void)showContextMenuForHandles:(metadb_handle_list_cref)handles atPoint:(NSPoint)point inView:(NSView *)view {
    @try {
        // Clear previous managers
        _contextMenuManager.release();
        _contextMenuManagerV1.release();

        // Create context menu manager
        auto cmm = contextmenu_manager_v2::tryGet();
        if (!cmm.is_valid()) {
            // Fall back to v1
            _contextMenuManagerV1 = contextmenu_manager::g_create();
            _contextMenuManagerV1->init_context(handles, 0);
            [self showContextMenuWithManagerV1:_contextMenuManagerV1 atPoint:point inView:view];
            return;
        }

        // Store for use in click handler
        _contextMenuManager = cmm;
        _contextMenuManager->init_context(handles, 0);
        menu_tree_item::ptr root = _contextMenuManager->build_menu();

        if (!root.is_valid()) return;

        // Build NSMenu from menu_tree_item
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        [menu setAutoenablesItems:NO];

        [self buildNSMenu:menu fromMenuItem:root contextManager:_contextMenuManager];

        // Show menu
        NSPoint screenPoint = [view.window convertPointToScreen:[view convertPoint:point toView:nil]];
        [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];

    } @catch (NSException *exception) {
        // Ignore Objective-C exceptions
    }
}

- (void)showContextMenuWithManagerV1:(contextmenu_manager::ptr)cmm atPoint:(NSPoint)point inView:(NSView *)view {
    contextmenu_node *root = cmm->get_root();
    if (!root) return;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu setAutoenablesItems:NO];

    [self buildNSMenuFromNode:menu parentNode:root contextManager:cmm baseID:0];

    NSPoint screenPoint = [view.window convertPointToScreen:[view convertPoint:point toView:nil]];
    [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];
}

- (void)buildNSMenu:(NSMenu *)menu fromMenuItem:(menu_tree_item::ptr)item contextManager:(contextmenu_manager_v2::ptr)cmm {
    for (size_t i = 0; i < item->childCount(); i++) {
        menu_tree_item::ptr child = item->childAt(i);

        switch (child->type()) {
            case menu_tree_item::itemSeparator: {
                [menu addItem:[NSMenuItem separatorItem]];
                break;
            }

            case menu_tree_item::itemCommand: {
                NSString *title = [NSString stringWithUTF8String:child->name()];
                NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                  action:@selector(contextMenuItemClicked:)
                                                           keyEquivalent:@""];
                menuItem.target = self;
                menuItem.tag = child->commandID();
                menuItem.representedObject = (__bridge id)cmm.get_ptr();  // Store reference

                menu_flags_t flags = child->flags();
                menuItem.enabled = !(flags & menu_flags::disabled);
                menuItem.state = (flags & menu_flags::checked) ? NSControlStateValueOn : NSControlStateValueOff;

                [menu addItem:menuItem];
                break;
            }

            case menu_tree_item::itemSubmenu: {
                NSString *title = [NSString stringWithUTF8String:child->name()];
                NSMenuItem *submenuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                     action:nil
                                                              keyEquivalent:@""];

                NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
                [submenu setAutoenablesItems:NO];
                [self buildNSMenu:submenu fromMenuItem:child contextManager:cmm];

                submenuItem.submenu = submenu;
                [menu addItem:submenuItem];
                break;
            }
        }
    }
}

- (void)buildNSMenuFromNode:(NSMenu *)menu parentNode:(contextmenu_node *)parent contextManager:(contextmenu_manager::ptr)cmm baseID:(int)baseID {
    for (t_size i = 0; i < parent->get_num_children(); i++) {
        contextmenu_node *child = parent->get_child(i);

        switch (child->get_type()) {
            case contextmenu_item_node::TYPE_SEPARATOR: {
                [menu addItem:[NSMenuItem separatorItem]];
                break;
            }

            case contextmenu_item_node::TYPE_COMMAND: {
                NSString *title = [NSString stringWithUTF8String:child->get_name()];
                NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                  action:@selector(contextMenuItemClickedV1:)
                                                           keyEquivalent:@""];
                menuItem.target = self;
                menuItem.tag = child->get_id();

                unsigned flags = child->get_display_flags();
                menuItem.enabled = !(flags & contextmenu_item_node::FLAG_DISABLED);
                menuItem.state = (flags & contextmenu_item_node::FLAG_CHECKED) ? NSControlStateValueOn : NSControlStateValueOff;

                [menu addItem:menuItem];
                break;
            }

            case contextmenu_item_node::TYPE_POPUP: {
                NSString *title = [NSString stringWithUTF8String:child->get_name()];
                NSMenuItem *submenuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                     action:nil
                                                              keyEquivalent:@""];

                NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
                [submenu setAutoenablesItems:NO];
                [self buildNSMenuFromNode:submenu parentNode:child contextManager:cmm baseID:baseID];

                submenuItem.submenu = submenu;
                [menu addItem:submenuItem];
                break;
            }

            default:
                break;
        }
    }
}

- (void)contextMenuItemClicked:(NSMenuItem *)sender {
    // Execute using the stored contextmenu_manager_v2
    // The command ID is stored in the tag
    unsigned commandID = (unsigned)sender.tag;

    @try {
        if (_contextMenuManager.is_valid()) {
            _contextMenuManager->execute_by_id(commandID);
        }
    } @catch (NSException *exception) {
        // Ignore
    }
}

- (void)contextMenuItemClickedV1:(NSMenuItem *)sender {
    // Execute using the stored contextmenu_manager (v1)
    unsigned commandID = (unsigned)sender.tag;

    @try {
        if (_contextMenuManagerV1.is_valid()) {
            _contextMenuManagerV1->execute_by_id(commandID);
        }
    } @catch (NSException *exception) {
        // Ignore
    }
}

- (void)playlistViewDidRequestRemoveSelection:(SimPlaylistView *)view {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) return;

    // Check if playlist is locked
    if (pm->playlist_lock_is_present(activePlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(activePlaylist);
        if (lockMask & playlist_lock::filter_remove) {
            console::info("[SimPlaylist] Cannot remove items - playlist is locked");
            return;
        }
    }

    // Create undo point
    pm->playlist_undo_backup(activePlaylist);

    // Build removal mask - convert row indices to playlist indices
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    bit_array_bittable mask(itemCount);

    // Collect playlist indices from selected rows
    NSMutableArray<NSNumber *> *playlistIndices = [NSMutableArray array];
    [view.selectedIndices enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        if (row < view.nodes.count) {
            GroupNode *node = view.nodes[row];
            if (node.type == GroupNodeTypeTrack && node.playlistIndex >= 0) {
                [playlistIndices addObject:@(node.playlistIndex)];
            }
        }
    }];

    for (NSNumber *num in playlistIndices) {
        t_size idx = [num unsignedLongValue];
        if (idx < itemCount) {
            mask.set(idx, true);
        }
    }

    // Remove items
    pm->playlist_remove_items(activePlaylist, mask);
}

#pragma mark - Album Art

// Check if path is a remote URL that could block
static BOOL isRemotePath(const char *path) {
    if (!path) return NO;
    return (strncmp(path, "http://", 7) == 0 ||
            strncmp(path, "https://", 8) == 0 ||
            strncmp(path, "ftp://", 6) == 0 ||
            strncmp(path, "cdda://", 7) == 0 ||
            strncmp(path, "mms://", 6) == 0 ||
            strncmp(path, "rtsp://", 7) == 0);
}

- (NSImage *)playlistView:(SimPlaylistView *)view albumArtForGroupAtPlaylistIndex:(NSInteger)playlistIndex {
    if (playlistIndex < 0 || _currentPlaylistIndex < 0) return nil;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;

    metadb_handle_ptr handle;
    if (!pm->playlist_get_item_handle(handle, activePlaylist, (t_size)playlistIndex)) {
        return nil;
    }

    const char *path = handle->get_path();

    // Skip album art loading for remote files - they block the main thread
    if (isRemotePath(path)) {
        return nil;  // Just show placeholder for remote files
    }

    NSString *cacheKey = [NSString stringWithFormat:@"%s", path];
    AlbumArtCache *cache = [AlbumArtCache sharedCache];
    NSImage *cached = [cache cachedImageForKey:cacheKey];
    if (cached) {
        return cached;
    }

    // If not loading yet and not already known to have no image, start async load
    if (![cache isLoadingKey:cacheKey] && ![cache hasNoImageForKey:cacheKey]) {
        __weak SimPlaylistController *weakSelf = self;
        [cache loadImageForKey:cacheKey handle:handle completion:^(NSImage *image) {
            // Only trigger redraw if we actually got an image
            if (image) {
                // Coalesce redraws - only schedule one per run loop
                SimPlaylistController *strongSelf = weakSelf;
                if (strongSelf && !strongSelf.needsRedraw) {
                    strongSelf.needsRedraw = YES;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SimPlaylistController *s = weakSelf;
                        if (s) {
                            s.needsRedraw = NO;
                            [s.playlistView setNeedsDisplay:YES];
                        }
                    });
                }
            }
        }];
    }

    return nil;  // Return nil for now, will redraw when loaded
}

- (void)playlistView:(SimPlaylistView *)view didChangeGroupColumnWidth:(CGFloat)newWidth {
    // Persist the new width to config
    simplaylist_config::setConfigInt(simplaylist_config::kGroupColumnWidth, (int64_t)newWidth);

    // Update header bar
    _headerBar.groupColumnWidth = newWidth;
    [_headerBar setNeedsDisplay:YES];
}

- (NSArray<NSString *> *)playlistView:(SimPlaylistView *)view columnValuesForPlaylistIndex:(NSInteger)playlistIndex {
    // Lazy load column values for a track - only called when drawing visible rows
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) return nil;

    metadb_handle_ptr handle;
    if (!pm->playlist_get_item_handle(handle, activePlaylist, playlistIndex)) {
        return nil;
    }

    // Format column values
    NSMutableArray<NSString *> *columnValues = [NSMutableArray array];
    for (ColumnDefinition *col in _columns) {
        auto script = simplaylist::TitleFormatHelper::compileWithCache(
            std::string([col.pattern UTF8String])
        );
        std::string value = simplaylist::TitleFormatHelper::format(handle, script);
        [columnValues addObject:[NSString stringWithUTF8String:value.c_str()]];
    }

    return columnValues;
}

#pragma mark - SimPlaylistHeaderBarDelegate

- (void)headerBar:(SimPlaylistHeaderBar *)bar didResizeColumn:(NSInteger)columnIndex toWidth:(CGFloat)newWidth {
    if (columnIndex < 0 || columnIndex >= (NSInteger)_columns.count) return;

    // Update column definition
    ColumnDefinition *col = _columns[columnIndex];
    col.width = newWidth;

    // Update playlist view
    [_playlistView reloadData];
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didFinishResizingColumn:(NSInteger)columnIndex {
    // Persist column widths
    NSString *columnsJSON = [ColumnDefinition columnsToJSON:_columns];
    if (columnsJSON) {
        simplaylist_config::setConfigString(simplaylist_config::kColumns, columnsJSON.UTF8String);
    }
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didReorderColumnFrom:(NSInteger)fromIndex to:(NSInteger)toIndex {
    if (fromIndex < 0 || fromIndex >= (NSInteger)_columns.count) return;
    if (toIndex < 0 || toIndex > (NSInteger)_columns.count) return;

    // Reorder columns array
    NSMutableArray *mutableColumns = [_columns mutableCopy];
    ColumnDefinition *movedCol = mutableColumns[fromIndex];
    [mutableColumns removeObjectAtIndex:fromIndex];

    NSInteger insertIndex = toIndex;
    if (toIndex > fromIndex) {
        insertIndex--;
    }
    insertIndex = MAX(0, MIN((NSInteger)mutableColumns.count, insertIndex));

    [mutableColumns insertObject:movedCol atIndex:insertIndex];
    _columns = [mutableColumns copy];

    // Update both views
    _headerBar.columns = _columns;
    _playlistView.columns = _columns;
    [_headerBar setNeedsDisplay:YES];
    [_playlistView clearFormattedValuesCache];  // Clear cache - values are in old column order
    [_playlistView setNeedsDisplay:YES];

    // Persist column order
    NSString *columnsJSON = [ColumnDefinition columnsToJSON:_columns];
    if (columnsJSON) {
        simplaylist_config::setConfigString(simplaylist_config::kColumns, columnsJSON.UTF8String);
    }
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didClickColumn:(NSInteger)columnIndex {
    // Could implement sorting here in the future
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didResizeGroupColumnToWidth:(CGFloat)newWidth {
    _playlistView.groupColumnWidth = newWidth;
    [_playlistView setNeedsDisplay:YES];
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didFinishResizingGroupColumn:(CGFloat)finalWidth {
    // Persist the width
    simplaylist_config::setConfigInt(simplaylist_config::kGroupColumnWidth, (int64_t)finalWidth);
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar showColumnMenuAtPoint:(NSPoint)screenPoint {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Columns"];

    // Get available column templates (hardcoded)
    NSArray<ColumnDefinition *> *templates = [ColumnDefinition availableColumnTemplates];

    // Get columns from SDK providers (dynamic - from other components)
    NSArray<ColumnDefinition *> *sdkColumns = [ColumnDefinition columnsFromSDKProviders];

    // Combine all columns for lookup by index
    NSMutableArray<ColumnDefinition *> *allColumns = [NSMutableArray arrayWithArray:templates];
    [allColumns addObjectsFromArray:sdkColumns];
    _availableColumnTemplates = allColumns;  // Store for use in columnMenuItemClicked:

    // Build set of currently visible column names for quick lookup
    NSMutableSet<NSString *> *visibleColumnNames = [NSMutableSet set];
    for (ColumnDefinition *col in _columns) {
        [visibleColumnNames addObject:col.name];
    }

    // Also track names we've already added to avoid duplicates with SDK columns
    NSMutableSet<NSString *> *addedNames = [NSMutableSet set];

    // Standard columns (first 19 items - includes BPM, Key, Sample Rate)
    NSInteger standardColumnCount = 19;
    for (NSInteger i = 0; i < MIN(standardColumnCount, (NSInteger)templates.count); i++) {
        ColumnDefinition *colTemplate = templates[i];
        [addedNames addObject:colTemplate.name];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:colTemplate.name
                                                      action:@selector(columnMenuItemClicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = i;
        item.state = [visibleColumnNames containsObject:colTemplate.name] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }

    // Separator before playback statistics
    if (templates.count > standardColumnCount) {
        [menu addItem:[NSMenuItem separatorItem]];

        // Playback statistics columns
        for (NSInteger i = standardColumnCount; i < (NSInteger)templates.count; i++) {
            ColumnDefinition *colTemplate = templates[i];
            [addedNames addObject:colTemplate.name];
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:colTemplate.name
                                                          action:@selector(columnMenuItemClicked:)
                                                   keyEquivalent:@""];
            item.target = self;
            item.tag = i;
            item.state = [visibleColumnNames containsObject:colTemplate.name] ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:item];
        }
    }

    // SDK columns (from playlistColumnProvider services - dynamic)
    if (sdkColumns.count > 0) {
        [menu addItem:[NSMenuItem separatorItem]];

        // Add a title item
        NSMenuItem *sdkTitle = [[NSMenuItem alloc] initWithTitle:@"From Components:" action:nil keyEquivalent:@""];
        sdkTitle.enabled = NO;
        [menu addItem:sdkTitle];

        NSInteger templateCount = templates.count;
        for (NSInteger i = 0; i < (NSInteger)sdkColumns.count; i++) {
            ColumnDefinition *colTemplate = sdkColumns[i];

            // Skip if already added from hardcoded templates
            if ([addedNames containsObject:colTemplate.name]) continue;
            [addedNames addObject:colTemplate.name];

            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:colTemplate.name
                                                          action:@selector(columnMenuItemClicked:)
                                                   keyEquivalent:@""];
            item.target = self;
            item.tag = templateCount + i;  // Offset by template count
            item.state = [visibleColumnNames containsObject:colTemplate.name] ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:item];
        }
    }

    // "More..." item for custom columns
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *moreItem = [[NSMenuItem alloc] initWithTitle:@"More..."
                                                      action:@selector(showColumnConfiguration:)
                                               keyEquivalent:@""];
    moreItem.target = self;
    [menu addItem:moreItem];

    [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];
}

- (void)columnMenuItemClicked:(NSMenuItem *)sender {
    // Use the combined templates array stored during menu creation
    NSArray<ColumnDefinition *> *templates = _availableColumnTemplates;
    if (!templates) {
        templates = [ColumnDefinition availableColumnTemplates];
    }
    NSInteger templateIndex = sender.tag;

    if (templateIndex < 0 || templateIndex >= (NSInteger)templates.count) return;

    ColumnDefinition *colTemplate = templates[templateIndex];

    // Check if column is currently visible
    NSInteger existingIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)_columns.count; i++) {
        if ([_columns[i].name isEqualToString:colTemplate.name]) {
            existingIndex = i;
            break;
        }
    }

    NSMutableArray<ColumnDefinition *> *newColumns = [_columns mutableCopy];

    if (existingIndex >= 0) {
        // Remove the column
        [newColumns removeObjectAtIndex:existingIndex];
    } else {
        // Add the column (at end)
        [newColumns addObject:[colTemplate copy]];
    }

    _columns = newColumns;

    // Update UI
    _headerBar.columns = _columns;
    _playlistView.columns = _columns;
    [_headerBar setNeedsDisplay:YES];
    [_playlistView clearFormattedValuesCache];
    [_playlistView setNeedsDisplay:YES];

    // Save to config
    NSString *json = [ColumnDefinition columnsToJSON:_columns];
    simplaylist_config::setConfigString(simplaylist_config::kColumns, [json UTF8String]);
}

- (void)showColumnConfiguration:(id)sender {
    // Future: show full column configuration dialog
    // For now just do nothing - placeholder for "More..." menu item
}

#pragma mark - Drag & Drop

- (void)playlistView:(SimPlaylistView *)view didReorderRows:(NSIndexSet *)sourceRowIndices toRow:(NSInteger)destinationRow {
    if (_currentPlaylistIndex < 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;

    // Check if playlist is locked
    if (pm->playlist_lock_is_present(activePlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(activePlaylist);
        if (lockMask & playlist_lock::filter_reorder) {
            return;
        }
    }

    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    if (itemCount == 0) return;

    // Convert row indices to playlist indices
    NSMutableArray<NSNumber *> *sourcePlaylistIndices = [NSMutableArray array];
    [sourceRowIndices enumerateIndexesUsingBlock:^(NSUInteger rowIdx, BOOL *stop) {
        if (rowIdx < view.nodes.count) {
            GroupNode *node = view.nodes[rowIdx];
            if (node.type == GroupNodeTypeTrack && node.playlistIndex >= 0) {
                [sourcePlaylistIndices addObject:@(node.playlistIndex)];
            }
        }
    }];

    if (sourcePlaylistIndices.count == 0) return;

    // Sort source indices
    [sourcePlaylistIndices sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [a compare:b];
    }];

    // Convert destination row to playlist index
    NSInteger destPlaylistIndex = 0;
    if (destinationRow >= (NSInteger)view.nodes.count) {
        destPlaylistIndex = itemCount;
    } else if (destinationRow >= 0 && destinationRow < (NSInteger)view.nodes.count) {
        GroupNode *destNode = view.nodes[destinationRow];
        if (destNode.type == GroupNodeTypeTrack) {
            destPlaylistIndex = destNode.playlistIndex;
        } else {
            // Find the next track node
            for (NSInteger r = destinationRow; r < (NSInteger)view.nodes.count; r++) {
                GroupNode *n = view.nodes[r];
                if (n.type == GroupNodeTypeTrack) {
                    destPlaylistIndex = n.playlistIndex;
                    break;
                }
            }
        }
    }

    // Build reorder array
    // Create new order array where items are moved to destination position
    std::vector<t_size> order(itemCount);

    // Create a set of source indices for quick lookup
    std::set<t_size> sourceSet;
    for (NSNumber *num in sourcePlaylistIndices) {
        sourceSet.insert([num unsignedLongValue]);
    }

    // Calculate where items actually go after removal
    t_size adjustedDest = destPlaylistIndex;
    for (NSNumber *num in sourcePlaylistIndices) {
        if ([num unsignedLongValue] < (t_size)destPlaylistIndex) {
            adjustedDest--;
        }
    }

    // Build the order array
    t_size writePos = 0;

    // Items before destination (excluding moved items)
    for (t_size i = 0; i < itemCount && writePos < adjustedDest; i++) {
        if (sourceSet.find(i) == sourceSet.end()) {
            order[writePos++] = i;
        }
    }

    // Insert moved items at destination
    for (NSNumber *num in sourcePlaylistIndices) {
        order[writePos++] = [num unsignedLongValue];
    }

    // Items after destination (excluding moved items)
    for (t_size i = 0; i < itemCount; i++) {
        if (sourceSet.find(i) == sourceSet.end()) {
            // Check if already added
            bool alreadyAdded = false;
            for (t_size j = 0; j < adjustedDest; j++) {
                if (order[j] == i) {
                    alreadyAdded = true;
                    break;
                }
            }
            if (!alreadyAdded) {
                order[writePos++] = i;
            }
        }
    }

    // Create undo point and reorder
    pm->playlist_undo_backup(activePlaylist);
    pm->playlist_reorder_items(activePlaylist, order.data(), itemCount);
}

- (void)playlistView:(SimPlaylistView *)view didReceiveDroppedURLs:(NSArray<NSURL *> *)urls atRow:(NSInteger)row {
    if (_currentPlaylistIndex < 0) return;
    if (urls.count == 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;

    // Check if playlist is locked
    if (pm->playlist_lock_is_present(activePlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(activePlaylist);
        if (lockMask & playlist_lock::filter_add) {
            return;
        }
    }

    // Convert row index to playlist index for insertion point
    t_size insertAt = SIZE_MAX;  // Default: append at end
    if (row >= 0 && row < (NSInteger)view.nodes.count) {
        GroupNode *node = view.nodes[row];
        if (node.type == GroupNodeTypeTrack) {
            insertAt = node.playlistIndex;
        } else {
            // Find next track
            for (NSInteger r = row; r < (NSInteger)view.nodes.count; r++) {
                GroupNode *n = view.nodes[r];
                if (n.type == GroupNodeTypeTrack) {
                    insertAt = n.playlistIndex;
                    break;
                }
            }
        }
    }

    // Build path list from URLs
    pfc::list_t<const char*> paths;
    std::vector<std::string> pathStrings;  // Keep strings alive

    for (NSURL *url in urls) {
        if (url.isFileURL) {
            NSString *path = url.path;
            pathStrings.push_back([path UTF8String]);
        }
    }

    for (const auto& s : pathStrings) {
        paths.add_item(s.c_str());
    }

    if (paths.get_count() == 0) return;

    // Use playlist_incoming_item_filter to process and add files
    @try {
        auto filter = playlist_incoming_item_filter::get();
        metadb_handle_list handles;

        // Process each path
        for (t_size i = 0; i < paths.get_count(); i++) {
            metadb_handle_list temp;
            if (filter->process_location(paths[i], temp, true, nullptr, nullptr, nullptr)) {
                handles.add_items(temp);
            }
        }

        if (handles.get_count() > 0) {
            // Sort items
            filter->filter_items(handles, handles);

            // Create undo point
            pm->playlist_undo_backup(activePlaylist);

            // Insert items
            pm->playlist_insert_items(activePlaylist, insertAt, handles, pfc::bit_array_val(true));
        }
    } @catch (NSException *exception) {
        // Ignore errors
    }
}

@end
