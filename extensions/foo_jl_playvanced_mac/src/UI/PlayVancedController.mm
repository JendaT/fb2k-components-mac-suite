#import "PlayVancedController.h"
#import "NowPlayingView.h"
#import "../Core/TrackInfo.h"
#import "../Core/ArtworkFetcher.h"
#import "../Integration/PlayVancedCallbacks.h"
#import "../../../../shared/UIStyles.h"

@interface PlayVancedController () <NowPlayingViewDelegate>
@end

@implementation PlayVancedController {
    NowPlayingView     *_barView;
    metadb_handle_ptr   _currentTrack;
    NSString           *_currentPath;

    titleformat_object::ptr _tfTitle;
    titleformat_object::ptr _tfArtist;
    titleformat_object::ptr _tfAlbum;
    titleformat_object::ptr _tfCodec;
    titleformat_object::ptr _tfBitrate;
    titleformat_object::ptr _tfSampleRate;
    titleformat_object::ptr _tfDuration;
    titleformat_object::ptr _tfRating;
}

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

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 52)];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    root.wantsLayer = YES;
    self.view = root;

    _barView = [[NowPlayingView alloc] initWithFrame:root.bounds];
    _barView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _barView.delegate = self;
    [root addSubview:_barView];

    [self compileTitleFormats];
    [self syncVolume];
    [self syncPlaybackOrder];
}

- (void)compileTitleFormats {
    auto compiler = titleformat_compiler::get();
    compiler->compile_safe_ex(_tfTitle, "%title%", "?");
    compiler->compile_safe_ex(_tfArtist, "$if2(%artist%,%album artist%)", "");
    compiler->compile_safe_ex(_tfAlbum, "%album%", "");
    compiler->compile_safe_ex(_tfCodec, "%codec%", "");
    compiler->compile_safe_ex(_tfBitrate, "%bitrate%", "");
    compiler->compile_safe_ex(_tfSampleRate, "%samplerate%", "");
    compiler->compile_safe_ex(_tfDuration, "%length%", "");
    compiler->compile_safe_ex(_tfRating, "%rating%", "");
}

- (void)syncVolume {
    try {
        auto pc = playback_control::get();
        float volDb = pc->get_volume();
        if (volDb > 0.0f) {
            // Cap at 0 dB — we don't expose amplification above unity gain
            pc->set_volume(0.0f);
            volDb = 0.0f;
        }
        float normalized = (volDb <= playback_control::volume_mute) ? 0.0f :
                           powf(10.0f, volDb / 20.0f);
        _barView.volume = normalized;
    } catch (...) {}
}

- (void)syncPlaybackOrder {
    try {
        auto pm = playlist_manager::get();
        t_size order = pm->playback_order_get_active();
        _barView.playbackOrder = (NSInteger)order;
    } catch (...) {}
}

- (void)viewDidAppear {
    [super viewDidAppear];

    auto pbCtrl = playback_control::get();
    if (pbCtrl.is_valid() && pbCtrl->is_playing()) {
        metadb_handle_ptr track;
        if (pbCtrl->get_now_playing(track) && track.is_valid()) {
            [self handleNewTrack:track];
        }
    }
}

#pragma mark - Playback Callbacks

- (void)handleNewTrack:(metadb_handle_ptr)track {
    if (!track.is_valid()) return;

    _currentTrack = track;
    NSString *path = [NSString stringWithUTF8String:track->get_path()];
    _currentPath = path;

    _barView.isPlaying = YES;
    _barView.isPaused = playback_control::get()->is_paused();
    _barView.playbackPosition = 0;
    _barView.trackDuration = track->get_length();

    metadb_handle_ptr trackCopy = track;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            TrackInfo *info = [strongSelf extractInfoFromHandle:trackCopy];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                innerSelf->_barView.trackInfo = info;
            });
        }
    });

    __weak typeof(self) weakSelfArtwork = self;
    [[ArtworkFetcher sharedFetcher] fetchArtworkForPath:path completion:^(NSImage *image) {
        __strong typeof(weakSelfArtwork) strongSelf = weakSelfArtwork;
        if (!strongSelf) return;
        if ([strongSelf->_currentPath isEqualToString:path]) {
            strongSelf->_barView.artworkImage = image;
        }
    }];
}

- (void)handlePlaybackStop {
    _currentTrack.release();
    _currentPath = nil;
    [_barView clearDisplay];
}

- (void)handlePlaybackPause:(BOOL)paused {
    _barView.isPaused = paused;
}

- (void)handlePlaybackTime:(double)time {
    _barView.playbackPosition = time;
}

- (void)handlePlaybackSeek:(double)time {
    _barView.playbackPosition = time;
}

- (void)handleSelectionChanged {
    auto pbCtrl = playback_control::get();
    if (pbCtrl.is_valid() && pbCtrl->is_playing()) return;

    metadb_handle_ptr selected = [self getSelectedTrack];
    if (!selected.is_valid()) return;

    _currentTrack = selected;
    NSString *path = [NSString stringWithUTF8String:selected->get_path()];
    _currentPath = path;

    _barView.isPlaying = NO;
    _barView.isPaused = NO;
    _barView.playbackPosition = 0;
    _barView.trackDuration = selected->get_length();

    metadb_handle_ptr trackCopy = selected;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            TrackInfo *info = [strongSelf extractInfoFromHandle:trackCopy];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                innerSelf->_barView.trackInfo = info;
            });
        }
    });

    __weak typeof(self) weakSelfArtwork = self;
    [[ArtworkFetcher sharedFetcher] fetchArtworkForPath:path completion:^(NSImage *image) {
        __strong typeof(weakSelfArtwork) strongSelf = weakSelfArtwork;
        if (!strongSelf) return;
        if ([strongSelf->_currentPath isEqualToString:path]) {
            strongSelf->_barView.artworkImage = image;
        }
    }];
}

- (void)handleVolumeChanged:(float)volume {
    _barView.volume = volume;
}

- (void)handlePlaybackOrderChanged:(NSInteger)order {
    _barView.playbackOrder = order;
}

#pragma mark - NowPlayingViewDelegate

- (void)nowPlayingViewDidPressPrevious {
    try {
        auto pc = playback_control::get();
        pc->start(playback_control::track_command_prev);
    } catch (...) {}
}

- (void)nowPlayingViewDidPressPlayPause {
    try {
        auto pc = playback_control::get();
        pc->play_or_pause();
    } catch (...) {}
}

- (void)nowPlayingViewDidPressNext {
    try {
        auto pc = playback_control::get();
        pc->start(playback_control::track_command_next);
    } catch (...) {}
}

- (void)nowPlayingViewDidPressStop {
    try {
        playback_control::get()->stop();
    } catch (...) {}
}

- (void)nowPlayingViewDidToggleShuffle {
    try {
        auto pm = playlist_manager::get();
        t_size current = pm->playback_order_get_active();
        // Shuffle is active when order >= 3 (Random/Shuffle variants)
        // Toggle: if active → Default(0), if inactive → Shuffle tracks(4)
        t_size next = (current >= 3) ? 0 : 4;
        pm->playback_order_set_active(next);
    } catch (...) {}
}

- (void)nowPlayingViewDidCycleRepeat {
    try {
        auto pm = playlist_manager::get();
        t_size current = pm->playback_order_get_active();
        t_size next;
        if (current == 1) {
            next = 2; // Repeat playlist → Repeat track
        } else if (current == 2) {
            next = 0; // Repeat track → Off
        } else {
            next = 1; // Anything else → Repeat playlist
        }
        pm->playback_order_set_active(next);
    } catch (...) {}
}

- (void)nowPlayingViewDidToggleMute {
    try {
        playback_control::get()->volume_mute_toggle();
    } catch (...) {}
}

- (void)nowPlayingViewDidSeekToPosition:(double)fraction {
    try {
        auto pc = playback_control::get();
        if (pc->is_playing() && pc->playback_can_seek()) {
            double target = fraction * _barView.trackDuration;
            pc->playback_seek(target);
        }
    } catch (...) {}
}

- (void)nowPlayingViewDidChangeVolume:(float)volume {
    try {
        auto pc = playback_control::get();
        float dB;
        if (volume <= 0.001f) {
            dB = playback_control::volume_mute;
        } else {
            dB = 20.0f * log10f(volume);
            if (dB > 0.0f) dB = 0.0f;
        }
        pc->set_volume(dB);
    } catch (...) {}
}

- (void)nowPlayingViewDidTapTrackInfo {
    try {
        auto pm = playlist_manager::get();

        t_size playlistIdx, itemIdx;
        bool found = pm->get_playing_item_location(&playlistIdx, &itemIdx);

        if (!found && _currentPath.length > 0) {
            found = [self findTrackByPath:_currentPath playlist:&playlistIdx item:&itemIdx];
        }
        if (!found) return;

        pm->set_active_playlist(playlistIdx);
        pm->playlist_set_focus_item(playlistIdx, itemIdx);
        pm->playlist_ensure_visible(playlistIdx, itemIdx);
    } catch (...) {}

    if (_currentPath.length > 0) {
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"fb2k.navigateToTrack"
                          object:nil
                        userInfo:@{@"path": _currentPath}];
    }
}

- (void)nowPlayingViewDidRequestSetRating:(NSInteger)rating {
    if (!_currentTrack.is_valid()) return;

    metadb_handle_list handles;
    handles.add_item(_currentTrack);

    auto cmm = contextmenu_manager_v2::tryGet();
    if (!cmm.is_valid()) {
        FB2K_console_formatter() << "[PlayVanced] Rating command unavailable: context menu v2 is not available";
        return;
    }

    cmm->init_context_ex(handles, contextmenu_manager::flag_view_full, contextmenu_item::caller_active_playlist_selection);
    menu_tree_item::ptr root = cmm->build_menu();
    if (!root.is_valid()) {
        FB2K_console_formatter() << "[PlayVanced] Rating command unavailable: context menu root is empty";
        return;
    }

    if (executeRatingCommand(root, rating, @"")) {
        metadb_handle_ptr trackCopy = _currentTrack;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !trackCopy.is_valid()) return;
            strongSelf->_barView.trackInfo = [strongSelf extractInfoFromHandle:trackCopy];
        });
        return;
    }

    FB2K_console_formatter() << "[PlayVanced] No native rating command matched requested rating " << (long)rating;
}

- (BOOL)findTrackByPath:(NSString *)path playlist:(t_size *)outPlaylist item:(t_size *)outItem {
    const char *targetPath = [path UTF8String];
    auto pm = playlist_manager::get();
    t_size active = pm->get_active_playlist();
    t_size count = pm->get_playlist_count();

    // Search active playlist first for faster hit
    for (t_size pass = 0; pass < 2; pass++) {
        t_size start = (pass == 0) ? active : 0;
        t_size end   = (pass == 0) ? active + 1 : count;
        for (t_size p = start; p < end; p++) {
            if (pass == 1 && p == active) continue;
            t_size items = pm->playlist_get_item_count(p);
            for (t_size i = 0; i < items; i++) {
                metadb_handle_ptr handle;
                if (pm->playlist_get_item_handle(handle, p, i) && handle.is_valid()) {
                    if (strcmp(handle->get_path(), targetPath) == 0) {
                        *outPlaylist = p;
                        *outItem = i;
                        return YES;
                    }
                }
            }
        }
    }
    return NO;
}

- (void)nowPlayingViewDidReceiveDroppedPaths:(NSArray<NSString *> *)paths {
    if (paths.count == 0) return;
    try {
        auto plMgr = playlist_manager::get();
        auto pbCtrl = playback_control::get();

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

        bool queueWasEmpty = (plMgr->queue_get_count() == 0);
        for (t_size i = 0; i < items.get_count(); i++) {
            plMgr->queue_add_item_playlist(active, baseIndex + i);
        }

        if (queueWasEmpty && !pbCtrl->is_playing()) {
            pbCtrl->start(playback_control::track_command_play);
        }
    } catch (...) {
        FB2K_console_formatter() << "[PlayVanced] Error adding dropped tracks to queue";
    }
}

#pragma mark - Metadata Extraction

- (TrackInfo *)extractInfoFromHandle:(metadb_handle_ptr)handle {
    TrackInfo *info = [[TrackInfo alloc] init];
    if (!handle.is_valid()) return info;

    info.title  = [self formatHandle:handle with:_tfTitle];
    info.artist = [self formatHandle:handle with:_tfArtist];
    info.album  = [self formatHandle:handle with:_tfAlbum];
    info.codec  = [self formatHandle:handle with:_tfCodec];
    info.rating = [self formatHandle:handle with:_tfRating];

    return info;
}

- (NSString *)formatHandle:(metadb_handle_ptr)handle with:(titleformat_object::ptr)tf {
    pfc::string8 result;
    handle->format_title(nullptr, result, tf, nullptr);
    return [NSString stringWithUTF8String:result.c_str()];
}

- (metadb_handle_ptr)getSelectedTrack {
    try {
        auto pm = playlist_manager::get();
        t_size active = pm->get_active_playlist();
        if (active == pfc::infinite_size) return metadb_handle_ptr();

        t_size focus = pm->playlist_get_focus_item(active);
        if (focus == pfc::infinite_size) return metadb_handle_ptr();

        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, active, focus)) {
            return handle;
        }
    } catch (...) {}
    return metadb_handle_ptr();
}

- (void)dealloc {
    PlayVancedCallbackManager::instance().unregisterController(self);
}

@end
