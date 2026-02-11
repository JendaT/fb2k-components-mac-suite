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

// Column identifiers
static NSString * const kColumnArt = @"art";
static NSString * const kColumnTitle = @"title";
static NSString * const kColumnArtist = @"artist";
static NSString * const kColumnDuration = @"duration";

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
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *loadingSpinner;

@property (nonatomic, strong) NSMutableArray<JLTidalTrack *> *searchResults;
@property (nonatomic, assign) BOOL isSearching;
@property (nonatomic, copy, nullable) NSString *lastSearchQuery;
@end

@implementation JLTidalBrowserController

#pragma mark - Initialization

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _searchResults = [NSMutableArray array];
        _isSearching = NO;

        // Observe auth state changes
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
    // Main container
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

    // Loading spinner (next to search field)
    self.loadingSpinner = [[NSProgressIndicator alloc] init];
    self.loadingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.loadingSpinner.style = NSProgressIndicatorStyleSpinning;
    self.loadingSpinner.controlSize = NSControlSizeSmall;
    [self.loadingSpinner setHidden:YES];
    [container addSubview:self.loadingSpinner];

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

    // Configure columns
    [self setupTableColumns];

    // Context menu
    NSMenu *contextMenu = [[NSMenu alloc] initWithTitle:@"Tidal Browser"];
    [contextMenu addItemWithTitle:@"Play" action:@selector(contextMenuPlay:) keyEquivalent:@""];
    [contextMenu addItemWithTitle:@"Add to Playlist" action:@selector(contextMenuAddToPlaylist:) keyEquivalent:@""];
    [contextMenu addItem:[NSMenuItem separatorItem]];
    [contextMenu addItemWithTitle:@"Copy URL" action:@selector(contextMenuCopyURL:) keyEquivalent:@""];
    self.tableView.menu = contextMenu;

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

        // Scroll view (table)
        [self.scrollView.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:8],
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

- (void)setupTableColumns {
    // Art column (thumbnail)
    NSTableColumn *artColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArt];
    artColumn.title = @"";
    artColumn.width = 40;
    artColumn.minWidth = 40;
    artColumn.maxWidth = 40;
    [self.tableView addTableColumn:artColumn];

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

#pragma mark - Search

- (void)searchWithQuery:(NSString *)query {
    if (query.length == 0) {
        [self clearResults];
        return;
    }

    // Check authentication
    if (![[JLTidalAuthService shared] isAuthenticated]) {
        self.statusLabel.stringValue = @"Not signed in - configure in Preferences";
        return;
    }

    self.lastSearchQuery = query;
    self.isSearching = YES;
    [self.loadingSpinner setHidden:NO];
    [self.loadingSpinner startAnimation:nil];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Searching for \"%@\"...", query];

    tidal::logDebug([[NSString stringWithFormat:@"Searching Tidal for: %@", query] UTF8String]);

    [[JLTidalAPI shared] searchTracksWithQuery:query
                                         limit:50
                                        offset:0
                                    completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isSearching = NO;
            [self.loadingSpinner setHidden:YES];
            [self.loadingSpinner stopAnimation:nil];

            if (error) {
                tidal::logError([[NSString stringWithFormat:@"Search failed: %@", error.localizedDescription] UTF8String]);
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Search failed: %@", error.localizedDescription];
                return;
            }

            [self.searchResults removeAllObjects];
            if (tracks) {
                [self.searchResults addObjectsFromArray:tracks];
            }
            [self.tableView reloadData];

            if (self.searchResults.count == 0) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"No results for \"%@\"", query];
            } else {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"%lu track%@ found",
                                                (unsigned long)self.searchResults.count,
                                                self.searchResults.count == 1 ? @"" : @"s"];
            }
        });
    }];
}

- (void)clearResults {
    [self.searchResults removeAllObjects];
    [self.tableView reloadData];
    [self updateStatusLabel];
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

- (void)authStateChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateStatusLabel];

        // Clear results if signed out
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
        [self searchWithQuery:query];
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.searchResults.count;
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
    if (row < 0 || row >= (NSInteger)self.searchResults.count) {
        return nil;
    }

    JLTidalTrack *track = self.searchResults[(NSUInteger)row];
    NSString *identifier = tableColumn.identifier;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] init];
        cell.identifier = identifier;

        if ([identifier isEqualToString:kColumnArt]) {
            // Art cell - just image
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
        } else {
            // Text cell
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
    }

    // Populate cell
    if ([identifier isEqualToString:kColumnArt]) {
        // Load album art from cache
        if (track.coverID.length > 0) {
            NSImage *cached = [[JLTidalAlbumArtCache shared] cachedImageForCoverID:track.coverID size:80];
            if (cached) {
                cell.imageView.image = cached;
                cell.imageView.contentTintColor = nil;
            } else {
                // Set placeholder while loading
                if (@available(macOS 11.0, *)) {
                    cell.imageView.image = [NSImage imageWithSystemSymbolName:@"music.note"
                                                     accessibilityDescription:@"Track"];
                    cell.imageView.contentTintColor = [NSColor tertiaryLabelColor];
                }

                // Load asynchronously
                NSString *coverID = track.coverID;
                [[JLTidalAlbumArtCache shared] loadImageForCoverID:coverID
                                                              size:80
                                                        completion:^(NSImage *image) {
                    // Find if this row is still visible and update it
                    if (image) {
                        NSInteger currentRow = [self.searchResults indexOfObjectPassingTest:^BOOL(JLTidalTrack *t, NSUInteger idx, BOOL *stop) {
                            return [t.coverID isEqualToString:coverID];
                        }];
                        if (currentRow != NSNotFound) {
                            [self.tableView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)currentRow]
                                                      columnIndexes:[NSIndexSet indexSetWithIndex:0]];
                        }
                    }
                }];
            }
        } else {
            // No cover art available
            if (@available(macOS 11.0, *)) {
                cell.imageView.image = [NSImage imageWithSystemSymbolName:@"music.note"
                                                 accessibilityDescription:@"Track"];
                cell.imageView.contentTintColor = [NSColor tertiaryLabelColor];
            }
        }
    } else if ([identifier isEqualToString:kColumnTitle]) {
        cell.textField.stringValue = track.title ?: @"";
        cell.textField.font = fb2k_ui::rowFont();
        cell.textField.textColor = fb2k_ui::textColor();
    } else if ([identifier isEqualToString:kColumnArtist]) {
        cell.textField.stringValue = track.artist ?: @"";
        cell.textField.font = fb2k_ui::rowFont();
        cell.textField.textColor = fb2k_ui::secondaryTextColor();
    } else if ([identifier isEqualToString:kColumnDuration]) {
        cell.textField.stringValue = [self formatDuration:track.duration];
        cell.textField.font = fb2k_ui::monospacedDigitFont();
        cell.textField.textColor = fb2k_ui::secondaryTextColor();
    }

    return cell;
}

#pragma mark - Drag & Drop

// Modern drag API - called per row
- (nullable id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.searchResults.count) {
        return nil;
    }
    // Return a pasteboard item placeholder - actual data is written in draggingSession:willBeginAtPoint:
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:@"placeholder" forType:JLTidalBrowserPasteboardType];
    return item;
}

// Called when drag session begins - write all selected rows as a single drag payload
- (void)tableView:(NSTableView *)tableView draggingSession:(NSDraggingSession *)session
    willBeginAtPoint:(NSPoint)screenPoint forRowIndexes:(NSIndexSet *)rowIndexes {

    NSMutableArray *urls = [NSMutableArray array];

    [rowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.searchResults.count) {
            JLTidalTrack *track = self.searchResults[idx];
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

    // Write to the first pasteboard item in the session
    [session enumerateDraggingItemsWithOptions:0
                                       forView:tableView
                                       classes:@[[NSPasteboardItem class]]
                                 searchOptions:@{}
                                    usingBlock:^(NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop) {
        if (idx == 0) {
            NSPasteboardItem *pbItem = (NSPasteboardItem *)draggingItem.item;
            [pbItem setData:data forType:JLTidalBrowserPasteboardType];
        }
        *stop = YES;  // Only write to first item
    }];

    tidal::logDebug([[NSString stringWithFormat:@"Started drag with %lu tracks", (unsigned long)urls.count] UTF8String]);
}

#pragma mark - Double Click

- (void)doubleClickRow:(id)sender {
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.searchResults.count) {
        return;
    }

    JLTidalTrack *track = self.searchResults[(NSUInteger)row];
    NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];

    tidal::logDebug([[NSString stringWithFormat:@"Double-clicked track: %@", url] UTF8String]);

    // Add track to active playlist and play it
    [self addTrackToPlaylistAndPlay:url];
}

- (void)addTrackToPlaylistAndPlay:(NSString *)urlString {
    // Get the active playlist
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) {
        // No active playlist - create one
        activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
        pm->set_active_playlist(activePlaylist);
    }

    // Get current item count before adding
    t_size insertPosition = pm->playlist_get_item_count(activePlaylist);

    // Create notify object that keeps paths alive and handles playback
    auto notify = new service_impl_t<TidalPlayNotify>(activePlaylist, insertPosition, true);
    notify->m_paths.add_item([urlString UTF8String]);
    notify->startImport();

    self.statusLabel.stringValue = @"Adding track to playlist...";
}

#pragma mark - Context Menu

- (NSArray<JLTidalTrack *> *)selectedTracks {
    NSMutableArray *tracks = [NSMutableArray array];
    NSIndexSet *selectedRows = self.tableView.selectedRowIndexes;

    [selectedRows enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.searchResults.count) {
            [tracks addObject:self.searchResults[idx]];
        }
    }];

    return tracks;
}

- (void)contextMenuPlay:(id)sender {
    NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
    if (tracks.count == 0) return;

    // Play the first selected track
    JLTidalTrack *track = tracks.firstObject;
    NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
    [self addTrackToPlaylistAndPlay:url];
}

- (void)contextMenuAddToPlaylist:(id)sender {
    NSArray<JLTidalTrack *> *tracks = [self selectedTracks];
    if (tracks.count == 0) return;

    // Get the active playlist
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) {
        activePlaylist = pm->create_playlist("Tidal", SIZE_MAX, SIZE_MAX);
        pm->set_active_playlist(activePlaylist);
    }

    // Get current item count before adding
    t_size insertPosition = pm->playlist_get_item_count(activePlaylist);

    // Create notify object that keeps paths alive (without auto-play)
    auto notify = new service_impl_t<TidalPlayNotify>(activePlaylist, insertPosition, false);

    for (JLTidalTrack *track in tracks) {
        NSString *url = [NSString stringWithFormat:@"tidal://track/%@", track.trackID];
        notify->m_paths.add_item([url UTF8String]);
    }

    notify->startImport();

    self.statusLabel.stringValue = [NSString stringWithFormat:@"Adding %lu track%@ to playlist...",
                                    (unsigned long)tracks.count,
                                    tracks.count == 1 ? @"" : @"s"];
}

- (void)contextMenuCopyURL:(id)sender {
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

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    // Only enable menu items if there's a selection
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
