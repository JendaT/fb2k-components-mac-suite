#import "AlbumViewVancedController.h"
#import "AlbumGridView.h"
#import "../Core/AlbumDataSource.h"
#import "../Core/AlbumItem.h"
#import "../fb2k_sdk.h"
#import "../../../../shared/PreferencesCommon.h"
#import "../../../../shared/UIStyles.h"
#include <algorithm>
#include <vector>

namespace albumviewvanced_config {
static const char* const kStableNowPlayingPlaylistName = "Now Playing";
}

static const CGFloat kSearchFieldHeight = 24.0;
static const CGFloat kStatusBarHeight   = 18.0;
static const CGFloat kSearchTopMargin   = 6.0;
static const CGFloat kSearchScrollGap   = 4.0;
static const CGFloat kStatusBottomMargin = 4.0;
static const CGFloat kPadding           = 8.0;

static NSInteger countFilledStars(NSString *string) {
    NSInteger count = 0;
    for (NSUInteger i = 0; i < string.length; i++) {
        if ([string characterAtIndex:i] == 0x2605) count++;
    }
    return count;
}

static BOOL ratingCommandMatches(NSString *fullPath, NSString *commandName, NSInteger rating) {
    NSString *path = fullPath.lowercaseString;
    NSString *name = commandName.lowercaseString;
    BOOL isRatingArea = ([path containsString:@"rating"] || [path containsString:@"playback statistics"]);
    if (!isRatingArea) return NO;

    if (rating == 0) {
        return [name containsString:@"clear"] || [name containsString:@"unrated"] ||
               [name containsString:@"not set"] || [name containsString:@"no rating"] ||
               [name containsString:@"remove rating"];
    }

    NSString *number = [NSString stringWithFormat:@"%ld", (long)rating];
    return [name isEqualToString:number] ||
           [name containsString:[NSString stringWithFormat:@"%@ star", number]] ||
           [name containsString:[NSString stringWithFormat:@"rating %@", number]] ||
           countFilledStars(commandName) == rating;
}

static BOOL executeRatingCommand(menu_tree_item::ptr item, NSInteger rating, NSString *prefix) {
    if (!item.is_valid()) return NO;

    NSString *name = item->name() ? [NSString stringWithUTF8String:item->name()] : @"";
    NSString *path = prefix.length > 0 ? [NSString stringWithFormat:@"%@/%@", prefix, name] : name;

    if (item->type() == menu_tree_item::itemCommand) {
        if (ratingCommandMatches(path, name, rating) && !(item->flags() & menu_flags::disabled)) {
            item->execute(nullptr);
            return YES;
        }
        return NO;
    }

    if (item->type() == menu_tree_item::itemSubmenu) {
        for (size_t i = 0; i < item->childCount(); i++) {
            if (executeRatingCommand(item->childAt(i), rating, path)) return YES;
        }
    }
    return NO;
}

@interface AlbumViewVancedController () <NSSearchFieldDelegate, AlbumDataSourceDelegate, AlbumGridViewDelegate>
@end

@implementation AlbumViewVancedController {
    NSVisualEffectView *_containerView;
    NSSearchField      *_searchField;
    NSScrollView       *_scrollView;
    AlbumGridView      *_gridView;
    NSTextField        *_statusLabel;
    AlbumDataSource    *_dataSource;
    BOOL                _initialLoadDone;

    // Context menu state (must survive menu lifecycle)
    contextmenu_manager_v2::ptr _contextMenuManager;
    service_ptr_t<contextmenu_manager> _contextMenuManagerV1;
    metadb_handle_list _contextMenuHandles;

    // Debounced search
    NSTimer *_searchDebounceTimer;
    NSTimer *_libraryRebuildDebounceTimer;

}

- (void)loadView {
    _containerView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 400, 500)];
    _containerView.material = NSVisualEffectMaterialSidebar;
    _containerView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _containerView.state = NSVisualEffectStateActive;
    _containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = _containerView;

    [self setupSearchField];
    [self setupGridView];
    [self setupStatusBar];
    [self setupDataSource];
    [self layoutAllSubviews];
}

- (void)setupSearchField {
    _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    _searchField.placeholderString = @"Search library...";
    _searchField.delegate = self;
    _searchField.sendsSearchStringImmediately = NO;
    _searchField.sendsWholeSearchString = YES;
    [_containerView addSubview:_searchField];
}

- (void)setupGridView {
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.drawsBackground = NO;
    _scrollView.backgroundColor = [NSColor clearColor];
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;

    _gridView = [[AlbumGridView alloc] initWithFrame:NSZeroRect];
    _gridView.delegate = self;

    _scrollView.documentView = _gridView;
    [_containerView addSubview:_scrollView];
}

- (void)setupStatusBar {
    _statusLabel = [NSTextField labelWithString:@""];
    _statusLabel.font = fb2k_ui::statusBarFont();
    _statusLabel.textColor = fb2k_ui::secondaryTextColor();
    _statusLabel.frame = NSZeroRect;
    [_containerView addSubview:_statusLabel];
}

- (void)setupDataSource {
    _dataSource = [[AlbumDataSource alloc] init];
    _dataSource.delegate = self;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (!_initialLoadDone) {
        _initialLoadDone = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleNavigateToTrack:)
                                                     name:@"fb2k.navigateToTrack"
                                                   object:nil];
        [self scheduleLibraryRebuild];
    }
}

- (void)handleNavigateToTrack:(NSNotification *)note {
    NSString *path = note.userInfo[@"path"];
    if (path.length > 0) {
        [_gridView scrollToAlbumWithTrackPath:path];
    }
}

#pragma mark - Layout (frame-based)

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

    // Update grid view width and recalc content height
    NSRect gridFrame = _gridView.frame;
    gridFrame.size.width = w;
    _gridView.frame = gridFrame;
    [_gridView recalcFrameHeight];
}

#pragma mark - AlbumDataSourceDelegate

- (void)albumDataSourceDidBeginUpdate {
    _statusLabel.stringValue = @"Loading...";
}

- (void)albumDataSourceDidUpdate {
    _gridView.albums = _dataSource.albums;
    [_gridView reloadData];
    [self updateStatusText];
}

- (void)updateStatusText {
    NSUInteger albumCount = _dataSource.albums.count;
    NSUInteger trackCount = _dataSource.totalTrackCount;
    _statusLabel.stringValue = [NSString stringWithFormat:@"%lu %@, %lu %@",
                                (unsigned long)albumCount,
                                albumCount == 1 ? @"album" : @"albums",
                                (unsigned long)trackCount,
                                trackCount == 1 ? @"track" : @"tracks"];
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

- (void)debouncedSearch {
    [self performSearch];
}

- (void)performSearch {
    NSString *query = _searchField.stringValue;
    if (query.length == 0) query = nil;
    [_gridView collapseExpandedAlbum];
    [_dataSource rebuildWithFilter:query];
}

- (void)scheduleLibraryRebuild {
    [_libraryRebuildDebounceTimer invalidate];
    _libraryRebuildDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                                     target:self
                                                                   selector:@selector(executeLibraryRebuild)
                                                                   userInfo:nil
                                                                    repeats:NO];
}

- (void)executeLibraryRebuild {
    NSString *query = _searchField.stringValue;
    if (query.length == 0) query = nil;
    [_dataSource rebuildWithFilter:query];
}

#pragma mark - AlbumGridViewDelegate

- (void)albumGridView:(id)gridView wantsPlayAlbum:(AlbumItem *)album {
    [self playPaths:[album allTrackPaths] startIndex:0];
}

- (void)albumGridView:(id)gridView wantsPlayTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album {
    NSArray *paths = [album allTrackPaths];
    NSUInteger idx = [paths indexOfObject:track.path];
    [self playPaths:paths startIndex:(idx != NSNotFound) ? idx : 0];
}

- (void)albumGridView:(id)gridView wantsQueueAlbum:(AlbumItem *)album {
    [self queuePathsDirectlyInternal:[album allTrackPaths]];
}

- (void)albumGridView:(id)gridView wantsQueueTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album {
    [self queuePathsDirectlyInternal:@[track.path]];
}

- (void)albumGridView:(id)gridView requestsContextMenuForAlbum:(AlbumItem *)album atPoint:(NSPoint)screenPoint {
    [self showContextMenuForPaths:[album allTrackPaths] atScreenPoint:screenPoint];
}

- (void)albumGridView:(id)gridView requestsContextMenuForTrack:(AlbumTrack *)track
               inAlbum:(AlbumItem *)album atPoint:(NSPoint)screenPoint {
    [self showContextMenuForPaths:@[track.path] atScreenPoint:screenPoint];
}

- (void)albumGridView:(id)gridView wantsSetRating:(NSInteger)rating forAlbum:(AlbumItem *)album {
    [self setRating:rating forPaths:[album allTrackPaths]];
}

- (void)albumGridView:(id)gridView wantsSetRating:(NSInteger)rating forTrack:(AlbumTrack *)track inAlbum:(AlbumItem *)album {
    if (track.path.length == 0) return;
    [self setRating:rating forPaths:@[track.path]];
}

#pragma mark - Playback actions

- (BOOL)handlesFromPaths:(NSArray<NSString *> *)paths into:(metadb_handle_list &)outHandles {
    if (paths.count == 0) return NO;
    auto db = metadb::get();
    for (NSString *path in paths) {
        if (path.length == 0) continue;
        auto handle = db->handle_create([path UTF8String], 0);
        if (handle.is_valid()) outHandles.add_item(handle);
    }
    return outHandles.get_count() > 0;
}

- (void)setRating:(NSInteger)rating forPaths:(NSArray<NSString *> *)paths {
    metadb_handle_list handles;
    @try {
        if (![self handlesFromPaths:paths into:handles]) return;

        auto cmm = contextmenu_manager_v2::tryGet();
        if (!cmm.is_valid()) {
            FB2K_console_formatter() << "[AlbumViewVanced] Rating command unavailable: context menu v2 is not available";
            return;
        }

        cmm->init_context_ex(handles, contextmenu_manager::flag_view_full, contextmenu_item::caller_active_playlist_selection);
        menu_tree_item::ptr root = cmm->build_menu();
        if (!root.is_valid()) {
            FB2K_console_formatter() << "[AlbumViewVanced] Rating command unavailable: context menu root is empty";
            return;
        }

        if (executeRatingCommand(root, rating, @"")) {
            [_gridView setNeedsDisplay:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self scheduleLibraryRebuild];
            });
            return;
        }

        FB2K_console_formatter() << "[AlbumViewVanced] No native rating command matched requested rating " << (long)rating;
    } @catch (NSException *exception) {
        FB2K_console_formatter() << "[AlbumViewVanced] Rating command error: " << [[exception description] UTF8String];
    }
}

/// Replace the stable Now Playing playlist and start playback from startIndex
- (void)playPaths:(NSArray<NSString *> *)paths startIndex:(NSUInteger)startIndex {
    if (paths.count == 0) return;

    try {
        auto plMgr = playlist_manager::get();
        auto pbCtrl = playback_control::get();

        metadb_handle_list items;
        auto db = metadb::get();
        for (NSString *path in paths) {
            auto handle = db->handle_create([path UTF8String], 0);
            if (handle.is_valid()) items.add_item(handle);
        }
        if (items.get_count() == 0) return;
        if (startIndex >= items.get_count()) startIndex = 0;

        if (plMgr->queue_get_count() > 0) {
            plMgr->queue_flush();
        }

        t_size playlistIndex = [self nowPlayingPlaylistOrCreate];
        plMgr->set_active_playlist(playlistIndex);
        plMgr->playlist_clear(playlistIndex);
        plMgr->playlist_insert_items(playlistIndex, 0, items, pfc::bit_array_false());
        plMgr->playlist_set_focus_item(playlistIndex, startIndex);

        pbCtrl->start(playback_control::track_command_play);
    } catch (...) {
        FB2K_console_formatter() << "[AlbumViewVanced] Error starting playback";
    }
}

- (void)addPathsToQueue:(NSArray<NSString *> *)paths {
    [self queuePathsDirectlyInternal:paths];
}

- (void)queuePathsDirectlyInternal:(NSArray<NSString *> *)paths {
    if (paths.count == 0) return;

    try {
        auto plMgr = playlist_manager::get();
        t_size active = plMgr->get_active_playlist();
        if (active == pfc::infinite_size) {
            active = plMgr->create_playlist_autoname(0);
            plMgr->set_active_playlist(active);
        }

        metadb_handle_list items;
        auto db = metadb::get();
        for (NSString *path in paths) {
            auto handle = db->handle_create([path UTF8String], 0);
            if (handle.is_valid()) items.add_item(handle);
        }

        if (items.get_count() == 0) return;

        t_size baseIndex = plMgr->playlist_get_item_count(active);
        plMgr->playlist_add_items(active, items, bit_array_false());

        for (t_size i = 0; i < items.get_count(); i++) {
            plMgr->queue_add_item_playlist(active, baseIndex + i);
        }
    } catch (...) {
        FB2K_console_formatter() << "[AlbumViewVanced] Error adding tracks to queue";
    }
}

- (void)showContextMenuForPaths:(NSArray<NSString *> *)paths atScreenPoint:(NSPoint)screenPoint {
    if (paths.count == 0) return;

    @try {
        _contextMenuManager.release();
        _contextMenuManagerV1.release();

        metadb_handle_list items;
        auto db = metadb::get();
        for (NSString *path in paths) {
            auto handle = db->handle_create([path UTF8String], 0);
            if (handle.is_valid()) items.add_item(handle);
        }
        if (items.get_count() == 0) return;
        _contextMenuHandles = items;

        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        [menu setAutoenablesItems:NO];

        NSMenuItem *playItem = [[NSMenuItem alloc]
            initWithTitle:@"Play"
                   action:@selector(contextPlay:)
             keyEquivalent:@"\r"];
        playItem.target = self;
        playItem.keyEquivalentModifierMask = 0;
        playItem.representedObject = paths;
        [menu addItem:playItem];

        NSMenuItem *addToQueueItem = [[NSMenuItem alloc]
            initWithTitle:@"Add to Playback Queue"
                   action:@selector(contextAddToQueue:)
               keyEquivalent:@"q"];
        addToQueueItem.target = self;
        addToQueueItem.keyEquivalentModifierMask = 0;
        addToQueueItem.representedObject = paths;

        NSMenuItem *addToNowPlayingItem = [[NSMenuItem alloc]
            initWithTitle:@"Add to Now Playing"
                   action:@selector(contextAddToNowPlayingPlaylist:)
            keyEquivalent:@""];
        addToNowPlayingItem.target = self;
        addToNowPlayingItem.representedObject = paths;

        [menu addItem:addToNowPlayingItem];
        [menu addItem:addToQueueItem];

        NSMenuItem *addToPlaylistItem = [[NSMenuItem alloc]
            initWithTitle:@"Add to Playlist"
                   action:nil
            keyEquivalent:@""];
        NSMenu *playlistMenu = [[NSMenu alloc] initWithTitle:@"Add to Playlist"];

        NSMenuItem *currentPlaylistItem = [[NSMenuItem alloc]
            initWithTitle:@"Current Playlist"
                   action:@selector(contextAddToCurrentPlaylist:)
            keyEquivalent:@""];
        currentPlaylistItem.target = self;
        currentPlaylistItem.representedObject = paths;
        [playlistMenu addItem:currentPlaylistItem];

        NSMenuItem *newPlaylistItem = [[NSMenuItem alloc]
            initWithTitle:@"New Playlist"
                   action:@selector(contextAddToNewPlaylist:)
            keyEquivalent:@""];
        newPlaylistItem.target = self;
        newPlaylistItem.representedObject = paths;
        [playlistMenu addItem:newPlaylistItem];

        [playlistMenu addItem:[NSMenuItem separatorItem]];

        auto plMgr = playlist_manager::get();
        t_size playlistCount = plMgr->get_playlist_count();
        struct PlaylistEntry {
            NSString *title;
            t_size index;
        };
        std::vector<PlaylistEntry> entries;
        entries.reserve((size_t)playlistCount);

        for (t_size i = 0; i < playlistCount; i++) {
            pfc::string8 name;
            const bool gotName = plMgr->playlist_get_name(i, name);
            NSString *title = gotName && name.length() > 0
                ? [NSString stringWithUTF8String:name.c_str()]
                : [NSString stringWithFormat:@"Playlist %lu", (unsigned long)(i + 1)];

            if ([title isEqualToString:@"Now Playing"] ||
                [title isEqualToString:@"Now Playing (AlbumViewVanced)"]) {
                continue;
            }

            entries.push_back({title, i});
        }

        std::sort(entries.begin(), entries.end(), [](const PlaylistEntry &a, const PlaylistEntry &b) {
            return [a.title localizedCaseInsensitiveCompare:b.title] == NSOrderedAscending;
        });

        for (const auto &entry : entries) {
            NSMenuItem *playlistItem = [[NSMenuItem alloc]
                initWithTitle:entry.title
                       action:@selector(contextAddToSpecificPlaylist:)
                keyEquivalent:@""];
            playlistItem.target = self;
            playlistItem.tag = (NSInteger)entry.index;
            playlistItem.representedObject = paths;
            [playlistMenu addItem:playlistItem];
        }

        addToPlaylistItem.submenu = playlistMenu;
        [menu addItem:addToPlaylistItem];

        [menu addItem:[NSMenuItem separatorItem]];

        // foobar2000 SDK context menu (v2 preferred)
        auto cmm = contextmenu_manager_v2::tryGet();
        if (cmm.is_valid()) {
            _contextMenuManager = cmm;
            _contextMenuManager->init_context(items, 0);
            menu_tree_item::ptr root = _contextMenuManager->build_menu();
            if (root.is_valid()) {
                [self buildNSMenu:menu fromMenuItem:root contextManager:_contextMenuManager];
            }
        } else {
            _contextMenuManagerV1 = contextmenu_manager::g_create();
            _contextMenuManagerV1->init_context(items, 0);
        }

        [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];

    } @catch (NSException *exception) {
        FB2K_console_formatter() << "[AlbumViewVanced] Context menu error: "
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
                initWithTitle:title action:nil keyEquivalent:@""];
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
            FB2K_console_formatter() << "[AlbumViewVanced] Context menu execution error";
        }
    }
}

- (void)contextPlay:(NSMenuItem *)sender {
    NSArray<NSString *> *paths = sender.representedObject;
    [self playPaths:paths startIndex:0];
}

- (void)contextAddToQueue:(NSMenuItem *)sender {
    NSArray<NSString *> *paths = sender.representedObject;
    [self addPathsToQueue:paths];
}

- (void)contextAddToNowPlayingPlaylist:(NSMenuItem *)sender {
    NSArray<NSString *> *paths = sender.representedObject;
    [self appendPaths:paths toPlaylistIndex:[self nowPlayingPlaylistOrCreate]];
}

- (void)contextAddToCurrentPlaylist:(NSMenuItem *)sender {
    NSArray<NSString *> *paths = sender.representedObject;
    [self appendPaths:paths toPlaylistIndex:[self activePlaylistOrCreate:YES]];
}

- (void)contextAddToNewPlaylist:(NSMenuItem *)sender {
    NSArray<NSString *> *paths = sender.representedObject;
    [self appendPaths:paths toPlaylistIndex:[self createAutoNamedPlaylist]];
}

- (void)contextAddToSpecificPlaylist:(NSMenuItem *)sender {
    NSArray<NSString *> *paths = sender.representedObject;
    [self appendPaths:paths toPlaylistIndex:(t_size)sender.tag];
}

- (t_size)activePlaylistOrCreate:(BOOL)createIfMissing {
    auto plMgr = playlist_manager::get();
    t_size active = plMgr->get_active_playlist();
    if (active == pfc::infinite_size && createIfMissing) {
        active = plMgr->create_playlist_autoname(0);
        plMgr->set_active_playlist(active);
    }
    return active;
}

- (t_size)createAutoNamedPlaylist {
    auto plMgr = playlist_manager::get();
    t_size playlist = plMgr->create_playlist_autoname(0);
    plMgr->set_active_playlist(playlist);
    return playlist;
}

- (t_size)nowPlayingPlaylistOrCreate {
    auto plMgr = playlist_manager::get();
    const char *playlistName = albumviewvanced_config::kStableNowPlayingPlaylistName;
    t_size playlist = plMgr->find_playlist(playlistName, pfc_infinite);
    if (playlist == pfc_infinite) {
        playlist = plMgr->create_playlist(playlistName, SIZE_MAX, SIZE_MAX);
    }
    return playlist;
}

- (void)appendPaths:(NSArray<NSString *> *)paths toPlaylistIndex:(t_size)playlistIndex {
    if (paths.count == 0 || playlistIndex == pfc::infinite_size) return;

    try {
        metadb_handle_list items;
        auto db = metadb::get();
        for (NSString *path in paths) {
            auto handle = db->handle_create([path UTF8String], 0);
            if (handle.is_valid()) items.add_item(handle);
        }

        if (items.get_count() == 0) return;

        auto plMgr = playlist_manager::get();
        t_size baseIndex = plMgr->playlist_get_item_count(playlistIndex);
        plMgr->playlist_insert_items(playlistIndex, baseIndex, items, pfc::bit_array_false());
    } catch (...) {
        FB2K_console_formatter() << "[AlbumViewVanced] Error adding tracks to playlist";
    }
}

#pragma mark - Library callbacks

- (void)handleLibraryItemsAdded {
    [self scheduleLibraryRebuild];
}

- (void)handleLibraryItemsRemoved {
    [self scheduleLibraryRebuild];
}

- (void)handleLibraryItemsModified {
    [self scheduleLibraryRebuild];
}

- (void)dealloc {
    [_searchDebounceTimer invalidate];
    [_libraryRebuildDebounceTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
