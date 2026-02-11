//
//  TidalBrowserController.mm
//  foo_jl_tidal_mac
//
//  Browser panel for searching and browsing Tidal catalog
//

#import "TidalBrowserController.h"
#import "TidalAlbumArtCache.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalModels.h"
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

// Column identifiers - albums
static NSString * const kColumnAlbumTitle = @"albumtitle";
static NSString * const kColumnAlbumArtist = @"albumartist";
static NSString * const kColumnAlbumTracks = @"albumtracks";
static NSString * const kColumnAlbumQuality = @"albumquality";

// Column identifiers - artists
static NSString * const kColumnArtistName = @"artistname";

// Pasteboard type for drag operations
NSString * const JLTidalBrowserPasteboardType = @"com.foobar2000.tidal.browser.rows";

// Notify class to keep paths alive during async import and handle playback
class TidalPlayNotify : public process_locations_notify {
public:
    t_size m_playlistIndex;
    t_size m_insertAt;
    pfc::string_list_impl m_paths;  // Keeps paths alive during async operation
    bool m_shouldPlay;

    TidalPlayNotify(t_size playlistIndex, t_size insertAt, bool shouldPlay = true)
        : m_playlistIndex(playlistIndex), m_insertAt(insertAt), m_shouldPlay(shouldPlay) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            if (m_playlistIndex < pm->get_playlist_count()) {
                pm->playlist_undo_backup(m_playlistIndex);
                pm->playlist_insert_items(m_playlistIndex, m_insertAt, items, pfc::bit_array_val(true));

                if (m_shouldPlay) {
                    pm->playlist_execute_default_action(m_playlistIndex, m_insertAt);
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
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSSegmentedControl *searchTypeControl;
@property (nonatomic, strong) NSButton *backButton;
@property (nonatomic, strong) NSTextField *breadcrumbLabel;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *loadingSpinner;
@property (nonatomic, strong) NSView *navigationBar;

// State
@property (nonatomic, assign) JLTidalSearchType searchType;
@property (nonatomic, assign) JLTidalBrowseMode browseMode;
@property (nonatomic, assign) BOOL isSearching;
@property (nonatomic, copy, nullable) NSString *lastSearchQuery;

// Result arrays (only one is active at a time based on browseMode)
@property (nonatomic, strong) NSMutableArray<JLTidalTrack *> *trackResults;
@property (nonatomic, strong) NSMutableArray<JLTidalAlbum *> *albumResults;
@property (nonatomic, strong) NSMutableArray<JLTidalArtist *> *artistResults;

// Drill-down context
@property (nonatomic, copy, nullable) NSString *drillDownTitle;
@property (nonatomic, strong, nullable) JLTidalAlbum *currentAlbum;
@property (nonatomic, strong, nullable) JLTidalArtist *currentArtist;
@end

@implementation JLTidalBrowserController

#pragma mark - Initialization

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _trackResults = [NSMutableArray array];
        _albumResults = [NSMutableArray array];
        _artistResults = [NSMutableArray array];
        _isSearching = NO;
        _searchType = JLTidalSearchTypeTracks;
        _browseMode = JLTidalBrowseModeSearchResults;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(authStateChanged:)
                                                     name:JLTidalAuthStateDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View Lifecycle

- (void)loadView {
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    container.wantsLayer = YES;

    // Search field
    self.searchField = [[NSSearchField alloc] init];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Search Tidal...";
    self.searchField.delegate = self;
    self.searchField.sendsSearchStringImmediately = NO;
    self.searchField.sendsWholeSearchString = YES;
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

    self.backButton = [NSButton buttonWithTitle:@"Back" target:self action:@selector(backButtonClicked:)];
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.backButton.bezelStyle = NSBezelStyleRecessed;
    self.backButton.controlSize = NSControlSizeSmall;
    self.backButton.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
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

    // Layout constraints
    [NSLayoutConstraint activateConstraints:@[
        // Search field
        [self.searchField.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [self.searchField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.searchField.trailingAnchor constraintEqualToAnchor:self.loadingSpinner.leadingAnchor constant:-8],
        [self.searchField.heightAnchor constraintEqualToConstant:24],

        // Loading spinner
        [self.loadingSpinner.centerYAnchor constraintEqualToAnchor:self.searchField.centerYAnchor],
        [self.loadingSpinner.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.loadingSpinner.widthAnchor constraintEqualToConstant:16],
        [self.loadingSpinner.heightAnchor constraintEqualToConstant:16],

        // Search type control
        [self.searchTypeControl.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:6],
        [self.searchTypeControl.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [self.searchTypeControl.heightAnchor constraintEqualToConstant:20],

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
    [self updateStatusLabel];
}

- (void)setupContextMenu {
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Tidal Browser"];
    [contextMenu addItemWithTitle:@"Play" action:@selector(contextMenuPlay:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Add to Playlist" action:@selector(contextMenuAddToPlaylist:) keyEquivalent:@""];
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

    // Title column
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnTitle];
    titleColumn.title = @"Title";
    titleColumn.width = 200;
    titleColumn.minWidth = 100;
    [self.tableView addTableColumn:titleColumn];

    // Artist column
    NSTableColumn *artistColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArtist];
    artistColumn.title = @"Artist";
    artistColumn.width = 150;
    artistColumn.minWidth = 80;
    [self.tableView addTableColumn:artistColumn];

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

    // Album title
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumTitle];
    titleColumn.title = @"Album";
    titleColumn.width = 200;
    titleColumn.minWidth = 100;
    [self.tableView addTableColumn:titleColumn];

    // Album artist
    NSTableColumn *artistColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnAlbumArtist];
    artistColumn.title = @"Artist";
    artistColumn.width = 150;
    artistColumn.minWidth = 80;
    [self.tableView addTableColumn:artistColumn];

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

#pragma mark - Mode Helpers

- (BOOL)isShowingTracks {
    if (self.browseMode == JLTidalBrowseModeAlbumTracks ||
        self.browseMode == JLTidalBrowseModeArtistTopTracks) {
        return YES;
    }
    return self.browseMode == JLTidalBrowseModeSearchResults &&
           self.searchType == JLTidalSearchTypeTracks;
}

- (BOOL)isShowingAlbums {
    if (self.browseMode == JLTidalBrowseModeArtistAlbums) return YES;
    return self.browseMode == JLTidalBrowseModeSearchResults &&
           self.searchType == JLTidalSearchTypeAlbums;
}

- (BOOL)isShowingArtists {
    return self.browseMode == JLTidalBrowseModeSearchResults &&
           self.searchType == JLTidalSearchTypeArtists;
}

- (BOOL)isDrillDown {
    return self.browseMode != JLTidalBrowseModeSearchResults;
}

#pragma mark - Search Type Switching

- (void)searchTypeChanged:(id)sender {
    JLTidalSearchType newType = (JLTidalSearchType)self.searchTypeControl.selectedSegment;
    if (newType == self.searchType && self.browseMode == JLTidalBrowseModeSearchResults) {
        return;
    }

    self.searchType = newType;

    // Exit drill-down if active
    [self exitDrillDown];

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
    if (self.browseMode == JLTidalBrowseModeSearchResults) return;

    self.browseMode = JLTidalBrowseModeSearchResults;
    self.drillDownTitle = nil;
    self.currentAlbum = nil;
    self.currentArtist = nil;
    [self.navigationBar setHidden:YES];
    [self setupColumnsForCurrentMode];
    [self.tableView reloadData];
    [self updateStatusForCurrentResults];
}

- (void)backButtonClicked:(id)sender {
    // If in artist top tracks, go back to artist albums
    // Otherwise go back to search results
    if (self.browseMode == JLTidalBrowseModeArtistTopTracks && self.currentArtist) {
        // Go back to artist albums view
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
    self.isSearching = YES;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Searching for \"%@\"...", query];

    tidal::logDebug([[NSString stringWithFormat:@"Searching Tidal for: %@ (type=%ld)", query, (long)self.searchType] UTF8String]);

    switch (self.searchType) {
        case JLTidalSearchTypeTracks:
            [self searchTracksWithQuery:query];
            break;
        case JLTidalSearchTypeAlbums:
            [self searchAlbumsWithQuery:query];
            break;
        case JLTidalSearchTypeArtists:
            [self searchArtistsWithQuery:query];
            break;
    }
}

- (void)searchTracksWithQuery:(NSString *)query {
    [[JLTidalAPI shared] searchTracksWithQuery:query
                                         limit:50
                                        offset:0
                                    completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                [self showError:error.localizedDescription forQuery:query];
                return;
            }

            [self.trackResults removeAllObjects];
            if (tracks) [self.trackResults addObjectsFromArray:tracks];
            [self.tableView reloadData];

            if (self.trackResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No tracks for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu track%@ found",
                                                (unsigned long)self.trackResults.count,
                                                self.trackResults.count == 1 ? @"" : @"s"];
            }
        });
    }];
}

- (void)searchAlbumsWithQuery:(NSString *)query {
    [[JLTidalAPI shared] searchAlbumsWithQuery:query
                                         limit:50
                                        offset:0
                                    completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                [self showError:error.localizedDescription forQuery:query];
                return;
            }

            [self.albumResults removeAllObjects];
            if (albums) [self.albumResults addObjectsFromArray:albums];
            [self.tableView reloadData];

            if (self.albumResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No albums for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu album%@ found",
                                                (unsigned long)self.albumResults.count,
                                                self.albumResults.count == 1 ? @"" : @"s"];
            }
        });
    }];
}

- (void)searchArtistsWithQuery:(NSString *)query {
    [[JLTidalAPI shared] searchArtistsWithQuery:query
                                          limit:50
                                         offset:0
                                     completion:^(NSArray<JLTidalArtist *> *artists, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                [self showError:error.localizedDescription forQuery:query];
                return;
            }

            [self.artistResults removeAllObjects];
            if (artists) [self.artistResults addObjectsFromArray:artists];
            [self.tableView reloadData];

            if (self.artistResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No artists for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu artist%@ found",
                                                (unsigned long)self.artistResults.count,
                                                self.artistResults.count == 1 ? @"" : @"s"];
            }
        });
    }];
}

- (void)finishLoading {
    self.isSearching = NO;
    [self.loadingSpinner setHidden:YES];
    [self.loadingSpinner stopAnimation:nil];
}

- (void)showError:(NSString *)errorMessage forQuery:(NSString *)query {
    tidal::logError([[NSString stringWithFormat:@"Search failed: %@", errorMessage] UTF8String]);
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Search failed: %@", errorMessage];
}

- (void)clearResults {
    [self.trackResults removeAllObjects];
    [self.albumResults removeAllObjects];
    [self.artistResults removeAllObjects];
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

            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu track%@",
                                            (unsigned long)self.trackResults.count,
                                            self.trackResults.count == 1 ? @"" : @"s"];
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
    self.statusLabel.stringValue = @"Loading artist albums...";

    [[JLTidalAPI shared] getArtistAlbumsForArtistID:artist.artistID
                                              limit:50
                                         completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLoading];

            if (error) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Failed to load artist: %@", error.localizedDescription];
                return;
            }

            [self.albumResults removeAllObjects];
            if (albums) [self.albumResults addObjectsFromArray:albums];
            [self.tableView reloadData];

            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu album%@",
                                            (unsigned long)self.albumResults.count,
                                            self.albumResults.count == 1 ? @"" : @"s"];
        });
    }];
}

#pragma mark - Status

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
            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu track%@",
                                            (unsigned long)count, count == 1 ? @"" : @"s"];
        }
    } else if ([self isShowingAlbums]) {
        NSUInteger count = self.albumResults.count;
        if (count == 0) {
            self.statusLabel.stringValue = @"";
        } else {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu album%@",
                                            (unsigned long)count, count == 1 ? @"" : @"s"];
        }
    } else if ([self isShowingArtists]) {
        NSUInteger count = self.artistResults.count;
        if (count == 0) {
            self.statusLabel.stringValue = @"";
        } else {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu artist%@",
                                            (unsigned long)count, count == 1 ? @"" : @"s"];
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

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSSearchField *field = notification.object;
    if (field == self.searchField) {
        NSString *query = [self.searchField.stringValue stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];

        // Exit drill-down when user types a new search
        if ([self isDrillDown]) {
            [self exitDrillDown];
        }

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
    }
    return 0;
}

#pragma mark - NSTableViewDelegate

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    NSTableRowView *rowView = [[NSTableRowView alloc] init];
    if (row % 2 == 1) {
        rowView.backgroundColor = fb2k_ui::alternateRowColor();
    } else {
        rowView.backgroundColor = fb2k_ui::backgroundColor();
    }
    return rowView;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if ([self isShowingTracks]) {
        return [self trackCellForColumn:tableColumn row:row];
    } else if ([self isShowingAlbums]) {
        return [self albumCellForColumn:tableColumn row:row];
    } else if ([self isShowingArtists]) {
        return [self artistCellForColumn:tableColumn row:row];
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
        return [self textCell:identifier
                         text:[NSString stringWithFormat:@"%ld", (long)album.numberOfTracks]
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

    if (coverID.length > 0) {
        NSImage *cached = [[JLTidalAlbumArtCache shared] cachedImageForCoverID:coverID size:80];
        if (cached) {
            cell.imageView.image = cached;
            cell.imageView.contentTintColor = nil;
        } else {
            [self setPlaceholderImage:cell.imageView];
            [[JLTidalAlbumArtCache shared] loadImageForCoverID:coverID
                                                          size:80
                                                    completion:^(NSImage *image) {
                if (image) {
                    [self.tableView reloadData];
                }
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
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = identifier;

        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:textField];
        cell.textField = textField;

        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [textField.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [textField.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }

    cell.textField.stringValue = text;
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
    // Only allow dragging tracks
    if (![self isShowingTracks]) return nil;
    if (row < 0 || row >= (NSInteger)self.trackResults.count) return nil;

    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:@"placeholder" forType:JLTidalBrowserPasteboardType];
    return item;
}

- (void)tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session
    willBeginAtPoint:(NSPoint)screenPoint forRowIndexes:(NSIndexSet *)rowIndexes {

    if (![self isShowingTracks]) return;

    NSMutableArray *urls = [NSMutableArray array];

    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.trackResults.count) {
            JLTidalTrack *track = self.trackResults[idx];
            NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
            [urls addObject:url];
        }
    }];

    if (urls.count == 0) return;

    NSDictionary *dragData = @{
        @"type": @"tidal",
        @"urls": urls
    };

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:dragData requiringSecureCoding:NO error:nil];

    [session enumerateDraggingItemsWithOptions:0
                                       forView:tableView
                                       classes:@[[NSPasteboardItem class]]
                                 searchOptions:@{}
                                    usingBlock:^(NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop) {
        if (idx == 0) {
            NSPasteboardItem *pbItem = (NSPasteboardItem *)draggingItem.item;
            [pbItem setData:data forType:JLTidalBrowserPasteboardType];
        }
        *stop = YES;
    }];

    tidal::logDebug([[NSString stringWithFormat:@"Started drag with %lu tracks", (unsigned long)urls.count] UTF8String]);
}

#pragma mark - Double Click

- (void)doubleClickRow:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0) return;

    if ([self isShowingTracks]) {
        if (row >= (NSInteger)self.trackResults.count) return;
        JLTidalTrack *track = self.trackResults[(NSUInteger)row];
        NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
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
    }
}

- (void)addTrackToPlaylistAndPlay:(NSString *)urlString {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) {
        activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
        pm->set_active_playlist(activePlaylist);
    }

    t_size insertPosition = pm->playlist_get_item_count(activePlaylist);

    auto notify = new service_impl_t<TidalPlayNotify>(activePlaylist, insertPosition, true);
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
        NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
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

        auto pm = playlist_manager::get();
        t_size activePlaylist = pm->get_active_playlist();

        if (activePlaylist == SIZE_MAX) {
            activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
            pm->set_active_playlist(activePlaylist);
        }

        t_size insertPosition = pm->playlist_get_item_count(activePlaylist);

        auto notify = new service_impl_t<TidalPlayNotify>(activePlaylist, insertPosition, false);
        for (JLTidalTrack *track in tracks) {
            NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
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

- (void)addAlbumToPlaylistAndPlay:(JLTidalAlbum *)album {
    self.statusLabel.stringValue = @"Loading album tracks...";

    [[JLTidalAPI shared] getAlbumTracksForAlbumID:album.albumID
                                       completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || tracks.count == 0) {
                self.statusLabel.stringValue = @"Failed to load album tracks";
                return;
            }

            auto pm = playlist_manager::get();
            t_size activePlaylist = pm->get_active_playlist();

            if (activePlaylist == SIZE_MAX) {
                activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
                pm->set_active_playlist(activePlaylist);
            }

            t_size insertPosition = pm->playlist_get_item_count(activePlaylist);
            auto notify = new service_impl_t<TidalPlayNotify>(activePlaylist, insertPosition, true);

            for (JLTidalTrack *track in tracks) {
                NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
                notify->m_paths.add_item([url UTF8String]);
            }
            notify->startImport();

            self.statusLabel.stringValue = [NSString stringWithFormat:@"Adding %lu tracks from \"%@\"...",
                                            (unsigned long)tracks.count, album.title];
        });
    }];
}

- (void)addAlbumToPlaylist:(JLTidalAlbum *)album {
    self.statusLabel.stringValue = @"Loading album tracks...";

    [[JLTidalAPI shared] getAlbumTracksForAlbumID:album.albumID
                                       completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || tracks.count == 0) {
                self.statusLabel.stringValue = @"Failed to load album tracks";
                return;
            }

            auto pm = playlist_manager::get();
            t_size activePlaylist = pm->get_active_playlist();

            if (activePlaylist == SIZE_MAX) {
                activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
                pm->set_active_playlist(activePlaylist);
            }

            t_size insertPosition = pm->playlist_get_item_count(activePlaylist);
            auto notify = new service_impl_t<TidalPlayNotify>(activePlaylist, insertPosition, false);

            for (JLTidalTrack *track in tracks) {
                NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
                notify->m_paths.add_item([url UTF8String]);
            }
            notify->startImport();

            self.statusLabel.stringValue = [NSString stringWithFormat:@"Adding %lu tracks from \"%@\"...",
                                            (unsigned long)tracks.count, album.title];
        });
    }];
}

- (void)contextMenuCopyURL:(id)sender {
    if ([self isShowingTracks]) {
        NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
        if (tracks.count == 0) return;

        NSMutableArray *urls = [NSMutableArray array];
        for (JLTidalTrack *track in tracks) {
            [urls addObject:[NSString stringWithFormat:@"tidal://track/%@", track.trackID]];
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

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(contextMenuCopyURL:)) {
        // Only for tracks
        return [self isShowingTracks] && self.tableView.selectedRowIndexes.count > 0;
    }
    return self.tableView.selectedRowIndexes.count > 0;
}

#pragma mark - Helpers

- (NSString *)formatDuration:(NSTimeInterval)duration {
    NSInteger totalSeconds = (NSInteger)duration;
    NSInteger minutes = totalSeconds / 60;
    NSInteger seconds = totalSeconds % 60;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)seconds];
}

@end
