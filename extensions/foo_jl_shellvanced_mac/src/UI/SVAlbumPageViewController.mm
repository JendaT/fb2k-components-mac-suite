//
//  SVAlbumPageViewController.mm
//  foo_jl_shellvanced_mac
//

#import "SVAlbumPageViewController.h"
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <vector>
#include "../fb2k_sdk.h"
#include "../../../../shared/UpNext.h"   // after the SDK include
#import "../../../../shared/UIStyles.h"
#include "../../../../shared/ArtistNames.h"
#include "../Core/ShellCore.h"
#include "../Integration/ShellPlaylists.h"
#import "../Artists/SVArtistLibrary.h"

static const CGFloat kCoverSize = 200.0;
static const CGFloat kPad = 24.0;
static const CGFloat kHeaderHeight = kCoverSize + 2 * kPad;
static const CGFloat kRowHeight = 28.0;

#pragma mark - Small views

// Table that forwards plain key presses (Return, Q) to the page.
@interface SVAlbumTrackTable : NSTableView
@property (nonatomic, copy, nullable) BOOL (^keyHandler)(NSEvent *event);
@end

@implementation SVAlbumTrackTable
- (void)keyDown:(NSEvent *)event {
    if (self.keyHandler && self.keyHandler(event)) return;
    [super keyDown:event];
}
@end

// Borderless artist link: underlined while hovered.
@interface SVAlbumLinkButton : NSButton
@property (nonatomic) BOOL linkEnabled;
- (void)setLinkTitle:(NSString *)title;
@end

@implementation SVAlbumLinkButton {
    NSTrackingArea *_tracking;
    BOOL _hovered;
    NSString *_linkTitle;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.bordered = NO;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.alignment = NSTextAlignmentLeft;
        [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}
- (void)setLinkTitle:(NSString *)title { _linkTitle = [title copy]; [self refresh]; }
- (void)setLinkEnabled:(BOOL)linkEnabled {
    _linkEnabled = linkEnabled;
    self.enabled = linkEnabled;
    [self refresh];
}
- (void)refresh {
    NSMutableDictionary *attrs = [@{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: _linkEnabled ? fb2k_ui::textColor() : fb2k_ui::secondaryTextColor(),
    } mutableCopy];
    if (_linkEnabled && _hovered) attrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
    self.attributedTitle = [[NSAttributedString alloc] initWithString:_linkTitle ?: @"" attributes:attrs];
    [self invalidateIntrinsicContentSize];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)mouseEntered:(NSEvent *)event { _hovered = YES; [self refresh]; if (_linkEnabled) [[NSCursor pointingHandCursor] push]; }
- (void)mouseExited:(NSEvent *)event  { _hovered = NO;  [self refresh]; if (_linkEnabled) [NSCursor pop]; }
@end

static NSImage *SVDecodeThumbnail(NSData *data, CGFloat maxPixels) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!src) return nil;
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixels),
    };
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    CFRelease(src);
    if (!cg) return nil;
    NSImage *img = [[NSImage alloc] initWithCGImage:cg size:NSZeroSize];
    CGImageRelease(cg);
    return img;
}

#pragma mark - Controller

@interface SVAlbumPageViewController () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSMenuItemValidation>
@end

@implementation SVAlbumPageViewController {
    // Header
    NSImageView *_cover;
    NSTextField *_captionLabel;
    NSTextField *_titleLabel;
    SVAlbumLinkButton *_artistLink;
    NSTextField *_metaLabel;
    NSButton *_playButton;
    NSButton *_shuffleButton;
    SVAlbumTrackTable *_table;
    NSTableColumn *_artistColumn;

    // Data
    NSString *_key;
    NSString *_albumTitle;
    NSString *_albumArtist;
    NSString *_year;
    NSString *_linkArtist;               // index spelling of the primary artist; nil = not linkable
    metadb_handle_list _handles;
    NSMutableArray<NSString *> *_titles;
    NSMutableArray<NSString *> *_artists;
    NSMutableArray<NSString *> *_lengths;
    NSUInteger _token;                   // discards stale async results
}

- (NSString *)albumKey { return _key; }
- (NSTableView *)tableView { return _table; }

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark View

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 680, 560)];
    root.material = NSVisualEffectMaterialSidebar;           // same backdrop as AlbumViewVanced
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateFollowsWindowActiveState;
    root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = root;

    _titles = [NSMutableArray array];
    _artists = [NSMutableArray array];
    _lengths = [NSMutableArray array];

    // --- Header
    NSView *header = [[NSView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;

    _cover = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _cover.imageScaling = NSImageScaleProportionallyUpOrDown;
    _cover.translatesAutoresizingMaskIntoConstraints = NO;
    _cover.wantsLayer = YES;
    _cover.layer.cornerRadius = 8;
    _cover.layer.masksToBounds = YES;
    _cover.layer.backgroundColor = [[NSColor labelColor] colorWithAlphaComponent:0.08].CGColor;
    _cover.accessibilityLabel = @"Album cover";

    _captionLabel = [NSTextField labelWithString:@"Album"];
    _captionLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _captionLabel.textColor = fb2k_ui::secondaryTextColor();
    _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;

    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.font = [NSFont systemFontOfSize:40 weight:NSFontWeightBold];
    _titleLabel.textColor = fb2k_ui::textColor();
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_titleLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];

    _artistLink = [[SVAlbumLinkButton alloc] initWithFrame:NSZeroRect];
    _artistLink.target = self;
    _artistLink.action = @selector(artistClicked:);

    _metaLabel = [NSTextField labelWithString:@""];
    _metaLabel.font = [NSFont systemFontOfSize:13];
    _metaLabel.textColor = fb2k_ui::secondaryTextColor();
    _metaLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [_metaLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *meta = [NSStackView stackViewWithViews:@[_artistLink, _metaLabel]];
    meta.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    meta.spacing = 0;
    meta.alignment = NSLayoutAttributeFirstBaseline;
    meta.translatesAutoresizingMaskIntoConstraints = NO;

    _playButton = [NSButton buttonWithTitle:@"Play" target:self action:@selector(playClicked:)];
    _playButton.bezelStyle = NSBezelStyleRounded;
    _playButton.bezelColor = [NSColor controlAccentColor];
    _playButton.keyEquivalent = @"";
    _playButton.translatesAutoresizingMaskIntoConstraints = NO;

    _shuffleButton = [NSButton buttonWithTitle:@"Shuffle" target:self action:@selector(shuffleClicked:)];
    _shuffleButton.bezelStyle = NSBezelStyleRounded;
    _shuffleButton.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSView *v in @[_cover, _captionLabel, _titleLabel, meta, _playButton, _shuffleButton]) [header addSubview:v];
    [root addSubview:header];

    // --- Track table
    _table = [[SVAlbumTrackTable alloc] initWithFrame:NSZeroRect];
    _table.style = NSTableViewStyleFullWidth;
    _table.backgroundColor = [NSColor clearColor];
    _table.rowHeight = kRowHeight;
    _table.intercellSpacing = NSMakeSize(8, 0);
    _table.allowsMultipleSelection = YES;
    _table.allowsEmptySelection = YES;
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(rowDoubleClicked:);
    _table.accessibilityLabel = @"Tracks";

    struct Col { NSString *ident; NSString *title; CGFloat min, max, width; };
    const Col cols[] = {
        {@"num",    @"#",      40,  48,  44},
        {@"title",  @"Title", 140, 4000, 320},
        {@"artist", @"Artist", 100, 4000, 200},
        {@"time",   @"Time",   56,  72,  64},
    };
    for (const Col &c : cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        col.title = c.title;
        col.minWidth = c.min;
        col.maxWidth = c.max;
        col.width = c.width;
        col.resizingMask = (c.max > 1000) ? NSTableColumnAutoresizingMask : NSTableColumnNoResizing;
        if ([c.ident isEqualToString:@"time"] || [c.ident isEqualToString:@"num"])
            col.headerCell.alignment = NSTextAlignmentRight;
        [_table addTableColumn:col];
        if ([c.ident isEqualToString:@"artist"]) _artistColumn = col;
    }
    _artistColumn.hidden = YES;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    _table.menu = menu;

    __weak SVAlbumPageViewController *weakSelf = self;
    _table.keyHandler = ^BOOL(NSEvent *event) { return [weakSelf handleTableKey:event]; };

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;
    scroll.documentView = _table;
    [root addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:kHeaderHeight],

        [_cover.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:kPad],
        [_cover.topAnchor constraintEqualToAnchor:header.topAnchor constant:kPad],
        [_cover.widthAnchor constraintEqualToConstant:kCoverSize],
        [_cover.heightAnchor constraintEqualToConstant:kCoverSize],

        [_captionLabel.leadingAnchor constraintEqualToAnchor:_cover.trailingAnchor constant:kPad],
        [_captionLabel.bottomAnchor constraintEqualToAnchor:_titleLabel.topAnchor constant:-2],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_captionLabel.leadingAnchor],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-kPad],
        [_titleLabel.bottomAnchor constraintEqualToAnchor:meta.topAnchor constant:-6],

        [meta.leadingAnchor constraintEqualToAnchor:_captionLabel.leadingAnchor],
        [meta.trailingAnchor constraintLessThanOrEqualToAnchor:header.trailingAnchor constant:-kPad],
        [meta.bottomAnchor constraintEqualToAnchor:_playButton.topAnchor constant:-14],

        [_playButton.leadingAnchor constraintEqualToAnchor:_captionLabel.leadingAnchor],
        [_playButton.bottomAnchor constraintEqualToAnchor:_cover.bottomAnchor],
        [_playButton.widthAnchor constraintEqualToConstant:90],

        [_shuffleButton.leadingAnchor constraintEqualToAnchor:_playButton.trailingAnchor constant:10],
        [_shuffleButton.centerYAnchor constraintEqualToAnchor:_playButton.centerYAnchor],
        [_shuffleButton.widthAnchor constraintEqualToConstant:90],

        [scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:kPad - 8],
        [scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-(kPad - 8)],
        [scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artistLibraryChanged:)
                                                 name:SVArtistLibraryDidChangeNotification object:nil];
    [self updateEnabledState];
}

#pragma mark Loading

- (void)showAlbumKey:(NSString *)key info:(NSDictionary<NSString *, id> *)info {
    [self view];   // make sure the UI exists
    if (key.length == 0) return;
    const NSUInteger token = ++_token;

    NSString *title = [info[@"title"] isKindOfClass:[NSString class]] ? info[@"title"] : nil;
    NSString *artist = [info[@"artist"] isKindOfClass:[NSString class]] ? info[@"artist"] : nil;
    NSString *year = [info[@"year"] isKindOfClass:[NSString class]] ? info[@"year"] : nil;
    NSArray *paths = [info[@"paths"] isKindOfClass:[NSArray class]] ? info[@"paths"] : nil;
    if (!title) title = SVToNS(shellcore::albumKeyTitle(SVToStd(key)));
    if (!artist) artist = SVToNS(shellcore::albumKeyArtist(SVToStd(key)));

    // Same album already shown: nothing to reload.
    if ([_key isEqualToString:key] && _handles.get_count() > 0) return;

    _key = [key copy];
    [self clearTracks];
    [self applyHeaderTitle:title artist:artist year:year ?: @"" handles:NULL];

    if (paths.count > 0) {
        metadb_handle_list handles;
        try {
            auto db = metadb::get();
            for (id p in paths) {
                if (![p isKindOfClass:[NSString class]] || [(NSString *)p length] == 0) continue;
                metadb_handle_ptr h = db->handle_create([(NSString *)p UTF8String], 0);
                if (h.is_valid()) handles.add_item(h);
            }
        } catch (...) { handles.remove_all(); }
        if (handles.get_count() > 0) {
            [self applyHandles:handles title:title artist:artist year:year ?: @""];
            return;
        }
    }
    [self scanLibraryForKey:key title:title artist:artist token:token];
}

// No usable paths (relaunch, back/forward after a library change): find the album in the library.
- (void)scanLibraryForKey:(NSString *)key title:(NSString *)title artist:(NSString *)artist token:(NSUInteger)token {
    metadb_handle_list all;
    try { library_manager::get()->get_all_items(all); } catch (...) {}
    if (all.get_count() == 0) { [self reportUnresolved:key token:token]; return; }

    const std::string wantTitle = SVToStd(title), wantArtist = SVToStd(artist);
    __weak SVAlbumPageViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        metadb_handle_list found;
        std::string year;
        try {
            auto script = titleformat_compiler::get()->compile_force(
                "%album artist%$char(1)%album%$char(1)%discnumber%$char(1)%tracknumber%$char(1)%date%");
            struct Hit { int disc, track; t_size idx; };
            std::vector<Hit> hits;
            pfc::string8 out;
            const bool variousWanted = artistnames::isVariousArtists(wantArtist);
            for (t_size i = 0; i < all.get_count(); i++) {
                out.reset();
                all[i]->format_title(nullptr, out, script, nullptr);
                std::string parts[5];
                size_t field = 0;
                for (const char *p = out.c_str(); *p; p++) {
                    if (*p == '\x01') { if (++field > 4) break; }
                    else parts[field].push_back(*p);
                }
                if (parts[1] != wantTitle) continue;
                if (parts[0] != wantArtist && !variousWanted) continue;
                if (year.empty()) year = parts[4];
                hits.push_back({atoi(parts[2].c_str()), atoi(parts[3].c_str()), i});
            }
            std::stable_sort(hits.begin(), hits.end(), [](const Hit &a, const Hit &b) {
                return a.disc != b.disc ? a.disc < b.disc : a.track < b.track;
            });
            for (const Hit &h : hits) found.add_item(all[h.idx]);
        } catch (...) { found.remove_all(); }

        dispatch_async(dispatch_get_main_queue(), ^{
            SVAlbumPageViewController *s = weakSelf;
            if (!s || token != s->_token) return;
            if (found.get_count() == 0) { [s reportUnresolved:key token:token]; return; }
            [s applyHandles:found title:title artist:artist year:SVToNS(year)];
        });
    });
}

- (void)reportUnresolved:(NSString *)key token:(NSUInteger)token {
    if (token != _token) return;
    // Next turn: the caller may be in the middle of navigating.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (token == self->_token && self.onUnresolved) self.onUnresolved(key);
    });
}

- (void)clearTracks {
    _handles.remove_all();
    [_titles removeAllObjects];
    [_artists removeAllObjects];
    [_lengths removeAllObjects];
    _artistColumn.hidden = YES;
    [_table reloadData];
    [self updateEnabledState];
}

- (void)applyHandles:(metadb_handle_list_cref)handles title:(NSString *)title artist:(NSString *)artist year:(NSString *)year {
    _handles = handles;
    [_titles removeAllObjects];
    [_artists removeAllObjects];
    [_lengths removeAllObjects];

    double total = 0;
    BOOL anyDiffers = NO;
    NSString *albumArtistFold = [self fold:artist];
    const BOOL va = artist.length == 0 || artistnames::isVariousArtists(SVToStd(artist));
    try {
        auto script = titleformat_compiler::get()->compile_force("%title%$char(1)%artist%");
        pfc::string8 out;
        for (t_size i = 0; i < _handles.get_count(); i++) {
            out.reset();
            _handles[i]->format_title(nullptr, out, script, nullptr);
            std::string t, a;
            bool second = false;
            for (const char *p = out.c_str(); *p; p++) {
                if (*p == '\x01') second = true;
                else (second ? a : t).push_back(*p);
            }
            if (t.empty()) {   // untagged: fall back to the file name
                pfc::string8 fn = pfc::string_filename_ext(_handles[i]->get_path());
                t = fn.c_str();
            }
            NSString *trackArtist = SVToNS(a);
            if (![[self fold:trackArtist] isEqualToString:albumArtistFold]) anyDiffers = YES;
            [_titles addObject:SVToNS(t)];
            [_artists addObject:trackArtist];
            double len = _handles[i]->get_length();
            if (len > 0) total += len;
            [_lengths addObject:SVToNS(shellcore::formatTrackLength(len))];
        }
    } catch (...) {}
    _artistColumn.hidden = !(anyDiffers || va);
    [self applyHeaderTitle:title artist:artist year:year handles:&total];
    [_table reloadData];
    [_table scrollRowToVisible:0];
    [self updateEnabledState];
    [self loadCoverForHandle:_handles.get_count() ? _handles[0] : metadb_handle_ptr() token:_token];
}

- (NSString *)fold:(NSString *)s {
    return [(s ?: @"") stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
}

- (void)applyHeaderTitle:(NSString *)title artist:(NSString *)artist year:(NSString *)year handles:(double *)totalSeconds {
    _albumTitle = [title copy];
    _albumArtist = [artist copy];
    _year = [year copy];
    _titleLabel.stringValue = title ?: @"";

    NSMutableArray<NSString *> *rest = [NSMutableArray array];
    NSString *y = SVToNS(shellcore::albumYear(SVToStd(year)));
    if (y.length) [rest addObject:y];
    if (totalSeconds) [rest addObject:SVToNS(shellcore::albumStats(_handles.get_count(), *totalSeconds))];
    NSString *tail = [rest componentsJoinedByString:@" • "];

    _artistLink.hidden = artist.length == 0;
    [_artistLink setLinkTitle:artist ?: @""];
    _metaLabel.stringValue = artist.length && tail.length ? [@" • " stringByAppendingString:tail] : tail;
    [self updateArtistLink];
}

// The artist name becomes a link only when the primary artist is in the index.
- (void)updateArtistLink {
    _linkArtist = nil;
    if (_albumArtist.length) {
        auto parts = artistnames::splitArtists(SVToStd(_albumArtist));
        if (!parts.empty() && !artistnames::isVariousArtists(SVToStd(_albumArtist))) {
            const std::string wantKey = artistnames::artistKey(parts[0]);
            if (!wantKey.empty()) {
                for (NSString *name in [SVArtistLibrary shared].artistNames) {
                    if (artistnames::artistKey(SVToStd(name)) == wantKey) { _linkArtist = name; break; }
                }
            }
        }
    }
    _artistLink.linkEnabled = _linkArtist != nil;
    _artistLink.toolTip = _linkArtist ? [NSString stringWithFormat:@"Go to %@", _linkArtist] : nil;
}

- (void)artistLibraryChanged:(NSNotification *)note {
    [self updateArtistLink];
}

- (void)updateEnabledState {
    const BOOL has = _handles.get_count() > 0;
    _playButton.enabled = has;
    _shuffleButton.enabled = has;
}

- (void)loadCoverForHandle:(metadb_handle_ptr)handle token:(NSUInteger)token {
    _cover.image = nil;
    if (handle.is_empty()) return;
    __weak SVAlbumPageViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSImage *image = nil;
        try {
            abort_callback_dummy abort;
            auto manager = album_art_manager_v2::get();
            metadb_handle_list items;
            items.add_item(handle);
            pfc::list_t<GUID> ids;
            ids.add_item(album_art_ids::cover_front);
            auto extractor = manager->open(items, ids, abort);
            album_art_data_ptr art;
            if (extractor->query(album_art_ids::cover_front, art, abort) && art.is_valid() && art->size() > 0) {
                NSData *data = [NSData dataWithBytes:art->data() length:art->size()];
                image = SVDecodeThumbnail(data, kCoverSize * 2);   // 2x for retina
            }
        } catch (...) {}
        dispatch_async(dispatch_get_main_queue(), ^{
            SVAlbumPageViewController *s = weakSelf;
            if (s && token == s->_token) s->_cover.image = image;
        });
    });
}

#pragma mark Playback

- (const char *)sourceLabel {
    static thread_local std::string label;
    label = SVToStd(_albumTitle);
    return label.c_str();   // bare album title; the popover adds "Next from: "
}

- (metadb_handle_list)handlesAtRows:(NSIndexSet *)rows {
    metadb_handle_list out;
    for (NSUInteger idx = rows.firstIndex; idx != NSNotFound; idx = [rows indexGreaterThanIndex:idx]) {
        if (idx < _handles.get_count()) out.add_item(_handles[idx]);
    }
    return out;
}

- (void)playFromRow:(NSInteger)row {
    if (_handles.get_count() == 0) return;
    if (row < 0 || row >= (NSInteger)_handles.get_count()) row = 0;
    try {
        upnext::fb::playNow(_handles, (t_size)row, [self sourceLabel]);   // only Now Playing changes
    } catch (...) {
        console::info("[ShellVanced] play album failed");
    }
}

- (void)playClicked:(id)sender { [self playFromRow:0]; }

- (void)shuffleClicked:(id)sender {
    const t_size n = _handles.get_count();
    if (n == 0) return;
    std::vector<t_size> order(n);
    for (t_size i = 0; i < n; i++) order[i] = i;
    for (t_size i = n; i > 1; i--) std::swap(order[i - 1], order[arc4random_uniform((uint32_t)i)]);
    metadb_handle_list shuffled;
    for (t_size idx : order) shuffled.add_item(_handles[idx]);
    try {
        upnext::fb::playNow(shuffled, 0, [self sourceLabel]);
    } catch (...) {
        console::info("[ShellVanced] shuffle album failed");
    }
}

- (void)artistClicked:(id)sender {
    if (_linkArtist && self.onOpenArtist) self.onOpenArtist(_linkArtist);
}

- (void)rowDoubleClicked:(id)sender {
    NSInteger row = _table.clickedRow;
    if (row >= 0) [self playFromRow:row];
}

// Rows an action applies to: the selection, or the clicked row when it isn't part of it.
- (NSIndexSet *)targetRows {
    NSInteger clicked = _table.clickedRow;
    if (clicked >= 0 && ![_table.selectedRowIndexes containsIndex:(NSUInteger)clicked])
        return [NSIndexSet indexSetWithIndex:(NSUInteger)clicked];
    return _table.selectedRowIndexes;
}

- (BOOL)handleTableKey:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                      NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (mods != 0 || event.charactersIgnoringModifiers.length != 1) return NO;
    unichar c = [event.charactersIgnoringModifiers characterAtIndex:0];
    if (c == '\r' || c == 3) {
        NSInteger row = _table.selectedRow;
        if (row < 0) return NO;
        [self playFromRow:row];
        return YES;
    }
    if (c == 'q' || c == 'Q') {
        metadb_handle_list items = [self handlesAtRows:_table.selectedRowIndexes];
        if (items.get_count() == 0) return NO;
        [self queue:items next:NO];
        return YES;
    }
    return NO;
}

- (void)queue:(metadb_handle_list_cref)items next:(BOOL)next {
    try {
        if (next) upnext::fb::playNext(items);
        else upnext::fb::addToQueue(items);
    } catch (...) {
        console::info("[ShellVanced] queue album tracks failed");
    }
}

#pragma mark Context menu

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSIndexSet *rows = [self targetRows];
    if (rows.count == 0) return;
    // Right-click on an unselected row selects it, like Finder.
    NSInteger clicked = _table.clickedRow;
    if (clicked >= 0 && ![_table.selectedRowIndexes containsIndex:(NSUInteger)clicked])
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)clicked] byExtendingSelection:NO];

    NSMenuItem *play = [menu addItemWithTitle:@"Play" action:@selector(menuPlay:) keyEquivalent:@""];
    NSMenuItem *next = [menu addItemWithTitle:@"Play Next" action:@selector(menuPlayNext:) keyEquivalent:@""];
    NSMenuItem *add = [menu addItemWithTitle:@"Add to Queue" action:@selector(menuAddToQueue:) keyEquivalent:@""];
    for (NSMenuItem *item in @[play, next, add]) {
        item.target = self;
        item.representedObject = rows;
    }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    return _handles.get_count() > 0;
}

- (void)menuPlay:(NSMenuItem *)sender {
    NSIndexSet *rows = sender.representedObject;
    if (rows.count == 0) return;
    if (rows.count == 1) { [self playFromRow:(NSInteger)rows.firstIndex]; return; }
    metadb_handle_list items = [self handlesAtRows:rows];   // several rows: play just those
    if (items.get_count() == 0) return;
    try {
        upnext::fb::playNow(items, 0, [self sourceLabel]);
    } catch (...) {
        console::info("[ShellVanced] play tracks failed");
    }
}

- (void)menuPlayNext:(NSMenuItem *)sender {
    metadb_handle_list items = [self handlesAtRows:sender.representedObject];
    if (items.get_count()) [self queue:items next:YES];
}

- (void)menuAddToQueue:(NSMenuItem *)sender {
    metadb_handle_list items = [self handlesAtRows:sender.representedObject];
    if (items.get_count()) [self queue:items next:NO];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_handles.get_count();
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSString *ident = column.identifier;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = ident;
        NSTextField *label = [NSTextField labelWithString:@""];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        const BOOL numeric = [ident isEqualToString:@"num"] || [ident isEqualToString:@"time"];
        if (numeric) {
            label.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
            label.alignment = NSTextAlignmentRight;
            label.textColor = [NSColor secondaryLabelColor];
        } else if ([ident isEqualToString:@"artist"]) {
            label.font = [NSFont systemFontOfSize:13];
            label.textColor = [NSColor secondaryLabelColor];
        } else {
            label.font = [NSFont systemFontOfSize:13];
        }
        [cell addSubview:label];
        cell.textField = label;
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    NSUInteger i = (NSUInteger)row;
    NSString *text = @"";
    if (i < _titles.count) {
        if ([ident isEqualToString:@"num"]) text = [NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)];
        else if ([ident isEqualToString:@"title"]) text = _titles[i];
        else if ([ident isEqualToString:@"artist"]) text = _artists[i];
        else if ([ident isEqualToString:@"time"]) text = _lengths[i];
    }
    cell.textField.stringValue = text;
    return cell;
}

@end
