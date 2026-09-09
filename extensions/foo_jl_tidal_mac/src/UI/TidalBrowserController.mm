//
//  TidalBrowserController.mm
//  foo_jl_tidal_mac
//
//  Browser panel for searching and browsing Tidal catalog
//

#import "TidalBrowserController.h"
#import "TidalAlbumArtCache.h"
#import "../Core/BrowserLogic.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalModels.h"
#import "../Core/TidalPlaylistSync.h"
#import "../Core/URLUtils.h"
#import "../API/TidalAPI.h"
#import "../Services/TidalAuthService.h"
#include "../fb2k_sdk.h"
#import "../../../../shared/UIStyles.h"

// Column identifiers - tracks
static NSString * const kColumnArt = @"art";
static NSString * const kColumnTitle = @"title";
static NSString * const kColumnArtist = @"artist";
static NSString * const kColumnDuration = @"duration";
static NSString * const kColumnTrackNum = @"tracknum";
static NSString * const kColumnTrackQuality = @"trackquality";

// Column identifiers - albums
static NSString * const kColumnAlbumTitle = @"albumtitle";
static NSString * const kColumnAlbumArtist = @"albumartist";
static NSString * const kColumnAlbumTracks = @"albumtracks";
static NSString * const kColumnAlbumYear = @"albumyear";
static NSString * const kColumnAlbumQuality = @"albumquality";

// Column identifiers - artists
static NSString * const kColumnArtistName = @"artistname";

// Column identifiers - playlists
static NSString * const kColumnPlaylistTitle = @"playlisttitle";
static NSString * const kColumnPlaylistTracks = @"playlisttracks";

// UserDefaults keys for persisted search state
static NSString * const kDefaultsKeySearchType = @"JLTidalSearchType";
static NSString * const kDefaultsKeyLastSearch = @"JLTidalLastSearch";

// Page size for search/favorites pagination
static const NSInteger kPageSize = 50;

// Pasteboard type for drag operations
NSString * const JLTidalBrowserPasteboardType = @"com.foobar2000.tidal.browser.rows";

// Canonical tidal://track/<id> URL for playlist insertion and drag payloads.
// Single funnel delegating to the shared C++ builder in URLUtils.
static NSString *trackURLString(NSString *trackID) {
    return [NSString stringWithUTF8String:
            tidal::makeTrackURL(std::string(trackID.UTF8String ?: "")).c_str()];
}

// Root container view that reports no intrinsic content size, so the host fb2k
// column can be freely resized regardless of how wide our subviews would prefer to be.
@interface JLTidalContainerView : NSView
@end
@implementation JLTidalContainerView
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}
@end

// Notify class to keep paths alive during async import and handle playback
class TidalPlayNotify : public process_locations_notify {
public:
    t_size m_playlistIndex;
    t_size m_insertAt;
    pfc::string_list_impl m_paths;  // Keeps paths alive during async operation
    bool m_shouldPlay;
    bool m_shouldQueue;

    TidalPlayNotify(t_size playlistIndex, t_size insertAt, bool shouldPlay = true, bool shouldQueue = false)
        : m_playlistIndex(playlistIndex), m_insertAt(insertAt),
          m_shouldPlay(shouldPlay), m_shouldQueue(shouldQueue) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            if (m_playlistIndex < pm->get_playlist_count()) {
                pm->playlist_undo_backup(m_playlistIndex);
                pm->playlist_insert_items(m_playlistIndex, m_insertAt, items, pfc::bit_array_val(true));

                if (m_shouldPlay) {
                    pm->playlist_execute_default_action(m_playlistIndex, m_insertAt);
                }

                if (m_shouldQueue) {
                    // Queue each inserted item
                    for (t_size i = 0; i < items.get_count(); i++) {
                        pm->queue_add_item_playlist(m_playlistIndex, m_insertAt + i);
                    }
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

@interface JLTidalBrowserController ()
// UI elements
@property (nonatomic, strong) NSSegmentedControl *panelModeControl;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSSegmentedControl *searchTypeControl;
@property (nonatomic, strong) NSSegmentedControl *librarySectionControl;
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSTextField *breadcrumbLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *loadingSpinner;
@property (nonatomic, strong) NSView *navigationBar;
@property (nonatomic, strong) NSButton *syncPullButton;
@property (nonatomic, strong) NSButton *syncPushButton;

// State
@property (nonatomic, assign) JLTidalPanelMode panelMode;
@property (nonatomic, assign) JLTidalSearchType searchType;
@property (nonatomic, assign) JLTidalLibrarySection librarySection;
@property (nonatomic, assign) JLTidalBrowseMode browseMode;
@property (nonatomic, assign) BOOL isSearching;
@property (nonatomic, copy, nullable) NSString *lastSearchQuery;
@property (nonatomic, strong, nullable) NSTimer *searchDebounceTimer;
@property (nonatomic, assign) NSUInteger searchGeneration;

// Pagination
@property (nonatomic, assign) NSInteger currentOffset;
@property (nonatomic, assign) BOOL hasMoreResults;
@property (nonatomic, assign) BOOL isLoadingMore;

// Result arrays (only one is active at a time based on browseMode)
@property (nonatomic, strong) NSMutableArray<JLTidalTrack *> *trackResults;
@property (nonatomic, strong) NSMutableArray<JLTidalAlbum *> *albumResults;
@property (nonatomic, strong) NSMutableArray<JLTidalArtist *> *artistResults;
@property (nonatomic, strong) NSMutableArray<JLTidalPlaylist *> *playlistResults;

// Drill-down context
@property (nonatomic, copy, nullable) NSString *drillDownTitle;
@property (nonatomic, strong, nullable) JLTidalAlbum *currentAlbum;
@property (nonatomic, strong, nullable) JLTidalArtist *currentArtist;
@property (nonatomic, strong, nullable) JLTidalPlaylist *currentPlaylist;
@end

@implementation JLTidalBrowserController

#pragma mark - Initialization

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _trackResults = [NSMutableArray array];
        _albumResults = [NSMutableArray array];
        _artistResults = [NSMutableArray array];
        _playlistResults = [NSMutableArray array];
        _isSearching = NO;
        _isLoadingMore = NO;
        _hasMoreResults = NO;
        _currentOffset = 0;
        _panelMode = JLTidalPanelModeSearch;
        _librarySection = JLTidalLibrarySectionFavTracks;
        _browseMode = JLTidalBrowseModeSearchResults;

        // Restore saved search state (clamp: defaults can hold any integer)
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSInteger savedType = [defaults integerForKey:kDefaultsKeySearchType];
        if (savedType < JLTidalSearchTypeTracks || savedType > JLTidalSearchTypeArtists) {
            savedType = JLTidalSearchTypeTracks;
        }
        _searchType = (JLTidalSearchType)savedType;
        _lastSearchQuery = [defaults stringForKey:kDefaultsKeyLastSearch];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(authStateChanged:)
                                                     name:JLTidalAuthStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [_searchDebounceTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View Lifecycle

- (void)loadView {
    // CRITICAL: A plain NSView reports an intrinsic content size derived from its
    // subviews' constraints, which makes fb2k's splitter refuse to shrink the column
    // past the panel's natural width. Subclass + override intrinsicContentSize +
    // low hugging/compression priorities together let the column be sized freely.
    // Same pattern as AlbumArtView / BiographyContentView. See docs/PANEL_COLUMN_RESIZING.md.
    NSView *container = [[JLTidalContainerView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    container.wantsLayer = YES;
    [container setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [container setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [container setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [container setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationVertical];

    // Panel mode control (Search / Library)
    self.panelModeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Search", @"Library"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(panelModeChanged:)];
    self.panelModeControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.panelModeControl.selectedSegment = 0;
    self.panelModeControl.controlSize = NSControlSizeSmall;
    self.panelModeControl.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [container addSubview:self.panelModeControl];

    // Search field
    self.searchField = [[NSSearchField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Search Tidal...";
    self.searchField.delegate = self;
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.sendsWholeSearchString = NO;
    [container addSubview:self.searchField];

    // Search type segmented control
    self.searchTypeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Tracks", @"Albums", @"Artists"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(searchTypeChanged:)];
    self.searchTypeControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchTypeControl.selectedSegment = 0;
    self.searchTypeControl.controlSize = NSControlSizeSmall;
    self.searchTypeControl.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [container addSubview:self.searchTypeControl];

    // Library section control (Fav Tracks / Fav Albums / Playlists)
    self.librarySectionControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Favorites", @"Albums", @"Playlists"]
                                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                        target:self
                                                                        action:@selector(librarySectionChanged:)];
    self.librarySectionControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.librarySectionControl.selectedSegment = 0;
    self.librarySectionControl.controlSize = NSControlSizeSmall;
    self.librarySectionControl.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [self.librarySectionControl setHidden:YES];
    [container addSubview:self.librarySectionControl];

    // Sync buttons (Library mode only)
    self.syncPullButton = [NSButton buttonWithTitle:@"Pull" target:self action:@selector(syncPullClicked:)];
    self.syncPullButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.syncPullButton.bezelStyle = NSBezelStyleRecessed;
    self.syncPullButton.controlSize = NSControlSizeSmall;
    self.syncPullButton.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    self.syncPullButton.toolTip = @"Pull playlists from TIDAL to foobar2000";
    [self.syncPullButton setHidden:YES];
    [container addSubview:self.syncPullButton];

    self.syncPushButton = [NSButton buttonWithTitle:@"Push" target:self action:@selector(syncPushClicked:)];
    self.syncPushButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.syncPushButton.bezelStyle = NSBezelStyleRecessed;
    self.syncPushButton.controlSize = NSControlSizeSmall;
    self.syncPushButton.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    self.syncPushButton.toolTip = @"Push playlists from foobar2000 to TIDAL";
    [self.syncPushButton setHidden:YES];
    [container addSubview:self.syncPushButton];

    // Loading spinner
    self.loadingSpinner = [[NSProgressIndicator alloc] init];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    self.loadingSpinner.controlSize = NSControlSizeSmall;
    [self.loadingSpinner setHidden:YES];
    [container addSubview:self.loadingSpinner];

    // Navigation bar (back button + breadcrumb) - hidden by default
    self.navigationBar = [[NSView alloc] init];
    self.navigationBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.navigationBar setHidden:YES];
    [container addSubview:self.navigationBar];

    if (@available(macOS 11.0, *)) {
        NSImage *chevron = [NSImage imageWithSystemSymbolName:@"chevron.left"
                                    accessibilityDescription:@"Back"];
        self.backButton = [NSButton buttonWithImage:chevron target:self action:@selector(backButtonClicked:)];
    } else {
        self.backButton = [NSButton buttonWithTitle:@"<" target:self action:@selector(backButtonClicked:)];
    }
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.backButton.bezelStyle = NSBezelStyleRecessed;
    self.backButton.controlSize = NSControlSizeSmall;
    self.backButton.bordered = NO;
    [self.navigationBar addSubview:self.backButton];

    self.breadcrumbLabel = [NSTextField labelWithString:@""];
    self.breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.breadcrumbLabel.font = [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]];
    self.breadcrumbLabel.textColor = fb2k_ui::textColor();
    self.breadcrumbLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.navigationBar addSubview:self.breadcrumbLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.backButton.leadingAnchor constraintEqualToAnchor:self.navigationBar.leadingAnchor],
        [self.backButton.centerYAnchor constraintEqualToAnchor:self.navigationBar.centerYAnchor],
        [self.breadcrumbLabel.leadingAnchor constraintEqualToAnchor:self.backButton.trailingAnchor constant:6],
        [self.breadcrumbLabel.trailingAnchor constraintEqualToAnchor:self.navigationBar.trailingAnchor],
        [self.breadcrumbLabel.centerYAnchor constraintEqualToAnchor:self.navigationBar.centerYAnchor],
    ]];

    // Table view inside scroll view
    self.tableView = [[NSTableView alloc] init];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = 44;
    self.tableView.intercellSpacing = NSMakeSize(4, 2);
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.backgroundColor = fb2k_ui::backgroundColor();
    self.tableView.doubleAction = @selector(doubleClickRow:);
    self.tableView.target = self;

    // Register for dragging (both local and non-local)
    [self.tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];
    [self.tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [self.tableView registerForDraggedTypes:@[JLTidalBrowserPasteboardType]];

    // Configure columns for initial mode (tracks)
    [self setupColumnsForCurrentMode];

    // Context menu
    [self setupContextMenu];

    self.scrollView = [[NSScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.documentView = self.tableView;
    self.scrollView.hasVerticalScroller = YES;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.autohidesScrollers = YES;
    self.scrollView.borderType = NSBezelBorder;
    [container addSubview:self.scrollView];

    // Status label
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = fb2k_ui::statusBarFont();
    self.statusLabel.textColor = fb2k_ui::secondaryTextColor();
    [container addSubview:self.statusLabel];

    // Lower compression resistance on every controlled subview so the toolbar
    // controls don't pin the container's min width to the sum of their intrinsic
    // content widths. They'll clip gracefully when the column is narrowed.
    for (NSView *sv in @[self.panelModeControl, self.searchField, self.searchTypeControl,
                          self.librarySectionControl, self.navigationBar, self.scrollView,
                          self.statusLabel, self.syncPullButton, self.syncPushButton,
                          self.backButton, self.breadcrumbLabel]) {
        [sv setContentCompressionResistancePriority:1
                                       forOrientation:NSLayoutConstraintOrientationHorizontal];
        [sv setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    }

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Panel mode control (top row)
        [self.panelModeControl.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [self.panelModeControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.panelModeControl.heightAnchor constraintEqualToConstant:20],

        // Loading spinner (aligned to panel mode)
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.panelModeControl.centerYAnchor],
        [self.loadingSpinner.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.loadingSpinner.widthAnchor constraintEqualToConstant:16],
        [self.loadingSpinner.heightAnchor constraintEqualToConstant:16],

        // Search field (second row - search mode)
        [self.searchField.topAnchor constraintEqualToAnchor:self.panelModeControl.bottomAnchor constant:6],
        [self.searchField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.searchField.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.searchField.heightAnchor constraintEqualToConstant:24],

        // Search type control (third row - search mode)
        [self.searchTypeControl.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:6],
        [self.searchTypeControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.searchTypeControl.heightAnchor constraintEqualToConstant:20],

        // Library section control (second row - library mode, shares position with search field)
        [self.librarySectionControl.topAnchor constraintEqualToAnchor:self.panelModeControl.bottomAnchor constant:6],
        [self.librarySectionControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.librarySectionControl.heightAnchor constraintEqualToConstant:20],

        // Sync buttons (trailing side of library section row)
        [self.syncPushButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.syncPushButton.centerYAnchor constraintEqualToAnchor:self.librarySectionControl.centerYAnchor],
        [self.syncPullButton.trailingAnchor constraintEqualToAnchor:self.syncPushButton.leadingAnchor constant:-4],
        [self.syncPullButton.centerYAnchor constraintEqualToAnchor:self.librarySectionControl.centerYAnchor],

        // Navigation bar
        [self.navigationBar.topAnchor constraintEqualToAnchor:self.searchTypeControl.bottomAnchor constant:4],
        [self.navigationBar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.navigationBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.navigationBar.heightAnchor constraintEqualToConstant:20],

        // Scroll view (table)
        [self.scrollView.topAnchor constraintEqualToAnchor:self.navigationBar.bottomAnchor constant:4],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-4],

        // Status label
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4],
        [self.statusLabel.heightAnchor constraintEqualToConstant:16],
    ]];

    self.view = container;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Restore saved search state
    if (self.searchType >= 0 && self.searchType <= 2) {
        self.searchTypeControl.selectedSegment = self.searchType;
    }
    [self setupColumnsForCurrentMode];

    if (self.lastSearchQuery.length > 0) {
        self.searchField.stringValue = self.lastSearchQuery;
        [self searchWithQuery:self.lastSearchQuery];
    } else {
        [self updateStatusLabel];
    }

    // Observe scroll for pagination
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrollViewDidScroll:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:self.scrollView.contentView];
    self.scrollView.contentView.postsBoundsChangedNotifications = YES;
}

- (void)scrollViewDidScroll:(NSNotification *)notification {
    NSClipView *clipView = self.scrollView.contentView;
    if ([JLTidalBrowserLogic shouldTriggerLoadMoreWithHasMore:self.hasMoreResults
                                                isLoadingMore:self.isLoadingMore
                                                  isSearching:self.isSearching
                                                 scrollOffset:clipView.bounds.origin.y
                                                visibleHeight:clipView.bounds.size.height
                                                contentHeight:self.tableView.frame.size.height]) {
        [self loadMoreResults];
    }
}

- (void)setupContextMenu {
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Tidal Browser"];
    [contextMenu addItemWithTitle:@"Play" action:@selector(contextMenuPlay:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Add to Playlist" action:@selector(contextMenuAddToPlaylist:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Queue" action:@selector(contextMenuQueue:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Import as New Playlist" action:@selector(contextMenuImportAsPlaylist:) keyEquivalent:@""];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItemWithTitle:@"Add to Favorites" action:@selector(contextMenuAddFavorite:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Remove from Favorites" action:@selector(contextMenuRemoveFavorite:) keyEquivalent:@""];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItemWithTitle:@"Copy URL" action:@selector(contextMenuCopyURL:) keyEquivalent:@""];
    self.tableView.menu = contextMenu;
}

#pragma mark - Column Configuration

- (void)setupColumnsForCurrentMode {
    // Remove all existing columns
    while (self.tableView.tableColumns.count > 0) {
        [self.tableView removeTableColumn:self.tableView.tableColumns.lastObject];
    }

    if ([self isShowingTracks]) {
        [self setupTrackColumns];
    } else if ([self isShowingAlbums]) {
        [self setupAlbumColumns];
    } else if ([self isShowingArtists]) {
        [self setupArtistColumns];
    } else if ([self isShowingPlaylists]) {
        [self setupPlaylistColumns];
    }
}

- (void)setupTrackColumns {
    // Art column (thumbnail)
    NSTableColumn *artColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArt];
    artColumn.title = @"";
    artColumn.width = 40;
    artColumn.minWidth = 40;
    artColumn.maxWidth = 40;
    [self.tableView addTableColumn:artColumn];

    // Track number (only in album tracks mode)
    if (self.browseMode == JLTidalBrowseModeAlbumTracks) {
        NSTableColumn *trackNumColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnTrackNum];
        trackNumColumn.title = @"#";
        trackNumColumn.width = 30;
        trackNumColumn.minWidth = 30;
        trackNumColumn.maxWidth = 40;
        [self.tableView addTableColumn:trackNumColumn];
    }

    // Artist column (first data column)
    NSTableColumn *artistColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArtist];
    artistColumn.title = @"Artist";
    artistColumn.width = 150;
    artistColumn.minWidth = 80;
    [self.tableView addTableColumn:artistColumn];

    // Title column
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnTitle];
    titleColumn.title = @"Title";
    titleColumn.width = 200;
    titleColumn.minWidth = 100;
    [self.tableView addTableColumn:titleColumn];

    // Quality column
    NSTableColumn *qualityColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnTrackQuality];
    qualityColumn.title = @"Quality";
    qualityColumn.width = 60;
    qualityColumn.minWidth = 50;
    qualityColumn.maxWidth = 80;
    [self.tableView addTableColumn:qualityColumn];

    // Duration column
    NSTableColumn *durationColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnDuration];
    durationColumn.title = @"Duration";
    durationColumn.width = 50;
    durationColumn.minWidth = 50;
    durationColumn.maxWidth = 60;
    [self.tableView addTableColumn:durationColumn];
}

- (void)setupAlbumColumns {
    // Art column (thumbnail)
    NSTableColumn *artColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArt];
    artColumn.title = @"";
    artColumn.width = 40;
    artColumn.minWidth = 40;
    artColumn.maxWidth = 40;
    [self.tableView addTableColumn:artColumn];

    // Album artist (first data column)
    NSTableColumn *artistColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumArtist];
    artistColumn.title = @"Artist";
    artistColumn.width = 150;
    artistColumn.minWidth = 80;
    [self.tableView addTableColumn:artistColumn];

    // Album title
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumTitle];
    titleColumn.title = @"Album";
    titleColumn.width = 200;
    titleColumn.minWidth = 100;
    [self.tableView addTableColumn:titleColumn];

    // Year
    NSTableColumn *yearColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumYear];
    yearColumn.title = @"Year";
    yearColumn.width = 50;
    yearColumn.minWidth = 40;
    yearColumn.maxWidth = 60;
    [self.tableView addTableColumn:yearColumn];

    // Number of tracks
    NSTableColumn *tracksColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumTracks];
    tracksColumn.title = @"Tracks";
    tracksColumn.width = 50;
    tracksColumn.minWidth = 40;
    tracksColumn.maxWidth = 60;
    [self.tableView addTableColumn:tracksColumn];

    // Quality
    NSTableColumn *qualityColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumQuality];
    qualityColumn.title = @"Quality";
    qualityColumn.width = 60;
    qualityColumn.minWidth = 50;
    qualityColumn.maxWidth = 80;
    [self.tableView addTableColumn:qualityColumn];
}

- (void)setupArtistColumns {
    // Art column (picture)
    NSTableColumn *artColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArt];
    artColumn.title = @"";
    artColumn.width = 40;
    artColumn.minWidth = 40;
    artColumn.maxWidth = 40;
    [self.tableView addTableColumn:artColumn];

    // Artist name
    NSTableColumn *nameColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArtistName];
    nameColumn.title = @"Artist";
    nameColumn.width = 300;
    nameColumn.minWidth = 100;
    [self.tableView addTableColumn:nameColumn];
}

- (void)setupPlaylistColumns {
    // Art column
    NSTableColumn *artColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArt];
    artColumn.title = @"";
    artColumn.width = 40;
    artColumn.minWidth = 40;
    artColumn.maxWidth = 40;
    [self.tableView addTableColumn:artColumn];

    // Playlist title
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnPlaylistTitle];
    titleColumn.title = @"Playlist";
    titleColumn.width = 250;
    titleColumn.minWidth = 100;
    [self.tableView addTableColumn:titleColumn];

    // Track count
    NSTableColumn *tracksColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnPlaylistTracks];
    tracksColumn.title = @"Tracks";
    tracksColumn.width = 50;
    tracksColumn.minWidth = 40;
    tracksColumn.maxWidth = 60;
    [self.tableView addTableColumn:tracksColumn];
}

#pragma mark - Mode Helpers

// Active-list selection lives in JLTidalBrowserLogic (pure, unit-tested).

- (BOOL)isShowingTracks {
    return [JLTidalBrowserLogic isShowingTracksInBrowseMode:self.browseMode
                                                 searchType:self.searchType
                                             librarySection:self.librarySection];
}

- (BOOL)isShowingAlbums {
    return [JLTidalBrowserLogic isShowingAlbumsInBrowseMode:self.browseMode
                                                 searchType:self.searchType
                                             librarySection:self.librarySection];
}

- (BOOL)isShowingArtists {
    return [JLTidalBrowserLogic isShowingArtistsInBrowseMode:self.browseMode
                                                  searchType:self.searchType];
}

- (BOOL)isShowingPlaylists {
    return [JLTidalBrowserLogic isShowingPlaylistsInBrowseMode:self.browseMode
                                                librarySection:self.librarySection];
}

- (BOOL)isDrillDown {
    return [JLTidalBrowserLogic isDrillDownMode:self.browseMode];
}

#pragma mark - Panel Mode Switching

- (void)panelModeChanged:(id)sender {
    JLTidalPanelMode newMode = (JLTidalPanelMode)self.panelModeControl.selectedSegment;
    if (newMode == self.panelMode) return;

    self.panelMode = newMode;
    [self exitDrillDown];

    if (newMode == JLTidalPanelModeSearch) {
        [self.searchField setHidden:NO];
        [self.searchTypeControl setHidden:NO];
        [self.librarySectionControl setHidden:YES];
        [self.syncPullButton setHidden:YES];
        [self.syncPushButton setHidden:YES];
        self.browseMode = JLTidalBrowseModeSearchResults;
        [self setupColumnsForCurrentMode];
        [self.tableView reloadData];
        [self updateStatusForCurrentResults];
    } else {
        [self.searchField setHidden:YES];
        [self.searchTypeControl setHidden:YES];
        [self.librarySectionControl setHidden:NO];
        [self.syncPullButton setHidden:NO];
        [self.syncPushButton setHidden:NO];
        [self loadLibrarySection];
    }
}

#pragma mark - Library Section Switching

- (void)librarySectionChanged:(id)sender {
    JLTidalLibrarySection newSection = (JLTidalLibrarySection)self.librarySectionControl.selectedSegment;
    if ([JLTidalBrowserLogic librarySectionChangeIsNoOpFromSection:self.librarySection
                                                         toSection:newSection
                                                        browseMode:self.browseMode]) return;

    self.librarySection = newSection;
    [self exitDrillDown];
    [self loadLibrarySection];
}

- (void)loadLibrarySection {
    if (![[JLTidalAuthService shared] isAuthenticated]) {
        self.statusLabel.stringValue = @"Not signed in - configure in Preferences";
        return;
    }

    self.browseMode = JLTidalBrowseModeLibraryList;
    self.currentOffset = 0;
    self.hasMoreResults = NO;
    self.isSearching = YES;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];

    // Same stale-result guard as search: rapid section switching must not
    // let a slow earlier completion overwrite the newer section's state.
    self.searchGeneration++;
    NSUInteger generation = self.searchGeneration;
    // An in-flight load-more for the previous section will be dropped as
    // stale, so its flag must not block loading in the new section.
    self.isLoadingMore = NO;

    switch (self.librarySection) {
        case JLTidalLibrarySectionFavTracks: {
            [self setupColumnsForCurrentMode];
            self.statusLabel.stringValue = @"Loading favorites...";
            [self.trackResults removeAllObjects];
            [[JLTidalAPI shared] getFavoriteTracksWithLimit:kPageSize offset:0
                                                completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.searchGeneration) return; // Stale result
                    [self finishLoading];
                    if (error) {
                        self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed: %@", error.localizedDescription];
                        return;
                    }
                    if (tracks) [self.trackResults addObjectsFromArray:tracks];
                    self.currentOffset = (NSInteger)tracks.count;
                    self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)tracks.count
                                                                                     pageSize:kPageSize];
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [self statusForCount:self.trackResults.count
                                                                   noun:@"favorite track"
                                                                hasMore:self.hasMoreResults];
                });
            }];
            break;
        }

        case JLTidalLibrarySectionFavAlbums: {
            [self setupColumnsForCurrentMode];
            self.statusLabel.stringValue = @"Loading favorite albums...";
            [self.albumResults removeAllObjects];
            [[JLTidalAPI shared] getFavoriteAlbumsWithLimit:kPageSize offset:0
                                                completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.searchGeneration) return; // Stale result
                    [self finishLoading];
                    if (error) {
                        self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed: %@", error.localizedDescription];
                        return;
                    }
                    if (albums) [self.albumResults addObjectsFromArray:albums];
                    self.currentOffset = (NSInteger)albums.count;
                    self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)albums.count
                                                                                     pageSize:kPageSize];
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [self statusForCount:self.albumResults.count
                                                                   noun:@"favorite album"
                                                                hasMore:self.hasMoreResults];
                });
            }];
            break;
        }

        case JLTidalLibrarySectionPlaylists: {
            [self setupColumnsForCurrentMode];
            self.statusLabel.stringValue = @"Loading playlists...";
            [self.playlistResults removeAllObjects];
            [[JLTidalAPI shared] getUserPlaylistsWithCompletion:^(NSArray<JLTidalPlaylist *> *playlists, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.searchGeneration) return; // Stale result
                    [self finishLoading];
                    if (error) {
                        self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed: %@", error.localizedDescription];
                        return;
                    }
                    if (playlists) [self.playlistResults addObjectsFromArray:playlists];
                    self.hasMoreResults = NO;  // Playlists API returns all at once
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [self statusForCount:self.playlistResults.count
                                                                   noun:@"playlist"
                                                                hasMore:NO];
                });
            }];
            break;
        }
    }
}

#pragma mark - Search Type Switching

- (void)searchTypeChanged:(id)sender {
    JLTidalSearchType newType = (JLTidalSearchType)self.searchTypeControl.selectedSegment;
    if ([JLTidalBrowserLogic searchTypeChangeIsNoOpFromType:self.searchType
                                                     toType:newType
                                                 browseMode:self.browseMode]) {
        return;
    }

    self.searchType = newType;

    // Exit drill-down if active
    [self exitDrillDown];

    // Always reconfigure columns for the new search type
    // (exitDrillDown skips this when already in SearchResults mode)
    [self setupColumnsForCurrentMode];
    [self.tableView reloadData];

    // Re-run search with new type if there's a query
    if (self.lastSearchQuery.length > 0) {
        [self searchWithQuery:self.lastSearchQuery];
    }
}

#pragma mark - Navigation

- (void)enterDrillDown:(JLTidalBrowseMode)mode title:(NSString *)title {
    self.browseMode = mode;
    self.drillDownTitle = title;
    self.breadcrumbLabel.stringValue = title;
    [self.navigationBar setHidden:NO];
    [self setupColumnsForCurrentMode];
}

- (void)exitDrillDown {
    if (![JLTidalBrowserLogic isDrillDownMode:self.browseMode]) return;

    self.browseMode = [JLTidalBrowserLogic rootModeForPanelMode:self.panelMode];
    self.drillDownTitle = nil;
    self.currentAlbum = nil;
    self.currentArtist = nil;
    self.currentPlaylist = nil;
    [self.navigationBar setHidden:YES];
    [self setupColumnsForCurrentMode];
    [self.tableView reloadData];
    [self updateStatusForCurrentResults];
}

- (void)backButtonClicked:(id)sender {
    // ArtistTopTracks goes back to artist albums; everything else
    // collapses straight to the root (search results / library list)
    if ([JLTidalBrowserLogic backReturnsToArtistAlbumsFromMode:self.browseMode
                                                     hasArtist:(self.currentArtist != nil)]) {
        [self drillIntoArtist:self.currentArtist];
        return;
    }
    [self exitDrillDown];
}

#pragma mark - Search

- (void)searchWithQuery:(NSString *)query {
    if (query.length == 0) {
        [self clearResults];
        return;
    }

    if (![[JLTidalAuthService shared] isAuthenticated]) {
        self.statusLabel.stringValue = @"Not signed in - configure in Preferences";
        return;
    }

    self.lastSearchQuery = query;
    self.currentOffset = 0;
    self.hasMoreResults = NO;
    self.isSearching = YES;
    self.searchGeneration++;

    // Persist search state
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:query forKey:kDefaultsKeyLastSearch];
    [defaults setInteger:self.searchType forKey:kDefaultsKeySearchType];

    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Searching for \"%@\"...", query];

    tidal::logDebug([[NSString stringWithFormat:@"Searching Tidal for: %@ (type=%ld)", query, (long)self.searchType] UTF8String]);

    switch (self.searchType) {
        case JLTidalSearchTypeTracks:
            [self.trackResults removeAllObjects];
            [self searchTracksWithQuery:query offset:0];
            break;
        case JLTidalSearchTypeAlbums:
            [self.albumResults removeAllObjects];
            [self searchAlbumsWithQuery:query offset:0];
            break;
        case JLTidalSearchTypeArtists:
            [self.artistResults removeAllObjects];
            [self searchArtistsWithQuery:query offset:0];
            break;
    }
}

- (void)searchTracksWithQuery:(NSString *)query offset:(NSInteger)offset {
    NSUInteger generation = self.searchGeneration;
    [[JLTidalAPI shared] searchTracksWithQuery:query
                                         limit:kPageSize
                                        offset:offset
                                    completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return; // Stale result
            [self finishLoading];
            self.isLoadingMore = NO;

            if (error) {
                [self showError:error.localizedDescription forQuery:query];
                return;
            }

            if (tracks) [self.trackResults addObjectsFromArray:tracks];
            self.currentOffset = [JLTidalBrowserLogic offsetAfterSearchPageAtOffset:offset
                                                                      returnedCount:(NSInteger)tracks.count];
            self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)tracks.count
                                                                             pageSize:kPageSize];
            [self.tableView reloadData];

            if (self.trackResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No tracks for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [self statusForCount:self.trackResults.count
                                                               noun:@"track"
                                                            hasMore:self.hasMoreResults];
            }
        });
    }];
}

- (void)searchAlbumsWithQuery:(NSString *)query offset:(NSInteger)offset {
    NSUInteger generation = self.searchGeneration;
    [[JLTidalAPI shared] searchAlbumsWithQuery:query
                                         limit:kPageSize
                                        offset:offset
                                    completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return; // Stale result
            [self finishLoading];
            self.isLoadingMore = NO;

            if (error) {
                [self showError:error.localizedDescription forQuery:query];
                return;
            }

            if (albums) [self.albumResults addObjectsFromArray:albums];
            self.currentOffset = [JLTidalBrowserLogic offsetAfterSearchPageAtOffset:offset
                                                                      returnedCount:(NSInteger)albums.count];
            self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)albums.count
                                                                             pageSize:kPageSize];
            [self.tableView reloadData];

            if (self.albumResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No albums for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [self statusForCount:self.albumResults.count
                                                               noun:@"album"
                                                            hasMore:self.hasMoreResults];
            }
        });
    }];
}

- (void)searchArtistsWithQuery:(NSString *)query offset:(NSInteger)offset {
    NSUInteger generation = self.searchGeneration;
    [[JLTidalAPI shared] searchArtistsWithQuery:query
                                          limit:kPageSize
                                         offset:offset
                                     completion:^(NSArray<JLTidalArtist *> *artists, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.searchGeneration) return; // Stale result
            [self finishLoading];
            self.isLoadingMore = NO;

            if (error) {
                [self showError:error.localizedDescription forQuery:query];
                return;
            }

            if (artists) [self.artistResults addObjectsFromArray:artists];
            self.currentOffset = [JLTidalBrowserLogic offsetAfterSearchPageAtOffset:offset
                                                                      returnedCount:(NSInteger)artists.count];
            self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)artists.count
                                                                             pageSize:kPageSize];
            [self.tableView reloadData];

            if (self.artistResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No artists for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [self statusForCount:self.artistResults.count
                                                               noun:@"artist"
                                                            hasMore:self.hasMoreResults];
            }
        });
    }];
}

- (void)loadMoreResults {
    if (!self.hasMoreResults || self.isLoadingMore) return;

    self.isLoadingMore = YES;
    self.statusLabel.stringValue = @"Loading more...";

    if (self.browseMode == JLTidalBrowseModeSearchResults && self.lastSearchQuery.length > 0) {
        switch (self.searchType) {
            case JLTidalSearchTypeTracks:
                [self searchTracksWithQuery:self.lastSearchQuery offset:self.currentOffset];
                break;
            case JLTidalSearchTypeAlbums:
                [self searchAlbumsWithQuery:self.lastSearchQuery offset:self.currentOffset];
                break;
            case JLTidalSearchTypeArtists:
                [self searchArtistsWithQuery:self.lastSearchQuery offset:self.currentOffset];
                break;
        }
    } else if (self.browseMode == JLTidalBrowseModeLibraryList) {
        [self loadMoreLibraryResults];
    } else {
        self.isLoadingMore = NO;
    }
}

- (void)loadMoreLibraryResults {
    // Stale-result guard: drop the completion if the user switched
    // sections (or searched) while the page was loading.
    NSUInteger generation = self.searchGeneration;
    switch (self.librarySection) {
        case JLTidalLibrarySectionFavTracks: {
            [[JLTidalAPI shared] getFavoriteTracksWithLimit:kPageSize offset:self.currentOffset
                                                completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.searchGeneration) return; // Stale result
                    self.isLoadingMore = NO;
                    if (error || !tracks) return;
                    [self.trackResults addObjectsFromArray:tracks];
                    self.currentOffset += (NSInteger)tracks.count;
                    self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)tracks.count
                                                                                     pageSize:kPageSize];
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [self statusForCount:self.trackResults.count
                                                                   noun:@"favorite track"
                                                                hasMore:self.hasMoreResults];
                });
            }];
            break;
        }

        case JLTidalLibrarySectionFavAlbums: {
            [[JLTidalAPI shared] getFavoriteAlbumsWithLimit:kPageSize offset:self.currentOffset
                                                completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.searchGeneration) return; // Stale result
                    self.isLoadingMore = NO;
                    if (error || !albums) return;
                    [self.albumResults addObjectsFromArray:albums];
                    self.currentOffset += (NSInteger)albums.count;
                    self.hasMoreResults = [JLTidalBrowserLogic hasMorePagesAfterReturnedCount:(NSInteger)albums.count
                                                                                     pageSize:kPageSize];
                    [self.tableView reloadData];
                    self.statusLabel.stringValue = [self statusForCount:self.albumResults.count
                                                                   noun:@"favorite album"
                                                                hasMore:self.hasMoreResults];
                });
            }];
            break;
        }

        case JLTidalLibrarySectionPlaylists: {
            self.isLoadingMore = NO;
            self.hasMoreResults = NO;
            break;
        }
    }
}

- (void)finishLoading {
    self.isSearching = NO;
    [self.loadingSpinner setHidden:YES];
    [self.loadingSpinner stopAnimation:nil];
}

- (void)showError:(NSString *)errorMessage forQuery:(NSString *)query {
    NSString *message = query.length > 0
        ? [NSString stringWithFormat:@"Search for \"%@\" failed: %@", query, errorMessage]
        : [NSString stringWithFormat:@"Search failed: %@", errorMessage];
    tidal::logError([message UTF8String]);
    self.statusLabel.stringValue = message;
}

- (void)clearResults {
    [self.trackResults removeAllObjects];
    [self.albumResults removeAllObjects];
    [self.artistResults removeAllObjects];
    [self.playlistResults removeAllObjects];
    self.currentOffset = 0;
    self.hasMoreResults = NO;
    self.isLoadingMore = NO;
    [self exitDrillDown];
    [self.tableView reloadData];
    [self updateStatusLabel];
}

#pragma mark - Drill-Down

- (void)drillIntoAlbum:(JLTidalAlbum *)album {
    self.currentAlbum = album;
    [self enterDrillDown:JLTidalBrowseModeAlbumTracks
                   title:[NSString stringWithFormat:@"%@ - %@", album.artist ?: @"", album.title]];

    self.isSearching = YES;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];
    self.statusLabel.stringValue = @"Loading album tracks...";

    [[JLTidalAPI shared] getAlbumTracksForAlbumID:album.albumID
                                       completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed to load album: %@", error.localizedDescription];
                return;
            }

            [self.trackResults removeAllObjects];
            if (tracks) [self.trackResults addObjectsFromArray:tracks];
            [self.tableView reloadData];

            self.statusLabel.stringValue = [self statusForCount:self.trackResults.count
                                                           noun:@"track"
                                                        hasMore:NO];
        });
    }];
}

- (void)drillIntoArtist:(JLTidalArtist *)artist {
    self.currentArtist = artist;
    [self enterDrillDown:JLTidalBrowseModeArtistAlbums
                   title:artist.name];

    self.isSearching = YES;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];
    self.statusLabel.stringValue = @"Loading artist...";

    [[JLTidalAPI shared] getArtistAlbumsForArtistID:artist.artistID
                                              limit:50
                                         completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || albums.count == 0) {
                // Fallback to top tracks if no albums (common for collaboration artists)
                tidal::logDebug([[NSString stringWithFormat:@"No albums for artist %@, trying top tracks",
                                  artist.artistID] UTF8String]);
                [self loadArtistTopTracks:artist];
                return;
            }

            [self finishLoading];
            [self.albumResults removeAllObjects];
            [self.albumResults addObjectsFromArray:albums];
            [self.tableView reloadData];

            self.statusLabel.stringValue = [self statusForCount:self.albumResults.count
                                                           noun:@"album"
                                                        hasMore:NO];
        });
    }];
}

- (void)loadArtistTopTracks:(JLTidalArtist *)artist {
    // Switch to top tracks mode
    self.browseMode = JLTidalBrowseModeArtistTopTracks;
    [self setupColumnsForCurrentMode];

    [[JLTidalAPI shared] getArtistTopTracksForArtistID:artist.artistID
                                                  limit:50
                                             completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed: %@", error.localizedDescription];
                return;
            }

            [self.trackResults removeAllObjects];
            if (tracks) [self.trackResults addObjectsFromArray:tracks];
            [self.tableView reloadData];

            self.statusLabel.stringValue = [self statusForCount:self.trackResults.count
                                                           noun:@"top track"
                                                        hasMore:NO];
        });
    }];
}

- (void)drillIntoPlaylist:(JLTidalPlaylist *)playlist {
    self.currentPlaylist = playlist;
    [self enterDrillDown:JLTidalBrowseModePlaylistTracks
                   title:playlist.title];

    self.isSearching = YES;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];
    self.statusLabel.stringValue = @"Loading playlist tracks...";

    [[JLTidalAPI shared] getPlaylistTracksForPlaylistID:playlist.playlistUUID
                                                  limit:100
                                                 offset:0
                                             completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed to load playlist: %@", error.localizedDescription];
                return;
            }

            [self.trackResults removeAllObjects];
            if (tracks) [self.trackResults addObjectsFromArray:tracks];
            [self.tableView reloadData];

            self.statusLabel.stringValue = [self statusForCount:self.trackResults.count
                                                           noun:@"track"
                                                        hasMore:NO];
        });
    }];
}

#pragma mark - Status

// Pluralized result-count status, e.g. "5 favorite tracks (scroll for more)".
- (NSString *)statusForCount:(NSUInteger)count noun:(NSString *)noun hasMore:(BOOL)hasMore {
    return [NSString stringWithFormat:@"%lu %@%@%@",
            (unsigned long)count, noun,
            count == 1 ? @"" : @"s",
            hasMore ? @" (scroll for more)" : @""];
}

- (void)updateStatusLabel {
    if ([[JLTidalAuthService shared] isAuthenticated]) {
        JLTidalSession *session = [[JLTidalAuthService shared] session];
        NSString *username = session.username;
        if (!username.length) {
            username = @"Tidal User";
        }
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Signed in as %@", username];
    } else {
        self.statusLabel.stringValue = @"Not signed in - configure in Preferences";
    }
}

- (void)updateStatusForCurrentResults {
    if ([self isShowingTracks]) {
        NSUInteger count = self.trackResults.count;
        if (count == 0) {
            self.statusLabel.stringValue = @"";
        } else {
            self.statusLabel.stringValue = [self statusForCount:count noun:@"track" hasMore:NO];
        }
    } else if ([self isShowingAlbums]) {
        NSUInteger count = self.albumResults.count;
        if (count == 0) {
            self.statusLabel.stringValue = @"";
        } else {
            self.statusLabel.stringValue = [self statusForCount:count noun:@"album" hasMore:NO];
        }
    } else if ([self isShowingArtists]) {
        NSUInteger count = self.artistResults.count;
        if (count == 0) {
            self.statusLabel.stringValue = @"";
        } else {
            self.statusLabel.stringValue = [self statusForCount:count noun:@"artist" hasMore:NO];
        }
    }
}

- (void)authStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusLabel];
        if (![[JLTidalAuthService shared] isAuthenticated]) {
            [self clearResults];
        }
    });
}

#pragma mark - NSSearchFieldDelegate

- (void)controlTextDidChange:(NSNotification *)notification {
    NSSearchField *field = notification.object;
    if (field != self.searchField) return;

    // Cancel previous debounce timer
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;

    NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (query.length == 0) {
        [self clearResults];
        return;
    }

    // Debounce: wait 400ms after last keystroke before searching
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                               target:self
                                                             selector:@selector(debounceSearchFired:)
                                                             userInfo:nil
                                                              repeats:NO];
}

- (void)debounceSearchFired:(NSTimer *)timer {
    NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (query.length == 0) return;

    // Exit drill-down when user types a new search
    if ([self isDrillDown]) {
        [self exitDrillDown];
    }

    [self searchWithQuery:query];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    // Also search on Enter (immediate, no debounce)
    NSSearchField *field = notification.object;
    if (field != self.searchField) return;

    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;

    NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([self isDrillDown]) {
        [self exitDrillDown];
    }

    if (query.length > 0) {
        [self searchWithQuery:query];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if ([self isShowingTracks]) {
        return (NSInteger)self.trackResults.count;
    } else if ([self isShowingAlbums]) {
        return (NSInteger)self.albumResults.count;
    } else if ([self isShowingArtists]) {
        return (NSInteger)self.artistResults.count;
    } else if ([self isShowingPlaylists]) {
        return (NSInteger)self.playlistResults.count;
    }
    return 0;
}

#pragma mark - NSTableViewDelegate

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    static NSString * const kRowViewID = @"TidalBrowserRowView";
    NSTableRowView *rowView = [tableView makeViewWithIdentifier:kRowViewID owner:self];
    if (!rowView) {
        rowView = [[NSTableRowView alloc] init];
        rowView.identifier = kRowViewID;
    }
    rowView.backgroundColor = (row % 2 == 1) ? fb2k_ui::alternateRowColor() : fb2k_ui::backgroundColor();
    return rowView;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if ([self isShowingTracks]) {
        return [self trackCellForColumn:tableColumn row:row];
    } else if ([self isShowingAlbums]) {
        return [self albumCellForColumn:tableColumn row:row];
    } else if ([self isShowingArtists]) {
        return [self artistCellForColumn:tableColumn row:row];
    } else if ([self isShowingPlaylists]) {
        return [self playlistCellForColumn:tableColumn row:row];
    }
    return nil;
}

#pragma mark - Track Cell Rendering

- (NSView *)trackCellForColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.trackResults.count) return nil;

    JLTidalTrack *track = self.trackResults[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:kColumnArt]) {
        return [self artCellForCoverID:track.coverID identifier:identifier];
    }

    if ([identifier isEqualToString:kColumnTrackNum]) {
        return [self textCell:identifier
                         text:[NSString stringWithFormat:@"%ld", (long)track.trackNumber]
                         font:fb2k_ui::monospacedDigitFont()
                        color:fb2k_ui::secondaryTextColor()];
    }

    if ([identifier isEqualToString:kColumnTitle]) {
        return [self textCell:identifier text:track.title ?: @""
                         font:fb2k_ui::rowFont() color:fb2k_ui::textColor()];
    }

    if ([identifier isEqualToString:kColumnArtist]) {
        return [self textCell:identifier text:track.artist ?: @""
                         font:fb2k_ui::rowFont() color:fb2k_ui::secondaryTextColor()];
    }

    if ([identifier isEqualToString:kColumnTrackQuality]) {
        return [self qualityBadgeCell:identifier quality:track.audioQuality];
    }

    if ([identifier isEqualToString:kColumnDuration]) {
        return [self textCell:identifier text:[self formatDuration:track.duration]
                         font:fb2k_ui::monospacedDigitFont() color:fb2k_ui::secondaryTextColor()];
    }

    return nil;
}

#pragma mark - Album Cell Rendering

- (NSView *)albumCellForColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.albumResults.count) return nil;

    JLTidalAlbum *album = self.albumResults[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:kColumnArt]) {
        return [self artCellForCoverID:album.coverID identifier:identifier];
    }

    if ([identifier isEqualToString:kColumnAlbumTitle]) {
        return [self textCell:identifier text:album.title ?: @""
                         font:fb2k_ui::rowFont() color:fb2k_ui::textColor()];
    }

    if ([identifier isEqualToString:kColumnAlbumArtist]) {
        return [self textCell:identifier text:album.artist ?: @""
                         font:fb2k_ui::rowFont() color:fb2k_ui::secondaryTextColor()];
    }

    if ([identifier isEqualToString:kColumnAlbumTracks]) {
        NSString *txt = album.numberOfTracks > 0
            ? [NSString stringWithFormat:@"%ld", (long)album.numberOfTracks]
            : @"";
        return [self textCell:identifier
                         text:txt
                         font:fb2k_ui::monospacedDigitFont() color:fb2k_ui::secondaryTextColor()];
    }

    if ([identifier isEqualToString:kColumnAlbumYear]) {
        NSString *yearStr = @"";
        if (album.releaseDate) {
            // [NSCalendar currentCalendar] allocates; this runs per visible row
            static NSCalendar *cal = nil;
            static dispatch_once_t calOnce;
            dispatch_once(&calOnce, ^{
                cal = [NSCalendar currentCalendar];
            });
            NSInteger year = [cal component:NSCalendarUnitYear fromDate:album.releaseDate];
            if (year > 0) yearStr = [NSString stringWithFormat:@"%ld", (long)year];
        }
        return [self textCell:identifier text:yearStr
                         font:fb2k_ui::monospacedDigitFont() color:fb2k_ui::secondaryTextColor()];
    }

    if ([identifier isEqualToString:kColumnAlbumQuality]) {
        return [self qualityBadgeCell:identifier quality:album.audioQuality];
    }

    return nil;
}

#pragma mark - Artist Cell Rendering

- (NSView *)artistCellForColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.artistResults.count) return nil;

    JLTidalArtist *artist = self.artistResults[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:kColumnArt]) {
        return [self artCellForCoverID:artist.pictureID identifier:identifier];
    }

    if ([identifier isEqualToString:kColumnArtistName]) {
        return [self textCell:identifier text:artist.name ?: @""
                         font:fb2k_ui::rowFont() color:fb2k_ui::textColor()];
    }

    return nil;
}

#pragma mark - Playlist Cell Rendering

- (NSView *)playlistCellForColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.playlistResults.count) return nil;

    JLTidalPlaylist *playlist = self.playlistResults[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:kColumnArt]) {
        return [self artCellForCoverID:playlist.coverID identifier:identifier];
    }

    if ([identifier isEqualToString:kColumnPlaylistTitle]) {
        return [self textCell:identifier text:playlist.title ?: @""
                         font:fb2k_ui::rowFont() color:fb2k_ui::textColor()];
    }

    if ([identifier isEqualToString:kColumnPlaylistTracks]) {
        return [self textCell:identifier
                         text:[NSString stringWithFormat:@"%ld", (long)playlist.numberOfTracks]
                         font:fb2k_ui::monospacedDigitFont() color:fb2k_ui::secondaryTextColor()];
    }

    return nil;
}

#pragma mark - Cell Factory Methods

- (NSTableCellView *)artCellForCoverID:(NSString *)coverID identifier:(NSString *)identifier {
    NSTableCellView *cell = [self.tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = identifier;

        NSImageView *imageView = [[NSImageView alloc] init];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
        imageView.wantsLayer = YES;
        imageView.layer.cornerRadius = 4;
        imageView.layer.masksToBounds = YES;
        [cell addSubview:imageView];
        cell.imageView = imageView;

        [NSLayoutConstraint activateConstraints:@[
            [imageView.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
            [imageView.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [imageView.widthAnchor constraintEqualToConstant:36],
            [imageView.heightAnchor constraintEqualToConstant:36],
        ]];
    }

    // Record which cover this image view currently represents so a late
    // download completion for a recycled cell is dropped instead of
    // painting the wrong artwork.
    cell.imageView.identifier = coverID.length > 0 ? coverID : @"";

    if (coverID.length > 0) {
        NSImage *cached = [[JLTidalAlbumArtCache shared] cachedImageForCoverID:coverID size:80];
        if (cached) {
            cell.imageView.image = cached;
            cell.imageView.contentTintColor = nil;
        } else {
            [self setPlaceholderImage:cell.imageView];
            // Use weak self to prevent retaining the controller while images load.
            // Update the specific cell directly instead of reloading all visible rows
            // to avoid an O(n^2) cascade of reloads and pending completion blocks.
            __weak typeof(self) weakSelf = self;
            __weak NSImageView *weakImageView = cell.imageView;
            [[JLTidalAlbumArtCache shared] loadImageForCoverID:coverID
                                                          size:80
                                                    completion:^(NSImage *image) {
                if (!image || !weakSelf || !weakImageView) return;
                if (![weakImageView.identifier isEqualToString:coverID]) return; // cell reused
                weakImageView.image = image;
                weakImageView.contentTintColor = nil;
            }];
        }
    } else {
        [self setPlaceholderImage:cell.imageView];
    }

    return cell;
}

- (void)setPlaceholderImage:(NSImageView *)imageView {
    if (@available(macOS 11.0, *)) {
        imageView.image = [NSImage imageWithSystemSymbolName:@"music.note"
                                     accessibilityDescription:@"No artwork"];
        imageView.contentTintColor = [NSColor tertiaryLabelColor];
    }
}

- (NSTableCellView *)textCell:(NSString *)identifier text:(NSString *)text
                         font:(NSFont *)font color:(NSColor *)color {
    NSTableCellView *cell = [self.tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell || !cell.textField) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = identifier;

        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        textField.drawsBackground = NO;
        textField.bordered = NO;
        textField.editable = NO;
        textField.selectable = NO;
        [cell addSubview:textField];
        cell.textField = textField;

        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [textField.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [textField.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    cell.textField.stringValue = text ?: @"";
    cell.textField.font = font;
    cell.textField.textColor = color;
    return cell;
}

- (NSTableCellView *)qualityBadgeCell:(NSString *)identifier quality:(NSString *)quality {
    NSTableCellView *cell = [self textCell:identifier text:@"" font:fb2k_ui::statusBarFont()
                                    color:fb2k_ui::secondaryTextColor()];

    if ([quality isEqualToString:@"HI_RES_LOSSLESS"] || [quality isEqualToString:@"HI_RES"]) {
        cell.textField.stringValue = @"Hi-Res";
        cell.textField.textColor = [NSColor systemOrangeColor];
    } else if ([quality isEqualToString:@"LOSSLESS"]) {
        cell.textField.stringValue = @"Lossless";
        cell.textField.textColor = [NSColor systemGreenColor];
    } else if ([quality isEqualToString:@"HIGH"]) {
        cell.textField.stringValue = @"High";
        cell.textField.textColor = fb2k_ui::secondaryTextColor();
    } else {
        cell.textField.stringValue = quality ?: @"";
    }

    return cell;
}

#pragma mark - Drag & Drop

- (nullable id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    // Called once per dragged row; skip the eager NSString formatting
    // unless debug logging is actually enabled (same as URLUtils).
    if (tidal::isDebugLoggingCached()) {
        tidal::logDebug([[NSString stringWithFormat:@"Drag: pasteboardWriterForRow:%ld called (showingTracks=%d, trackCount=%lu)",
                          (long)row, [self isShowingTracks], (unsigned long)self.trackResults.count] UTF8String]);
    }
    // Only allow dragging tracks
    if (![self isShowingTracks]) {
        tidal::logDebug("Drag: rejected - not showing tracks");
        return nil;
    }
    if (row < 0 || row >= (NSInteger)self.trackResults.count) {
        tidal::logDebug("Drag: rejected - row out of bounds");
        return nil;
    }

    // Determine which rows are being dragged
    NSIndexSet *draggedRows;
    if ([self.tableView.selectedRowIndexes containsIndex:(NSUInteger)row]) {
        draggedRows = self.tableView.selectedRowIndexes;
    } else {
        draggedRows = [NSIndexSet indexSetWithIndex:(NSUInteger)row];
    }

    NSMutableArray *urls = [NSMutableArray array];
    [draggedRows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.trackResults.count) {
            JLTidalTrack *track = self.trackResults[idx];
            [urls addObject:trackURLString(track.trackID)];
        }
    }];

    if (urls.count == 0) return nil;

    // The drop destination is whatever SimPlaylist build the user has installed.
    // Upstream SimPlaylist (no Tidal awareness) handles drops via:
    //   - NSPasteboardTypeURL: reads NSURL objects from each pasteboard item
    //   - NSPasteboardTypeString: only if the string starts with http(s)/soundcloud:/mixcloud:
    // We therefore put THIS row's tidal:// URL as NSPasteboardTypeURL on this item.
    // NSTableView calls pasteboardWriterForRow: once per dragged row, so the destination
    // ends up with N pasteboard items, one URL each — exactly what readObjectsForClasses:[NSURL]
    // returns. No SimPlaylist changes required.
    NSString *thisRowURL = nil;
    if ((NSUInteger)row < self.trackResults.count) {
        JLTidalTrack *track = self.trackResults[(NSUInteger)row];
        thisRowURL = trackURLString(track.trackID);
    }

    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];

    if (thisRowURL.length) {
        // NSPasteboardTypeURL ("public.url") accepts a URL string — read back as NSURL.
        [item setString:thisRowURL forType:NSPasteboardTypeURL];
    }

    // Back-compat: emit the legacy NSKeyedArchiver dict that the tidal-integration
    // worktree's SimPlaylist build (and any consumer expecting it) parses.
    NSDictionary *dragDict = @{@"type": @"tidal", @"urls": [urls copy]};
    NSError *archiveError = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragDict
                                         requiringSecureCoding:YES
                                                         error:&archiveError];
    if (data) {
        [item setData:data forType:JLTidalBrowserPasteboardType];
    } else {
        tidal::logError([[NSString stringWithFormat:@"Drag archive failed: %@",
                          archiveError.localizedDescription] UTF8String]);
    }

    // Plain text — Finder/text editors/anything else that wants a string.
    NSString *urlString = [urls componentsJoinedByString:@"\n"];
    [item setString:urlString forType:NSPasteboardTypeString];

    tidal::logDebug([[NSString stringWithFormat:@"Drag: row %ld -> %@ (archive=%s, urlSet=%s)",
                      (long)row, thisRowURL ?: @"?",
                      data ? "ok" : "FAIL",
                      thisRowURL.length ? "yes" : "no"] UTF8String]);
    return item;
}

#pragma mark - Double Click

- (void)doubleClickRow:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0) return;

    if ([self isShowingTracks]) {
        if (row >= (NSInteger)self.trackResults.count) return;
        JLTidalTrack *track = self.trackResults[(NSUInteger)row];
        NSString *url = trackURLString(track.trackID);
        tidal::logDebug([[NSString stringWithFormat:@"Double-clicked track: %@", url] UTF8String]);
        [self addTrackToPlaylistAndPlay:url];

    } else if ([self isShowingAlbums]) {
        if (row >= (NSInteger)self.albumResults.count) return;
        JLTidalAlbum *album = self.albumResults[(NSUInteger)row];
        tidal::logDebug([[NSString stringWithFormat:@"Double-clicked album: %@", album.albumID] UTF8String]);
        [self drillIntoAlbum:album];

    } else if ([self isShowingArtists]) {
        if (row >= (NSInteger)self.artistResults.count) return;
        JLTidalArtist *artist = self.artistResults[(NSUInteger)row];
        tidal::logDebug([[NSString stringWithFormat:@"Double-clicked artist: %@", artist.artistID] UTF8String]);
        [self drillIntoArtist:artist];

    } else if ([self isShowingPlaylists]) {
        if (row >= (NSInteger)self.playlistResults.count) return;
        JLTidalPlaylist *playlist = self.playlistResults[(NSUInteger)row];
        tidal::logDebug([[NSString stringWithFormat:@"Double-clicked playlist: %@", playlist.playlistUUID] UTF8String]);
        [self drillIntoPlaylist:playlist];
    }
}

- (void)getActivePlaylistOrCreate:(t_size &)outPlaylist insertAt:(t_size &)outInsert {
    auto pm = playlist_manager::get();
    outPlaylist = pm->get_active_playlist();
    if (outPlaylist == SIZE_MAX) {
        outPlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
        pm->set_active_playlist(outPlaylist);
    }
    outInsert = pm->playlist_get_item_count(outPlaylist);
}

- (void)addTrackToPlaylistAndPlay:(NSString *)urlString {
    t_size activePlaylist, insertPosition;
    [self getActivePlaylistOrCreate:activePlaylist insertAt:insertPosition];

    auto notify = fb2k::service_new<TidalPlayNotify>(activePlaylist, insertPosition, true);
    notify->m_paths.add_item([urlString UTF8String]);
    notify->startImport();

    self.statusLabel.stringValue = @"Adding track to playlist...";
}

#pragma mark - Context Menu

- (NSArray<JLTidalTrack *> *)selectedTracks {
    if (![self isShowingTracks]) return @[];

    NSMutableArray *tracks = [NSMutableArray array];
    NSIndexSet *selectedRows = self.tableView.selectedRowIndexes;

    [selectedRows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.trackResults.count) {
            [tracks addObject:self.trackResults[idx]];
        }
    }];

    return tracks;
}

- (void)contextMenuPlay:(id)sender {
    if ([self isShowingTracks]) {
        NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
        if (tracks.count == 0) return;

        JLTidalTrack *track = tracks.firstObject;
        NSString *url = trackURLString(track.trackID);
        [self addTrackToPlaylistAndPlay:url];

    } else if ([self isShowingAlbums]) {
        // Add all tracks from selected album
        NSInteger row = self.tableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.albumResults.count) {
            [self addAlbumToPlaylistAndPlay:self.albumResults[(NSUInteger)row]];
        }
    }
}

- (void)contextMenuAddToPlaylist:(id)sender {
    if ([self isShowingTracks]) {
        NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
        if (tracks.count == 0) return;

        t_size activePlaylist, insertPosition;
        [self getActivePlaylistOrCreate:activePlaylist insertAt:insertPosition];

        auto notify = fb2k::service_new<TidalPlayNotify>(activePlaylist, insertPosition, false);
        for (JLTidalTrack *track in tracks) {
            NSString *url = trackURLString(track.trackID);
            notify->m_paths.add_item([url UTF8String]);
        }
        notify->startImport();

        self.statusLabel.stringValue = [NSString stringWithFormat:@"Adding %lu track%@ to playlist...",
                                        (unsigned long)tracks.count,
                                        tracks.count == 1 ? @"" : @"s"];

    } else if ([self isShowingAlbums]) {
        NSInteger row = self.tableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.albumResults.count) {
            [self addAlbumToPlaylist:self.albumResults[(NSUInteger)row]];
        }
    }
}

- (void)contextMenuQueue:(id)sender {
    if ([self isShowingTracks]) {
        NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
        if (tracks.count == 0) return;
        [self addTracksToPlaylistAndQueue:tracks];

    } else if ([self isShowingAlbums]) {
        NSInteger row = self.tableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.albumResults.count) {
            [self addAlbumToPlaylistAndQueue:self.albumResults[(NSUInteger)row]];
        }
    }
}

- (void)addTracksToPlaylistAndQueue:(NSArray<JLTidalTrack *> *)tracks {
    t_size activePlaylist, insertPosition;
    [self getActivePlaylistOrCreate:activePlaylist insertAt:insertPosition];

    auto notify = fb2k::service_new<TidalPlayNotify>(activePlaylist, insertPosition, false, true);
    for (JLTidalTrack *track in tracks) {
        NSString *url = trackURLString(track.trackID);
        notify->m_paths.add_item([url UTF8String]);
    }
    notify->startImport();

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Queueing %lu track%@...",
                                    (unsigned long)tracks.count,
                                    tracks.count == 1 ? @"" : @"s"];
}

// Shared implementation for the three album-add variants below.
- (void)addAlbum:(JLTidalAlbum *)album play:(BOOL)play queue:(BOOL)queue {
    self.statusLabel.stringValue = queue ? @"Loading album tracks for queue..."
                                         : @"Loading album tracks...";

    [[JLTidalAPI shared] getAlbumTracksForAlbumID:album.albumID
                                       completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || tracks.count == 0) {
                self.statusLabel.stringValue = @"Failed to load album tracks";
                return;
            }

            if (queue) {
                [self addTracksToPlaylistAndQueue:tracks];
                return;
            }

            t_size activePlaylist, insertPosition;
            [self getActivePlaylistOrCreate:activePlaylist insertAt:insertPosition];

            auto notify = fb2k::service_new<TidalPlayNotify>(activePlaylist, insertPosition, play);

            for (JLTidalTrack *track in tracks) {
                NSString *url = trackURLString(track.trackID);
                notify->m_paths.add_item([url UTF8String]);
            }
            notify->startImport();

            self.statusLabel.stringValue = [NSString stringWithFormat:@"Adding %lu tracks from \"%@\"...",
                                            (unsigned long)tracks.count, album.title];
        });
    }];
}

- (void)addAlbumToPlaylistAndQueue:(JLTidalAlbum *)album {
    [self addAlbum:album play:NO queue:YES];
}

- (void)addAlbumToPlaylistAndPlay:(JLTidalAlbum *)album {
    [self addAlbum:album play:YES queue:NO];
}

- (void)addAlbumToPlaylist:(JLTidalAlbum *)album {
    [self addAlbum:album play:NO queue:NO];
}

- (void)contextMenuCopyURL:(id)sender {
    if ([self isShowingTracks]) {
        NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
        if (tracks.count == 0) return;

        NSMutableArray *urls = [NSMutableArray array];
        for (JLTidalTrack *track in tracks) {
            [urls addObject:trackURLString(track.trackID)];
        }

        NSString *urlString = [urls componentsJoinedByString:@"\n"];

        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:urlString forType:NSPasteboardTypeString];

        self.statusLabel.stringValue = [NSString stringWithFormat:@"Copied %lu URL%@ to clipboard",
                                        (unsigned long)tracks.count,
                                        tracks.count == 1 ? @"" : @"s"];
    }
}

- (void)contextMenuAddFavorite:(id)sender {
    NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
    if (tracks.count == 0) return;

    for (JLTidalTrack *track in tracks) {
        [[JLTidalAPI shared] addTrackToFavorites:track.trackID completion:^(BOOL success, NSError *error) {
            if (error) {
                tidal::logError([[NSString stringWithFormat:@"Failed to add favorite: %@", error.localizedDescription] UTF8String]);
            }
        }];
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Added %lu track%@ to favorites",
                                    (unsigned long)tracks.count,
                                    tracks.count == 1 ? @"" : @"s"];
}

- (void)contextMenuRemoveFavorite:(id)sender {
    NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
    if (tracks.count == 0) return;

    for (JLTidalTrack *track in tracks) {
        [[JLTidalAPI shared] removeTrackFromFavorites:track.trackID completion:^(BOOL success, NSError *error) {
            if (error) {
                tidal::logError([[NSString stringWithFormat:@"Failed to remove favorite: %@", error.localizedDescription] UTF8String]);
            }
        }];
    }

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Removed %lu track%@ from favorites",
                                    (unsigned long)tracks.count,
                                    tracks.count == 1 ? @"" : @"s"];

    // If in favorites view, reload
    if (self.panelMode == JLTidalPanelModeLibrary &&
        self.librarySection == JLTidalLibrarySectionFavTracks) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self loadLibrarySection];
        });
    }
}

- (void)contextMenuImportAsPlaylist:(id)sender {
    if ([self isShowingPlaylists]) {
        NSInteger row = self.tableView.selectedRow;
        if (row < 0 || row >= (NSInteger)self.playlistResults.count) return;
        JLTidalPlaylist *playlist = self.playlistResults[(NSUInteger)row];
        [self importPlaylistAsNewFb2kPlaylist:playlist];

    } else if ([self isShowingAlbums]) {
        NSInteger row = self.tableView.selectedRow;
        if (row < 0 || row >= (NSInteger)self.albumResults.count) return;
        JLTidalAlbum *album = self.albumResults[(NSUInteger)row];
        [self importAlbumAsNewFb2kPlaylist:album];
    }
}

- (void)importPlaylistAsNewFb2kPlaylist:(JLTidalPlaylist *)playlist {
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Importing \"%@\"...", playlist.title];

    [[JLTidalAPI shared] getPlaylistTracksForPlaylistID:playlist.playlistUUID
                                                  limit:500
                                                 offset:0
                                             completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || tracks.count == 0) {
                self.statusLabel.stringValue = error ?
                    [NSString stringWithFormat:@"Failed: %@", error.localizedDescription] :
                    @"Playlist is empty";
                return;
            }

            [self createFb2kPlaylistWithName:playlist.title tracks:tracks];
        });
    }];
}

- (void)importAlbumAsNewFb2kPlaylist:(JLTidalAlbum *)album {
    NSString *playlistName = [NSString stringWithFormat:@"%@ - %@", album.artist ?: @"Unknown", album.title];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Importing \"%@\"...", album.title];

    [[JLTidalAPI shared] getAlbumTracksForAlbumID:album.albumID
                                       completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || tracks.count == 0) {
                self.statusLabel.stringValue = error ?
                    [NSString stringWithFormat:@"Failed: %@", error.localizedDescription] :
                    @"Album has no tracks";
                return;
            }

            [self createFb2kPlaylistWithName:playlistName tracks:tracks];
        });
    }];
}

- (void)createFb2kPlaylistWithName:(NSString *)name tracks:(NSArray<JLTidalTrack *> *)tracks {
    auto pm = playlist_manager::get();

    // Create new playlist with the given name
    pfc::string8 playlistName([name UTF8String]);
    t_size newPlaylist = pm->create_playlist(playlistName, playlistName.length(), SIZE_MAX);
    pm->set_active_playlist(newPlaylist);

    // Import tracks
    auto notify = fb2k::service_new<TidalPlayNotify>(newPlaylist, 0, false);
    for (JLTidalTrack *track in tracks) {
        NSString *url = trackURLString(track.trackID);
        notify->m_paths.add_item([url UTF8String]);
    }
    notify->startImport();

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Created playlist \"%@\" with %lu tracks",
                                    name, (unsigned long)tracks.count];
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    NSUInteger selectedCount = self.tableView.selectedRowIndexes.count;
    if (selectedCount == 0) return NO;

    if (menuItem.action == @selector(contextMenuCopyURL:)) {
        return [self isShowingTracks];
    }
    if (menuItem.action == @selector(contextMenuAddFavorite:) ||
        menuItem.action == @selector(contextMenuRemoveFavorite:)) {
        return [self isShowingTracks];
    }
    if (menuItem.action == @selector(contextMenuImportAsPlaylist:)) {
        return [self isShowingPlaylists] || [self isShowingAlbums];
    }
    if (menuItem.action == @selector(contextMenuPlay:) ||
        menuItem.action == @selector(contextMenuAddToPlaylist:) ||
        menuItem.action == @selector(contextMenuQueue:)) {
        return [self isShowingTracks] || [self isShowingAlbums];
    }
    return YES;
}

#pragma mark - Playlist Sync

- (void)syncPullClicked:(id)sender {
    [self runSyncWithCheckingMessage:@"Checking TIDAL playlists..."
                           direction:@"Pull from TIDAL"
                        emptyMessage:@"Everything is up to date"
                     applyingMessage:@"Syncing playlists..."
                       successPrefix:@"Pull complete"
                         errorPrefix:@"Sync error"
                   includesDeletions:YES
                             preview:^(JLTidalSyncPreviewCompletion completion) {
        [[JLTidalPlaylistSync shared] previewPullFromTidalWithCompletion:completion];
    }
                               apply:^(JLTidalSyncReport *report, void (^completion)(BOOL, NSError *)) {
        [[JLTidalPlaylistSync shared] applyPullWithReport:report completion:completion];
    }];
}

- (void)syncPushClicked:(id)sender {
    [self runSyncWithCheckingMessage:@"Checking local playlists..."
                           direction:@"Push to TIDAL"
                        emptyMessage:@"Nothing to push"
                     applyingMessage:@"Pushing to TIDAL..."
                       successPrefix:@"Push complete"
                         errorPrefix:@"Push error"
                   includesDeletions:NO
                             preview:^(JLTidalSyncPreviewCompletion completion) {
        [[JLTidalPlaylistSync shared] previewPushToTidalWithCompletion:completion];
    }
                               apply:^(JLTidalSyncReport *report, void (^completion)(BOOL, NSError *)) {
        [[JLTidalPlaylistSync shared] applyPushWithReport:report completion:completion];
    }];
}

// Shared driver for the pull/push sync buttons; the two flows differ only in
// their preview/apply calls, user-facing strings, and whether deletions count
// toward the "anything to do" check.
- (void)runSyncWithCheckingMessage:(NSString *)checkingMessage
                         direction:(NSString *)direction
                      emptyMessage:(NSString *)emptyMessage
                   applyingMessage:(NSString *)applyingMessage
                     successPrefix:(NSString *)successPrefix
                       errorPrefix:(NSString *)errorPrefix
                 includesDeletions:(BOOL)includesDeletions
                           preview:(void (^)(JLTidalSyncPreviewCompletion))preview
                             apply:(void (^)(JLTidalSyncReport *report,
                                             void (^completion)(BOOL, NSError *)))apply {
    if (![[JLTidalAuthService shared] isAuthenticated]) {
        self.statusLabel.stringValue = @"Not signed in - configure in Preferences";
        return;
    }

    self.syncPullButton.enabled = NO;
    self.syncPushButton.enabled = NO;
    self.statusLabel.stringValue = checkingMessage;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];

    preview(^(JLTidalSyncReport *report, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.loadingSpinner setHidden:YES];
            [self.loadingSpinner stopAnimation:nil];
            self.syncPullButton.enabled = YES;
            self.syncPushButton.enabled = YES;

            if (error) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Sync failed: %@", error.localizedDescription];
                return;
            }

            if (report.totalCreated == 0 && report.totalUpdated == 0 &&
                (!includesDeletions || report.totalDeleted == 0)) {
                self.statusLabel.stringValue = emptyMessage;
                return;
            }

            [self showSyncConfirmDialog:report direction:direction applyBlock:^{
                self.statusLabel.stringValue = applyingMessage;
                [self.loadingSpinner setHidden:NO];
                [self.loadingSpinner startAnimation:nil];

                apply(report, ^(BOOL success, NSError *applyError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.loadingSpinner setHidden:YES];
                        [self.loadingSpinner stopAnimation:nil];
                        if (success) {
                            self.statusLabel.stringValue = [NSString stringWithFormat:@"%@: %@",
                                                            successPrefix, [report summary]];
                        } else {
                            self.statusLabel.stringValue = [NSString stringWithFormat:@"%@: %@",
                                                            errorPrefix, applyError.localizedDescription];
                        }
                    });
                });
            }];
        });
    });
}

- (void)showSyncConfirmDialog:(JLTidalSyncReport *)report
                    direction:(NSString *)direction
                   applyBlock:(void (^)(void))applyBlock {
    NSMutableString *details = [NSMutableString string];
    for (JLTidalSyncChange *change in report.changes) {
        if (change.changeType == JLTidalSyncChangeTypeUnchanged) continue;

        NSString *action;
        switch (change.changeType) {
            case JLTidalSyncChangeTypeCreate: action = @"Create"; break;
            case JLTidalSyncChangeTypeUpdate: action = @"Update"; break;
            case JLTidalSyncChangeTypeDelete: action = @"Remove"; break;
            default: continue;
        }
        [details appendFormat:@"%@: %@", action, change.playlistName];
        if (change.tracksAdded > 0) [details appendFormat:@" (+%ld)", (long)change.tracksAdded];
        if (change.tracksRemoved > 0) [details appendFormat:@" (-%ld)", (long)change.tracksRemoved];
        [details appendString:@"\n"];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = direction;
    alert.informativeText = [NSString stringWithFormat:@"%@\n\n%@", [report summary], details];
    [alert addButtonWithTitle:@"Apply"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleInformational;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        applyBlock();
    } else {
        self.statusLabel.stringValue = @"Sync cancelled";
    }
}

#pragma mark - Helpers

- (NSString *)formatDuration:(NSTimeInterval)duration {
    NSInteger totalSeconds = (NSInteger)duration;
    NSInteger minutes = totalSeconds / 60;
    NSInteger seconds = totalSeconds % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

@end
