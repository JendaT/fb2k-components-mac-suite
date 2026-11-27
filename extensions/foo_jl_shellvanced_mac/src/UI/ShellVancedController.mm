#import "ShellVancedController.h"
#import <objc/message.h>
#import "ShellSidebarController.h"
#import "../Integration/ElementHost.h"
#import "../Integration/ShellPlaylistCallbacks.h"
#include "../Integration/ShellPlaylists.h"
#include "../Integration/ShellConfig.h"
#include "../Core/ShellCore.h"
#include "../fb2k_sdk.h"
#include "../../../../shared/UpNext.h"   // after the SDK include
#import "../Artists/SVArtistLibrary.h"
#import "../Artists/SVArtistHeaderView.h"

using shellcore::DestKind;
using shellcore::Destination;

static const CGFloat kNavBarHeight = 38.0;
static const CGFloat kArtistHeaderHeight = 176.0;   // 128 pt photo + 2 x 24 pt padding (SVArtistHeaderView)

#pragma mark - Root view

// Gets key equivalents before the hosted elements and foobar's main menu.
@interface SVShellRootView : NSView
@property (nonatomic, copy, nullable) BOOL (^keyEquivalentHandler)(NSEvent *event);
@end

@implementation SVShellRootView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.keyEquivalentHandler && self.keyEquivalentHandler(event)) return YES;
    return [super performKeyEquivalent:event];
}
@end

// 1 px separator that follows appearance changes.
@interface SVHairlineView : NSView
@end

@implementation SVHairlineView
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor separatorColor] setFill];
    NSRectFill(self.bounds);
}
@end

static NSSearchField *SVFirstVisibleSearchField(NSView *view) {
    if (view.isHidden) return nil;
    if ([view isKindOfClass:[NSSearchField class]] && ((NSSearchField *)view).isEnabled) return (NSSearchField *)view;
    for (NSView *sub in view.subviews) {
        if (NSSearchField *found = SVFirstVisibleSearchField(sub)) return found;
    }
    return nil;
}

// AlbumViewVanced lives in another dylib: no header, so call by selector.
static void SVSetArtistFilter(id vc, NSString *name) {
    SEL sel = NSSelectorFromString(@"setArtistFilter:");
    if (![vc respondsToSelector:sel]) return;
    ((void (*)(id, SEL, NSString *))objc_msgSend)(vc, sel, name);
}

// First visible view that can take keyboard focus (the hosted grid / list).
static NSView *SVFirstFocusableView(NSView *view) {
    if (view.isHidden) return nil;
    if (view.acceptsFirstResponder) return view;
    for (NSView *sub in view.subviews) {
        if (NSView *found = SVFirstFocusableView(sub)) return found;
    }
    return nil;
}

static NSView *SVMakePlaceholder(NSString *text) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:28 weight:NSFontWeightLight];
    icon.contentTintColor = [NSColor tertiaryLabelColor];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *label = [NSTextField labelWithString:text];
    label.textColor = [NSColor secondaryLabelColor];
    label.alignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [v addSubview:icon];
    [v addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [icon.bottomAnchor constraintEqualToAnchor:v.centerYAnchor constant:-6],
        [label.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:v.centerYAnchor constant:6],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:v.leadingAnchor constant:12],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-12],
    ]];
    return v;
}

#pragma mark - Controller

@interface ShellVancedController () <ShellSidebarDelegate>
@end

@implementation ShellVancedController {
    NSSplitViewController *_split;
    NSSplitViewItem *_sidebarItem;
    ShellSidebarController *_sidebar;
    NSViewController *_contentVC;

    // Navigation bar
    NSButton *_sidebarToggle;
    NSSegmentedControl *_navButtons;
    NSTextField *_titleLabel;
    NSTextField *_subtitleLabel;

    // Hosted elements (instantiated on first visit, then kept alive)
    NSView *_hostContainer;
    NSViewController *_albumsVC;
    NSView *_albumsView;
    NSViewController *_playlistVC;
    NSView *_playlistView;

    // Artist page: header above the shared AlbumViewVanced, which gets the artist filter.
    SVArtistHeaderView *_artistHeader;
    NSString *_filteredArtist;        // artist currently applied to AlbumViewVanced (nil = none)
    NSString *_pendingArtistRestore;  // saved artist waiting for the library index to finish
    BOOL _userNavigated;
    BOOL _suppressPersist;            // restoring while the artist index is still building

    shellcore::NavHistory _history;

    BOOL _layoutRestored;
    int64_t _savedWidth;
    BOOL _savedCollapsed;
    BOOL _callbacksRetained;
}

- (instancetype)init {
    return [super initWithNibName:nil bundle:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_callbacksRetained) SVPlaylistCallbacksRelease();
}

#pragma mark View

- (void)loadView {
    SVShellRootView *root = [[SVShellRootView alloc] initWithFrame:NSMakeRect(0, 0, 900, 600)];
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    __weak ShellVancedController *weakSelf = self;
    root.keyEquivalentHandler = ^BOOL(NSEvent *event) {
        return [weakSelf handleKeyEquivalent:event];
    };
    self.view = root;

    _savedWidth = shell_config::getInt(shell_config::kSidebarWidth, shell_config::kDefaultSidebarWidth);
    _savedWidth = std::clamp(_savedWidth, shell_config::kMinSidebarWidth, shell_config::kMaxSidebarWidth);
    _savedCollapsed = shell_config::getBool(shell_config::kSidebarCollapsed, false);

    _sidebar = [[ShellSidebarController alloc] init];
    _sidebar.delegate = self;
    _contentVC = [[NSViewController alloc] initWithNibName:nil bundle:nil];
    _contentVC.view = [self buildContentView];

    NSSplitView *splitView = [[NSSplitView alloc] initWithFrame:root.bounds];
    splitView.vertical = YES;
    splitView.dividerStyle = NSSplitViewDividerStyleThin;

    _split = [[NSSplitViewController alloc] init];
    _split.splitView = splitView;

    _sidebarItem = [NSSplitViewItem splitViewItemWithViewController:_sidebar];
    _sidebarItem.canCollapse = YES;
    _sidebarItem.minimumThickness = shell_config::kMinSidebarWidth;
    _sidebarItem.maximumThickness = shell_config::kMaxSidebarWidth;
    _sidebarItem.holdingPriority = NSLayoutPriorityDefaultLow + 10;   // keeps its width when the window resizes
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:_contentVC];
    contentItem.minimumThickness = 320;

    [_split addSplitViewItem:_sidebarItem];
    [_split addSplitViewItem:contentItem];
    [self addChildViewController:_split];
    _split.view.frame = root.bounds;
    _split.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_split.view];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(splitViewDidResize:)
               name:NSSplitViewDidResizeSubviewsNotification object:splitView];
    [nc addObserver:self selector:@selector(playlistsDidChange:)
               name:SVPlaylistsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(playlistRenamed:)
               name:SVPlaylistRenamedNotification object:nil];
    [nc addObserver:self selector:@selector(activePlaylistDidChange:)
               name:SVActivePlaylistDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(artistLibraryDidChange:)
               name:SVArtistLibraryDidChangeNotification object:nil];
    SVPlaylistCallbacksRetain();
    _callbacksRetained = YES;

    [self restoreLastDestination];
}

- (NSView *)buildContentView {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 600)];

    // Navigation bar: [sidebar] [‹|›]  Title  subtitle
    NSVisualEffectView *bar = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    bar.material = NSVisualEffectMaterialSidebar;           // matches AlbumViewVanced's background
    bar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    bar.state = NSVisualEffectStateFollowsWindowActiveState;
    bar.translatesAutoresizingMaskIntoConstraints = NO;

    _sidebarToggle = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"sidebar.left"
                                                          accessibilityDescription:@"Toggle Sidebar"]
                                        target:self action:@selector(toggleSidebar:)];
    _sidebarToggle.bordered = NO;
    _sidebarToggle.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
    _sidebarToggle.contentTintColor = [NSColor secondaryLabelColor];
    _sidebarToggle.toolTip = @"Show or Hide Sidebar (⌃⌘S)";
    _sidebarToggle.translatesAutoresizingMaskIntoConstraints = NO;

    NSImage *backImg = [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Back"];
    NSImage *fwdImg = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Forward"];
    _navButtons = [NSSegmentedControl segmentedControlWithImages:@[backImg, fwdImg]
                                                    trackingMode:NSSegmentSwitchTrackingMomentary
                                                          target:self action:@selector(navSegmentClicked:)];
    _navButtons.segmentStyle = NSSegmentStyleSeparated;
    [_navButtons setToolTip:@"Back (⌘[)" forSegment:0];
    [_navButtons setToolTip:@"Forward (⌘])" forSegment:1];
    [_navButtons setWidth:28 forSegment:0];
    [_navButtons setWidth:28 forSegment:1];
    _navButtons.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    _titleLabel.textColor = [NSColor labelColor];
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    _subtitleLabel = [NSTextField labelWithString:@""];
    _subtitleLabel.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    _subtitleLabel.textColor = [NSColor secondaryLabelColor];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_subtitleLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];

    SVHairlineView *hairline = [[SVHairlineView alloc] initWithFrame:NSZeroRect];
    hairline.translatesAutoresizingMaskIntoConstraints = NO;

    _hostContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 680, 560)];
    _hostContainer.translatesAutoresizingMaskIntoConstraints = NO;

    [bar addSubview:_sidebarToggle];
    [bar addSubview:_navButtons];
    [bar addSubview:_titleLabel];
    [bar addSubview:_subtitleLabel];
    [content addSubview:_hostContainer];
    [content addSubview:bar];
    [content addSubview:hairline];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:content.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:kNavBarHeight],

        [_sidebarToggle.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:10],
        [_sidebarToggle.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_sidebarToggle.widthAnchor constraintEqualToConstant:24],
        [_sidebarToggle.heightAnchor constraintEqualToConstant:22],

        [_navButtons.leadingAnchor constraintEqualToAnchor:_sidebarToggle.trailingAnchor constant:8],
        [_navButtons.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_navButtons.trailingAnchor constant:14],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:8],
        [_subtitleLabel.firstBaselineAnchor constraintEqualToAnchor:_titleLabel.firstBaselineAnchor],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:bar.trailingAnchor constant:-12],

        [hairline.topAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [hairline.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [hairline.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [hairline.heightAnchor constraintEqualToConstant:1],

        [_hostContainer.topAnchor constraintEqualToAnchor:hairline.bottomAnchor],
        [_hostContainer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_hostContainer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_hostContainer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];
    return content;
}

- (void)viewDidLayout {
    [super viewDidLayout];
    if (_layoutRestored || NSWidth(self.view.bounds) <= 0) return;
    _layoutRestored = YES;
    [_split.splitView setPosition:(CGFloat)_savedWidth ofDividerAtIndex:0];
    if (_savedCollapsed) _sidebarItem.collapsed = YES;
}

#pragma mark Sidebar width / collapse persistence

- (void)splitViewDidResize:(NSNotification *)note {
    if (!_layoutRestored) return;
    BOOL collapsed = _sidebarItem.isCollapsed;
    if (collapsed != _savedCollapsed) {
        _savedCollapsed = collapsed;
        shell_config::setBool(shell_config::kSidebarCollapsed, collapsed);
    }
    if (collapsed) return;
    int64_t width = (int64_t)llround(NSWidth(_sidebar.view.frame));
    if (width < shell_config::kMinSidebarWidth || width > shell_config::kMaxSidebarWidth) return;
    if (width != _savedWidth) {
        _savedWidth = width;
        shell_config::setInt(shell_config::kSidebarWidth, width);
    }
}

- (void)toggleSidebar:(id)sender {
    _sidebarItem.animator.collapsed = !_sidebarItem.isCollapsed;
}

#pragma mark Hosting

- (NSView *)embedHosted:(NSViewController *)vc placeholder:(NSString *)text {
    NSView *view;
    if (vc) {
        [_contentVC addChildViewController:vc];
        view = vc.view;
    } else {
        view = SVMakePlaceholder(text);
    }
    view.frame = _hostContainer.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.hidden = YES;
    [_hostContainer addSubview:view];
    return view;
}

- (NSView *)albumsHostView {
    if (!_albumsView) {
        _albumsVC = SVInstantiateElement(kSVGuidAlbumViewVanced, @{});
        if (!_albumsVC) console::info("[ShellVanced] AlbumViewVanced not available");
        _albumsView = [self embedHosted:_albumsVC placeholder:@"Install AlbumViewVanced to use this section"];
    }
    return _albumsView;
}

- (NSView *)playlistHostView {
    if (!_playlistView) {
        // Shell mode: SimPlaylist plays into Now Playing; always shows the active playlist.
        _playlistVC = SVInstantiateElement(kSVGuidSimPlaylist, @{@"vanced": @"1"});
        if (!_playlistVC) console::info("[ShellVanced] SimPlaylist not available");
        _playlistView = [self embedHosted:_playlistVC placeholder:@"Install SimPlaylist to use this section"];
    }
    return _playlistView;
}

- (void)showHostView:(NSView *)target {
    NSWindow *window = self.view.window;
    BOOL focusLost = NO;
    for (NSView *v in _hostContainer.subviews) {
        if (v == _artistHeader) continue;   // shown/hidden by -applyArtistPage:
        BOOL hide = (v != target);
        if (hide && !v.hidden) {
            // Don't leave keyboard focus inside a view that is about to hide.
            id fr = window.firstResponder;
            if ([fr isKindOfClass:[NSView class]] && [(NSView *)fr isDescendantOf:v]) focusLost = YES;
        }
        v.hidden = hide;
    }
    if (!focusLost) return;
    // Prefer the sidebar list, but not while the sidebar is collapsed (hidden).
    BOOL sidebarUsable = !_sidebarItem.isCollapsed && !_sidebar.tableView.isHiddenOrHasHiddenAncestor;
    if (sidebarUsable && [window makeFirstResponder:_sidebar.tableView]) return;
    NSView *focusTarget = SVFirstFocusableView(target);
    if (focusTarget && [window makeFirstResponder:focusTarget]) return;
    [window makeFirstResponder:nil];   // window itself, so keys never go to a hidden view
}

#pragma mark Artist page

- (void)playArtist:(NSString *)name shuffled:(BOOL)shuffled {
    if (name.length == 0) return;
    try {
        metadb_handle_list handles = [[SVArtistLibrary shared] handlesForArtist:name];
        if (handles.get_count() == 0) return;
        if (shuffled) {
            std::vector<t_size> order(handles.get_count());
            for (t_size i = 0; i < order.size(); i++) order[i] = i;
            for (t_size i = order.size(); i > 1; i--) std::swap(order[i - 1], order[arc4random_uniform((uint32_t)i)]);
            metadb_handle_list copy;
            for (t_size idx : order) copy.add_item(handles[idx]);
            handles = copy;
        }
        pfc::string8 label("Next from: ");
        label << name.UTF8String;
        upnext::fb::playNow(handles, 0, label.c_str());   // only Now Playing changes
    } catch (...) {
        console::info("[ShellVanced] play artist failed");
    }
}

- (SVArtistHeaderView *)artistHeader {
    if (!_artistHeader) {
        _artistHeader = [[SVArtistHeaderView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(_hostContainer.bounds), kArtistHeaderHeight)];
        _artistHeader.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;   // pinned to the top
        _artistHeader.hidden = YES;
        __weak ShellVancedController *weakSelf = self;
        _artistHeader.onPlay = ^{
            ShellVancedController *s = weakSelf;
            if (s) [s playArtist:s->_artistHeader.artistName shuffled:NO];
        };
        _artistHeader.onShuffle = ^{
            ShellVancedController *s = weakSelf;
            if (s) [s playArtist:s->_artistHeader.artistName shuffled:YES];
        };
        [_hostContainer addSubview:_artistHeader];
    }
    return _artistHeader;
}

// Shows the artist header and filter for `name`, or clears both when nil. The
// AlbumViewVanced instance is shared with the Albums page, so every page switch
// goes through here and the filter is only touched when it actually changes.
- (void)applyArtistPage:(nullable NSString *)name {
    NSView *albums = _albumsView;
    id albumsVC = _albumsVC;
    BOOL filterable = albumsVC && [albumsVC respondsToSelector:@selector(setArtistFilter:)];

    if (name.length > 0) {
        SVArtistHeaderView *header = [self artistHeader];
        if (![header.artistName isEqualToString:name]) header.artistName = name;
        header.frame = NSMakeRect(0, NSHeight(_hostContainer.bounds) - kArtistHeaderHeight,
                                  NSWidth(_hostContainer.bounds), kArtistHeaderHeight);
        header.hidden = NO;
        albums.frame = NSMakeRect(0, 0, NSWidth(_hostContainer.bounds),
                                  MAX(0, NSHeight(_hostContainer.bounds) - kArtistHeaderHeight));
        if (filterable && ![_filteredArtist isEqualToString:name]) SVSetArtistFilter(albumsVC, name);
        _filteredArtist = [name copy];
        return;
    }

    if (!_filteredArtist && (!_artistHeader || _artistHeader.isHidden)) return;
    if (filterable) SVSetArtistFilter(albumsVC, nil);   // restores the search text
    _filteredArtist = nil;
    _artistHeader.hidden = YES;
    albums.frame = _hostContainer.bounds;
}

- (void)artistLibraryDidChange:(NSNotification *)note {
    NSArray<NSString *> *names = [SVArtistLibrary shared].artistNames;
    if (_filteredArtist && !_pendingArtistRestore) {
        auto cur = _history.current();
        if (names.count > 0 && ![names containsObject:_filteredArtist] && cur && cur->kind == DestKind::Artist) {
            // The artist vanished from a built index.
            _history.remove(*cur);
            [self navigateTo:Destination{DestKind::Albums, ""}];
        } else {
            [_artistHeader refreshCounts];
        }
        return;
    }
    if (!_pendingArtistRestore) return;
    if (names.count == 0) return;   // still empty (empty library or not built yet)
    NSString *pending = _pendingArtistRestore;
    _pendingArtistRestore = nil;
    if (!_userNavigated && [names containsObject:pending]) {
        [self navigateTo:Destination{DestKind::Artist, SVToStd(pending)}];
    }
}

#pragma mark Navigation

- (void)restoreLastDestination {
    auto kind = shell_config::getInt(shell_config::kLastDestKind, (int64_t)DestKind::Albums);
    std::string name = shell_config::getString(shell_config::kLastDestName, "");
    Destination d{DestKind::Albums, ""};
    NSString *deferred = nil;
    if (kind == (int64_t)DestKind::Playlist && SVFindPlaylistExact(name) != pfc_infinite) {
        d = {DestKind::Playlist, name};
    }
    if (kind == (int64_t)DestKind::Artist && !name.empty()) {
        NSString *artist = SVToNS(name);
        NSArray<NSString *> *names = [SVArtistLibrary shared].artistNames;
        if ([names containsObject:artist]) {
            d = {DestKind::Artist, name};
        } else if (names.count == 0) {
            // The artist index builds in the background: open Albums now and
            // jump to the artist when it arrives (unless the user navigates first).
            deferred = artist;
        }
    }
    _suppressPersist = deferred != nil;   // keep the saved Artist destination until the index arrives
    [self navigateTo:d];
    _suppressPersist = NO;
    _userNavigated = NO;   // restoring is not the user navigating
    _pendingArtistRestore = deferred;      // after navigateTo:, which clears it
}

- (void)navigateTo:(const Destination &)d {
    _userNavigated = YES;
    _pendingArtistRestore = nil;
    _history.push(d);
    [self showCurrent];
}

- (void)goBack {
    if (_history.back()) [self showCurrent];
}

- (void)goForward {
    if (_history.forward()) [self showCurrent];
}

- (void)showCurrent {
    if (!_history.current()) _history.push({DestKind::Albums, ""});
    const Destination d = *_history.current();

    switch (d.kind) {
        case DestKind::Playlist: {
            t_size idx = SVFindPlaylistExact(d.name);
            if (idx == pfc_infinite) {
                _history.remove(d);
                _history.push({DestKind::Albums, ""});
                [self showCurrent];
                return;
            }
            // The one place the shell changes foobar's active playlist: the
            // hosted SimPlaylist always shows the active one.
            try {
                auto pm = playlist_manager::get();
                if (pm->get_active_playlist() != idx) pm->set_active_playlist(idx);
            } catch (...) {}
            [self applyArtistPage:nil];
            [self showHostView:[self playlistHostView]];
            break;
        }
        case DestKind::Artist: {
            NSArray<NSString *> *names = [SVArtistLibrary shared].artistNames;
            NSString *artist = SVToNS(d.name);
            if (names.count > 0 && ![names containsObject:artist]) {
                // The artist is no longer in the library (index is built: it isn't just loading).
                _history.remove(d);
                _history.push({DestKind::Albums, ""});
                [self showCurrent];
                return;
            }
            [self showHostView:[self albumsHostView]];
            [self applyArtistPage:artist];
            break;
        }
        case DestKind::Albums:
            [self showHostView:[self albumsHostView]];
            [self applyArtistPage:nil];
            break;
    }

    [self updateChrome];
    [_sidebar reflectDestination:d];
    [self persistDestination:d];
}

- (void)updateChrome {
    auto cur = _history.current();
    Destination d = cur ? *cur : Destination{DestKind::Albums, ""};
    NSString *title = @"Albums";
    NSString *subtitle = @"";
    if (d.kind != DestKind::Albums) title = SVToNS(d.name);
    if (d.kind == DestKind::Playlist) {
        t_size idx = SVFindPlaylistExact(d.name);
        if (idx != pfc_infinite) {
            t_size n = SVPlaylistItemCount(idx);
            NSString *count = [NSNumberFormatter localizedStringFromNumber:@(n) numberStyle:NSNumberFormatterDecimalStyle];
            subtitle = [NSString stringWithFormat:@"%@ %@", count, n == 1 ? @"track" : @"tracks"];
        }
    }
    _titleLabel.stringValue = title;
    _subtitleLabel.stringValue = subtitle;
    [_navButtons setEnabled:_history.canGoBack() forSegment:0];
    [_navButtons setEnabled:_history.canGoForward() forSegment:1];
}

- (void)persistDestination:(const Destination &)d {
    if (_suppressPersist || _pendingArtistRestore) return;
    shell_config::setInt(shell_config::kLastDestKind, (int64_t)d.kind);
    shell_config::setString(shell_config::kLastDestName, d.name.c_str());
}

- (void)navSegmentClicked:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 0) [self goBack];
    else if (sender.selectedSegment == 1) [self goForward];
}

#pragma mark ShellSidebarDelegate

- (void)sidebar:(ShellSidebarController *)sidebar didChooseDestination:(const Destination &)destination {
    [self navigateTo:destination];
}

#pragma mark Playlist changes

- (void)playlistsDidChange:(NSNotification *)note {
    [_sidebar reloadPlaylists];

    auto missing = [](const Destination &e) {
        return e.kind == DestKind::Playlist && SVFindPlaylistExact(e.name) == pfc_infinite;
    };
    auto cur = _history.current();
    BOOL currentGone = cur && missing(*cur);
    _history.removeIf(missing);
    if (currentGone) {
        [self navigateTo:Destination{DestKind::Albums, ""}];
    } else {
        [self updateChrome];
    }
}

- (void)playlistRenamed:(NSNotification *)note {
    NSString *oldName = note.userInfo[@"old"];
    NSString *newName = note.userInfo[@"new"];
    if (oldName.length == 0 || newName.length == 0) return;
    _history.renamePlaylist(SVToStd(oldName), SVToStd(newName));
    if (auto cur = _history.current()) {
        [_sidebar reflectDestination:*cur];
        [self persistDestination:*cur];
    }
    [self updateChrome];
}

// Keeps the page in sync when something else activates another playlist.
- (void)activePlaylistDidChange:(NSNotification *)note {
    auto cur = _history.current();
    if (!cur || cur->kind != DestKind::Playlist) return;
    // A deleted page is handled by playlistsDidChange: (back to Albums).
    if (SVFindPlaylistExact(cur->name) == pfc_infinite) return;
    t_size active = pfc_infinite;
    try { active = playlist_manager::get()->get_active_playlist(); } catch (...) {}
    std::string name = SVPlaylistName(active);
    if (name.empty() || name == cur->name || name == shellcore::kNowPlayingPlaylistName) return;
    [self navigateTo:Destination{DestKind::Playlist, name}];
}

#pragma mark Keyboard shortcuts

- (BOOL)handleKeyEquivalent:(NSEvent *)event {
    if (event.type != NSEventTypeKeyDown || !self.view.window.isKeyWindow) return NO;
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                      NSEventModifierFlagControl | NSEventModifierFlagShift);
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    if (key.length != 1) return NO;

    if (mods == NSEventModifierFlagCommand) {
        if ([key isEqualToString:@"f"] || [key isEqualToString:@"l"]) {
            [self focusSearch];
            return YES;          // also a deliberate no-op on playlist pages
        }
        if ([key isEqualToString:@"["]) { [self goBack]; return YES; }
        if ([key isEqualToString:@"]"]) { [self goForward]; return YES; }
        if ([key isEqualToString:@"1"]) { [self navigateTo:Destination{DestKind::Albums, ""}]; return YES; }
        if ([key isEqualToString:@"n"]) {
            if (_sidebarItem.isCollapsed) _sidebarItem.collapsed = NO;
            [_sidebar createPlaylistAndBeginRename];
            return YES;
        }
    } else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagControl) && [key isEqualToString:@"s"]) {
        [self toggleSidebar:nil];
        return YES;
    }
    return NO;
}

- (void)focusSearch {
    auto cur = _history.current();
    if (!cur || cur->kind != DestKind::Albums || !_albumsView) return;
    NSSearchField *field = SVFirstVisibleSearchField(_albumsView);
    if (!field) return;
    [self.view.window makeFirstResponder:field];
    [field selectText:nil];
}

@end
