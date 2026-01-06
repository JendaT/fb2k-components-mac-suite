//
//  CloudBrowserController.mm
//  foo_jl_cloud_streamer_mac
//
//  UI controller for Cloud Browser panel
//

#import "CloudBrowserController.h"
#import "../Core/CloudTrack.h"
#import "../Services/CloudSearchService.h"
#include "../Core/ThumbnailCache.h"
#include "../../shared/UIStyles.h"
#include "../fb2k_sdk.h"

// Column identifiers
static NSString* const kColumnArtwork = @"artwork";
static NSString* const kColumnTitle = @"title_artist";
static NSString* const kColumnDuration = @"duration";

// Artwork size
static const CGFloat kArtworkSize = 40.0;
static const CGFloat kRowHeight = 44.0;

// Debounce timer interval
static const NSTimeInterval kSearchDebounceInterval = 0.5;

// User defaults keys
static NSString* const kLastSearchKey = @"CloudBrowserLastSearch";
static NSString* const kSelectedServiceKey = @"CloudBrowserSelectedService";

@interface CloudBrowserController ()
@property (nonatomic, strong) NSSegmentedControl* serviceSelector;
@property (nonatomic, strong) NSTextField* searchField;
@property (nonatomic, strong) NSButton* searchButton;
@property (nonatomic, strong) NSScrollView* scrollView;
@property (nonatomic, strong) NSTableView* tableView;
@property (nonatomic, strong) NSTextField* statusBar;
@property (nonatomic, strong) NSProgressIndicator* progressIndicator;
@property (nonatomic, strong) NSMutableArray<CloudTrack*>* results;
@property (nonatomic) CloudBrowserState state;
@property (nonatomic, strong) NSTimer* debounceTimer;
@property (nonatomic, copy) NSString* lastError;
@end

@implementation CloudBrowserController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _results = [NSMutableArray array];
        _state = CloudBrowserStateEmpty;
        _transparentBackground = NO;
        // Restore selected service from defaults
        NSInteger savedService = [[NSUserDefaults standardUserDefaults] integerForKey:kSelectedServiceKey];
        _selectedService = (CloudServiceType)savedService;
    }
    return self;
}

- (void)loadView {
    // Create root view
    NSView* rootView;
    if (_transparentBackground) {
        NSVisualEffectView* effectView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
        effectView.material = NSVisualEffectMaterialSidebar;
        effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        effectView.state = NSVisualEffectStateFollowsWindowActiveState;
        rootView = effectView;
    } else {
        rootView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 400)];
        rootView.wantsLayer = YES;
        rootView.layer.backgroundColor = fb2k_ui::backgroundColor().CGColor;
    }
    rootView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = rootView;

    [self setupServiceSelector];
    [self setupSearchBar];
    [self setupTableView];
    [self setupStatusBar];
    [self updateStatusBar];
    [self updateSearchPlaceholder];

    // Restore last search
    NSString* lastSearch = [[NSUserDefaults standardUserDefaults] stringForKey:kLastSearchKey];
    if (lastSearch.length > 0) {
        _searchField.stringValue = lastSearch;
        [self performSearch:lastSearch];
    }
}

- (void)setupServiceSelector {
    CGFloat padding = 8;

    // Service selector (segmented control)
    _serviceSelector = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
    _serviceSelector.translatesAutoresizingMaskIntoConstraints = NO;
    _serviceSelector.segmentCount = 2;
    [_serviceSelector setLabel:@"SoundCloud" forSegment:0];
    [_serviceSelector setLabel:@"Mixcloud" forSegment:1];
    _serviceSelector.segmentStyle = NSSegmentStyleTexturedRounded;
    _serviceSelector.selectedSegment = (NSInteger)_selectedService;
    _serviceSelector.target = self;
    _serviceSelector.action = @selector(serviceChanged:);
    [self.view addSubview:_serviceSelector];

    [NSLayoutConstraint activateConstraints:@[
        [_serviceSelector.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:padding],
        [_serviceSelector.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-padding],
        [_serviceSelector.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:padding],
        [_serviceSelector.heightAnchor constraintEqualToConstant:24],
    ]];
}

- (void)setupSearchBar {
    CGFloat searchBarHeight = 32;
    CGFloat padding = 8;

    // Search field
    _searchField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _searchField.translatesAutoresizingMaskIntoConstraints = NO;
    _searchField.placeholderString = @"Search SoundCloud...";
    _searchField.bezelStyle = NSTextFieldRoundedBezel;
    _searchField.delegate = self;
    _searchField.target = self;
    _searchField.action = @selector(searchFieldAction:);
    [self.view addSubview:_searchField];

    // Search button
    _searchButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _searchButton.translatesAutoresizingMaskIntoConstraints = NO;
    _searchButton.bezelStyle = NSBezelStyleTexturedRounded;
    _searchButton.title = @"Search";
    _searchButton.target = self;
    _searchButton.action = @selector(searchButtonClicked:);
    [self.view addSubview:_searchButton];

    // Progress indicator (hidden by default)
    _progressIndicator = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    _progressIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _progressIndicator.style = NSProgressIndicatorStyleSpinning;
    _progressIndicator.controlSize = NSControlSizeSmall;
    _progressIndicator.displayedWhenStopped = NO;
    [self.view addSubview:_progressIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [_searchField.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:padding],
        [_searchField.topAnchor constraintEqualToAnchor:_serviceSelector.bottomAnchor constant:padding],
        [_searchField.heightAnchor constraintEqualToConstant:searchBarHeight - padding],

        [_searchButton.leadingAnchor constraintEqualToAnchor:_searchField.trailingAnchor constant:padding],
        [_searchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-padding],
        [_searchButton.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_searchButton.widthAnchor constraintEqualToConstant:70],

        [_progressIndicator.trailingAnchor constraintEqualToAnchor:_searchField.trailingAnchor constant:-4],
        [_progressIndicator.centerYAnchor constraintEqualToAnchor:_searchField.centerYAnchor],
        [_progressIndicator.widthAnchor constraintEqualToConstant:16],
        [_progressIndicator.heightAnchor constraintEqualToConstant:16],
    ]];
}

- (void)setupTableView {
    CGFloat serviceSelectorHeight = 28;  // Service selector + spacing
    CGFloat searchBarHeight = 32;
    CGFloat statusBarHeight = 24;
    CGFloat padding = 8;

    // Scroll view
    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.drawsBackground = NO;
    [self.view addSubview:_scrollView];

    // Table view
    _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = kRowHeight;
    _tableView.allowsMultipleSelection = NO;
    _tableView.allowsEmptySelection = YES;
    _tableView.usesAlternatingRowBackgroundColors = NO;
    _tableView.backgroundColor = _transparentBackground ? [NSColor clearColor] : fb2k_ui::backgroundColor();
    _tableView.doubleAction = @selector(tableViewDoubleClick:);
    _tableView.target = self;
    _tableView.intercellSpacing = NSMakeSize(0, 0);
    _tableView.gridStyleMask = NSTableViewGridNone;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;

    // No header for cleaner look
    _tableView.headerView = nil;

    // Enable drag from table
    [_tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];
    [_tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:YES];

    // Artwork column (fixed)
    NSTableColumn* artworkColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnArtwork];
    artworkColumn.title = @"";
    artworkColumn.width = kArtworkSize + 8;
    artworkColumn.minWidth = kArtworkSize + 8;
    artworkColumn.maxWidth = kArtworkSize + 8;
    artworkColumn.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:artworkColumn];

    // Title-Artist column (flexible)
    NSTableColumn* titleColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnTitle];
    titleColumn.title = @"Title - Artist";
    titleColumn.width = 200;
    titleColumn.minWidth = 100;
    titleColumn.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [_tableView addTableColumn:titleColumn];

    // Duration column (fixed)
    NSTableColumn* durationColumn = [[NSTableColumn alloc] initWithIdentifier:kColumnDuration];
    durationColumn.title = @"Duration";
    durationColumn.width = 60;
    durationColumn.minWidth = 60;
    durationColumn.maxWidth = 60;
    durationColumn.resizingMask = NSTableColumnNoResizing;
    [_tableView addTableColumn:durationColumn];

    _scrollView.documentView = _tableView;

    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:serviceSelectorHeight + searchBarHeight + padding],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-statusBarHeight],
    ]];
}

- (void)setupStatusBar {
    CGFloat statusBarHeight = 24;

    _statusBar = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _statusBar.translatesAutoresizingMaskIntoConstraints = NO;
    _statusBar.editable = NO;
    _statusBar.selectable = NO;
    _statusBar.bordered = NO;
    _statusBar.drawsBackground = NO;
    _statusBar.font = fb2k_ui::statusBarFont();
    _statusBar.textColor = fb2k_ui::secondaryTextColor();
    _statusBar.alignment = NSTextAlignmentLeft;
    _statusBar.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:_statusBar];

    [NSLayoutConstraint activateConstraints:@[
        [_statusBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_statusBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_statusBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
        [_statusBar.heightAnchor constraintEqualToConstant:statusBarHeight - 8],
    ]];
}

#pragma mark - State Management

- (void)setState:(CloudBrowserState)state {
    _state = state;
    [self updateStatusBar];
    [self updateSearchButton];
}

- (void)updateStatusBar {
    switch (_state) {
        case CloudBrowserStateEmpty:
            _statusBar.stringValue = @"Enter a search term";
            break;
        case CloudBrowserStateSearching:
            _statusBar.stringValue = @"Searching...";
            break;
        case CloudBrowserStateResults:
            _statusBar.stringValue = [NSString stringWithFormat:@"%lu result%@",
                                      (unsigned long)_results.count,
                                      _results.count == 1 ? @"" : @"s"];
            break;
        case CloudBrowserStateNoResults:
            _statusBar.stringValue = @"No results found";
            break;
        case CloudBrowserStateError:
            _statusBar.stringValue = _lastError ?: @"Search failed";
            break;
    }
}

- (void)updateSearchButton {
    if (_state == CloudBrowserStateSearching) {
        _searchButton.title = @"Cancel";
        [_progressIndicator startAnimation:nil];
    } else {
        _searchButton.title = @"Search";
        [_progressIndicator stopAnimation:nil];
    }
}

- (void)updateSearchPlaceholder {
    if (_selectedService == CloudServiceTypeMixcloud) {
        _searchField.placeholderString = @"Search Mixcloud...";
    } else {
        _searchField.placeholderString = @"Search SoundCloud...";
    }
}

- (void)serviceChanged:(id)sender {
    _selectedService = (CloudServiceType)_serviceSelector.selectedSegment;

    // Save selection
    [[NSUserDefaults standardUserDefaults] setInteger:_selectedService forKey:kSelectedServiceKey];

    // Update placeholder
    [self updateSearchPlaceholder];

    // Clear current results and re-search if there's a query
    [_results removeAllObjects];
    [_tableView reloadData];
    self.state = CloudBrowserStateEmpty;

    NSString* query = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length > 0) {
        [self performSearch:query];
    }
}

#pragma mark - Search

- (void)performSearch:(NSString*)query {
    // Invalidate any pending debounce timer
    [_debounceTimer invalidate];
    _debounceTimer = nil;

    if (query.length == 0) {
        self.state = CloudBrowserStateEmpty;
        [_results removeAllObjects];
        [_tableView reloadData];
        return;
    }

    // Save last search query
    [[NSUserDefaults standardUserDefaults] setObject:query forKey:kLastSearchKey];

    // Cancel any existing search
    [[CloudSearchService shared] cancelSearch];

    self.state = CloudBrowserStateSearching;

    __weak typeof(self) weakSelf = self;
    [[CloudSearchService shared] searchTracks:query
                                      service:_selectedService
                                  bypassCache:NO
                                   completion:^(NSArray<CloudTrack*>* tracks, NSError* error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            if (error.code == CloudSearchErrorCancelled) {
                // Ignore cancelled errors (new search started)
                return;
            }
            strongSelf.lastError = error.localizedDescription;
            strongSelf.state = CloudBrowserStateError;
        } else if (tracks.count == 0) {
            [strongSelf.results removeAllObjects];
            strongSelf.state = CloudBrowserStateNoResults;
        } else {
            [strongSelf.results removeAllObjects];
            [strongSelf.results addObjectsFromArray:tracks];
            strongSelf.state = CloudBrowserStateResults;
        }
        [strongSelf.tableView reloadData];
    }];
}

- (void)cancelSearch {
    [[CloudSearchService shared] cancelSearch];
    if (_state == CloudBrowserStateSearching) {
        self.state = CloudBrowserStateEmpty;
    }
}

- (NSArray<CloudTrack*>*)searchResults {
    return [_results copy];
}

#pragma mark - Actions

- (void)searchFieldAction:(id)sender {
    NSString* query = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self performSearch:query];
}

- (void)searchButtonClicked:(id)sender {
    if (_state == CloudBrowserStateSearching) {
        [self cancelSearch];
    } else {
        NSString* query = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self performSearch:query];
    }
}

- (void)tableViewDoubleClick:(id)sender {
    [self addAndPlaySelectedTrack];
}

- (void)addSelectedTrackToPlaylist {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_results.count) {
        return;
    }

    CloudTrack* track = _results[row];
    [self addTrackToPlaylist:track startPlayback:NO];
}

- (void)addAndPlaySelectedTrack {
    NSInteger row = _tableView.selectedRow;
    if (row < 0 || row >= (NSInteger)_results.count) {
        return;
    }

    CloudTrack* track = _results[row];
    [self addTrackToPlaylist:track startPlayback:YES];
}

// Async completion handler for adding tracks
class CloudTrackImportNotify : public process_locations_notify {
public:
    t_size m_playlistIndex;
    t_size m_insertAt;
    bool m_startPlayback;
    pfc::string8 m_url;  // Keep URL alive during async operation

    CloudTrackImportNotify(t_size playlistIndex, t_size insertAt, bool startPlayback, const char* url)
        : m_playlistIndex(playlistIndex)
        , m_insertAt(insertAt)
        , m_startPlayback(startPlayback)
        , m_url(url) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            if (m_playlistIndex < pm->get_playlist_count()) {
                pm->playlist_insert_items(m_playlistIndex, m_insertAt, items, pfc::bit_array_false());

                // Start playback if requested
                if (m_startPlayback) {
                    pm->playlist_execute_default_action(m_playlistIndex, m_insertAt);
                }
            }
        }
    }

    void on_aborted() override {}
};

- (void)addTrackToPlaylist:(CloudTrack*)track startPlayback:(BOOL)play {
    @autoreleasepool {
        // Get the internal URL for the track
        NSString* url = track.internalURL.length > 0 ? track.internalURL : track.webURL;
        if (url.length == 0) {
            return;
        }

        // Use foobar2000 SDK to add to active playlist
        auto api = playlist_manager::get();

        // Get active playlist
        t_size activePlaylist = api->get_active_playlist();
        if (activePlaylist == pfc::infinite_size) {
            // No active playlist, try to create one or use first
            if (api->get_playlist_count() == 0) {
                activePlaylist = api->create_playlist_autoname(0);
            } else {
                activePlaylist = 0;
            }
            api->set_active_playlist(activePlaylist);
        }

        // Create URL string
        std::string urlStr([url UTF8String]);

        // Get current item count to know insert position
        t_size insertPosition = api->playlist_get_item_count(activePlaylist);

        // Create completion handler
        auto notify = fb2k::service_new<CloudTrackImportNotify>(
            activePlaylist,
            insertPosition,
            play ? true : false,
            urlStr.c_str()
        );

        // Build URL list
        pfc::list_t<const char*> urlList;
        urlList.add_item(notify->m_url.c_str());

        // Process locations asynchronously
        playlist_incoming_item_filter_v2::get()->process_locations_async(
            urlList,
            playlist_incoming_item_filter_v2::op_flag_no_filter |
            playlist_incoming_item_filter_v2::op_flag_delay_ui,
            nullptr,  // restrict mask
            nullptr,  // exclude mask
            nullptr,  // parent window
            notify
        );
    }
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    return (NSInteger)_results.count;
}

#pragma mark - NSTableViewDelegate

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)tableColumn row:(NSInteger)row {
    NSString* identifier = tableColumn.identifier;

    if (row < 0 || row >= (NSInteger)_results.count) {
        return nil;
    }
    CloudTrack* track = _results[row];

    // Artwork column - uses NSImageView
    if ([identifier isEqualToString:kColumnArtwork]) {
        NSTableCellView* cellView = [tableView makeViewWithIdentifier:identifier owner:self];
        if (!cellView) {
            cellView = [[NSTableCellView alloc] init];
            cellView.identifier = identifier;

            NSImageView* imageView = [[NSImageView alloc] init];
            imageView.translatesAutoresizingMaskIntoConstraints = NO;
            imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
            imageView.wantsLayer = YES;
            imageView.layer.cornerRadius = 4.0;
            imageView.layer.masksToBounds = YES;
            imageView.layer.backgroundColor = [NSColor darkGrayColor].CGColor;
            imageView.tag = 100;  // Tag for finding later
            [cellView addSubview:imageView];
            cellView.imageView = imageView;

            [NSLayoutConstraint activateConstraints:@[
                [imageView.widthAnchor constraintEqualToConstant:kArtworkSize],
                [imageView.heightAnchor constraintEqualToConstant:kArtworkSize],
                [imageView.centerXAnchor constraintEqualToAnchor:cellView.centerXAnchor],
                [imageView.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
            ]];
        }

        NSImageView* imageView = cellView.imageView;
        imageView.image = nil;  // Clear while loading

        // Load thumbnail asynchronously
        if (track.thumbnailURL.length > 0) {
            std::string url([track.thumbnailURL UTF8String]);
            __weak NSImageView* weakImageView = imageView;
            NSString* trackId = track.trackId;  // Capture for validation

            cloud_streamer::ThumbnailCache::shared().fetchData(url, [weakImageView, trackId](const cloud_streamer::ThumbnailResult& result) {
                if (result.success && result.imageData) {
                    NSImage* image = [[NSImage alloc] initWithData:result.imageData];
                    if (image) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSImageView* strongImageView = weakImageView;
                            if (strongImageView) {
                                strongImageView.image = image;
                            }
                        });
                    }
                }
            });
        }

        return cellView;
    }

    // Text columns
    NSTableCellView* cellView = [tableView makeViewWithIdentifier:identifier owner:self];
    if (!cellView) {
        cellView = [[NSTableCellView alloc] init];
        cellView.identifier = identifier;

        NSTextField* textField = [[NSTextField alloc] init];
        textField.bordered = NO;
        textField.editable = NO;
        textField.selectable = NO;
        textField.drawsBackground = NO;
        textField.translatesAutoresizingMaskIntoConstraints = NO;
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        [cellView addSubview:textField];
        cellView.textField = textField;

        [NSLayoutConstraint activateConstraints:@[
            [textField.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:fb2k_ui::kCellTextPadding],
            [textField.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor constant:-fb2k_ui::kCellTextPadding],
            [textField.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor]
        ]];
    }

    NSTextField* textField = cellView.textField;

    if ([identifier isEqualToString:kColumnTitle]) {
        // Title - Artist format
        NSString* displayText;
        if (track.artist.length > 0) {
            displayText = [NSString stringWithFormat:@"%@ - %@", track.title, track.artist];
        } else {
            displayText = track.title;
        }
        textField.stringValue = displayText ?: @"";
        textField.font = fb2k_ui::rowFont();
        textField.textColor = fb2k_ui::textColor();
    } else if ([identifier isEqualToString:kColumnDuration]) {
        textField.stringValue = [track formattedDuration];
        textField.font = fb2k_ui::monospacedDigitFont();
        textField.textColor = fb2k_ui::secondaryTextColor();
        textField.alignment = NSTextAlignmentRight;
    }

    return cellView;
}

- (void)tableViewSelectionDidChange:(NSNotification*)notification {
    // Update UI based on selection if needed
}

#pragma mark - Drag Support

- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView pasteboardWriterForRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_results.count) {
        return nil;
    }

    CloudTrack* track = _results[row];

    // Use web URL for drag-drop since foobar2000's Default UI processes it
    // through playlist_incoming_item_filter which routes to our input decoder.
    NSString* urlString = track.webURL.length > 0 ? track.webURL : track.internalURL;
    if (urlString.length == 0) {
        return nil;
    }

    // Create pasteboard item with multiple types for compatibility
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:urlString forType:NSPasteboardTypeURL];
    [item setString:urlString forType:NSPasteboardTypeString];

    return item;
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification*)notification {
    // Debounce search input
    [_debounceTimer invalidate];

    NSString* query = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (query.length == 0) {
        self.state = CloudBrowserStateEmpty;
        [_results removeAllObjects];
        [_tableView reloadData];
        return;
    }

    _debounceTimer = [NSTimer scheduledTimerWithTimeInterval:kSearchDebounceInterval
                                                      target:self
                                                    selector:@selector(debounceTimerFired:)
                                                    userInfo:nil
                                                     repeats:NO];
}

- (void)debounceTimerFired:(NSTimer*)timer {
    NSString* query = [_searchField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self performSearch:query];
}

#pragma mark - Keyboard Handling

- (void)keyDown:(NSEvent*)event {
    NSString* chars = event.charactersIgnoringModifiers;
    unichar key = [chars characterAtIndex:0];
    NSEventModifierFlags modifiers = event.modifierFlags;

    if (key == NSCarriageReturnCharacter || key == NSEnterCharacter) {
        if (modifiers & NSEventModifierFlagCommand) {
            // Cmd+Enter: Add and play
            [self addAndPlaySelectedTrack];
        } else {
            // Enter: Add to playlist
            [self addSelectedTrackToPlaylist];
        }
    } else if (key == 0x1B) {  // Escape
        if (_state == CloudBrowserStateSearching) {
            [self cancelSearch];
        } else {
            // Clear search field
            _searchField.stringValue = @"";
            [_results removeAllObjects];
            [_tableView reloadData];
            self.state = CloudBrowserStateEmpty;
        }
    } else {
        [super keyDown:event];
    }
}

@end
