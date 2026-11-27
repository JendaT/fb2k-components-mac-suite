#import "ShellSidebarController.h"
#include "../fb2k_sdk.h"
#include "../../../../shared/UpNext.h"   // after the SDK include
#import "../../../../shared/UIStyles.h"
#include "../../../../shared/ArtistNames.h"
#include "../Integration/ShellConfig.h"
#include "../Integration/ShellPlaylists.h"
#import "../Artists/SVArtistLibrary.h"
#import "../Artists/SVArtistImageProvider.h"

using shellcore::DestKind;
using shellcore::Destination;
using shellcore::LibraryFilter;

static NSPasteboardType const SVSimPlaylistRowsType = @"com.foobar2000.simplaylist.rows";

// Row metrics (points). Regular rows follow the macOS "medium" sidebar size.
static const CGFloat kRowHeight          = 28.0;
static const CGFloat kArtistRowHeight    = 40.0;
static const CGFloat kSectionRowHeight   = 24.0;
static const CGFloat kHeaderRowHeight    = 72.0;
static const CGFloat kSearchExtraHeight  = 30.0;   // header grows by this while the search field is open
static const NSInteger kHeaderRowIndex   = 0;      // the list starts with the Your Library header (Albums is pinned above it)
static const CGFloat kArtistPhotoSize    = 32.0;
static const CGFloat kHomeTopMargin     = 8.0;    // space above the pinned Albums row
static const CGFloat kHomeGap           = 12.0;   // space between it and "Your Library"
static const CGFloat kHomeAreaHeight     = kHomeTopMargin + 28.0 + kHomeGap;

#pragma mark - Model

typedef NS_ENUM(NSInteger, SVRowKind) {
    SVRowKindLibraryHeader,  // "Your Library" + chips (group row, floats)
    SVRowKindSection,        // small "Playlists" / "Artists" label
    SVRowKindPlaylist,
    SVRowKindArtist,
    SVRowKindNote,           // non-selectable hint ("No artists found")
};

@interface SVSidebarItem : NSObject
@property (nonatomic) SVRowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy, nullable) NSString *detail;     // playlist item count
@property (nonatomic) t_size playlistIndex;                // hint only; resolve by name
@property (nonatomic) t_size itemCount;
+ (instancetype)itemWithKind:(SVRowKind)kind title:(NSString *)title;
@end

@implementation SVSidebarItem
+ (instancetype)itemWithKind:(SVRowKind)kind title:(NSString *)title {
    SVSidebarItem *item = [[SVSidebarItem alloc] init];
    item.kind = kind;
    item.title = title ?: @"";
    item.playlistIndex = pfc_infinite;
    return item;
}
- (BOOL)isSelectable {
    return _kind == SVRowKindPlaylist || _kind == SVRowKindArtist;
}
- (BOOL)sameRowAs:(SVSidebarItem *)other {
    return other && other.kind == _kind && [other.title isEqualToString:_title];
}
@end

#pragma mark - Filter chip

// Capsule toggle in the "Your Library" header. Accent-filled when selected,
// a faint label-tinted capsule otherwise.
@interface SVChipButton : NSButton
@property (nonatomic) BOOL chipSelected;
@end

@implementation SVChipButton {
    NSTrackingArea *_tracking;
    BOOL _hovered;
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        self.title = title;
        self.bordered = NO;
        self.buttonType = NSButtonTypeMomentaryChange;
        self.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}

- (void)setChipSelected:(BOOL)chipSelected {
    if (_chipSelected == chipSelected) return;
    _chipSelected = chipSelected;
    [self setNeedsDisplay:YES];
    [self setAccessibilityValue:chipSelected ? @"selected" : @"not selected"];
}

- (NSSize)intrinsicContentSize {
    NSSize text = [self.title sizeWithAttributes:@{NSFontAttributeName: self.font}];
    return NSMakeSize(ceil(text.width) + 22.0, 22.0);
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:self.bounds
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event { _hovered = YES; [self setNeedsDisplay:YES]; }
- (void)mouseExited:(NSEvent *)event  { _hovered = NO;  [self setNeedsDisplay:YES]; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *capsule = [NSBezierPath bezierPathWithRoundedRect:r xRadius:NSHeight(r) / 2 yRadius:NSHeight(r) / 2];
    BOOL pressed = self.isHighlighted;
    NSColor *fill;
    NSColor *text;
    if (_chipSelected) {
        fill = [NSColor controlAccentColor];
        if (pressed) fill = [fill shadowWithLevel:0.15] ?: fill;
        text = [NSColor alternateSelectedControlTextColor];
    } else {
        CGFloat alpha = fb2k_ui::isDarkMode() ? 0.10 : 0.06;
        if (_hovered) alpha += 0.05;
        if (pressed)  alpha += 0.06;
        fill = [[NSColor labelColor] colorWithAlphaComponent:alpha];
        text = [NSColor labelColor];
    }
    [fill setFill];
    [capsule fill];

    NSDictionary *attrs = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: text};
    NSSize size = [self.title sizeWithAttributes:attrs];
    NSPoint p = NSMakePoint(NSMidX(self.bounds) - size.width / 2,
                            NSMidY(self.bounds) - size.height / 2);
    [self.title drawAtPoint:p withAttributes:attrs];
}

- (void)drawFocusRingMask {
    NSRect r = self.bounds;
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:NSHeight(r) / 2 yRadius:NSHeight(r) / 2] fill];
}

- (NSRect)focusRingMaskBounds { return self.bounds; }

@end

#pragma mark - Cell views

@interface SVLibraryHeaderView : NSTableCellView
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSButton *addButton;
@property (nonatomic, strong) NSButton *searchButton;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, assign) BOOL searchExpanded;
@property (nonatomic, strong) SVChipButton *playlistsChip;
@property (nonatomic, strong) SVChipButton *artistsChip;
@property (nonatomic, assign) BOOL separatorVisible;
@end

@implementation SVLibraryHeaderView {
    NSBox *_separator;
    NSLayoutConstraint *_chipsTopCollapsed;
    NSLayoutConstraint *_chipsTopExpanded;
}
- (void)setSearchExpanded:(BOOL)expanded {
    _searchExpanded = expanded;
    _searchField.hidden = !expanded;
    _chipsTopCollapsed.active = !expanded;
    _chipsTopExpanded.active = expanded;
    _searchButton.contentTintColor = expanded ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
    [self setAccessibilityValue:expanded ? @"search open" : nil];
}
- (void)setSeparatorVisible:(BOOL)visible {
    _separatorVisible = visible;
    _separator.hidden = !visible;
}
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Opaque backdrop in the sidebar's own material so rows scroll beneath
        // the sticky header instead of showing through it.
        NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        backdrop.material = NSVisualEffectMaterialSidebar;
        backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        backdrop.state = NSVisualEffectStateFollowsWindowActiveState;
        backdrop.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:backdrop];
        _separator = [[NSBox alloc] initWithFrame:NSZeroRect];
        _separator.boxType = NSBoxSeparator;
        _separator.translatesAutoresizingMaskIntoConstraints = NO;
        _separator.hidden = YES;
        [self addSubview:_separator];
        [NSLayoutConstraint activateConstraints:@[
            [backdrop.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [backdrop.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [backdrop.topAnchor constraintEqualToAnchor:self.topAnchor],
            [backdrop.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_separator.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_separator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_separator.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_separator.heightAnchor constraintEqualToConstant:1],
        ]];

        _titleLabel = [NSTextField labelWithString:@"Your Library"];
        _titleLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        _titleLabel.textColor = [NSColor secondaryLabelColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;

        NSImage *plus = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New Playlist"];
        _addButton = [NSButton buttonWithImage:plus target:nil action:nil];
        _addButton.bordered = NO;
        _addButton.imageScaling = NSImageScaleProportionallyDown;
        _addButton.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
        _addButton.contentTintColor = [NSColor secondaryLabelColor];
        _addButton.toolTip = @"New Playlist (⌘N)";
        _addButton.translatesAutoresizingMaskIntoConstraints = NO;

        NSImage *glass = [NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:@"Search in Your Library"];
        _searchButton = [NSButton buttonWithImage:glass target:nil action:nil];
        _searchButton.bordered = NO;
        _searchButton.imageScaling = NSImageScaleProportionallyDown;
        _searchButton.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
        _searchButton.contentTintColor = [NSColor secondaryLabelColor];
        _searchButton.toolTip = @"Search in Your Library";
        _searchButton.translatesAutoresizingMaskIntoConstraints = NO;

        _searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
        _searchField.placeholderString = @"Search in Your Library";
        _searchField.controlSize = NSControlSizeSmall;
        _searchField.font = [NSFont systemFontOfSize:12];
        _searchField.sendsSearchStringImmediately = YES;
        _searchField.hidden = YES;
        _searchField.translatesAutoresizingMaskIntoConstraints = NO;

        _playlistsChip = [[SVChipButton alloc] initWithTitle:@"Playlists"];
        _artistsChip = [[SVChipButton alloc] initWithTitle:@"Artists"];

        for (NSView *v in @[_titleLabel, _searchButton, _addButton, _searchField, _playlistsChip, _artistsChip]) [self addSubview:v];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:18],
            [_addButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_addButton.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
            [_addButton.widthAnchor constraintEqualToConstant:20],
            [_addButton.heightAnchor constraintEqualToConstant:20],
            [_searchButton.trailingAnchor constraintEqualToAnchor:_addButton.leadingAnchor constant:-2],
            [_searchButton.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],
            [_searchButton.widthAnchor constraintEqualToConstant:20],
            [_searchButton.heightAnchor constraintEqualToConstant:20],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_searchButton.leadingAnchor constant:-4],
            [_searchField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_searchField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6],
            [_searchField.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
            [_playlistsChip.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [_artistsChip.leadingAnchor constraintEqualToAnchor:_playlistsChip.trailingAnchor constant:6],
            [_artistsChip.centerYAnchor constraintEqualToAnchor:_playlistsChip.centerYAnchor],
        ]];
        _chipsTopCollapsed = [_playlistsChip.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8];
        _chipsTopExpanded = [_playlistsChip.topAnchor constraintEqualToAnchor:_searchField.bottomAnchor constant:8];
        _chipsTopCollapsed.active = YES;
    }
    return self;
}
@end

@interface SVPlaylistCellView : NSTableCellView
@property (nonatomic, strong) NSTextField *countField;
@end

@implementation SVPlaylistCellView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
        self.imageView = icon;

        NSTextField *name = [NSTextField labelWithString:@""];
        name.font = [NSFont systemFontOfSize:fb2k_ui::rowFontSize(fb2k_ui::SizeVariant::Normal)];
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        name.translatesAutoresizingMaskIntoConstraints = NO;
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [name setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.textField = name;

        _countField = [NSTextField labelWithString:@""];
        _countField.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        _countField.textColor = [NSColor tertiaryLabelColor];
        _countField.alignment = NSTextAlignmentRight;
        _countField.translatesAutoresizingMaskIntoConstraints = NO;
        [_countField setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [_countField setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];

        [self addSubview:icon];
        [self addSubview:name];
        [self addSubview:_countField];

        [NSLayoutConstraint activateConstraints:@[
            [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
            [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [icon.widthAnchor constraintEqualToConstant:18],
            [name.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6],
            [name.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_countField.leadingAnchor constraintEqualToAnchor:name.trailingAnchor constant:6],
            [_countField.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [_countField.firstBaselineAnchor constraintEqualToAnchor:name.firstBaselineAnchor],
        ]];
    }
    return self;
}

// Keep the count readable on the accent-filled selection.
- (void)setBackgroundStyle:(NSBackgroundStyle)backgroundStyle {
    [super setBackgroundStyle:backgroundStyle];
    _countField.textColor = backgroundStyle == NSBackgroundStyleEmphasized
        ? [[NSColor alternateSelectedControlTextColor] colorWithAlphaComponent:0.75]
        : [NSColor tertiaryLabelColor];
}
@end

// 32 pt round photo + name. The silhouette shows until SVArtistImageProvider
// delivers the photo.
@interface SVArtistCellView : NSTableCellView
@property (nonatomic, copy, nullable) NSString *artistName;
@end

@implementation SVArtistCellView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        NSImageView *photo = [[NSImageView alloc] initWithFrame:NSZeroRect];
        photo.translatesAutoresizingMaskIntoConstraints = NO;
        photo.imageScaling = NSImageScaleProportionallyUpOrDown;
        photo.wantsLayer = YES;
        photo.layer.cornerRadius = kArtistPhotoSize / 2;
        photo.layer.masksToBounds = YES;
        self.imageView = photo;

        NSTextField *name = [NSTextField labelWithString:@""];
        name.font = [NSFont systemFontOfSize:fb2k_ui::rowFontSize(fb2k_ui::SizeVariant::Normal)];
        name.lineBreakMode = NSLineBreakByTruncatingTail;
        name.translatesAutoresizingMaskIntoConstraints = NO;
        [name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [name setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        self.textField = name;

        [self addSubview:photo];
        [self addSubview:name];
        [NSLayoutConstraint activateConstraints:@[
            [photo.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [photo.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [photo.widthAnchor constraintEqualToConstant:kArtistPhotoSize],
            [photo.heightAnchor constraintEqualToConstant:kArtistPhotoSize],
            [name.leadingAnchor constraintEqualToAnchor:photo.trailingAnchor constant:8],
            [name.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
            [name.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

+ (NSImage *)placeholderPhoto {
    static NSImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:kArtistPhotoSize weight:NSFontWeightLight];
        image = [[NSImage imageWithSystemSymbolName:@"person.crop.circle.fill" accessibilityDescription:nil]
                 imageWithSymbolConfiguration:cfg];
    });
    return image;
}
@end

#pragma mark - Table

@interface SVSidebarTableView : NSTableView
@property (nonatomic, copy, nullable) BOOL (^keyHandler)(NSEvent *event);
@end

@implementation SVSidebarTableView
- (void)keyDown:(NSEvent *)event {
    if (self.keyHandler && self.keyHandler(event)) return;
    [super keyDown:event];
}
@end

#pragma mark - Drop import

namespace {

// Async import for dropped locations. The target is resolved by name at
// completion: playlists can be created, removed or reordered meanwhile.
class SVDropImportNotify : public process_locations_notify {
public:
    std::string m_target;
    pfc::string_list_impl m_paths;
    bool m_noFilter = false;

    explicit SVDropImportNotify(const std::string& target) : m_target(target) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() == 0) return;
        t_size target = SVFindPlaylistExact(m_target);
        if (target == pfc_infinite) {
            FB2K_console_formatter() << "[ShellVanced] drop target playlist no longer exists: " << m_target.c_str();
            return;
        }
        auto pm = playlist_manager::get();
        pm->playlist_insert_items(target, pm->playlist_get_item_count(target), items, pfc::bit_array_false());
    }

    void on_aborted() override {}

    void start() {
        if (m_paths.get_count() == 0) return;
        pfc::list_t<const char*> ptrs;
        for (t_size i = 0; i < m_paths.get_count(); ++i) ptrs.add_item(m_paths[i]);
        t_uint32 flags = playlist_incoming_item_filter_v2::op_flag_delay_ui;
        if (m_noFilter) flags |= playlist_incoming_item_filter_v2::op_flag_no_filter;
        playlist_incoming_item_filter_v2::get()->process_locations_async(ptrs, flags, nullptr, nullptr, nullptr, this);
    }
};

// {sourcePlaylist, indices, paths} from SimPlaylist / AlbumViewVanced drags,
// shape-checked. nil when absent or malformed.
NSDictionary* SVReadRowsPayload(NSPasteboard* pb) {
    if (![pb.types containsObject:SVSimPlaylistRowsType]) return nil;
    NSData* data = [pb dataForType:SVSimPlaylistRowsType];
    if (!data) return nil;
    NSSet* classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSNumber class], [NSString class], nil];
    id obj = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary* d = obj;
    id src = d[@"sourcePlaylist"], idx = d[@"indices"], paths = d[@"paths"];
    if (src && ![src isKindOfClass:[NSNumber class]]) return nil;
    if (idx) {
        if (![idx isKindOfClass:[NSArray class]]) return nil;
        for (id v in (NSArray*)idx) if (![v isKindOfClass:[NSNumber class]] || [v integerValue] < 0) return nil;
    }
    if (paths) {
        if (![paths isKindOfClass:[NSArray class]]) return nil;
        for (id v in (NSArray*)paths) if (![v isKindOfClass:[NSString class]]) return nil;
    }
    return d;
}

NSArray<NSURL*>* SVReadFileURLs(NSPasteboard* pb) {
    return [pb readObjectsForClasses:@[[NSURL class]]
                             options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}] ?: @[];
}

} // namespace

#pragma mark - Controller

@interface ShellSidebarController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuDelegate, NSMenuItemValidation>
@end

@implementation ShellSidebarController {
    SVSidebarTableView *_table;
    NSScrollView *_scroll;
    NSScrollView *_homeScroll;       // fixed "Albums" row above the list; never scrolls
    SVSidebarTableView *_homeTable;  // one-row source list, so it looks and selects exactly like the list rows
    NSArray<SVSidebarItem *> *_items;
    LibraryFilter _filter;
    Destination _reflected;
    BOOL _reflecting;

    // Inline rename state
    NSString *_editingName;      // original name while the field is being edited
    t_size _editingIndexHint;
    BOOL _renameCancelled;
    BOOL _reloadPending;

    // "Search in Your Library"
    BOOL _searchOpen;
    NSString *_query;                       // raw text; empty = no filtering
    NSArray<NSString *> *_keyedNames;       // artist names the caches below were built for
    NSArray<NSString *> *_foldedArtists;    // case/accent-folded names, parallel to _keyedNames
    std::vector<std::string> _artistKeys;   // artistnames::artistKey, parallel to _keyedNames

    // Drag payload cache (keyed by pasteboard changeCount)
    NSInteger _dragChangeCount;
    NSDictionary *_dragRows;
    BOOL _dragHasFiles;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _items = @[];
        _filter = shellcore::filterFromInt(shell_config::getInt(shell_config::kLibraryFilter, 0));
        _editingIndexHint = pfc_infinite;
        _dragChangeCount = -1;
    }
    return self;
}

- (NSTableView *)tableView { return _table; }

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 220, 500)];
    root.material = NSVisualEffectMaterialSidebar;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateFollowsWindowActiveState;

    _scroll = [[NSScrollView alloc] initWithFrame:root.bounds];
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _scroll.borderType = NSNoBorder;
    _scroll.drawsBackground = NO;

    _table = [[SVSidebarTableView alloc] initWithFrame:_scroll.bounds];
    _table.style = NSTableViewStyleSourceList;
    _table.backgroundColor = [NSColor clearColor];
    _table.headerView = nil;
    _table.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    _table.intercellSpacing = NSMakeSize(0, 2);
    _table.floatsGroupRows = YES;
    _table.allowsEmptySelection = YES;
    _table.allowsMultipleSelection = NO;
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    _table.dataSource = self;
    _table.delegate = self;

    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    col.width = NSWidth(_scroll.bounds);   // the default 100 pt never grew, so names truncated at ~60 pt
    [_table addTableColumn:col];

    [_table registerForDraggedTypes:@[SVSimPlaylistRowsType, NSPasteboardTypeFileURL]];
    _table.draggingDestinationFeedbackStyle = NSTableViewDraggingDestinationFeedbackStyleSourceList;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    _table.menu = menu;

    __weak ShellSidebarController *weakSelf = self;
    _table.keyHandler = ^BOOL(NSEvent *event) { return [weakSelf handleTableKey:event]; };

    _scroll.documentView = _table;
    _scroll.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sidebarScrolled:)
                                                 name:NSViewBoundsDidChangeNotification object:_scroll.contentView];
    [root addSubview:_scroll];

    _homeScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 220, kHomeAreaHeight)];
    _homeScroll.hasVerticalScroller = NO;
    _homeScroll.hasHorizontalScroller = NO;
    _homeScroll.verticalScrollElasticity = NSScrollElasticityNone;
    _homeScroll.horizontalScrollElasticity = NSScrollElasticityNone;
    _homeScroll.borderType = NSNoBorder;
    _homeScroll.drawsBackground = NO;
    _homeScroll.automaticallyAdjustsContentInsets = NO;
    _homeScroll.contentInsets = NSEdgeInsetsZero;
    _scroll.automaticallyAdjustsContentInsets = NO;
    _homeTable = [[SVSidebarTableView alloc] initWithFrame:_homeScroll.bounds];
    _homeTable.style = NSTableViewStyleSourceList;
    _homeTable.backgroundColor = [NSColor clearColor];
    _homeTable.headerView = nil;
    _homeTable.rowSizeStyle = NSTableViewRowSizeStyleCustom;
    _homeTable.intercellSpacing = NSMakeSize(0, 2);
    _homeTable.allowsEmptySelection = YES;
    _homeTable.allowsMultipleSelection = NO;
    _homeTable.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    NSTableColumn *homeCol = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    homeCol.resizingMask = NSTableColumnAutoresizingMask;
    homeCol.width = 220;
    [_homeTable addTableColumn:homeCol];
    _homeTable.dataSource = self;
    _homeTable.delegate = self;
    _homeTable.keyHandler = ^BOOL(NSEvent *event) { return [weakSelf handleHomeKey:event]; };
    _homeScroll.documentView = _homeTable;
    [root addSubview:_homeScroll];
    self.view = root;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artistLibraryDidChange:)
                                                 name:SVArtistLibraryDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artistImagesDidChange:)
                                                 name:SVArtistImagesDidChangeNotification object:nil];

    [self rebuildItemsReloading:YES];
}

// Keep the single column as wide as the sidebar, whatever width the splitter gives it.
- (void)viewDidLayout {
    [super viewDidLayout];
    // Pinned Albums row on top (below any title-bar safe area), the list fills the rest.
    const NSRect b = self.view.bounds;
    const CGFloat top = self.view.safeAreaInsets.top;
    const CGFloat homeH = kHomeAreaHeight;
    _homeScroll.frame = NSMakeRect(0, NSMaxY(b) - top - homeH, NSWidth(b), homeH);
    _scroll.frame = NSMakeRect(0, 0, NSWidth(b), MAX(0, NSHeight(b) - top - homeH));
    [_homeTable sizeLastColumnToFit];
    // The source-list table pads its first row by an amount of its own: place row 0 exactly kHomeTopMargin
    // below the top of the pinned area, whatever that padding is, and never leave the view scrolled.
    const CGFloat pad = NSMinY([_homeTable rectOfRow:0]);
    const CGFloat inset = MAX(0, kHomeTopMargin - pad);
    _homeScroll.contentInsets = NSEdgeInsetsMake(inset, 0, 0, 0);
    [_homeScroll.contentView scrollToPoint:NSMakePoint(0, MAX(pad - kHomeTopMargin, 0) - inset)];
    [_homeScroll reflectScrolledClipView:_homeScroll.contentView];
    [_table sizeLastColumnToFit];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Hairline under the sticky header only while rows are scrolled beneath it.
- (void)sidebarScrolled:(NSNotification *)note {
    if (_items.count <= (NSUInteger)kHeaderRowIndex || _items[kHeaderRowIndex].kind != SVRowKindLibraryHeader) return;
    NSView *v = [_table viewAtColumn:0 row:kHeaderRowIndex makeIfNecessary:NO];
    if ([v isKindOfClass:[SVLibraryHeaderView class]])
        ((SVLibraryHeaderView *)v).separatorVisible = _scroll.contentView.bounds.origin.y > 0.5;
}

// Cached artist photos changed: reload only the visible artist rows (no rebuild of the sidebar).
- (void)artistImagesDidChange:(NSNotification *)note {
    NSRange vis = [_table rowsInRect:_table.visibleRect];
    NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
    for (NSUInteger i = vis.location; i < NSMaxRange(vis) && i < _items.count; i++)
        if (_items[i].kind == SVRowKindArtist) [rows addIndex:i];
    if (rows.count) [_table reloadDataForRowIndexes:rows columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}

- (void)artistLibraryDidChange:(NSNotification *)note {
    [self reloadPlaylists];   // rebuilds every section; deferred while a rename is typed
}

#pragma mark Items

- (NSArray<SVSidebarItem *> *)buildItems {
    NSMutableArray<SVSidebarItem *> *items = [NSMutableArray array];
    [items addObject:[SVSidebarItem itemWithKind:SVRowKindLibraryHeader title:@"Your Library"]];

    const BOOL both = _filter == LibraryFilter::All;
    NSString *foldedQuery = [self foldedQuery];
    const BOOL searching = foldedQuery.length > 0;
    const std::string needle = SVToStd(foldedQuery);
    const NSUInteger headerCount = items.count;

    if (shellcore::showsPlaylists(_filter)) {
        const auto names = SVPlaylistNames();
        auto visible = shellcore::sidebarPlaylists(names);
        if (searching) {
            std::vector<size_t> hits;
            for (size_t idx : visible) {
                if (shellcore::searchMatches(SVToStd([self fold:SVToNS(names[idx])]), needle)) hits.push_back(idx);
            }
            visible = hits;
        }
        if (both && (!searching || !visible.empty()))
            [items addObject:[SVSidebarItem itemWithKind:SVRowKindSection title:@"Playlists"]];
        static NSNumberFormatter *fmt;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [[NSNumberFormatter alloc] init];
            fmt.numberStyle = NSNumberFormatterDecimalStyle;
        });
        for (size_t idx : visible) {
            SVSidebarItem *item = [SVSidebarItem itemWithKind:SVRowKindPlaylist title:SVToNS(names[idx])];
            item.playlistIndex = idx;
            item.itemCount = SVPlaylistItemCount(idx);
            item.detail = [fmt stringFromNumber:@(item.itemCount)];
            [items addObject:item];
        }
        if (visible.empty() && !searching) {
            [items addObject:[SVSidebarItem itemWithKind:SVRowKindNote title:@"No playlists yet"]];
        }
    }

    if (shellcore::showsArtists(_filter)) {
        [self appendArtistItems:items query:foldedQuery showSection:both];
    }

    if (searching && items.count == headerCount) {
        [items addObject:[SVSidebarItem itemWithKind:SVRowKindNote title:@"No matches"]];
    }
    return items;
}

#pragma mark Search

// Case-, accent- and width-insensitive form used for substring matching.
- (NSString *)fold:(NSString *)s {
    return [(s ?: @"") stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                           locale:nil];
}

- (NSString *)foldedQuery {
    NSString *trimmed = [(_query ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [self fold:trimmed];
}

// Folded names and artist keys are rebuilt only when the index delivers a new name list.
- (void)ensureArtistCaches:(NSArray<NSString *> *)names {
    if (_keyedNames == names) return;
    NSMutableArray<NSString *> *folded = [NSMutableArray arrayWithCapacity:names.count];
    _artistKeys.clear();
    _artistKeys.reserve(names.count);
    for (NSString *name in names) {
        [folded addObject:[self fold:name]];
        _artistKeys.push_back(artistnames::artistKey(SVToStd(name)));
    }
    _foldedArtists = folded;
    _keyedNames = names;
}

- (void)appendArtistItems:(NSMutableArray<SVSidebarItem *> *)items query:(NSString *)foldedQuery showSection:(BOOL)showSection {
    // First touch of the singleton happens here, from UI creation (not static init).
    NSArray<NSString *> *names = [SVArtistLibrary shared].artistNames;
    const BOOL searching = foldedQuery.length > 0;
    NSUInteger firstRow = items.count;
    if (showSection && !searching) [items addObject:[SVSidebarItem itemWithKind:SVRowKindSection title:@"Artists"]];

    if (!searching) {
        for (NSString *name in names) [items addObject:[SVSidebarItem itemWithKind:SVRowKindArtist title:name]];
        if (names.count == 0) {
            // The index builds in the background; this row is replaced when it arrives.
            [items addObject:[SVSidebarItem itemWithKind:SVRowKindNote title:@"No artists found"]];
        }
        return;
    }

    // Artists match on the folded name or on artistKey (also ignores spaces and punctuation).
    [self ensureArtistCaches:names];
    const std::string needle = SVToStd(foldedQuery);
    const std::string needleKey = artistnames::artistKey(needle);
    NSMutableArray<SVSidebarItem *> *hits = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) {
        bool hit = shellcore::searchMatches(SVToStd(_foldedArtists[i]), needle) ||
                   (!needleKey.empty() && shellcore::searchMatches(_artistKeys[i], needleKey));
        if (hit) [hits addObject:[SVSidebarItem itemWithKind:SVRowKindArtist title:names[i]]];
    }
    if (hits.count == 0) return;   // no matches: the section hides
    if (showSection) [items insertObject:[SVSidebarItem itemWithKind:SVRowKindSection title:@"Artists"] atIndex:firstRow];
    [items addObjectsFromArray:hits];
}

- (SVLibraryHeaderView *)libraryHeaderView {
    if (_items.count <= (NSUInteger)kHeaderRowIndex) return nil;
    NSView *v = [_table viewAtColumn:0 row:kHeaderRowIndex makeIfNecessary:YES];
    return [v isKindOfClass:[SVLibraryHeaderView class]] ? (SVLibraryHeaderView *)v : nil;
}

- (void)searchClicked:(id)sender {
    if (_searchOpen) [self closeSearchReturningFocus:YES];
    else [self openSearch];
}

- (void)openSearch {
    SVLibraryHeaderView *header = [self libraryHeaderView];
    if (!header) return;
    _searchOpen = YES;
    [self scrollSidebarToTop];   // the header must sit in its own row, not float over a scrolled list
    header = [self libraryHeaderView] ?: header;
    header.searchExpanded = YES;
    [_table noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:(NSUInteger)kHeaderRowIndex]];
    [self.view.window makeFirstResponder:header.searchField];
}

// Collapses the field and restores the unfiltered lists.
- (void)closeSearchReturningFocus:(BOOL)focus {
    if (!_searchOpen) return;
    SVLibraryHeaderView *header = [self libraryHeaderView];
    NSWindow *window = self.view.window;
    BOOL fieldHasFocus = NO;
    if (header && window) {
        id fr = window.firstResponder;
        fieldHasFocus = [fr isKindOfClass:[NSTextView class]] && [(NSTextView *)fr delegate] == (id)header.searchField;
    }
    _searchOpen = NO;
    BOOL hadQuery = [self foldedQuery].length > 0;
    _query = nil;
    header.searchField.stringValue = @"";
    header.searchExpanded = NO;
    [_table noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndex:(NSUInteger)kHeaderRowIndex]];
    if (fieldHasFocus) [window makeFirstResponder:_table];   // never leave focus in the collapsed field
    if (hadQuery) [self rebuildItemsReloading:NO];
}

- (void)searchCancelClicked:(id)sender {
    [self closeSearchReturningFocus:YES];
}

- (void)scrollSidebarToTop {
    [_scroll.contentView scrollToPoint:NSZeroPoint];
    [_scroll reflectScrolledClipView:_scroll.contentView];
}

- (void)searchTextChanged {
    SVLibraryHeaderView *header = [self libraryHeaderView];
    NSString *text = header.searchField.stringValue ?: @"";
    if ([text isEqualToString:_query ?: @""]) return;
    _query = [text copy];
    // Scroll first: while the list is scrolled the header is a floating group row, and replacing the
    // rows below it re-creates that view, which took the field editor (and focus) with it.
    [self scrollSidebarToTop];
    [self rebuildItemsReloading:NO];
    [self scrollSidebarToTop];
    [self keepSearchFocus];
}

// If the header view was re-created anyway, put the caret back at the end of the query.
- (void)keepSearchFocus {
    NSWindow *window = self.view.window;
    SVLibraryHeaderView *header = [self libraryHeaderView];
    if (!window || !header || !_searchOpen) return;
    NSSearchField *field = header.searchField;
    id fr = window.firstResponder;
    if ([fr isKindOfClass:[NSTextView class]] && ((NSTextView *)fr).delegate == (id)field) return;
    field.stringValue = _query ?: @"";
    [window makeFirstResponder:field];
    NSText *editor = field.currentEditor;
    editor.selectedRange = NSMakeRange(editor.string.length, 0);
}

// Down arrow in the field: into the results.
- (void)searchMoveIntoList {
    NSWindow *window = self.view.window;
    [window makeFirstResponder:_table];
    if (_table.selectedRow >= 0) return;
    for (NSUInteger i = 0; i < _items.count; i++) {
        SVRowKind k = _items[i].kind;
        if (k == SVRowKindPlaylist || k == SVRowKindArtist) {
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [_table scrollRowToVisible:(NSInteger)i];
            return;
        }
    }
}

- (void)rebuildItemsReloading:(BOOL)forceReload {
    NSArray<SVSidebarItem *> *fresh = [self buildItems];
    BOOL sameRows = !forceReload && fresh.count == _items.count;
    if (sameRows) {
        for (NSUInteger i = 0; i < fresh.count; i++) {
            if (![fresh[i] sameRowAs:_items[i]]) { sameRows = NO; break; }
        }
    }
    NSArray<SVSidebarItem *> *old = _items;
    _items = fresh;
    if (sameRows) {
        // Only counts changed: patch visible cells, keep selection and scroll.
        for (NSUInteger i = 0; i < fresh.count; i++) {
            if (fresh[i].kind != SVRowKindPlaylist) continue;
            if ([fresh[i].detail isEqualToString:old[i].detail]) continue;
            SVPlaylistCellView *cell = [_table viewAtColumn:0 row:(NSInteger)i makeIfNecessary:NO];
            if ([cell isKindOfClass:[SVPlaylistCellView class]]) cell.countField.stringValue = fresh[i].detail ?: @"";
        }
        return;
    }
    // reloadData may clear the selection and reset scrolling: keep the user's position.
    NSClipView *clip = _scroll.contentView;
    const NSPoint origin = clip.bounds.origin;
    _reflecting = YES;
    const NSUInteger keep = (NSUInteger)kHeaderRowIndex + 1;   // the Your Library header stays put
    const BOOL patch = !forceReload && old.count >= keep && fresh.count >= keep &&
        fresh[kHeaderRowIndex].kind == SVRowKindLibraryHeader && old[kHeaderRowIndex].kind == SVRowKindLibraryHeader;
    if (patch) {
        // Replace only the rows below the header: the header's search field keeps keyboard focus while typing.
        [_table beginUpdates];
        if (old.count > keep)
            [_table removeRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(keep, old.count - keep)]
                          withAnimation:NSTableViewAnimationEffectNone];
        if (fresh.count > keep)
            [_table insertRowsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(keep, fresh.count - keep)]
                          withAnimation:NSTableViewAnimationEffectNone];
        [_table endUpdates];
    } else {
        [_table reloadData];
    }
    _reflecting = NO;
    [self reflectDestination:_reflected scroll:NO];
    NSPoint restored = origin;
    restored.y = MAX(0, MIN(restored.y, NSHeight(_table.frame) - NSHeight(clip.bounds)));
    [clip scrollToPoint:restored];
    [_scroll reflectScrolledClipView:clip];
}

- (void)reloadPlaylists {
    if (!self.isViewLoaded) return;
    if (_editingName) { _reloadPending = YES; return; }
    [self rebuildItemsReloading:NO];
}

- (NSInteger)rowForDestination:(const Destination &)d {
    for (NSUInteger i = 0; i < _items.count; i++) {
        SVSidebarItem *item = _items[i];
        switch (d.kind) {
            case DestKind::Albums:
                return -1;   // the pinned Albums row lives outside the list
            case DestKind::Playlist:
                if (item.kind == SVRowKindPlaylist && SVToStd(item.title) == d.name) return (NSInteger)i;
                break;
            case DestKind::Artist:
                if (item.kind == SVRowKindArtist && SVToStd(item.title) == d.name) return (NSInteger)i;
                break;
            case DestKind::Album:
                break;   // album pages have no sidebar row
        }
    }
    return -1;
}

- (void)reflectDestination:(const Destination &)destination {
    [self reflectDestination:destination scroll:YES];
}

- (void)reflectDestination:(const Destination &)destination scroll:(BOOL)scroll {
    _reflected = destination;
    if (!self.isViewLoaded) return;
    NSInteger row = [self rowForDestination:destination];
    _reflecting = YES;
    const BOOL albums = destination.kind == DestKind::Albums;
    if (albums) {
        if (_homeTable.selectedRow != 0) [_homeTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    } else if (_homeTable.selectedRow >= 0) {
        [_homeTable deselectAll:nil];
    }
    if (row >= 0) {
        if (_table.selectedRow != row) {
            [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        }
        if (scroll) [_table scrollRowToVisible:row];
    } else {
        [_table deselectAll:nil];
    }
    _reflecting = NO;
}

- (void)setFilter:(LibraryFilter)filter {
    if (_filter == filter) return;
    _filter = filter;
    shell_config::setInt(shell_config::kLibraryFilter, (int64_t)filter);
    [self rebuildItemsReloading:NO];
    SVLibraryHeaderView *header = [self libraryHeaderView];
    header.playlistsChip.chipSelected = _filter == LibraryFilter::Playlists;
    header.artistsChip.chipSelected = _filter == LibraryFilter::Artists;
}

#pragma mark Actions

- (void)chipClicked:(SVChipButton *)sender {
    LibraryFilter tapped = [sender.title isEqualToString:@"Artists"] ? LibraryFilter::Artists : LibraryFilter::Playlists;
    [self setFilter:shellcore::toggleFilter(_filter, tapped)];
}

- (void)addClicked:(id)sender {
    [self createPlaylistAndBeginRename];
}

- (void)createPlaylistAndBeginRename {
    if (!self.isViewLoaded) return;
    if (_editingName) [self.view.window makeFirstResponder:_table];   // commit a pending rename first
    [self closeSearchReturningFocus:NO];   // the new playlist must not be filtered out
    if (!shellcore::showsPlaylists(_filter)) [self setFilter:LibraryFilter::All];

    std::string name;
    try {
        auto pm = playlist_manager::get();
        t_size idx = pm->create_playlist_autoname(pfc_infinite);
        name = SVPlaylistName(idx);
    } catch (...) {
        console::info("[ShellVanced] could not create playlist");
        return;
    }
    if (name.empty()) return;

    [self rebuildItemsReloading:NO];
    Destination d{DestKind::Playlist, name};
    [self reflectDestination:d];
    [self.delegate sidebar:self didChooseDestination:d];

    // Start editing on the next turn: the first visit instantiates the hosted
    // SimPlaylist, which may claim focus while it attaches to the window.
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger row = [self rowForDestination:d];
        if (row >= 0) [self beginRenameAtRow:row];
    });
}

- (SVSidebarItem *)playlistItemAtRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_items.count) return nil;
    SVSidebarItem *item = _items[(NSUInteger)row];
    return item.kind == SVRowKindPlaylist ? item : nil;
}

- (t_size)resolveItem:(SVSidebarItem *)item {
    return item ? SVFindPlaylistExact(SVToStd(item.title), item.playlistIndex) : pfc_infinite;
}

// Context-menu actions carry the playlist name; the row is looked up at action
// time because the list can change while the menu is open.
- (NSInteger)rowForPlaylistNamed:(NSString *)name {
    if (![name isKindOfClass:[NSString class]]) return -1;
    for (NSUInteger i = 0; i < _items.count; i++) {
        if (_items[i].kind == SVRowKindPlaylist && [_items[i].title isEqualToString:name]) return (NSInteger)i;
    }
    return -1;
}

- (void)playRow:(NSInteger)row {
    SVSidebarItem *item = [self playlistItemAtRow:row];
    t_size idx = [self resolveItem:item];
    if (idx == pfc_infinite || SVPlaylistItemCount(idx) == 0) return;
    try {
        upnext::fb::playPlaylistIntoNowPlaying(idx, 0);
    } catch (...) {
        console::info("[ShellVanced] play playlist failed");
    }
}

- (void)deleteRow:(NSInteger)row {
    SVSidebarItem *item = [self playlistItemAtRow:row];
    if (!item) return;
    NSString *name = item.title;
    t_size hint = item.playlistIndex;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Delete “%@”?", name];
    alert.informativeText = @"The playlist is removed from foobar2000. Your music files are not affected.";
    // Cancel is the first (default) button, so Return cancels; Delete must be clicked.
    [alert addButtonWithTitle:@"Cancel"];
    NSButton *del = [alert addButtonWithTitle:@"Delete"];
    if (@available(macOS 11.0, *)) del.hasDestructiveAction = YES;

    void (^confirm)(NSModalResponse) = ^(NSModalResponse response) {
        if (response != NSAlertSecondButtonReturn) return;
        t_size idx = SVFindPlaylistExact(SVToStd(name), hint);
        if (idx == pfc_infinite) return;
        try {
            playlist_manager::get()->remove_playlist(idx);
        } catch (...) {
            console::info("[ShellVanced] delete playlist failed");
        }
    };
    if (self.view.window) {
        [alert beginSheetModalForWindow:self.view.window completionHandler:confirm];
    } else {
        confirm([alert runModal]);
    }
}

#pragma mark Inline rename

- (void)beginRenameAtRow:(NSInteger)row {
    SVSidebarItem *item = [self playlistItemAtRow:row];
    if (!item || !self.view.window) return;
    [_table scrollRowToVisible:row];
    SVPlaylistCellView *cell = [_table viewAtColumn:0 row:row makeIfNecessary:YES];
    if (![cell isKindOfClass:[SVPlaylistCellView class]]) return;

    _editingName = [item.title copy];
    _editingIndexHint = item.playlistIndex;
    _renameCancelled = NO;
    cell.textField.editable = YES;
    cell.textField.selectable = YES;
    cell.textField.delegate = self;
    [self.view.window makeFirstResponder:cell.textField];   // selects the whole name
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (control == [self libraryHeaderView].searchField) {
        if (selector == @selector(cancelOperation:)) {   // Esc
            [self closeSearchReturningFocus:YES];
            return YES;
        }
        if (selector == @selector(moveDown:)) {
            [self searchMoveIntoList];
            return YES;
        }
        return NO;
    }
    if (selector == @selector(cancelOperation:) && _editingName) {
        _renameCancelled = YES;
        ((NSTextField *)control).stringValue = _editingName;
        [self.view.window makeFirstResponder:_table];
        return YES;
    }
    return NO;
}

- (void)controlTextDidChange:(NSNotification *)note {
    if (note.object == [self libraryHeaderView].searchField) [self searchTextChanged];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    NSTextField *field = note.object;
    if (field == (id)[self libraryHeaderView].searchField) return;   // leaving the search field keeps it open
    if (!_editingName || ![field isKindOfClass:[NSTextField class]]) return;

    NSString *original = _editingName;
    t_size hint = _editingIndexHint;
    BOOL cancelled = _renameCancelled;
    _editingName = nil;
    _editingIndexHint = pfc_infinite;
    _renameCancelled = NO;
    field.editable = NO;
    field.selectable = NO;
    field.delegate = nil;

    if (cancelled) {
        field.stringValue = original;
    } else {
        NSString *typed = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![self commitRenameFrom:original hint:hint to:typed]) field.stringValue = original;
    }

    // After Return/Escape focus would otherwise be left on the (now read-only)
    // field or the window; hand it back to the list. A click elsewhere keeps
    // its new target.
    NSWindow *window = self.view.window;
    NSTableView *table = _table;
    dispatch_async(dispatch_get_main_queue(), ^{
        id fr = window.firstResponder;
        BOOL stranded = fr == nil || fr == window || fr == field ||
            ([fr isKindOfClass:[NSTextView class]] && ((NSTextView *)fr).delegate == (id)field);
        if (stranded) [window makeFirstResponder:table];
    });
    if (_reloadPending) {
        _reloadPending = NO;
        [self rebuildItemsReloading:NO];
    }
}

// Returns NO (and beeps when the name is unusable) if nothing was renamed.
- (BOOL)commitRenameFrom:(NSString *)original hint:(t_size)hint to:(NSString *)typed {
    if (typed.length == 0 || [typed isEqualToString:original]) return NO;
    std::string oldName = SVToStd(original), newName = SVToStd(typed);
    try {
        auto pm = playlist_manager::get();
        t_size idx = SVFindPlaylistExact(oldName, hint);
        if (idx == pfc_infinite) return NO;
        // foobar matches names case-insensitively (find_playlist); refuse a
        // name that would alias another playlist or the Now Playing queue.
        t_size clash = pm->find_playlist(newName.c_str(), SIZE_MAX);
        bool isQueueName = pfc::stricmp_ascii(newName.c_str(), shellcore::kNowPlayingPlaylistName) == 0;
        if ((clash != pfc_infinite && clash != idx) || isQueueName) {
            NSBeep();
            return NO;
        }
        pm->playlist_rename(idx, newName.c_str(), SIZE_MAX);
        return YES;
    } catch (...) {
        console::info("[ShellVanced] rename failed");
    }
    return NO;
}

#pragma mark Keyboard

- (NSInteger)firstSelectableListRow {
    for (NSUInteger i = 0; i < _items.count; i++)
        if ([_items[i] isSelectable]) return (NSInteger)i;
    return -1;
}

// Down from the pinned Albums row: into the first list row.
- (BOOL)handleHomeKey:(NSEvent *)event {
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                               NSEventModifierFlagControl | NSEventModifierFlagShift)) return NO;
    if (event.charactersIgnoringModifiers.length != 1 ||
        [event.charactersIgnoringModifiers characterAtIndex:0] != NSDownArrowFunctionKey) return NO;
    NSInteger first = [self firstSelectableListRow];
    if (first < 0) return YES;
    [self.view.window makeFirstResponder:_table];
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)first] byExtendingSelection:NO];
    [_table scrollRowToVisible:first];
    return YES;
}

- (BOOL)handleTableKey:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                      NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (mods != 0 || event.charactersIgnoringModifiers.length != 1) return NO;
    unichar c = [event.charactersIgnoringModifiers characterAtIndex:0];
    NSInteger row = _table.selectedRow;
    if (c == NSUpArrowFunctionKey && row >= 0 && row == [self firstSelectableListRow]) {
        [self.view.window makeFirstResponder:_homeTable];   // Up from the first row reaches the pinned Albums row
        [_homeTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        return YES;
    }
    if (![self playlistItemAtRow:row]) return NO;
    if (c == '\r' || c == 3) {            // Return / Enter: rename (Finder convention)
        [self beginRenameAtRow:row];
        return YES;
    }
    if (c == 0x7F || c == NSDeleteFunctionKey) {
        [self deleteRow:row];
        return YES;
    }
    return NO;
}

#pragma mark Context menu

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = _table.clickedRow;
    SVSidebarItem *item = [self playlistItemAtRow:row];
    if (item) {
        NSMenuItem *play = [menu addItemWithTitle:@"Play" action:@selector(menuPlay:) keyEquivalent:@""];
        play.target = self;
        play.representedObject = item.title;
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *rename = [menu addItemWithTitle:@"Rename" action:@selector(menuRename:) keyEquivalent:@""];
        rename.target = self;
        rename.representedObject = item.title;
        NSMenuItem *del = [menu addItemWithTitle:@"Delete…" action:@selector(menuDelete:) keyEquivalent:@""];
        del.target = self;
        del.representedObject = item.title;
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem *add = [menu addItemWithTitle:@"New Playlist" action:@selector(addClicked:) keyEquivalent:@""];
    add.target = self;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(menuPlay:)) {
        return [self playlistItemAtRow:[self rowForPlaylistNamed:menuItem.representedObject]].itemCount > 0;
    }
    return YES;
}

- (void)menuPlay:(NSMenuItem *)sender   { [self playRow:[self rowForPlaylistNamed:sender.representedObject]]; }
- (void)menuRename:(NSMenuItem *)sender { [self beginRenameAtRow:[self rowForPlaylistNamed:sender.representedObject]]; }
- (void)menuDelete:(NSMenuItem *)sender { [self deleteRow:[self rowForPlaylistNamed:sender.representedObject]]; }

#pragma mark NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == _homeTable) return 1;
    return (NSInteger)_items.count;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row {
    if (tableView == _homeTable) return NO;
    return _items[(NSUInteger)row].kind == SVRowKindLibraryHeader;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    if (tableView == _homeTable) return kRowHeight;
    switch (_items[(NSUInteger)row].kind) {
        case SVRowKindLibraryHeader: return kHeaderRowHeight + (_searchOpen ? kSearchExtraHeight : 0);
        case SVRowKindSection:       return kSectionRowHeight;
        case SVRowKindArtist:        return kArtistRowHeight;
        default:                     return kRowHeight;
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    if (tableView == _homeTable) return YES;
    return [_items[(NSUInteger)row] isSelectable];
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (tableView == _homeTable) {
        SVPlaylistCellView *v = [tableView makeViewWithIdentifier:@"home" owner:self];
        if (!v) {
            v = [[SVPlaylistCellView alloc] initWithFrame:NSZeroRect];
            v.identifier = @"home";
        }
        v.imageView.image = [NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:nil];
        v.textField.stringValue = @"Albums";
        v.textField.editable = NO;
        v.textField.selectable = NO;
        v.countField.stringValue = @"";
        return v;
    }
    SVSidebarItem *item = _items[(NSUInteger)row];
    switch (item.kind) {
        case SVRowKindLibraryHeader: {
            SVLibraryHeaderView *v = [tableView makeViewWithIdentifier:@"header" owner:self];
            if (!v) {
                v = [[SVLibraryHeaderView alloc] initWithFrame:NSZeroRect];
                v.identifier = @"header";
                v.addButton.target = self;
                v.addButton.action = @selector(addClicked:);
                v.searchButton.target = self;
                v.searchButton.action = @selector(searchClicked:);
                v.searchField.delegate = self;
                NSButtonCell *cancel = [(NSSearchFieldCell *)v.searchField.cell cancelButtonCell];
                cancel.target = self;
                cancel.action = @selector(searchCancelClicked:);
                v.playlistsChip.target = self;
                v.playlistsChip.action = @selector(chipClicked:);
                v.artistsChip.target = self;
                v.artistsChip.action = @selector(chipClicked:);
            }
            v.playlistsChip.chipSelected = _filter == LibraryFilter::Playlists;
            v.artistsChip.chipSelected = _filter == LibraryFilter::Artists;
            v.searchExpanded = _searchOpen;
            if (!v.searchField.currentEditor) v.searchField.stringValue = _searchOpen ? (_query ?: @"") : @"";
            return v;
        }
        case SVRowKindSection: {
            NSTableCellView *v = [tableView makeViewWithIdentifier:@"section" owner:self];
            if (!v) {
                v = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
                v.identifier = @"section";
                NSTextField *label = [NSTextField labelWithString:@""];
                label.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
                label.textColor = [NSColor tertiaryLabelColor];
                label.translatesAutoresizingMaskIntoConstraints = NO;
                [v addSubview:label];
                v.textField = label;
                [NSLayoutConstraint activateConstraints:@[
                    [label.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:8],
                    [label.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-3],
                ]];
            }
            v.textField.stringValue = item.title;
            return v;
        }
        case SVRowKindNote: {
            NSTableCellView *v = [tableView makeViewWithIdentifier:@"note" owner:self];
            if (!v) {
                v = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
                v.identifier = @"note";
                NSTextField *label = [NSTextField labelWithString:@""];
                label.font = [NSFont systemFontOfSize:12];
                label.textColor = [NSColor tertiaryLabelColor];
                label.lineBreakMode = NSLineBreakByTruncatingTail;
                label.translatesAutoresizingMaskIntoConstraints = NO;
                [v addSubview:label];
                v.textField = label;
                [NSLayoutConstraint activateConstraints:@[
                    [label.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:30],
                    [label.trailingAnchor constraintLessThanOrEqualToAnchor:v.trailingAnchor constant:-8],
                    [label.centerYAnchor constraintEqualToAnchor:v.centerYAnchor],
                ]];
            }
            v.textField.stringValue = item.title;
            return v;
        }
        case SVRowKindArtist: {
            SVArtistCellView *v = [tableView makeViewWithIdentifier:@"artist" owner:self];
            if (!v) {
                v = [[SVArtistCellView alloc] initWithFrame:NSZeroRect];
                v.identifier = @"artist";
            }
            v.artistName = item.title;
            v.textField.stringValue = item.title;
            v.imageView.image = [SVArtistCellView placeholderPhoto];
            v.imageView.contentTintColor = [NSColor tertiaryLabelColor];
            NSString *name = item.title;
            __weak SVArtistCellView *weakCell = v;
            [[SVArtistImageProvider shared] imageForArtist:name size:kArtistPhotoSize completion:^(NSImage *image) {
                SVArtistCellView *cell = weakCell;
                // The cell may have been reused for another artist meanwhile.
                if (!image || !cell || ![cell.artistName isEqualToString:name]) return;
                cell.imageView.image = image;
                cell.imageView.contentTintColor = nil;
            }];
            return v;
        }
        case SVRowKindPlaylist: {
            SVPlaylistCellView *v = [tableView makeViewWithIdentifier:@"row" owner:self];
            if (!v) {
                v = [[SVPlaylistCellView alloc] initWithFrame:NSZeroRect];
                v.identifier = @"row";
            }
            v.imageView.image = [NSImage imageWithSystemSymbolName:@"music.note.list" accessibilityDescription:nil];
            v.textField.stringValue = item.title;
            v.textField.editable = NO;
            v.textField.selectable = NO;
            v.countField.stringValue = item.detail ?: @"";
            return v;
        }
    }
    return nil;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (_reflecting) return;
    if (notification.object == _homeTable) {
        if (_homeTable.selectedRow < 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self reflectDestination:self->_reflected scroll:NO]; });
            return;
        }
        _reflecting = YES;
        [_table deselectAll:nil];
        _reflecting = NO;
        Destination albums{DestKind::Albums, ""};
        if (albums == _reflected) return;
        _reflected = albums;
        [self.delegate sidebar:self didChooseDestination:albums];
        return;
    }
    NSInteger row = _table.selectedRow;
    if (row < 0) {
        // Clicking empty space: keep showing what the content shows.
        dispatch_async(dispatch_get_main_queue(), ^{ [self reflectDestination:self->_reflected scroll:NO]; });
        return;
    }
    SVSidebarItem *item = _items[(NSUInteger)row];
    if (_homeTable.selectedRow >= 0) {
        _reflecting = YES;
        [_homeTable deselectAll:nil];
        _reflecting = NO;
    }
    Destination d;
    switch (item.kind) {
        case SVRowKindPlaylist: d = {DestKind::Playlist, SVToStd(item.title)}; break;
        case SVRowKindArtist:   d = {DestKind::Artist, SVToStd(item.title)}; break;
        default: return;
    }
    if (d == _reflected) return;
    _reflected = d;
    [self.delegate sidebar:self didChooseDestination:d];
}

#pragma mark Drag and drop

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {
    // Tracks always append to the playlist under the cursor.
    SVSidebarItem *target = [self playlistItemAtRow:row];
    if (!target) return NSDragOperationNone;
    if (op != NSTableViewDropOn) [tableView setDropRow:row dropOperation:NSTableViewDropOn];

    NSPasteboard *pb = info.draggingPasteboard;
    // validateDrop runs on every mouse move: decode the payload once per drag.
    if (pb.changeCount != _dragChangeCount) {
        _dragChangeCount = pb.changeCount;
        _dragRows = SVReadRowsPayload(pb);
        _dragHasFiles = !_dragRows && SVReadFileURLs(pb).count > 0;
    }
    if (NSDictionary *rows = _dragRows) {
        NSNumber *src = rows[@"sourcePlaylist"];
        if (src && src.integerValue >= 0 &&
            SVPlaylistName((t_size)src.integerValue) == SVToStd(target.title)) {
            return NSDragOperationNone;   // dropping a playlist's rows on itself
        }
        return NSDragOperationCopy;
    }
    return _dragHasFiles ? NSDragOperationCopy : NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)op {
    SVSidebarItem *target = [self playlistItemAtRow:row];
    if (!target) return NO;
    std::string targetName = SVToStd(target.title);
    NSPasteboard *pb = info.draggingPasteboard;
    try {
        if (NSDictionary *rows = SVReadRowsPayload(pb)) {
            return [self acceptRows:rows into:targetName hint:target.playlistIndex];
        }
        NSArray<NSURL *> *urls = SVReadFileURLs(pb);
        if (urls.count == 0) return NO;
        auto notify = fb2k::service_new<SVDropImportNotify>(targetName);
        for (NSURL *url in urls) {
            if (url.isFileURL && url.path.length) notify->m_paths.add_item(url.path.UTF8String);
        }
        if (notify->m_paths.get_count() == 0) return NO;
        notify->start();
        return YES;
    } catch (...) {
        console::info("[ShellVanced] drop failed");
    }
    return NO;
}

// Rows from a playlist are copied as handles (keeps subsongs) when the source
// still matches the dragged paths; otherwise the paths are imported.
- (BOOL)acceptRows:(NSDictionary *)rows into:(const std::string &)targetName hint:(t_size)hint {
    auto pm = playlist_manager::get();
    t_size target = SVFindPlaylistExact(targetName, hint);
    if (target == pfc_infinite) return NO;

    NSNumber *src = rows[@"sourcePlaylist"];
    NSArray<NSNumber *> *indices = rows[@"indices"];
    NSArray<NSString *> *paths = rows[@"paths"];

    if (src && src.integerValue >= 0 && indices.count > 0 &&
        (t_size)src.integerValue < pm->get_playlist_count()) {
        t_size source = (t_size)src.integerValue;
        t_size count = pm->playlist_get_item_count(source);
        pfc::bit_array_bittable mask(count);
        bool valid = count > 0;
        for (NSNumber *n in indices) {
            t_size i = (t_size)n.integerValue;
            if (i >= count) { valid = false; break; }
            mask.set(i, true);
        }
        if (valid) {
            metadb_handle_list handles;
            pm->playlist_get_items(source, handles, mask);
            bool matches = handles.get_count() == indices.count;
            if (matches && paths.count == handles.get_count()) {
                // indices are ascending in SimPlaylist's payload, as is the mask order
                for (t_size i = 0; i < handles.get_count(); ++i) {
                    if (strcmp(handles[i]->get_path(), paths[i].UTF8String ?: "") != 0) { matches = false; break; }
                }
            }
            if (matches && handles.get_count() > 0) {
                pm->playlist_insert_items(target, pm->playlist_get_item_count(target), handles, pfc::bit_array_false());
                return YES;
            }
        }
    }

    if (paths.count == 0) return NO;
    auto notify = fb2k::service_new<SVDropImportNotify>(targetName);
    notify->m_noFilter = true;   // keep the dragged selection exactly as is
    for (NSString *p in paths) {
        if (p.length) notify->m_paths.add_item(p.UTF8String);
    }
    notify->start();
    return YES;
}

@end
