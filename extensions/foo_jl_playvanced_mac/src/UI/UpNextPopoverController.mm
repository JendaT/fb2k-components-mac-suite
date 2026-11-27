#import "UpNextPopoverController.h"
#include "../fb2k_sdk.h"
#import "../../../../shared/UpNext.h"
#import "../../../../shared/UIStyles.h"
#import "../Core/ArtworkFetcher.h"

#include <vector>
#include <set>

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

namespace {

enum class RowKind { Header, Track };
enum class Section { Current, Queued, Next };

struct UpNextRow {
    RowKind kind;
    Section section;
    size_t index;               // Current/Next: playlist index; Queued: queue index
    metadb_handle_ptr handle;   // Track rows only
};

static const CGFloat kPopoverWidth   = 360.0;
static const CGFloat kPopoverHeight  = 480.0;
static const CGFloat kTrackRowHeight = 46.0;
static const CGFloat kHeaderRowHeight = 30.0;
static const CGFloat kThumbSize      = 34.0;
static const NSTimeInterval kReopenGuard = 0.25;

static NSPasteboardType const kUpNextRowPBType = @"com.foobar2000.playvanced.upnext.rows";

static NSString *formatDuration(double seconds) {
    if (seconds <= 0 || !isfinite(seconds)) return @"";
    long total = (long)llround(seconds);
    long h = total / 3600, m = (total % 3600) / 60, s = total % 60;
    if (h > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, s];
    return [NSString stringWithFormat:@"%ld:%02ld", m, s];
}

static NSString *nsString(const pfc::string8 &s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

#define FOR_EACH_INDEX(set, var) \
    for (NSUInteger var = (set).firstIndex; var != NSNotFound; var = [(set) indexGreaterThanIndex:var])

static NSNumber *selectionKey(Section section, size_t index) {
    return @(((unsigned long long)section << 48) | (unsigned long long)index);
}

} // namespace

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------

@class UpNextTableView;

@protocol UpNextTableActions <NSObject>
- (void)upNextRemoveSelected;
- (void)upNextPlaySelected;
- (nullable NSMenu *)upNextMenuForRow:(NSInteger)row;
@end

@interface UpNextTableView : NSTableView
@property (nonatomic, weak) id<UpNextTableActions> actions;
@end

@implementation UpNextTableView

// Runs before the main menu's key equivalents, so a menu item bound to plain
// Delete/Return can't act on the user's playlist while the popover has focus.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder == self && [self handleEditingKey:event]) return YES;
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    if ([self handleEditingKey:event]) return;
    [super keyDown:event];
}

- (BOOL)handleEditingKey:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                       NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (mods == 0 && (c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteFunctionKey)) {
        [self.actions upNextRemoveSelected];
        return YES;
    }
    if (mods == 0 && (c == NSCarriageReturnCharacter || c == NSEnterCharacter)) {
        [self.actions upNextPlaySelected];
        return YES;
    }
    return NO;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    if (row < 0) return nil;
    return [self.actions upNextMenuForRow:row];
}

@end

@interface UpNextHeaderCell : NSTableCellView
@property (nonatomic, strong) NSTextField *label;
@end

@implementation UpNextHeaderCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _label = [NSTextField labelWithString:@""];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.lineBreakMode = NSLineBreakByTruncatingTail;
        [_label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_label.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-6],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-5],
        ]];
    }
    return self;
}

@end

@interface UpNextTrackCell : NSTableCellView
@property (nonatomic, strong) NSImageView *art;
@property (nonatomic, strong) NSTextField *title;
@property (nonatomic, strong) NSTextField *artist;
@property (nonatomic, strong) NSTextField *duration;
@property (nonatomic, copy, nullable) NSString *artPath;
@end

@implementation UpNextTrackCell

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _art = [[NSImageView alloc] init];
        _art.translatesAutoresizingMaskIntoConstraints = NO;
        _art.imageScaling = NSImageScaleProportionallyUpOrDown;
        _art.wantsLayer = YES;
        _art.layer.cornerRadius = 4.0;
        _art.layer.masksToBounds = YES;
        [self addSubview:_art];

        _title = [NSTextField labelWithString:@""];
        _title.translatesAutoresizingMaskIntoConstraints = NO;
        _title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        _title.lineBreakMode = NSLineBreakByTruncatingTail;
        [_title setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:_title];

        _artist = [NSTextField labelWithString:@""];
        _artist.translatesAutoresizingMaskIntoConstraints = NO;
        _artist.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        _artist.textColor = [NSColor secondaryLabelColor];
        _artist.lineBreakMode = NSLineBreakByTruncatingTail;
        [_artist setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                          forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:_artist];

        _duration = [NSTextField labelWithString:@""];
        _duration.translatesAutoresizingMaskIntoConstraints = NO;
        _duration.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        _duration.textColor = [NSColor secondaryLabelColor];
        _duration.alignment = NSTextAlignmentRight;
        [_duration setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_duration setContentHuggingPriority:NSLayoutPriorityRequired
                              forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self addSubview:_duration];

        [NSLayoutConstraint activateConstraints:@[
            [_art.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_art.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_art.widthAnchor constraintEqualToConstant:kThumbSize],
            [_art.heightAnchor constraintEqualToConstant:kThumbSize],

            [_title.leadingAnchor constraintEqualToAnchor:_art.trailingAnchor constant:10],
            [_title.trailingAnchor constraintLessThanOrEqualToAnchor:_duration.leadingAnchor constant:-10],
            [_title.lastBaselineAnchor constraintEqualToAnchor:self.centerYAnchor constant:-2],

            [_artist.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_artist.trailingAnchor constraintLessThanOrEqualToAnchor:_duration.leadingAnchor constant:-10],
            [_artist.topAnchor constraintEqualToAnchor:self.centerYAnchor constant:2],

            [_duration.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_duration.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

@end

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

@interface UpNextPopoverController () <NSPopoverDelegate, NSTableViewDataSource, NSTableViewDelegate, UpNextTableActions>
@end

@implementation UpNextPopoverController {
    NSPopover        *_popover;
    NSViewController *_contentController;
    UpNextTableView  *_table;
    NSScrollView     *_scroll;
    NSTextField      *_titleLabel;
    NSTextField      *_shuffleNote;
    NSButton         *_clearButton;
    NSView           *_emptyView;

    std::vector<UpNextRow> _rows;
    NSString *_nextLabel;
    BOOL      _nextEditable;      // "Next from" rows belong to Now Playing
    t_size    _nowPlayingIndex;   // playlist index of Now Playing at last reload (or infinite)
    size_t    _nextFrom;          // playlist index of first "Next from" row
    size_t    _nextCount;
    NSInteger _nextRowStart;      // table row of first "Next from" track row (-1 if none)

    BOOL           _reloadScheduled;
    NSTimeInterval _lastCloseTime;
    NSIndexSet    *_draggedRows;

    titleformat_object::ptr _tfTitle;
    titleformat_object::ptr _tfArtist;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nowPlayingIndex = pfc_infinite;
        _nextRowStart = -1;
        auto compiler = titleformat_compiler::get();
        compiler->compile_safe_ex(_tfTitle, "%title%", "?");
        compiler->compile_safe_ex(_tfArtist, "$if2(%artist%,%album artist%)", "");
    }
    return self;
}

- (void)dealloc {
    [_popover close];
}

#pragma mark - Popover

- (BOOL)isShown {
    return _popover != nil && _popover.isShown;
}

- (NSWindow *)popoverWindow {
    return self.isShown ? _contentController.view.window : nil;
}

- (void)buildPopoverIfNeeded {
    if (_popover) return;

    _contentController = [[NSViewController alloc] init];
    _contentController.view = [self buildContentView];

    _popover = [[NSPopover alloc] init];
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.animates = YES;
    _popover.contentSize = NSMakeSize(kPopoverWidth, kPopoverHeight);
    _popover.contentViewController = _contentController;
    _popover.delegate = self;
}

- (NSView *)buildContentView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kPopoverWidth, kPopoverHeight)];

    _titleLabel = [NSTextField labelWithString:@"Up Next"];
    _titleLabel.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    _titleLabel.textColor = [NSColor labelColor];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:_titleLabel];

    _clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearPressed:)];
    _clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    _clearButton.bordered = NO;
    _clearButton.attributedTitle = [[NSAttributedString alloc] initWithString:@"Clear" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor controlAccentColor],
    }];
    _clearButton.toolTip = @"Remove all upcoming tracks from Now Playing";
    [root addSubview:_clearButton];

    // Shuffle note: small symbol + text, collapsed when shuffle is off.
    NSMutableAttributedString *note = [[NSMutableAttributedString alloc] init];
    NSImage *shuffleImg = [NSImage imageWithSystemSymbolName:@"shuffle" accessibilityDescription:nil];
    if (shuffleImg) {
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:10
                                                                                          weight:NSFontWeightMedium];
        NSTextAttachment *att = [[NSTextAttachment alloc] init];
        att.image = [shuffleImg imageWithSymbolConfiguration:cfg];
        [note appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
        [note appendAttributedString:[[NSAttributedString alloc] initWithString:@" "]];
    }
    [note appendAttributedString:[[NSAttributedString alloc] initWithString:@"Shuffle is on — order may differ"]];
    [note addAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
    } range:NSMakeRange(0, note.length)];
    _shuffleNote = [NSTextField labelWithAttributedString:note];
    _shuffleNote.translatesAutoresizingMaskIntoConstraints = NO;
    _shuffleNote.hidden = YES;

    NSStackView *headerStack = [NSStackView stackViewWithViews:@[_shuffleNote]];
    headerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerStack.alignment = NSLayoutAttributeLeading;
    headerStack.spacing = 0;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:headerStack];

    NSBox *separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:separator];

    _table = [[UpNextTableView alloc] initWithFrame:NSZeroRect];
    _table.actions = self;
    _table.style = NSTableViewStyleInset;
    _table.headerView = nil;
    _table.backgroundColor = [NSColor clearColor];
    _table.intercellSpacing = NSMakeSize(0, 0);
    _table.allowsMultipleSelection = YES;
    _table.allowsEmptySelection = YES;
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(rowDoubleClicked:);
    [_table registerForDraggedTypes:@[kUpNextRowPBType]];
    [_table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [_table setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:col];

    _scroll = [[NSScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.documentView = _table;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.drawsBackground = NO;
    _scroll.borderType = NSNoBorder;
    [root addSubview:_scroll];

    _emptyView = [self buildEmptyView];
    [root addSubview:_emptyView];

    [NSLayoutConstraint activateConstraints:@[
        [_titleLabel.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:18],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_clearButton.leadingAnchor constant:-8],

        [_clearButton.firstBaselineAnchor constraintEqualToAnchor:_titleLabel.firstBaselineAnchor],
        [_clearButton.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16],

        [headerStack.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [headerStack.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [headerStack.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-16],

        [separator.topAnchor constraintEqualToAnchor:headerStack.bottomAnchor constant:10],
        [separator.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],

        [_scroll.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],

        [_emptyView.centerXAnchor constraintEqualToAnchor:_scroll.centerXAnchor],
        [_emptyView.centerYAnchor constraintEqualToAnchor:_scroll.centerYAnchor constant:-20],
        [_emptyView.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-48],
    ]];

    return root;
}

- (NSView *)buildEmptyView {
    NSImageView *icon = [[NSImageView alloc] init];
    NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:30
                                                                                      weight:NSFontWeightLight];
    icon.image = [[NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:nil]
                  imageWithSymbolConfiguration:cfg];
    icon.contentTintColor = [NSColor tertiaryLabelColor];

    NSTextField *title = [NSTextField labelWithString:@"Nothing up next"];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    title.textColor = [NSColor secondaryLabelColor];

    NSTextField *hint = [NSTextField wrappingLabelWithString:@"Tracks you play next or add to the queue will show up here."];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor tertiaryLabelColor];
    hint.alignment = NSTextAlignmentCenter;
    hint.preferredMaxLayoutWidth = 240;

    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, title, hint]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 6;
    [stack setCustomSpacing:10 afterView:icon];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.hidden = YES;
    return stack;
}

- (void)showRelativeToView:(NSView *)anchor {
    if (!anchor.window) return;
    [self buildPopoverIfNeeded];
    if (_popover.isShown) return;

    [self reloadNow];

    // Bar sits at the bottom of the window: open upwards.
    NSRectEdge edge = anchor.isFlipped ? NSRectEdgeMinY : NSRectEdgeMaxY;
    [_popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:edge];
    [_contentController.view.window makeFirstResponder:_table];
    [self scrollToTop];
    if (self.visibilityChanged) self.visibilityChanged(YES);
}

- (void)close {
    if (_popover.isShown) [_popover performClose:nil];
}

- (void)toggleRelativeToView:(NSView *)anchor {
    if (self.isShown) {
        [self close];
        return;
    }
    // A click on the anchor while shown first closes the transient popover
    // (mouse-down outside), then fires the button action: don't reopen.
    if ([NSDate timeIntervalSinceReferenceDate] - _lastCloseTime < kReopenGuard) return;
    [self showRelativeToView:anchor];
}

- (void)popoverDidClose:(NSNotification *)notification {
    _lastCloseTime = [NSDate timeIntervalSinceReferenceDate];
    _draggedRows = nil;
    if (self.visibilityChanged) self.visibilityChanged(NO);
}

- (void)scrollToTop {
    if (_rows.empty()) return;
    [_table scrollRowToVisible:0];
}

#pragma mark - Reload

- (void)setNeedsReload {
    if (!self.isShown || _reloadScheduled) return;
    _reloadScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_reloadScheduled = NO;
        if (strongSelf.isShown) [strongSelf reloadNow];
    });
}

- (void)reloadNow {
    // Preserve selection by (section, index).
    NSMutableSet<NSNumber *> *selectedKeys = [NSMutableSet set];
    [_table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        if (row < self->_rows.size() && self->_rows[row].kind == RowKind::Track) {
            [selectedKeys addObject:selectionKey(self->_rows[row].section, self->_rows[row].index)];
        }
    }];

    [self rebuildModel];
    [_table reloadData];

    NSMutableIndexSet *reselect = [NSMutableIndexSet indexSet];
    if (selectedKeys.count) {
        for (size_t i = 0; i < _rows.size(); ++i) {
            if (_rows[i].kind != RowKind::Track) continue;
            if ([selectedKeys containsObject:selectionKey(_rows[i].section, _rows[i].index)]) [reselect addIndex:i];
        }
    }
    [_table selectRowIndexes:reselect byExtendingSelection:NO];

    BOOL empty = _rows.empty();
    _emptyView.hidden = !empty;
    _scroll.hidden = empty;
    _clearButton.hidden = !(_nextEditable && _nextCount > 0);
}

- (void)rebuildModel {
    _rows.clear();
    _nextLabel = @"";
    _nextEditable = NO;
    _nowPlayingIndex = pfc_infinite;
    _nextFrom = 0;
    _nextCount = 0;
    _nextRowStart = -1;

    BOOL shuffle = NO;
    try {
        auto pm = playlist_manager::get();
        auto pc = playback_control::get();

        const upnext::PlaybackState st = upnext::fb::currentPlaybackState();
        shuffle = st.shuffle;

        // Read only: never create "Now Playing" just because the popover opened.
        const t_size np = pm->find_playlist(upnext::kNowPlayingName);
        _nowPlayingIndex = np;

        // Which playlist feeds "Next from", and from where.
        t_size listPlaylist = np;
        bool playingKnown = st.playing && st.playingIndexKnown && st.playingPlaylist != (size_t)-1;
        if (playingKnown) listPlaylist = (t_size)st.playingPlaylist;

        const t_size listCount = (listPlaylist != pfc_infinite) ? pm->playlist_get_item_count(listPlaylist) : 0;
        const upnext::UpNextSections sec = upnext::buildSections(playingKnown, playingKnown ? st.playingIndex : 0,
                                                                 listCount);

        // Now playing
        metadb_handle_ptr current;
        if (st.playing && pc->get_now_playing(current) && current.is_valid()) {
            _rows.push_back({RowKind::Header, Section::Current, 0, metadb_handle_ptr()});
            _rows.push_back({RowKind::Track, Section::Current, playingKnown ? st.playingIndex : (size_t)-1, current});
        }

        // Queued (foobar playback queue)
        pfc::list_t<t_playback_queue_item> queue;
        pm->queue_get_contents(queue);
        if (queue.get_count() > 0) {
            _rows.push_back({RowKind::Header, Section::Queued, 0, metadb_handle_ptr()});
            for (t_size i = 0; i < queue.get_count(); ++i) {
                _rows.push_back({RowKind::Track, Section::Queued, i, queue[i].m_handle});
            }
        }

        // Next from: <label>
        if (listPlaylist != pfc_infinite && sec.nextCount > 0) {
            _nextEditable = (np != pfc_infinite && listPlaylist == np);
            if (_nextEditable) {
                NSString *label = nsString(upnext::fb::getSourceLabel());
                if ([label hasPrefix:@"Next from: "]) label = [label substringFromIndex:11];
                _nextLabel = label;
            } else {
                pfc::string8 name;
                pm->playlist_get_name(listPlaylist, name);
                _nextLabel = nsString(name);
            }

            metadb_handle_list all;
            pm->playlist_get_all_items(listPlaylist, all);
            _nextFrom = sec.nextFrom;
            _nextCount = sec.nextCount;
            _rows.push_back({RowKind::Header, Section::Next, 0, metadb_handle_ptr()});
            _nextRowStart = (NSInteger)_rows.size();
            for (size_t i = 0; i < sec.nextCount && sec.nextFrom + i < all.get_count(); ++i) {
                _rows.push_back({RowKind::Track, Section::Next, sec.nextFrom + i, all[sec.nextFrom + i]});
            }
        }
    } catch (...) {
        _rows.clear();
        _nextEditable = NO;
        _nextRowStart = -1;
        _nextCount = 0;
    }

    _shuffleNote.hidden = !shuffle;
}

#pragma mark - Table data

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)_rows.size();
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (row < 0 || (size_t)row >= _rows.size()) return kTrackRowHeight;
    return _rows[row].kind == RowKind::Header ? kHeaderRowHeight : kTrackRowHeight;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return row >= 0 && (size_t)row < _rows.size() && _rows[row].kind == RowKind::Track;
}

- (NSIndexSet *)tableView:(NSTableView *)tableView selectionIndexesForProposedSelection:(NSIndexSet *)proposed {
    NSMutableIndexSet *out = [NSMutableIndexSet indexSet];
    [proposed enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        if (row < self->_rows.size() && self->_rows[row].kind == RowKind::Track) [out addIndex:row];
    }];
    return out;
}

- (NSAttributedString *)headerTextForSection:(Section)section {
    NSDictionary *strong = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: [NSColor labelColor]};
    NSDictionary *soft = @{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                           NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    switch (section) {
        case Section::Current:
            return [[NSAttributedString alloc] initWithString:@"Now playing" attributes:strong];
        case Section::Queued:
            return [[NSAttributedString alloc] initWithString:@"Queued" attributes:strong];
        case Section::Next: {
            NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:@"Next from: "
                                                                                  attributes:soft];
            [s appendAttributedString:[[NSAttributedString alloc] initWithString:(_nextLabel ?: @"")
                                                                      attributes:strong]];
            return s;
        }
    }
    return [[NSAttributedString alloc] init];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (row < 0 || (size_t)row >= _rows.size()) return nil;
    const UpNextRow &r = _rows[row];

    if (r.kind == RowKind::Header) {
        UpNextHeaderCell *cell = [tableView makeViewWithIdentifier:@"header" owner:self];
        if (!cell) {
            cell = [[UpNextHeaderCell alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"header";
        }
        cell.label.attributedStringValue = [self headerTextForSection:r.section];
        return cell;
    }

    UpNextTrackCell *cell = [tableView makeViewWithIdentifier:@"track" owner:self];
    if (!cell) {
        cell = [[UpNextTrackCell alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"track";
    }

    NSString *title = @"", *artist = @"", *path = @"";
    double length = 0;
    if (r.handle.is_valid()) {
        pfc::string8 t, a;
        r.handle->format_title(nullptr, t, _tfTitle, nullptr);
        r.handle->format_title(nullptr, a, _tfArtist, nullptr);
        title = nsString(t);
        artist = nsString(a);
        path = [NSString stringWithUTF8String:r.handle->get_path()] ?: @"";
        length = r.handle->get_length();
    }

    const bool isCurrent = (r.section == Section::Current);
    cell.title.stringValue = title;
    cell.title.font = [NSFont systemFontOfSize:13 weight:(isCurrent ? NSFontWeightSemibold : NSFontWeightRegular)];
    cell.title.textColor = isCurrent ? [NSColor controlAccentColor] : [NSColor labelColor];
    cell.artist.stringValue = artist;
    cell.duration.stringValue = formatDuration(length);
    cell.toolTip = artist.length ? [NSString stringWithFormat:@"%@ — %@", title, artist] : title;

    // Thumbnail: cached art immediately, otherwise the shared fetcher loads it
    // in the background and we fill it in if the cell still shows that track.
    cell.artPath = path;
    NSImage *cached = [[ArtworkFetcher sharedFetcher] cachedImageForPath:path];
    cell.art.image = cached ?: [ArtworkFetcher placeholderImageOfSize:kThumbSize];
    if (!cached && path.length) {
        __weak UpNextTrackCell *weakCell = cell;
        [[ArtworkFetcher sharedFetcher] fetchArtworkForPath:path completion:^(NSImage *image) {
            UpNextTrackCell *c = weakCell;
            if (c && image && [c.artPath isEqualToString:path]) c.art.image = image;
        }];
    }
    return cell;
}

#pragma mark - Row helpers

- (BOOL)isEditableRow:(NSInteger)row {
    return row >= 0 && (size_t)row < _rows.size() && _rows[row].kind == RowKind::Track &&
           _rows[row].section == Section::Next && _nextEditable;
}

- (BOOL)isQueuedRow:(NSInteger)row {
    return row >= 0 && (size_t)row < _rows.size() && _rows[row].kind == RowKind::Track &&
           _rows[row].section == Section::Queued;
}

// Re-resolves "Now Playing" and checks the row still points at the same item.
// Returns the playlist index of Now Playing, or infinite if anything moved.
- (t_size)validatedNowPlayingForRows:(NSIndexSet *)rows {
    auto pm = playlist_manager::get();
    t_size np = pm->find_playlist(upnext::kNowPlayingName);
    if (np == pfc_infinite || np != _nowPlayingIndex) return pfc_infinite;
    FOR_EACH_INDEX(rows, row) {
        if (row >= _rows.size()) return pfc_infinite;
        const UpNextRow &r = _rows[row];
        metadb_handle_ptr h;
        if (!pm->playlist_get_item_handle(h, np, r.index) || h != r.handle) return pfc_infinite;
    }
    return np;
}

- (NSIndexSet *)targetRowsForClickedRow:(NSInteger)row {
    if (row >= 0 && [_table.selectedRowIndexes containsIndex:(NSUInteger)row]) return _table.selectedRowIndexes;
    return row >= 0 ? [NSIndexSet indexSetWithIndex:(NSUInteger)row] : [NSIndexSet indexSet];
}

#pragma mark - Actions

- (void)playRow:(NSInteger)row {
    if (![self isEditableRow:row]) return;
    try {
        t_size np = [self validatedNowPlayingForRows:[NSIndexSet indexSetWithIndex:(NSUInteger)row]];
        if (np == pfc_infinite) { [self reloadNow]; return; }
        playlist_manager::get()->playlist_execute_default_action(np, _rows[row].index);
    } catch (...) {}
}

- (void)rowDoubleClicked:(id)sender {
    [self playRow:_table.clickedRow];
}

- (void)upNextPlaySelected {
    NSIndexSet *sel = _table.selectedRowIndexes;
    if (sel.count == 1) [self playRow:(NSInteger)sel.firstIndex];
}

- (void)removeRows:(NSIndexSet *)rows {
    NSMutableIndexSet *npRows = [NSMutableIndexSet indexSet];
    NSMutableIndexSet *queueRows = [NSMutableIndexSet indexSet];
    [rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
        if ([self isEditableRow:(NSInteger)row]) [npRows addIndex:row];
        else if ([self isQueuedRow:(NSInteger)row]) [queueRows addIndex:row];
    }];
    if (!npRows.count && !queueRows.count) { NSBeep(); return; }

    try {
        auto pm = playlist_manager::get();

        if (queueRows.count) {
            // Re-read the queue and match rows by handle (prefer the same slot):
            // it may have advanced since the last reload.
            pfc::list_t<t_playback_queue_item> queue;
            pm->queue_get_contents(queue);
            const t_size qCount = queue.get_count();
            pfc::bit_array_bittable mask(qCount);
            std::vector<bool> used(qCount, false);
            bool any = false;
            FOR_EACH_INDEX(queueRows, row) {
                const UpNextRow &r = _rows[row];
                t_size hit = pfc_infinite;
                if (r.index < qCount && !used[r.index] && queue[r.index].m_handle == r.handle) hit = r.index;
                for (t_size i = 0; hit == pfc_infinite && i < qCount; ++i) {
                    if (!used[i] && queue[i].m_handle == r.handle) hit = i;
                }
                if (hit != pfc_infinite) { used[hit] = true; mask.set(hit, true); any = true; }
            }
            if (any) pm->queue_remove_mask(mask);
        }

        if (npRows.count) {
            t_size np = [self validatedNowPlayingForRows:npRows];
            if (np != pfc_infinite) {
                t_size count = pm->playlist_get_item_count(np);
                pfc::bit_array_bittable mask(count);
                FOR_EACH_INDEX(npRows, row) {
                    if (_rows[row].index < count) mask.set(_rows[row].index, true);
                }
                pm->playlist_undo_backup(np);
                pm->playlist_remove_items(np, mask);
            }
        }
    } catch (...) {}

    // Keep the cursor near where the user was deleting.
    NSUInteger anchorRow = rows.firstIndex;
    [_table deselectAll:nil];
    [self reloadNow];
    if (anchorRow != NSNotFound) {
        for (NSUInteger r = MIN(anchorRow, _rows.size() ? _rows.size() - 1 : 0); r < _rows.size(); ++r) {
            if (_rows[r].kind == RowKind::Track && _rows[r].section != Section::Current) {
                [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
                break;
            }
        }
    }
}

- (void)upNextRemoveSelected {
    [self removeRows:_table.selectedRowIndexes];
}

- (void)clearPressed:(id)sender {
    if (!_nextEditable || _nextCount == 0) return;
    try {
        // Recompute from live state: the track may have advanced since the
        // last (coalesced) reload, and the playing item must never be removed.
        auto pm = playlist_manager::get();
        t_size np = pm->find_playlist(upnext::kNowPlayingName);
        if (np == pfc_infinite) { [self reloadNow]; return; }
        const upnext::PlaybackState st = upnext::fb::currentPlaybackState();
        const t_size count = pm->playlist_get_item_count(np);
        bool playingKnown = st.playing && st.playingIndexKnown && st.playingPlaylist != (size_t)-1;
        if (st.playing && (!playingKnown || st.playingPlaylist != (size_t)np)) {
            // Playing from elsewhere (or position unknown): nothing safe to clear.
            [self reloadNow];
            return;
        }
        if (playingKnown) {
            metadb_handle_ptr cur, atIdx;
            if (!playback_control::get()->get_now_playing(cur) ||
                !pm->playlist_get_item_handle(atIdx, np, st.playingIndex) || atIdx != cur) {
                [self reloadNow];
                return;
            }
        }
        const upnext::UpNextSections sec = upnext::buildSections(playingKnown, playingKnown ? st.playingIndex : 0, count);
        if (sec.nextCount > 0 && sec.nextFrom < count) {
            pfc::bit_array_range mask(sec.nextFrom, sec.nextCount);
            pm->playlist_undo_backup(np);
            pm->playlist_remove_items(np, mask);
        }
    } catch (...) {}
    [self reloadNow];
}

#pragma mark - Context menu

- (NSMenu *)upNextMenuForRow:(NSInteger)row {
    if (row < 0 || (size_t)row >= _rows.size() || _rows[row].kind != RowKind::Track) return nil;
    if (![_table.selectedRowIndexes containsIndex:(NSUInteger)row]) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    }
    NSIndexSet *targets = [self targetRowsForClickedRow:row];

    __block NSUInteger editable = 0, queued = 0;
    [targets enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        if ([self isEditableRow:(NSInteger)r]) editable++;
        else if ([self isQueuedRow:(NSInteger)r]) queued++;
    }];
    if (!editable && !queued) return nil;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Up Next"];
    if (editable == 1 && targets.count == 1) {
        NSMenuItem *play = [menu addItemWithTitle:@"Play" action:@selector(menuPlay:) keyEquivalent:@""];
        play.target = self;
        play.representedObject = @(row);
        [menu addItem:[NSMenuItem separatorItem]];
    }
    if (editable) {
        NSMenuItem *rm = [menu addItemWithTitle:@"Remove" action:@selector(menuRemove:) keyEquivalent:@""];
        rm.target = self;
        rm.representedObject = targets;
    }
    if (queued) {
        NSMenuItem *rq = [menu addItemWithTitle:@"Remove from Queue" action:@selector(menuRemove:) keyEquivalent:@""];
        rq.target = self;
        rq.representedObject = targets;
    }
    return menu;
}

- (void)menuPlay:(NSMenuItem *)item {
    [self playRow:[item.representedObject integerValue]];
}

- (void)menuRemove:(NSMenuItem *)item {
    NSIndexSet *targets = item.representedObject;
    if ([targets isKindOfClass:[NSIndexSet class]]) [self removeRows:targets];
}

#pragma mark - Drag reorder (Now Playing rows only)

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    if (![self isEditableRow:row]) return nil;
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)row] forType:kUpNextRowPBType];
    return item;
}

- (void)tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session
    willBeginAtPoint:(NSPoint)screenPoint forRowIndexes:(NSIndexSet *)rowIndexes {
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger r, BOOL *stop) {
        if ([self isEditableRow:(NSInteger)r]) [rows addIndex:r];
    }];
    _draggedRows = rows;
}

- (void)tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session
    endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    _draggedRows = nil;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op {
    if (info.draggingSource != tableView || !_draggedRows.count || !_nextEditable || _nextRowStart < 0) {
        return NSDragOperationNone;
    }
    const NSInteger first = _nextRowStart;
    const NSInteger end = _nextRowStart + (NSInteger)_nextCount; // drop "above end" == append
    if (op == NSTableViewDropOn) {
        row += 1; // dropping on a row means "after it"
        [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    }
    if (row < first) {
        row = first;
        [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    }
    if (row > end) return NSDragOperationNone;
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op {
    NSIndexSet *dragged = _draggedRows;
    _draggedRows = nil;
    if (!dragged.count || _nextRowStart < 0) return NO;

    try {
        t_size np = [self validatedNowPlayingForRows:dragged];
        if (np == pfc_infinite) { [self reloadNow]; return NO; }

        auto pm = playlist_manager::get();
        const t_size n = pm->playlist_get_item_count(np);
        const size_t target = _nextFrom + (size_t)(row - _nextRowStart); // insert before this NP index

        std::vector<bool> isMoved(n, false);
        std::vector<t_size> moved;
        FOR_EACH_INDEX(dragged, r) {
            size_t idx = _rows[r].index;
            if (idx < n && !isMoved[idx]) { isMoved[idx] = true; moved.push_back(idx); }
        }
        std::sort(moved.begin(), moved.end());

        std::vector<t_size> remaining;
        remaining.reserve(n);
        size_t insertPos = 0;
        for (t_size i = 0; i < n; ++i) {
            if (isMoved[i]) continue;
            if (i < target) insertPos++;
            remaining.push_back(i);
        }

        std::vector<t_size> order;
        order.reserve(n);
        order.insert(order.end(), remaining.begin(), remaining.begin() + insertPos);
        order.insert(order.end(), moved.begin(), moved.end());
        order.insert(order.end(), remaining.begin() + insertPos, remaining.end());

        bool identity = true;
        for (t_size i = 0; i < n; ++i) if (order[i] != i) { identity = false; break; }
        if (identity) return NO;

        pm->playlist_undo_backup(np);
        if (!pm->playlist_reorder_items(np, order.data(), n)) { [self reloadNow]; return NO; }

        // Select the moved items at their new positions.
        [self reloadNow];
        NSMutableIndexSet *sel = [NSMutableIndexSet indexSet];
        for (size_t k = 0; k < moved.size(); ++k) {
            size_t newIdx = insertPos + k;
            if (newIdx >= _nextFrom && newIdx < _nextFrom + _nextCount) {
                [sel addIndex:(NSUInteger)(_nextRowStart + (NSInteger)(newIdx - _nextFrom))];
            }
        }
        [_table selectRowIndexes:sel byExtendingSelection:NO];
        return YES;
    } catch (...) {
        [self reloadNow];
        return NO;
    }
}

@end
