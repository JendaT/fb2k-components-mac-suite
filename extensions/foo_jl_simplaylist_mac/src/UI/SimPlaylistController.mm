//
//  SimPlaylistController.mm
//  foo_simplaylist_mac
//
//  View controller for SimPlaylist UI element
//

#import "SimPlaylistController.h"
#import "SimPlaylistView.h"
#import "SimPlaylistHeaderBar.h"
#import "../Core/ColumnDefinition.h"
#import "../Core/GroupPreset.h"
#import "../Core/TitleFormatHelper.h"
#import "../Core/ConfigHelper.h"
#import "../Core/AlbumArtCache.h"
#import "../Core/ReorderPlanner.h"
#import "../Core/SubgroupDetector.h"
#import "../Core/GroupBuilder.h"
#import "../Core/DecorationStore.h"
#import "../Integration/DecorationCoordinator.h"
#import "../Integration/PlaylistCallbacks.h"
#import "../../../../shared/UIStyles.h"

#include <SDK/menu_helpers.h>
#include <atomic>
#include <numeric>
#include <set>
#include <unordered_set>
#include <tuple>
#include <vector>

// Subgroup detection state machine lives in Core/SubgroupDetector.h
// (SDK-free, unit-tested) so all detection code paths share IDENTICAL logic.

// Global debug flag - set to true to enable debug logging.
// Output goes to simplaylist_subgroup_debug.txt in NSTemporaryDirectory()
// (see SubgroupDetector.h - a fixed /tmp path would be symlink-attackable).
static std::atomic<bool> g_subgroupDebugEnabled{false};

// Scroll-anchor dictionary keys. Also the persisted JSON field names of the
// per-playlist anchors - do not rename.
static NSString * const kAnchorIndexKey = @"index";
static NSString * const kAnchorOffsetKey = @"offset";

// =============================================================================
// ASYNC FILE IMPORT (copied from Plorg's working implementation)
// =============================================================================

class SimPlaylistImportNotify : public process_locations_notify {
public:
    t_size m_playlistIndex;
    t_size m_insertAt;
    pfc::string_list_impl m_paths;  // Keeps paths alive during async operation

    SimPlaylistImportNotify(t_size playlistIndex, t_size insertAt)
        : m_playlistIndex(playlistIndex), m_insertAt(insertAt) {}

    void on_completion(metadb_handle_list_cref items) override {
        if (items.get_count() > 0) {
            auto pm = playlist_manager::get();
            if (m_playlistIndex < pm->get_playlist_count()) {
                // Sort by (album artist, album, tracknumber-as-integer, path fallback).
                // Track number is parsed as an integer so ordering is 1, 2 ... 12, 13.
                // Path is a tiebreaker for tracks with no track number metadata.
                metadb_handle_list itemsCopy(items);
                t_size count = itemsCopy.get_count();

                auto albumArtistScript = simplaylist::TitleFormatHelper::compileWithCache("%album artist%");
                auto albumScript       = simplaylist::TitleFormatHelper::compileWithCache("%album%");
                auto trackNumScript    = simplaylist::TitleFormatHelper::compileWithCache("%tracknumber%");
                auto pathScript        = simplaylist::TitleFormatHelper::compileWithCache("%path_sort%");

                // Build sort keys once per track to avoid repeated formatting
                using SortKey = std::tuple<std::string, std::string, int, std::string>;
                std::vector<SortKey> keys;
                keys.reserve(count);
                for (t_size i = 0; i < count; i++) {
                    auto h = itemsCopy.get_item(i);
                    std::string albumArtist = simplaylist::TitleFormatHelper::format(h, albumArtistScript);
                    std::string album       = simplaylist::TitleFormatHelper::format(h, albumScript);
                    std::string trackStr    = simplaylist::TitleFormatHelper::format(h, trackNumScript);
                    std::string path        = simplaylist::TitleFormatHelper::format(h, pathScript);
                    int trackNum = trackStr.empty() ? 0 : std::atoi(trackStr.c_str());
                    keys.emplace_back(std::move(albumArtist), std::move(album), trackNum, std::move(path));
                }

                // Sort indices by key; stable_sort preserves original order for equal keys
                std::vector<t_size> order(count);
                std::iota(order.begin(), order.end(), 0);
                std::stable_sort(order.begin(), order.end(), [&](t_size a, t_size b) {
                    return keys[a] < keys[b];
                });

                metadb_handle_list sortedItems;
                sortedItems.prealloc(count);
                for (t_size i : order) {
                    sortedItems.add_item(itemsCopy.get_item(i));
                }

                pm->playlist_undo_backup(m_playlistIndex);
                // Clear existing selection before inserting new items
                pm->playlist_set_selection(m_playlistIndex, pfc::bit_array_true(), pfc::bit_array_false());
                // Insert and select only the new items
                pm->playlist_insert_items(m_playlistIndex, m_insertAt, sortedItems, pfc::bit_array_val(true));
                // Set focus to first inserted item
                pm->playlist_set_focus_item(m_playlistIndex, m_insertAt);
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
            playlist_incoming_item_filter_v2::op_flag_delay_ui |
            playlist_incoming_item_filter_v2::op_flag_background,
            nullptr, nullptr, nullptr,
            this
        );
    }
};

static void importFilesToPlaylistAsync(t_size playlistIndex, t_size insertAt, NSArray<NSURL*>* urls) {
    if (urls.count == 0) return;

    auto pm = playlist_manager::get();
    if (playlistIndex >= pm->get_playlist_count()) return;

    // Sort URLs by filename (last path component) for proper track ordering
    // Files are typically named with track numbers (e.g., "01 - Song.mp3")
    NSArray<NSURL*>* sortedURLs = [urls sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];

    auto notify = fb2k::service_new<SimPlaylistImportNotify>(playlistIndex, insertAt);

    for (NSURL* url in sortedURLs) {
        if (url.isFileURL) {
            // File URL - use path
            NSString* path = url.path;
            if (path && path.length > 0) {
                notify->m_paths.add_item([path UTF8String]);
            }
        } else {
            // Web URL (e.g., soundcloud://, mixcloud://) - use full URL string
            NSString* urlString = url.absoluteString;
            if (urlString && urlString.length > 0) {
                // Log scheme only — full URLs may carry signed query parameters
                FB2K_console_formatter() << "[SimPlaylist] importing web URL, scheme: "
                                         << (url.scheme.UTF8String ?: "unknown");
                notify->m_paths.add_item([urlString UTF8String]);
            }
        }
    }

    notify->startImport();
}

// Import files using foobar2000 native paths (supports file://, mac-volume://, etc.)
static void importFb2kPathsToPlaylistAsync(t_size playlistIndex, t_size insertAt, NSArray<NSString*>* fb2kPaths) {
    if (fb2kPaths.count == 0) return;

    auto pm = playlist_manager::get();
    if (playlistIndex >= pm->get_playlist_count()) return;

    // Sort paths by filename for proper track ordering
    NSArray<NSString*>* sortedPaths = [fb2kPaths sortedArrayUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];

    auto notify = fb2k::service_new<SimPlaylistImportNotify>(playlistIndex, insertAt);

    for (NSString* path in sortedPaths) {
        if (path && path.length > 0) {
            // Pass foobar2000 native paths directly (file://, mac-volume://, etc.)
            notify->m_paths.add_item([path UTF8String]);
        }
    }

    notify->startImport();
}

// Track reload operations for progress display. Identified by a monotonic ID,
// not by position: completed entries are compacted out whenever the context
// menu is built, which shifts every index after them.
struct ReloadOperation {
    uint64_t opID;
    t_size totalCount;
    t_size processedCount;
    bool completed;
};

@interface SimPlaylistController () <SimPlaylistViewDelegate, SimPlaylistHeaderBarDelegate> {
    // Context menu manager - must be stored for execute_by_id to work
    contextmenu_manager_v2::ptr _contextMenuManager;
    contextmenu_manager::ptr _contextMenuManagerV1;
    // Store handles for custom menu actions (Reload Info)
    metadb_handle_list _contextMenuHandles;
    // Active reload operations for progress tracking
    std::vector<ReloadOperation> _reloadOperations;
    // Pre-compiled title format scripts for columns (rebuilt when columns change)
    std::vector<titleformat_object::ptr> _compiledColumnScripts;
    // Selection holder — drives Selection Properties (sections=metadata) panel
    ui_selection_holder::ptr _selectionHolder;
    // Row decorator providers (intake doc 04 Part A). nil when zero providers
    // are registered — the guard for the whole decoration path.
    DecorationCoordinator *_decorationCoordinator;
    // Last row range handed to the coordinator; only newly entered rows are
    // index-mapped each draw. Reset on invalidation/mapping changes.
    NSRange _decorPreparedRange;
    // Cancels stale group detection. Per-instance: the component supports several
    // panels at once, and a process-wide counter let one panel's rebuild cancel
    // another's in-flight detection. Heap-allocated so background blocks can
    // observe it by value without keeping the controller alive.
    std::shared_ptr<std::atomic<NSInteger>> _groupDetectionGeneration;
}
@property (nonatomic, strong) SimPlaylistView *playlistView;
@property (nonatomic, strong) SimPlaylistHeaderBar *headerBar;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) NSArray<ColumnDefinition *> *columns;
@property (nonatomic, strong) NSArray<ColumnDefinition *> *availableColumnTemplates;  // Combined hardcoded + SDK columns
@property (nonatomic, strong) NSArray<GroupPreset *> *groupPresets;
@property (nonatomic, assign) NSInteger activePresetIndex;
@property (nonatomic, assign) NSInteger currentPlaylistIndex;
@property (nonatomic, assign) BOOL artRedrawScheduled;  // Album-art redraw batching flag (50 ms window)
// Per-playlist scroll anchors: playlist index -> @{kAnchorIndexKey: first visible
// track's playlist index, kAnchorOffsetKey: pixel delta between the viewport top and
// that row's top (negative when a header/padding block is scrolled above it)}.
// Pixel-exact so switching away and back lands on the identical position.
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSDictionary *> *scrollAnchorIndices;
@property (nonatomic, assign) NSInteger scrollRestorePlaylistIndex;  // Playlist index for pending scroll restore (-1 = none)
@property (nonatomic, assign) BOOL currentPlaylistInitialized;  // True after groups fully loaded (gates group-cache persistence)
// True once the viewport reflects the user's position for the current playlist
// (after restore ran, or when there was nothing to restore). Gates anchor
// saving so a pre-restore viewport never overwrites a good anchor.
@property (nonatomic, assign) BOOL scrollPositionEstablished;
// "Focus playing now" across a playlist switch: center this track once the
// target playlist has rebuilt (consumed by performScrollRestore).
@property (nonatomic, assign) NSInteger pendingCenterIndex;
@property (nonatomic, assign) NSInteger pendingCenterPlaylist;
@property (nonatomic, strong) NSDictionary<NSNumber *, NSNumber *> *queuePositionMap;  // item_index → 1-based queue position
@property (nonatomic, assign) BOOL hasQueueColumn;  // True if any visible column uses __queue_position__
@property (nonatomic, assign) BOOL activePlaylistJustCleared;  // Finder-open detection: full clear of active playlist
@property (nonatomic, assign) BOOL internalModification;  // True while we are mutating playlist programmatically

- (void)recomputeGroupDurations;
- (void)recomputeGroupDurationsWithHandles:(const metadb_handle_list &)handles;
- (void)clearGroupData;
- (void)persistColumns;
- (void)maybeApplyFinderOpenOverride:(std::shared_ptr<metadb_handle_list>)addedHandles;
- (void)refreshSelectionTracking;
@end

@implementation SimPlaylistController

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _columns = [ColumnDefinition defaultColumns];
        [self recompileColumnScripts];
        _groupPresets = [GroupPreset defaultPresets];
        _activePresetIndex = 0;
        _currentPlaylistIndex = -1;
        _scrollAnchorIndices = [NSMutableDictionary dictionary];
        _scrollRestorePlaylistIndex = -1;
        _currentPlaylistInitialized = NO;
        _scrollPositionEstablished = NO;
        _pendingCenterIndex = -1;
        _pendingCenterPlaylist = -1;
        _groupDetectionGeneration = std::make_shared<std::atomic<NSInteger>>(0);
    }
    return self;
}

- (void)loadView {
    // Load style settings from config
    BOOL glassBackground = simplaylist_config::getConfigBool(
        simplaylist_config::kGlassBackground,
        simplaylist_config::kDefaultGlassBackground);
    fb2k_ui::SizeVariant headerSize = static_cast<fb2k_ui::SizeVariant>(
        simplaylist_config::getConfigInt(
            simplaylist_config::kColumnHeaderSize,
            simplaylist_config::kDefaultColumnHeaderSize));
    fb2k_ui::AccentMode accentMode = static_cast<fb2k_ui::AccentMode>(
        simplaylist_config::getConfigInt(
            simplaylist_config::kHeaderAccentColor,
            simplaylist_config::kDefaultHeaderAccentColor));

    // Create container view - use glass helper for transparent mode
    NSView *container;
    if (glassBackground) {
        container = fb2k_ui::createGlassContainer(NSMakeRect(0, 0, 400, 300));
    } else {
        container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    }
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.view = container;

    // Header height from shared UIStyles
    CGFloat headerHeight = fb2k_ui::headerHeight(headerSize);
    CGFloat containerHeight = 300;

    // Create header bar at TOP (in non-flipped view, y increases upward)
    _headerBar = [[SimPlaylistHeaderBar alloc] initWithFrame:NSMakeRect(0, containerHeight - headerHeight, 400, headerHeight)];
    _headerBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _headerBar.delegate = self;
    _headerBar.columns = _columns;
    _headerBar.groupColumnWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    _headerBar.headerSize = headerSize;
    _headerBar.accentMode = accentMode;
    _headerBar.glassBackground = glassBackground;
    [container addSubview:_headerBar];

    // Create scroll view BELOW header (from y=0 to y=containerHeight-headerHeight)
    _scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 400, containerHeight - headerHeight)];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = YES;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.wantsLayer = YES;  // Enable smooth scrolling optimizations

    // Create playlist view
    _playlistView = [[SimPlaylistView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    _playlistView.delegate = self;
    _playlistView.columns = _columns;
    _playlistView.groupColumnWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    _playlistView.albumArtSize = simplaylist_config::getConfigInt(
        simplaylist_config::kAlbumArtSize,
        simplaylist_config::kDefaultAlbumArtSize);
    _playlistView.glassBackground = glassBackground;
    _playlistView.wantsLayer = YES;  // Layer backing for smooth drawing

    // Configure scroll view and set document view
    _scrollView.documentView = _playlistView;
    fb2k_ui::configureScrollViewForGlass(_scrollView, glassBackground);
    [container addSubview:_scrollView];

    // Observe scroll changes to sync header
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrollViewDidScroll:)
                                                 name:NSViewBoundsDidChangeNotification
                                               object:_scrollView.contentView];
    _scrollView.contentView.postsBoundsChangedNotifications = YES;

    // Observe frame changes for auto-resize columns
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrollViewFrameDidChange:)
                                                 name:NSViewFrameDidChangeNotification
                                               object:_scrollView];
    _scrollView.postsFrameChangedNotifications = YES;

    // Observe settings changes from preferences
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:@"SimPlaylistSettingsChanged"
                                               object:nil];

    // Observe lightweight redraw requests (for settings that don't affect grouping)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRedrawNeeded:)
                                                 name:@"SimPlaylistRedrawNeeded"
                                               object:nil];

    // Row decorator providers (intake doc 04 Part A): enumerate once at panel
    // init. With zero providers the coordinator is nil, decorationsEnabled
    // stays NO and the draw path is untouched.
    __weak typeof(self) weakSelf = self;
    _decorPreparedRange = NSMakeRange(NSNotFound, 0);
    _decorationCoordinator = [DecorationCoordinator coordinatorWithInvalidationHandler:^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_decorPreparedRange = NSMakeRange(NSNotFound, 0);
        [strongSelf.playlistView setNeedsDisplayInRect:strongSelf.playlistView.visibleRect];
    }];
    if (_decorationCoordinator) {
        // View and header bar must agree or columns misalign against headers
        const CGFloat gutterWidth = 16;
        _playlistView.decorationGutterWidth = gutterWidth;
        _playlistView.decorationsEnabled = YES;
        _headerBar.decorationGutterWidth = gutterWidth;
    }

    // Register for callbacks
    SimPlaylistCallbackManager_registerController(self);

    // Initial data load
    [self rebuildFromPlaylist];

    // Start selection tracking so Selection Properties (sections=metadata) reflects this view
    [self refreshSelectionTracking];

    // Auto-resize columns to fit view
    [self autoResizeColumns];
}

- (void)scrollViewDidScroll:(NSNotification *)notification {
    // Sync header bar horizontal scroll with content
    NSClipView *clipView = _scrollView.contentView;
    [_headerBar setScrollOffset:clipView.bounds.origin.x];
}

- (void)scrollViewFrameDidChange:(NSNotification *)notification {
    [self autoResizeColumns];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    // Save current scroll position before rebuilding
    NSDictionary *savedAnchor = [self captureScrollAnchor];

    // Reload group presets from config
    std::string savedJSON = simplaylist_config::getConfigString(
        simplaylist_config::kGroupPresets, "");
    if (!savedJSON.empty()) {
        NSString *jsonString = [NSString stringWithUTF8String:savedJSON.c_str()];
        _groupPresets = [GroupPreset presetsFromJSON:jsonString];
        _activePresetIndex = [GroupPreset activeIndexFromJSON:jsonString];
    } else {
        _groupPresets = [GroupPreset defaultPresets];
        _activePresetIndex = 0;
    }

    // Reload header size and accent mode from config
    fb2k_ui::SizeVariant headerSize = static_cast<fb2k_ui::SizeVariant>(
        simplaylist_config::getConfigInt(
            simplaylist_config::kColumnHeaderSize,
            simplaylist_config::kDefaultColumnHeaderSize));
    fb2k_ui::AccentMode accentMode = static_cast<fb2k_ui::AccentMode>(
        simplaylist_config::getConfigInt(
            simplaylist_config::kHeaderAccentColor,
            simplaylist_config::kDefaultHeaderAccentColor));
    CGFloat headerHeight = fb2k_ui::headerHeight(headerSize);

    // Update header bar properties and frames
    _headerBar.headerSize = headerSize;
    _headerBar.accentMode = accentMode;
    CGFloat containerHeight = self.view.bounds.size.height;
    _headerBar.frame = NSMakeRect(0, containerHeight - headerHeight, self.view.bounds.size.width, headerHeight);
    _scrollView.frame = NSMakeRect(0, 0, self.view.bounds.size.width, containerHeight - headerHeight);

    // Handle glass background toggle without requiring restart
    BOOL glassBackground = simplaylist_config::getConfigBool(
        simplaylist_config::kGlassBackground,
        simplaylist_config::kDefaultGlassBackground);
    BOOL currentlyGlass = [self.view isKindOfClass:[NSVisualEffectView class]];
    if (glassBackground != currentlyGlass) {
        NSView *newContainer;
        if (glassBackground) {
            newContainer = fb2k_ui::createGlassContainer(self.view.frame);
        } else {
            newContainer = [[NSView alloc] initWithFrame:self.view.frame];
        }
        newContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // Transfer subviews to new container
        [_headerBar removeFromSuperview];
        [_scrollView removeFromSuperview];
        [newContainer addSubview:_headerBar];
        [newContainer addSubview:_scrollView];

        // Replace the view (NSViewController manages parent insertion)
        self.view = newContainer;
    }
    _headerBar.glassBackground = glassBackground;
    _playlistView.glassBackground = glassBackground;
    fb2k_ui::configureScrollViewForGlass(_scrollView, glassBackground);

    // Reload group column width
    CGFloat newWidth = simplaylist_config::getConfigInt(
        simplaylist_config::kGroupColumnWidth,
        simplaylist_config::kDefaultGroupColumnWidth);
    _playlistView.groupColumnWidth = newWidth;
    _headerBar.groupColumnWidth = newWidth;

    // Reload album art size
    CGFloat newArtSize = simplaylist_config::getConfigInt(
        simplaylist_config::kAlbumArtSize,
        simplaylist_config::kDefaultAlbumArtSize);
    _playlistView.albumArtSize = newArtSize;

    // Store scroll anchor for current playlist so it gets restored after rebuild
    if (savedAnchor && _currentPlaylistIndex >= 0) {
        _scrollAnchorIndices[@(_currentPlaylistIndex)] = savedAnchor;
        _scrollRestorePlaylistIndex = _currentPlaylistIndex;
    }

    // Rebuild with new settings (recalculates group padding based on new album art size)
    [self rebuildFromPlaylist];
    [_headerBar setNeedsDisplay:YES];
}

- (void)handleRedrawNeeded:(NSNotification *)notification {
    // Lightweight redraw for settings that don't affect grouping (e.g., dim parentheses, now playing shading)
    // Re-read group duration setting in case it just toggled, then refresh the durations array.
    _playlistView.showGroupDuration = simplaylist_config::getConfigBool(
        simplaylist_config::kShowGroupDuration,
        simplaylist_config::kDefaultShowGroupDuration);
    [self recomputeGroupDurations];
    [_playlistView clearFormattedValuesCache];
    [_playlistView setNeedsDisplay:YES];
}

- (void)autoResizeColumns {
    CGFloat availableWidth = _scrollView.bounds.size.width - _playlistView.groupColumnWidth;

    // Calculate fixed width (non-auto-resize columns)
    CGFloat fixedWidth = 0;
    NSMutableArray<ColumnDefinition *> *autoResizeCols = [NSMutableArray array];

    for (ColumnDefinition *col in _columns) {
        if (col.autoResize) {
            [autoResizeCols addObject:col];
        } else {
            fixedWidth += col.width;
        }
    }

    if (autoResizeCols.count == 0) return;

    // Distribute remaining space proportionally to preserve user-adjusted column ratios
    CGFloat remainingWidth = availableWidth - fixedWidth;
    if (remainingWidth <= 0) return;

    CGFloat totalAutoWidth = 0;
    for (ColumnDefinition *col in autoResizeCols) {
        totalAutoWidth += col.width;
    }

    BOOL changed = NO;
    for (ColumnDefinition *col in autoResizeCols) {
        CGFloat proportion = (totalAutoWidth > 0) ? col.width / totalAutoWidth : 1.0 / (CGFloat)autoResizeCols.count;
        CGFloat newWidth = remainingWidth * proportion;
        if (fabs(col.width - newWidth) > 1.0) {
            col.width = newWidth;
            changed = YES;
        }
    }

    if (changed) {
        [_playlistView reloadData];
        [_headerBar setNeedsDisplay:YES];
    }
}

- (void)dealloc {
    // Remove notification observers
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Unregister from callbacks
    SimPlaylistCallbackManager_unregisterController(self);
    // Unregister decorator provider callbacks
    [_decorationCoordinator shutdown];
}

#pragma mark - Playlist Data Loading (SPARSE MODEL)

// Helper to compute subgroup count per group (for O(1) lookup in totalRowsInGroup)
- (void)updateSubgroupCountPerGroup {
    NSArray<NSNumber *> *groupStarts = _playlistView.groupStarts;
    NSArray<NSNumber *> *subgroupStarts = _playlistView.subgroupStarts;

    // Accumulate in a plain vector; box to NSNumber once at the end
    std::vector<NSInteger> rawCounts(groupStarts.count, 0);

    // For each subgroup, find which group it belongs to and increment that group's count
    NSUInteger groupIndex = 0;
    for (NSNumber *subgroupStart in subgroupStarts) {
        NSInteger sgIndex = [subgroupStart integerValue];
        // Find the group this subgroup belongs to
        while (groupIndex + 1 < groupStarts.count &&
               [groupStarts[groupIndex + 1] integerValue] <= sgIndex) {
            groupIndex++;
        }
        if (groupIndex < rawCounts.size()) {
            rawCounts[groupIndex]++;
        }
    }

    NSMutableArray<NSNumber *> *counts = [NSMutableArray arrayWithCapacity:rawCounts.size()];
    for (NSInteger c : rawCounts) {
        [counts addObject:@(c)];
    }
    _playlistView.subgroupCountPerGroup = counts;
}

// Filter out subgroups in groups that only have one subgroup (when hideSingleSubgroup is enabled)
- (void)filterSingleSubgroupsIfNeeded {
    bool hideSingleSubgroup = simplaylist_config::getConfigBool(
        simplaylist_config::kHideSingleSubgroup,
        simplaylist_config::kDefaultHideSingleSubgroup);

    if (!hideSingleSubgroup) return;

    NSArray<NSNumber *> *groupStarts = _playlistView.groupStarts;
    NSArray<NSNumber *> *subgroupStarts = _playlistView.subgroupStarts;
    NSArray<NSString *> *subgroupHeaders = _playlistView.subgroupHeaders;
    NSArray<NSNumber *> *subgroupCountPerGroup = _playlistView.subgroupCountPerGroup;

    if (subgroupStarts.count == 0 || groupStarts.count == 0) return;

    // starts and headers are 1:1. If a caller ever desyncs them, filtering would
    // drop the pairs unevenly and leave subgroup rows with no header text (blank
    // rows that still occupy space) - leave the arrays untouched instead.
    if (subgroupHeaders.count != subgroupStarts.count) return;

    // Build filtered arrays - keep only subgroups in groups with count > 1
    NSMutableArray<NSNumber *> *filteredStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *filteredHeaders = [NSMutableArray array];

    NSUInteger groupIndex = 0;
    for (NSUInteger i = 0; i < subgroupStarts.count; i++) {
        NSInteger sgIndex = [subgroupStarts[i] integerValue];

        // Find which group this subgroup belongs to
        while (groupIndex + 1 < groupStarts.count &&
               [groupStarts[groupIndex + 1] integerValue] <= sgIndex) {
            groupIndex++;
        }

        // Keep subgroup only if its group has more than one subgroup
        if (groupIndex < subgroupCountPerGroup.count) {
            NSInteger count = [subgroupCountPerGroup[groupIndex] integerValue];
            if (count > 1) {
                [filteredStarts addObject:subgroupStarts[i]];
                [filteredHeaders addObject:subgroupHeaders[i]];
            }
        }
    }

    // Only update if we filtered something out
    if (filteredStarts.count != subgroupStarts.count) {
        _playlistView.subgroupStarts = filteredStarts;
        _playlistView.subgroupHeaders = filteredHeaders;
        // Recalculate counts with filtered data
        [self updateSubgroupCountPerGroup];
    }
}

- (void)recomputeGroupDurations {
    if (!_playlistView.showGroupDuration) {
        _playlistView.groupDurations = nil;
        return;
    }
    if (_currentPlaylistIndex < 0) {
        _playlistView.groupDurations = nil;
        return;
    }
    if (_playlistView.groupStarts.count == 0) {
        _playlistView.groupDurations = nil;
        return;
    }

    auto pm = playlist_manager::get();
    metadb_handle_list handles;
    pm->playlist_get_all_items((t_size)_currentPlaylistIndex, handles);
    [self recomputeGroupDurationsWithHandles:handles];
}

// Overload for callers that already hold the playlist's handle list: the fetch
// above copies the whole list (one refcount per item) on the main thread, and
// the sync detection path had just fetched the identical list.
- (void)recomputeGroupDurationsWithHandles:(const metadb_handle_list &)handles {
    if (!_playlistView.showGroupDuration) {
        _playlistView.groupDurations = nil;
        return;
    }
    if (_currentPlaylistIndex < 0) {
        _playlistView.groupDurations = nil;
        return;
    }
    NSArray<NSNumber *> *starts = _playlistView.groupStarts;
    if (starts.count == 0) {
        _playlistView.groupDurations = nil;
        return;
    }

    t_size itemCount = handles.get_count();

    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:starts.count];
    for (NSUInteger g = 0; g < starts.count; g++) {
        t_size gs = (t_size)[starts[g] integerValue];
        t_size ge = (g + 1 < starts.count)
            ? (t_size)[starts[g + 1] integerValue]
            : itemCount;
        if (ge > itemCount) ge = itemCount;
        double total = 0;
        for (t_size i = gs; i < ge; i++) {
            double len = handles[i]->get_length();
            if (len > 0) total += len;
        }
        [durations addObject:@(total)];
    }
    _playlistView.groupDurations = durations;
}

// Apply user's "Finder open" override behavior when an external replacement of the
// active playlist is detected (full clear immediately followed by mass add at base 0).
//
// Behavior modes:
//   0 = default — do nothing, leave the replacement as-is.
//   1 = append to current — undo the replacement (restoring previous content) and
//       append the imported items to the end of the active playlist.
//   2 = send to named playlist — undo the replacement and add the imported items
//       to a configured target playlist (created on demand).
- (void)maybeApplyFinderOpenOverride:(std::shared_ptr<metadb_handle_list>)addedHandles {
    int64_t behavior = simplaylist_config::getConfigInt(
        simplaylist_config::kFinderOpenBehavior,
        simplaylist_config::kDefaultFinderOpenBehavior);
    if (behavior == 0 || !addedHandles || addedHandles->get_count() == 0) return;

    auto pm = playlist_manager::get();
    t_size active = pm->get_active_playlist();
    if (active == SIZE_MAX) return;

    metadb_handle_list captured = *addedHandles;
    BOOL undoAvailable = pm->playlist_is_undo_available(active);

    _internalModification = YES;

    if (behavior == 1) {
        // Append to current: requires undo to restore previous content
        if (!undoAvailable) {
            FB2K_console_formatter() << "[SimPlaylist] Finder-open override (append): no undo available, leaving replacement as-is";
            _internalModification = NO;
            return;
        }
        // Respect the add lock (as every drop handler does) before mutating
        if (pm->playlist_lock_is_present(active) &&
            (pm->playlist_lock_get_filter_mask(active) & playlist_lock::filter_add)) {
            FB2K_console_formatter() << "[SimPlaylist] Finder-open override (append): playlist is locked for add, leaving replacement as-is";
            _internalModification = NO;
            return;
        }
        pm->playlist_undo_restore(active);
        // After undo, append captured items at the end
        t_size endPos = pm->playlist_get_item_count(active);
        pfc::bit_array_false selectNone;
        pm->playlist_insert_items(active, endPos, captured, selectNone);
    } else if (behavior == 2) {
        // Send to named playlist
        std::string targetName = simplaylist_config::getConfigString(
            simplaylist_config::kFinderOpenTargetPlaylist,
            simplaylist_config::kDefaultFinderOpenTargetPlaylist);
        if (targetName.empty()) {
            targetName = simplaylist_config::kDefaultFinderOpenTargetPlaylist;
        }

        // Find or create target playlist BEFORE touching the active playlist,
        // so a missing or add-locked target does not cost the restore.
        t_size target = pm->find_or_create_playlist(targetName.c_str(), pfc_infinite);
        if (target == SIZE_MAX) {
            FB2K_console_formatter() << "[SimPlaylist] Finder-open override: could not find or create target playlist \"" << targetName.c_str() << "\"";
            _internalModification = NO;
            return;
        }
        // Respect the add lock (as every drop handler does) before mutating
        if (pm->playlist_lock_is_present(target) &&
            (pm->playlist_lock_get_filter_mask(target) & playlist_lock::filter_add)) {
            FB2K_console_formatter() << "[SimPlaylist] Finder-open override: target playlist \"" << targetName.c_str() << "\" is locked for add, leaving replacement as-is";
            _internalModification = NO;
            return;
        }

        // Restore active playlist's previous content if possible
        if (undoAvailable) {
            pm->playlist_undo_restore(active);
        } else {
            // No undo — clear the active playlist (user's previous content is lost).
            FB2K_console_formatter() << "[SimPlaylist] Finder-open override (send to playlist): no undo available, clearing active playlist";
            pm->playlist_clear(active);
        }
        t_size endPos = pm->playlist_get_item_count(target);
        pfc::bit_array_false selectNone;
        pm->playlist_insert_items(target, endPos, captured, selectNone);
    }

    _internalModification = NO;
}

- (void)rebuildFromPlaylist {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    // Detect if we're switching to a different playlist (vs. refreshing the same one)
    BOOL isFirstLoad = (_currentPlaylistIndex < 0);
    BOOL isSwitchingPlaylist = (activePlaylist != SIZE_MAX &&
                                 (isFirstLoad || (NSInteger)activePlaylist != _currentPlaylistIndex));

    // Save scroll anchor for BOTH playlist switches AND same-playlist refreshes
    // This prevents visual jumping when items are added/removed
    // IMPORTANT: Skip saving if a drag is in progress - drag can trigger playlist switches
    // when hovering over another playlist, and we don't want to save the mid-drag position
    if (!isFirstLoad && !_playlistView.isDragging) {
        // Only save when the viewport reflects the user's position (a restore
        // has run, or there was nothing to restore) - never overwrite a good
        // anchor with a pre-restore viewport.
        if (_scrollPositionEstablished) {
            NSDictionary *anchor = [self captureScrollAnchor];
            if (anchor) {
                _scrollAnchorIndices[@(_currentPlaylistIndex)] = anchor;
            }
        }
        // Persist group cache for the outgoing playlist (async) - gated
        // internally on complete group data, independent of the anchor gate.
        if (isSwitchingPlaylist && _currentPlaylistIndex >= 0) {
            [self saveGroupCacheForPlaylist:(t_size)_currentPlaylistIndex synchronous:NO];
        }
    }

    // Reset flags for the new playlist. The established flag survives
    // same-playlist refreshes: the viewport is untouched, so it still reflects
    // the user's position and anchors must keep being saved.
    if (isSwitchingPlaylist) {
        _scrollPositionEstablished = NO;
    }
    _currentPlaylistInitialized = NO;

    // Invalidate any in-progress async group detection from the previous playlist.
    // Without this, switching to an ungrouped/empty playlist (which doesn't start
    // its own detection) leaves the generation counter unchanged, allowing stale
    // callbacks to apply old group data to the new playlist's view.
    ++(*_groupDetectionGeneration);

    // Clear cached data on any playlist change (incremental invalidation is
    // tracked in BACKLOG.md)
    [_playlistView clearFormattedValuesCache];

    // Decoration index bindings and group badges are keyed by playlist
    // position/grouping and are stale after any rebuild.
    if (_decorationCoordinator) {
        [_decorationCoordinator noteIndexMappingChanged];
        _decorPreparedRange = NSMakeRange(NSNotFound, 0);
    }

    if (activePlaylist == SIZE_MAX) {
        _playlistView.itemCount = 0;
        [self clearGroupData];
        _currentPlaylistIndex = -1;
        _playlistView.sourcePlaylistIndex = -1;  // For drag validation
        [_playlistView reloadData];
        return;
    }

    _currentPlaylistIndex = activePlaylist;
    _playlistView.sourcePlaylistIndex = activePlaylist;  // For drag validation
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);

    // Cold start / first visit this session: seed the anchor from its own
    // persisted entry (independent of the group cache, so it exists for
    // ungrouped and over-limit playlists too). In-memory always wins.
    if (!_scrollAnchorIndices[@(activePlaylist)]) {
        NSDictionary *persistedAnchor = [self loadPersistedScrollAnchorForPlaylist:activePlaylist];
        if (persistedAnchor) {
            _scrollAnchorIndices[@(activePlaylist)] = persistedAnchor;
        }
    }

    if (itemCount == 0) {
        _playlistView.itemCount = 0;
        [self clearGroupData];
        [_playlistView reloadData];
        return;
    }

    // Check if grouping is enabled
    GroupPreset *activePreset = nil;
    if (_activePresetIndex >= 0 && _activePresetIndex < (NSInteger)_groupPresets.count) {
        activePreset = _groupPresets[_activePresetIndex];
    }

    BOOL useGrouping = (activePreset && activePreset.headerPattern.length > 0);

    if (useGrouping) {
        // Try loading cached group data first for instant rendering
        BOOL cacheHit = [self loadGroupCacheForPlaylist:activePlaylist itemCount:itemCount preset:activePreset];

        if (cacheHit) {
            // Cache loaded valid data - view is immediately usable
            _currentPlaylistInitialized = YES;
            [self recomputeGroupDurations];
            // Validate in background (won't clear current display)
            _scrollRestorePlaylistIndex = activePlaylist;
            [self detectGroupsForPlaylistBackground:activePlaylist itemCount:itemCount preset:activePreset];
        } else {
            // Cache miss - fall back to existing detection paths
            BOOL hasSavedPosition = (_scrollAnchorIndices[@(activePlaylist)] != nil);

            if (hasSavedPosition) {
                // SYNCHRONOUS: Detect groups immediately for instant scroll restore
                _scrollRestorePlaylistIndex = activePlaylist;
                [self detectGroupsForPlaylistSync:activePlaylist itemCount:itemCount preset:activePreset];
            } else {
                // ASYNC: First visit or no saved position - async is fine
                [self detectGroupsForPlaylist:activePlaylist itemCount:itemCount preset:activePreset];
            }
        }
    } else {
        // No grouping - just set item count
        _playlistView.itemCount = itemCount;
        [self clearGroupData];
    }

    // Set frame size
    CGFloat totalHeight = [_playlistView totalContentHeightCached];
    [_playlistView setFrameSize:NSMakeSize(_playlistView.frame.size.width, totalHeight)];

    // Sync selection
    [self syncSelectionFromPlaylist];

    // Set focus
    t_size focusItem = pm->playlist_get_focus_item(activePlaylist);
    _playlistView.focusIndex = (focusItem != SIZE_MAX) ? (NSInteger)focusItem : -1;

    // Update playing indicator
    [self updatePlayingIndicator];

    // Display
    [_playlistView reloadData];

    // Scroll restoration
    BOOL wantsPendingCenter = (_pendingCenterIndex >= 0 &&
                               _pendingCenterPlaylist == (NSInteger)activePlaylist);
    if (isSwitchingPlaylist) {
        if (useGrouping && (_scrollAnchorIndices[@(activePlaylist)] != nil || wantsPendingCenter)) {
            // Sync or cache-hit path set _scrollRestorePlaylistIndex above;
            // ensure it is set for the pending-center and async cases too.
            _scrollRestorePlaylistIndex = activePlaylist;
            [self scheduleDeferredScrollRestore];
        } else if (!useGrouping) {
            _scrollRestorePlaylistIndex = activePlaylist;
            [self scheduleDeferredScrollRestore];
        } else if (_currentPlaylistInitialized) {
            // Grouped, data already complete (cache hit), but no saved anchor:
            // nothing to restore - run the restore path anyway so the focus
            // fallback applies and the position is marked established.
            _scrollRestorePlaylistIndex = activePlaylist;
            [self scheduleDeferredScrollRestore];
        }
        // Async detection path with no anchor: position is marked established
        // when detection completes (detectGroupsForPlaylist:).
    }
    // When NOT switching (just refreshing same playlist), keep current scroll position
}

- (void)scheduleDeferredScrollRestore {
    // Use weak self to avoid retain cycles and crashes if controller is deallocated
    __weak SimPlaylistController *weakSelf = self;
    NSInteger targetPlaylist = _scrollRestorePlaylistIndex;

    // Defer to next run loop iteration to let layout settle
    dispatch_async(dispatch_get_main_queue(), ^{
        SimPlaylistController *strongSelf = weakSelf;
        if (!strongSelf) return;

        // Only restore if we're still on the same playlist and still need to restore
        if (strongSelf.scrollRestorePlaylistIndex != targetPlaylist) return;
        if (strongSelf.currentPlaylistIndex != targetPlaylist) return;

        [strongSelf performScrollRestore];
    });
}

- (void)performScrollRestore {
    if (_scrollRestorePlaylistIndex < 0) return;
    if (!_playlistView || !_scrollView || !_scrollAnchorIndices) {
        _scrollRestorePlaylistIndex = -1;
        return;
    }

    // "Focus playing now" navigation takes priority over anchor restore.
    if (_pendingCenterIndex >= 0) {
        NSInteger centerIndex = _pendingCenterIndex;
        BOOL forThisPlaylist = (_pendingCenterPlaylist == _currentPlaylistIndex);
        _pendingCenterIndex = -1;
        _pendingCenterPlaylist = -1;
        if (forThisPlaylist) {
            [self scrollPlaylistIndexToCenter:centerIndex];
            _scrollRestorePlaylistIndex = -1;
            _scrollPositionEstablished = YES;
            return;
        }
        // Stale pending center (user switched elsewhere first): discard and
        // fall through to the normal anchor restore.
    }

    NSDictionary *anchor = _scrollAnchorIndices[@(_scrollRestorePlaylistIndex)];
    if (anchor) {
        NSInteger playlistIndex = [anchor[kAnchorIndexKey] integerValue];
        CGFloat offset = [anchor[kAnchorOffsetKey] doubleValue];
        // Clamp to valid range (items may have been deleted after the anchor)
        if (playlistIndex >= _playlistView.itemCount) {
            playlistIndex = MAX(0, _playlistView.itemCount - 1);
            offset = 0;
        }
        [self scrollToPlaylistIndex:playlistIndex pixelOffset:offset];
    } else if (_playlistView.focusIndex >= 0) {
        // No saved position - center the focus item (first time viewing this playlist)
        [self scrollPlaylistIndexToCenter:_playlistView.focusIndex];
    }

    // Clear the restore marker; the viewport now reflects the user's position,
    // so it is safe to start saving anchors from it.
    _scrollRestorePlaylistIndex = -1;
    _scrollPositionEstablished = YES;
}

// Capture the current viewport position as a pixel-exact anchor: the first
// visible track's playlist index plus the pixel delta between the viewport top
// and that row's top. Returns nil when there is nothing to anchor to.
- (NSDictionary *)captureScrollAnchor {
    if (!_scrollView || !_playlistView) return nil;
    if (_playlistView.itemCount == 0) return nil;

    NSRect visibleRect = _scrollView.contentView.bounds;
    if (visibleRect.size.height <= 0) return nil;

    NSInteger firstRow = [_playlistView rowAtPoint:NSMakePoint(0, NSMinY(visibleRect))];
    if (firstRow < 0) firstRow = 0;

    NSInteger totalRows = [_playlistView rowCount];
    if (totalRows == 0) return nil;

    // Find the first row that corresponds to an actual playlist item. The
    // offset is negative when header/padding rows sit between the viewport top
    // and that track, so the restore reveals the same header block above it.
    // Bounded scan: header + subgroup + padding blocks between the viewport top
    // and the first real track never approach this many consecutive rows.
    static const NSInteger kAnchorScanRowLimit = 50;
    for (NSInteger row = firstRow; row < totalRows && row < firstRow + kAnchorScanRowLimit; row++) {
        NSInteger playlistIndex = [_playlistView playlistIndexForRow:row];
        if (playlistIndex >= 0) {
            CGFloat offset = NSMinY(visibleRect) - [_playlistView yOffsetForRow:row];
            return @{kAnchorIndexKey: @(playlistIndex), kAnchorOffsetKey: @(offset)};
        }
    }

    return nil;
}

#pragma mark - Scroll primitives

// Scroll so the given track's row top sits `offset` pixels below the viewport
// top (offset may be negative to reveal its group header above it).
- (void)scrollToPlaylistIndex:(NSInteger)playlistIndex pixelOffset:(CGFloat)offset {
    NSInteger row = [_playlistView rowForPlaylistIndex:playlistIndex];
    if (row < 0) return;
    [self scrollViewportToY:[_playlistView yOffsetForRow:row] + offset];
}

// Scroll so the given track's row is vertically centered in the viewport.
- (void)scrollPlaylistIndexToCenter:(NSInteger)playlistIndex {
    NSInteger row = [_playlistView rowForPlaylistIndex:playlistIndex];
    if (row < 0) return;
    NSRect rowRect = [_playlistView rectForRow:row];
    CGFloat viewportHeight = _scrollView.contentView.bounds.size.height;
    [self scrollViewportToY:NSMidY(rowRect) - viewportHeight / 2.0];
}

// Absolute, clamped vertical scroll. Unlike scrollRectToVisible (minimal
// scrolling, which lets a restored anchor land at the bottom edge), this
// positions the viewport top exactly.
- (void)scrollViewportToY:(CGFloat)y {
    NSClipView *clipView = _scrollView.contentView;
    CGFloat maxY = MAX(0.0, _playlistView.frame.size.height - clipView.bounds.size.height);
    CGFloat clampedY = MAX(0.0, MIN(y, maxY));
    [clipView scrollToPoint:NSMakePoint(clipView.bounds.origin.x, clampedY)];
    [_scrollView reflectScrolledClipView:clipView];
}

// Shared padding calculation for album art minimum group height
static NSInteger calculatePaddingForGroup(NSInteger trackCount, NSInteger subgroupsInGroup,
                                           CGFloat albumArtSize, CGFloat rowHeight,
                                           NSInteger headerStyle) {
    // Clamp albumArtSize to prevent overflow with extreme config values
    albumArtSize = MIN(MAX(albumArtSize, 0.0), 1000.0);
    CGFloat padding = 6.0;
    NSInteger minContentRows = (rowHeight > 0) ? (NSInteger)ceil((albumArtSize + padding * 2) / rowHeight) : 0;

    NSInteger minPadding = (headerStyle == 3) ? 1 : 0;
    NSInteger extraHeaderSpace = (headerStyle == 2) ? 1 : 0;
    NSInteger extraTextSpace = (headerStyle == 3) ? 1 : 0;

    return MAX(minPadding, minContentRows - trackCount - subgroupsInGroup - extraHeaderSpace + extraTextSpace);
}

// Drops the view back to an ungrouped flat list. The derived caches are rebuilt
// from the now-empty arrays rather than hand-cleared, which is what the rebuild
// methods do for empty input anyway. Callers own itemCount.
- (void)clearGroupData {
    _playlistView.groupStarts = @[];
    _playlistView.groupHeaders = @[];
    _playlistView.groupArtKeys = @[];
    _playlistView.groupPaddingRows = @[];
    _playlistView.subgroupStarts = @[];
    _playlistView.subgroupHeaders = @[];
    _playlistView.subgroupCountPerGroup = @[];
    [_playlistView rebuildPaddingCache];
    [_playlistView rebuildSubgroupRowCache];
}

// Single entry point for handing a complete set of group arrays to the view.
// The order here is load-bearing and was previously duplicated at five call
// sites: subgroup counts must exist before the padding math reads them, the
// padding cache must exist before the subgroup row cache, and the frame height
// depends on both.
//
// lastGroupEnd is the end index of the final group — the sync path passes its
// partial detection limit, every other path passes the playlist item count.
// updateFrameSize is NO for the cache-apply path, whose caller sizes the view
// itself once the rest of the restore completes.
- (void)applyGroupData:(NSArray<NSNumber *> *)groupStarts
               headers:(NSArray<NSString *> *)groupHeaders
               artKeys:(NSArray<NSString *> *)groupArtKeys
        subgroupStarts:(NSArray<NSNumber *> *)subgroupStarts
       subgroupHeaders:(NSArray<NSString *> *)subgroupHeaders
          lastGroupEnd:(NSInteger)lastGroupEnd
       updateFrameSize:(BOOL)updateFrameSize {
    _playlistView.groupStarts = groupStarts;
    _playlistView.groupHeaders = groupHeaders;
    _playlistView.groupArtKeys = groupArtKeys;
    _playlistView.subgroupStarts = subgroupStarts ?: @[];
    _playlistView.subgroupHeaders = subgroupHeaders ?: @[];
    [self updateSubgroupCountPerGroup];
    [self filterSingleSubgroupsIfNeeded];

    CGFloat rowHeight = _playlistView.rowHeight;
    CGFloat albumArtSize = _playlistView.albumArtSize;
    NSInteger headerStyle = _playlistView.headerDisplayStyle;

    NSMutableArray<NSNumber *> *paddingRows = [NSMutableArray arrayWithCapacity:groupStarts.count];
    for (NSUInteger g = 0; g < groupStarts.count; g++) {
        NSInteger groupStart = [groupStarts[g] integerValue];
        NSInteger groupEnd = (g + 1 < groupStarts.count) ? [groupStarts[g + 1] integerValue] : lastGroupEnd;
        NSInteger trackCount = groupEnd - groupStart;
        NSInteger subgroupsInGroup = (g < _playlistView.subgroupCountPerGroup.count)
            ? [_playlistView.subgroupCountPerGroup[g] integerValue] : 0;
        [paddingRows addObject:@(calculatePaddingForGroup(trackCount, subgroupsInGroup,
                                                          albumArtSize, rowHeight, headerStyle))];
    }
    _playlistView.groupPaddingRows = paddingRows;
    [_playlistView rebuildPaddingCache];
    [_playlistView rebuildSubgroupRowCache];

    if (updateFrameSize) {
        CGFloat newHeight = [_playlistView totalContentHeightCached];
        [_playlistView setFrameSize:NSMakeSize(_playlistView.frame.size.width, newHeight)];
    }
}

// FAST PARTIAL GROUP DETECTION: Only detect groups up to scroll anchor for instant restore
- (void)detectGroupsForPlaylistSync:(t_size)playlist itemCount:(t_size)itemCount preset:(GroupPreset *)preset {
    // Get the anchor position we need to scroll to
    NSDictionary *anchor = _scrollAnchorIndices[@(playlist)];
    NSInteger anchorIndex = anchor ? [anchor[kAnchorIndexKey] integerValue] : 0;

    // Only detect groups up to anchor + buffer (for visible area)
    // Cap at 5000 to prevent main thread blocking for deep scroll positions
    static const t_size kMaxSyncDetect = 5000;
    // Buffer past the anchor so the visible area below it is fully grouped
    static const t_size kSyncDetectAnchorBuffer = 200;
    t_size detectUpTo = MIN(itemCount, MIN((t_size)anchorIndex + kSyncDetectAnchorBuffer, kMaxSyncDetect));

    // Increment generation to cancel any in-progress async detection
    auto generationCounter = _groupDetectionGeneration;
    NSInteger currentGeneration = ++(*generationCounter);

    // Fetch all handles: the sync pass below only walks [0, detectUpTo), but
    // the background continuation started at the end of this method consumes
    // the rest of the list.
    auto pm = playlist_manager::get();
    metadb_handle_list handles;
    pm->playlist_get_all_items(playlist, handles);

    // Compile header pattern
    titleformat_object::ptr headerScript =
        simplaylist::TitleFormatHelper::compileWithFallback([preset.headerPattern UTF8String], nullptr);

    // Compile subgroup pattern (if any)
    NSString *subgroupPattern = [preset subgroupPattern];
    titleformat_object::ptr subgroupScript;
    BOOL hasSubgroups = (subgroupPattern && subgroupPattern.length > 0);
    if (hasSubgroups) {
        subgroupScript = simplaylist::TitleFormatHelper::compileWithFallback([subgroupPattern UTF8String], nullptr);
    }

    // Build group data synchronously - only up to detectUpTo
    NSMutableArray<NSNumber *> *groupStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *groupHeaders = [NSMutableArray array];
    NSMutableArray<NSString *> *groupArtKeys = [NSMutableArray array];

    // Build subgroup data
    NSMutableArray<NSNumber *> *subgroupStarts = [NSMutableArray array];
    NSMutableArray<NSString *> *subgroupHeaders = [NSMutableArray array];

    // Check if we should show the first subgroup header for each group
    bool showFirstSubgroup = simplaylist_config::getConfigBool(
        simplaylist_config::kShowFirstSubgroupHeader,
        simplaylist_config::kDefaultShowFirstSubgroupHeader);

    // Use shared SubgroupDetector to ensure consistent logic across all code paths
    SubgroupDetector subgroupDetector(showFirstSubgroup, g_subgroupDebugEnabled);

    std::string currentHeader;
    pfc::string8 formattedHeader;
    pfc::string8 formattedSubgroup;

    simplaylist::GroupBuildCallbacks buildCb;
    buildCb.formatHeader = [&](size_t i) {
        handles[i]->format_title(nullptr, formattedHeader, headerScript, nullptr);
        return formattedHeader.c_str();
    };
    if (hasSubgroups) {
        buildCb.formatSubgroup = [&](size_t i) {
            handles[i]->format_title(nullptr, formattedSubgroup, subgroupScript, nullptr);
            return formattedSubgroup.c_str();
        };
    }
    buildCb.artKey = [&](size_t i) { return handles[i]->get_path(); };

    simplaylist::buildGroups(0, MIN((size_t)detectUpTo, (size_t)handles.get_count()),
                             hasSubgroups, /* forceFirstNewGroup */ true,
                             currentHeader, subgroupDetector, buildCb,
                             groupStarts, groupHeaders, groupArtKeys,
                             subgroupStarts, subgroupHeaders);

    // Set partial data immediately - enough for visible area. The last group
    // ends at detectUpTo, not itemCount: the rest is still undetected.
    // Frame size gets updated again when full detection completes.
    _playlistView.itemCount = itemCount;
    [self applyGroupData:groupStarts
                 headers:groupHeaders
                 artKeys:groupArtKeys
          subgroupStarts:subgroupStarts
         subgroupHeaders:subgroupHeaders
            lastGroupEnd:(NSInteger)detectUpTo
         updateFrameSize:YES];

    // Restore scroll position immediately (we have enough groups)
    [self performScrollRestore];

    // handles is still owned here (moved into handlesPtr below), so reuse it
    // instead of refetching the same list.
    [self recomputeGroupDurationsWithHandles:handles];
    [_playlistView setNeedsDisplay:YES];

    // Continue detecting remaining groups in background
    if (detectUpTo < itemCount) {
        auto handlesPtr = std::make_shared<metadb_handle_list>(std::move(handles));
        NSString *headerPattern = preset.headerPattern;
        NSString *lastHeader = (groupHeaders.count > 0) ? [groupHeaders lastObject] : @"";
        // IMPORTANT: Use the actual subgroup state from detector, not subgroupHeaders.lastObject
        // because if showFirstSubgroup=OFF, the first subgroup wasn't added to the list.
        // Kept as std::string: the NSString round-trip yielded nil for invalid
        // UTF-8, which silently reset the continuation state at the seam.
        std::string lastSubgroup(subgroupDetector.getCurrentSubgroup());

        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (*generationCounter != currentGeneration) return;

            // Continue from where we left off
            NSMutableArray<NSNumber *> *moreGroupStarts = [NSMutableArray array];
            NSMutableArray<NSString *> *moreGroupHeaders = [NSMutableArray array];
            NSMutableArray<NSString *> *moreGroupArtKeys = [NSMutableArray array];
            NSMutableArray<NSNumber *> *moreSubgroupStarts = [NSMutableArray array];
            NSMutableArray<NSString *> *moreSubgroupHeaders = [NSMutableArray array];

            std::string bgCurrentHeader([lastHeader UTF8String]);
            pfc::string8 bgFormattedHeader;
            pfc::string8 bgFormattedSubgroup;

            titleformat_object::ptr bgHeaderScript =
                simplaylist::TitleFormatHelper::compileWithFallback([headerPattern UTF8String], nullptr);

            titleformat_object::ptr bgSubgroupScript;
            if (hasSubgroups) {
                bgSubgroupScript = simplaylist::TitleFormatHelper::compileWithFallback([subgroupPattern UTF8String], nullptr);
            }

            // Read showFirstSubgroup setting for consistent behavior with initial detection
            bool bgShowFirstSubgroup = simplaylist_config::getConfigBool(
                simplaylist_config::kShowFirstSubgroupHeader,
                simplaylist_config::kDefaultShowFirstSubgroupHeader);

            // Use shared SubgroupDetector - initialized from sync portion's final state
            SubgroupDetector bgSubgroupDetector(bgShowFirstSubgroup, g_subgroupDebugEnabled);
            bgSubgroupDetector.initFromState(lastSubgroup.c_str());

            // Continuation: no forced first group (the seam is only a group
            // boundary if the header actually changes from the sync portion).
            simplaylist::GroupBuildCallbacks buildCb;
            buildCb.formatHeader = [&](size_t i) {
                (*handlesPtr)[i]->format_title(nullptr, bgFormattedHeader, bgHeaderScript, nullptr);
                return bgFormattedHeader.c_str();
            };
            if (hasSubgroups) {
                buildCb.formatSubgroup = [&](size_t i) {
                    (*handlesPtr)[i]->format_title(nullptr, bgFormattedSubgroup, bgSubgroupScript, nullptr);
                    return bgFormattedSubgroup.c_str();
                };
            }
            buildCb.artKey = [&](size_t i) { return (*handlesPtr)[i]->get_path(); };
            buildCb.isCancelled = [&]() { return *generationCounter != currentGeneration; };

            if (!simplaylist::buildGroups(detectUpTo, handlesPtr->get_count(),
                                          hasSubgroups, /* forceFirstNewGroup */ false,
                                          bgCurrentHeader, bgSubgroupDetector, buildCb,
                                          moreGroupStarts, moreGroupHeaders, moreGroupArtKeys,
                                          moreSubgroupStarts, moreSubgroupHeaders)) {
                return;
            }

            if (*generationCounter != currentGeneration) return;

            // Merge results on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                if (*generationCounter != currentGeneration) return;

                // Save scroll anchor BEFORE merging groups (new groups shift items)
                NSDictionary *mergeAnchor = [strongSelf captureScrollAnchor];

                // Merge with existing groups
                NSMutableArray *allStarts = [strongSelf.playlistView.groupStarts mutableCopy];
                NSMutableArray *allHeaders = [strongSelf.playlistView.groupHeaders mutableCopy];
                NSMutableArray *allArtKeys = [strongSelf.playlistView.groupArtKeys mutableCopy];

                [allStarts addObjectsFromArray:moreGroupStarts];
                [allHeaders addObjectsFromArray:moreGroupHeaders];
                [allArtKeys addObjectsFromArray:moreGroupArtKeys];

                // Merge subgroups
                NSMutableArray *allSubgroupStarts = [strongSelf.playlistView.subgroupStarts mutableCopy];
                NSMutableArray *allSubgroupHeaders = [strongSelf.playlistView.subgroupHeaders mutableCopy];
                [allSubgroupStarts addObjectsFromArray:moreSubgroupStarts];
                [allSubgroupHeaders addObjectsFromArray:moreSubgroupHeaders];

                // Whole list is detected now, so the last group ends at itemCount.
                [strongSelf applyGroupData:allStarts
                                   headers:allHeaders
                                   artKeys:allArtKeys
                            subgroupStarts:allSubgroupStarts
                           subgroupHeaders:allSubgroupHeaders
                              lastGroupEnd:(NSInteger)itemCount
                           updateFrameSize:YES];

                // Restore scroll position pixel-exactly (new groups shifted items down)
                if (mergeAnchor) {
                    [strongSelf scrollToPlaylistIndex:[mergeAnchor[kAnchorIndexKey] integerValue]
                                          pixelOffset:[mergeAnchor[kAnchorOffsetKey] doubleValue]];
                }

                // NOW it's safe to save scroll positions - full data available
                strongSelf->_currentPlaylistInitialized = YES;

                // Persist group cache after full detection
                [strongSelf saveGroupCacheForPlaylist:playlist synchronous:NO];

                [strongSelf recomputeGroupDurations];
                [strongSelf.playlistView reloadData];
            });
        });
    } else {
        // No background detection needed - full data already available.
        // Durations were already recomputed above from the same group arrays.
        _currentPlaylistInitialized = YES;
        // Persist group cache
        [self saveGroupCacheForPlaylist:playlist synchronous:NO];
    }
}

// PROGRESSIVE GROUP DETECTION: Shows UI immediately, detects groups without freezing
- (void)detectGroupsForPlaylist:(t_size)playlist itemCount:(t_size)itemCount preset:(GroupPreset *)preset {
    // Increment generation to cancel any in-progress detection
    auto generationCounter = _groupDetectionGeneration;
    NSInteger currentGeneration = ++(*generationCounter);

    // IMMEDIATE: Set item count and show flat list right away
    _playlistView.itemCount = itemCount;
    [self clearGroupData];

    // Set frame size and display immediately
    CGFloat totalHeight = [_playlistView totalContentHeightCached];
    [_playlistView setFrameSize:NSMakeSize(_playlistView.frame.size.width, totalHeight)];
    [_playlistView setNeedsDisplay:YES];

    // Get all handles NOW (on main thread, this is fast as it's just pointer copies)
    auto pm = playlist_manager::get();
    metadb_handle_list handles;
    pm->playlist_get_all_items(playlist, handles);

    // Copy handles to a shared_ptr for thread safety
    auto handlesPtr = std::make_shared<metadb_handle_list>(std::move(handles));
    NSString *headerPattern = preset.headerPattern;
    NSString *subgroupPattern = [preset subgroupPattern];  // Get first subgroup pattern

    // PROGRESSIVE: Detect groups in background without blocking UI
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (*generationCounter != currentGeneration) return;

        // Compile header pattern
        titleformat_object::ptr headerScript =
            simplaylist::TitleFormatHelper::compileWithFallback([headerPattern UTF8String], nullptr);

        // Compile subgroup pattern (if any)
        titleformat_object::ptr subgroupScript;
        BOOL hasSubgroups = (subgroupPattern && subgroupPattern.length > 0);
        if (hasSubgroups) {
            subgroupScript = simplaylist::TitleFormatHelper::compileWithFallback([subgroupPattern UTF8String], nullptr);
        }

        // Build group data
        NSMutableArray<NSNumber *> *groupStarts = [NSMutableArray array];
        NSMutableArray<NSString *> *groupHeaders = [NSMutableArray array];
        NSMutableArray<NSString *> *groupArtKeys = [NSMutableArray array];

        // Build subgroup data
        NSMutableArray<NSNumber *> *subgroupStarts = [NSMutableArray array];
        NSMutableArray<NSString *> *subgroupHeaders = [NSMutableArray array];

        // Check if we should show the first subgroup header for each group
        bool showFirstSubgroup = simplaylist_config::getConfigBool(
            simplaylist_config::kShowFirstSubgroupHeader,
            simplaylist_config::kDefaultShowFirstSubgroupHeader);

        // Use shared SubgroupDetector to ensure consistent logic across all code paths
        SubgroupDetector subgroupDetector(showFirstSubgroup, g_subgroupDebugEnabled);

        // format_title with metadb_handle is thread-safe for reading
        std::string currentHeader;
        pfc::string8 formattedHeader;
        pfc::string8 formattedSubgroup;

        simplaylist::GroupBuildCallbacks buildCb;
        buildCb.formatHeader = [&](size_t i) {
            (*handlesPtr)[i]->format_title(nullptr, formattedHeader, headerScript, nullptr);
            return formattedHeader.c_str();
        };
        if (hasSubgroups) {
            buildCb.formatSubgroup = [&](size_t i) {
                (*handlesPtr)[i]->format_title(nullptr, formattedSubgroup, subgroupScript, nullptr);
                return formattedSubgroup.c_str();
            };
        }
        buildCb.artKey = [&](size_t i) { return (*handlesPtr)[i]->get_path(); };
        buildCb.isCancelled = [&]() { return *generationCounter != currentGeneration; };

        if (!simplaylist::buildGroups(0, handlesPtr->get_count(),
                                      hasSubgroups, /* forceFirstNewGroup */ true,
                                      currentHeader, subgroupDetector, buildCb,
                                      groupStarts, groupHeaders, groupArtKeys,
                                      subgroupStarts, subgroupHeaders)) {
            return;
        }

        if (*generationCounter != currentGeneration) return;

        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (*generationCounter != currentGeneration) return;

            // The captured itemCount is the count these groups were detected
            // against; reading it back off the view could pick up a newer one.
            [strongSelf applyGroupData:groupStarts
                               headers:groupHeaders
                               artKeys:groupArtKeys
                        subgroupStarts:subgroupStarts
                       subgroupHeaders:subgroupHeaders
                          lastGroupEnd:(NSInteger)itemCount
                       updateFrameSize:YES];

            // Full detection complete - safe to save scroll positions now
            strongSelf->_currentPlaylistInitialized = YES;

            // Persist group cache after full detection
            [strongSelf saveGroupCacheForPlaylist:playlist synchronous:NO];

            // Schedule scroll restore after frame size change settles
            if (strongSelf->_scrollRestorePlaylistIndex >= 0) {
                [strongSelf scheduleDeferredScrollRestore];
            } else {
                // First visit, nothing to restore: the viewport (top, or
                // wherever the user scrolled during detection) IS the
                // position - start saving anchors from it.
                strongSelf->_scrollPositionEstablished = YES;
            }

            [strongSelf recomputeGroupDurations];
            [strongSelf.playlistView reloadData];
        });
    });
}

// =============================================================================
// GROUP CACHE PERSISTENCE
// =============================================================================

// Build the preset hash string for cache validation: "headerPattern|subgroupPattern"
static NSString *presetHashForPreset(GroupPreset *preset) {
    NSString *sub = [preset subgroupPattern] ?: @"";
    return [NSString stringWithFormat:@"%@|%@", preset.headerPattern, sub];
}

// Maximum group count for caching. configStore is designed for small config
// values, not megabytes of serialized data. Large playlists fall back to
// background detection which is fast enough.
static const NSUInteger kMaxCacheableGroups = 500;

// Scroll anchors persist SEPARATELY from the group cache (tiny per-playlist
// entries) so positions survive restarts for every playlist - including
// ungrouped ones and those over kMaxCacheableGroups, whose group cache is
// never written (and any stale entry is actively deleted).
static std::string scrollAnchorKeyForName(const char *playlistName) {
    return std::string("scroll_anchor.") + simplaylist_config::sanitizePlaylistName(playlistName);
}

- (void)persistScrollAnchor:(NSDictionary *)anchor forPlaylistName:(const char *)playlistName {
    NSString *json = [NSString stringWithFormat:@"{\"index\":%ld,\"offset\":%.1f}",
                      (long)[anchor[kAnchorIndexKey] integerValue],
                      [anchor[kAnchorOffsetKey] doubleValue]];
    simplaylist_config::setConfigString(scrollAnchorKeyForName(playlistName).c_str(), json.UTF8String);
}

- (NSDictionary *)loadPersistedScrollAnchorForPlaylist:(t_size)playlist {
    auto pm = playlist_manager::get();
    if (playlist >= pm->get_playlist_count()) return nil;
    pfc::string8 nameStr;
    pm->playlist_get_name(playlist, nameStr);
    std::string json = simplaylist_config::getConfigString(
        scrollAnchorKeyForName(nameStr.c_str()).c_str(), "");
    if (json.empty()) return nil;

    NSData *data = [[NSString stringWithUTF8String:json.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return nil;
    NSNumber *index = parsed[kAnchorIndexKey];
    if (![index isKindOfClass:[NSNumber class]] || [index integerValue] < 0) return nil;
    NSNumber *offset = parsed[kAnchorOffsetKey];
    if (![offset isKindOfClass:[NSNumber class]]) offset = @0;
    return @{kAnchorIndexKey: index, kAnchorOffsetKey: offset};
}

- (void)saveGroupCacheForPlaylist:(t_size)playlist synchronous:(BOOL)synchronous {
    // Get playlist name
    auto pm = playlist_manager::get();
    if (playlist >= pm->get_playlist_count()) return;
    pfc::string8 nameStr;
    pm->playlist_get_name(playlist, nameStr);
    NSString *cacheKeyNS = [NSString stringWithUTF8String:
        simplaylist_config::groupCacheKey(nameStr.c_str()).c_str()];

    // Persist the scroll anchor FIRST, independent of group-cache eligibility,
    // so positions survive restarts for ungrouped and over-limit playlists too.
    // For the playlist currently on screen the LIVE viewport wins over the
    // stored anchor - the stored one dates from the last switch-away and would
    // silently drop any scrolling done since (the "gap after restart" bug).
    NSDictionary *anchor = nil;
    if (playlist == (t_size)_currentPlaylistIndex && _scrollPositionEstablished) {
        anchor = [self captureScrollAnchor];
    }
    if (!anchor) {
        anchor = _scrollAnchorIndices[@(playlist)];
    }
    if (anchor) {
        [self persistScrollAnchor:anchor forPlaylistName:nameStr.c_str()];
    }

    if (!_currentPlaylistInitialized) return;
    if (_playlistView.groupStarts.count == 0) return;

    if (_playlistView.groupStarts.count > kMaxCacheableGroups) {
        // Not cacheable - and any EXISTING entry for this playlist is
        // unrefreshable (this guard blocks every re-save), so a stale entry
        // would be applied on every switch-in forever: the restore then runs
        // against the wrong layout and the background validation used to
        // corrupt the scroll anchor. Actively remove it.
        simplaylist_config::setConfigString([cacheKeyNS UTF8String], "");
        return;
    }

    // Capture snapshot on main thread
    NSArray<NSNumber *> *groupStarts = [_playlistView.groupStarts copy];
    NSArray<NSString *> *groupHeaders = [_playlistView.groupHeaders copy];
    NSArray<NSNumber *> *subgroupStarts = [_playlistView.subgroupStarts copy];
    NSArray<NSString *> *subgroupHeaders = [_playlistView.subgroupHeaders copy];
    NSInteger itemCount = _playlistView.itemCount;

    // Legacy cache fields, kept for older builds reading this entry. The
    // authoritative anchor is the separate scroll_anchor.<name> entry above.
    NSInteger scrollAnchor = anchor ? [anchor[kAnchorIndexKey] integerValue] : -1;
    double scrollOffset = anchor ? [anchor[kAnchorOffsetKey] doubleValue] : 0;

    // Get current preset hash
    GroupPreset *activePreset = nil;
    if (_activePresetIndex >= 0 && _activePresetIndex < (NSInteger)_groupPresets.count) {
        activePreset = _groupPresets[_activePresetIndex];
    }
    NSString *presetHash = activePreset ? presetHashForPreset(activePreset) : @"";

    // Serialize and write
    auto doSave = ^{
        @autoreleasepool {
            NSMutableDictionary *cache = [NSMutableDictionary dictionary];
            cache[@"v"] = @(1);
            cache[@"itemCount"] = @(itemCount);
            cache[@"presetHash"] = presetHash;
            cache[@"scrollAnchor"] = @(scrollAnchor);
            cache[@"scrollOffset"] = @(scrollOffset);
            cache[@"groupStarts"] = groupStarts;
            cache[@"groupHeaders"] = groupHeaders;
            // groupArtKeys intentionally omitted — they contain full file paths
            // which can be megabytes for large playlists. The view only checks
            // groupArtKeys.count; actual art paths come from track handles.
            cache[@"groupCount"] = @(groupStarts.count);
            cache[@"subgroupStarts"] = subgroupStarts;
            cache[@"subgroupHeaders"] = subgroupHeaders;

            NSError *error = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:cache options:0 error:&error];
            if (!jsonData) return;

            NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            if (!jsonString) return;

            simplaylist_config::setConfigString([cacheKeyNS UTF8String], [jsonString UTF8String]);
        }
    };

    if (synchronous) {
        doSave();
    } else {
        // Serial queue so rapid saves persist in submission order; the
        // concurrent global queue could write an older cache last.
        static dispatch_queue_t sSaveQueue;
        static dispatch_once_t sOnce;
        dispatch_once(&sOnce, ^{
            sSaveQueue = dispatch_queue_create("simplaylist.groupcache.save",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        });
        dispatch_async(sSaveQueue, doSave);
    }
}

- (void)saveGroupCacheForCurrentPlaylist {
    if (_currentPlaylistIndex < 0) return;
    [self saveGroupCacheForPlaylist:(t_size)_currentPlaylistIndex synchronous:YES];
}

// Validation for persisted cache arrays: a corrupted/hand-edited config entry
// must fail the load (falling back to fresh detection), not crash on playlist
// switch-in — that would be a crash loop at every startup.
static BOOL validCachedIndexArray(NSArray *arr, t_size itemCount) {
    NSInteger prev = -1;
    for (id v in arr) {
        if (![v isKindOfClass:[NSNumber class]]) return NO;
        NSInteger x = [v integerValue];
        if (x < 0 || x >= (NSInteger)itemCount || x <= prev) return NO;
        prev = x;
    }
    return YES;
}

static BOOL validCachedStringArray(NSArray *arr) {
    for (id v in arr) {
        if (![v isKindOfClass:[NSString class]]) return NO;
    }
    return YES;
}

- (BOOL)loadGroupCacheForPlaylist:(t_size)playlist itemCount:(t_size)itemCount preset:(GroupPreset *)preset {
    // Get playlist name and load cache JSON
    auto pm = playlist_manager::get();
    if (playlist >= pm->get_playlist_count()) return NO;
    pfc::string8 nameStr;
    pm->playlist_get_name(playlist, nameStr);
    std::string cacheKey = simplaylist_config::groupCacheKey(nameStr.c_str());

    std::string jsonStr = simplaylist_config::getConfigString(cacheKey.c_str(), "");
    if (jsonStr.empty()) return NO;

    // Parse JSON
    NSData *jsonData = [[NSString stringWithUTF8String:jsonStr.c_str()] dataUsingEncoding:NSUTF8StringEncoding];
    if (!jsonData) return NO;

    // A top-level JSON array parses fine and is NOT a dictionary; subscripting
    // it below would raise. A config entry corrupted to "[]" must fail the load,
    // not crash on every playlist switch-in.
    NSError *error = nil;
    id root = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if (error || ![root isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *cache = root;

    // Validate schema version. JSON can put an array/dictionary/null in any of
    // these three fields; NSArray does not respond to integerValue and neither
    // NSNumber nor NSArray responds to isEqualToString:, so an unguarded read
    // is an unrecognised selector on every playlist switch-in.
    NSNumber *version = cache[@"v"];
    if (![version isKindOfClass:[NSNumber class]] || [version integerValue] != 1) return NO;

    // Validate item count
    NSNumber *cachedItemCount = cache[@"itemCount"];
    if (![cachedItemCount isKindOfClass:[NSNumber class]] ||
        [cachedItemCount integerValue] != (NSInteger)itemCount) return NO;

    // Validate preset hash
    NSString *cachedPresetHash = cache[@"presetHash"];
    NSString *currentPresetHash = presetHashForPreset(preset);
    if (![cachedPresetHash isKindOfClass:[NSString class]] ||
        ![cachedPresetHash isEqualToString:currentPresetHash]) return NO;

    // Extract arrays
    NSArray *groupStarts = cache[@"groupStarts"];
    NSArray *groupHeaders = cache[@"groupHeaders"];
    NSArray *subgroupStarts = cache[@"subgroupStarts"];
    NSArray *subgroupHeaders = cache[@"subgroupHeaders"];
    NSNumber *scrollAnchor = cache[@"scrollAnchor"];
    NSNumber *scrollOffset = cache[@"scrollOffset"];  // may be nil in older caches

    if (![groupStarts isKindOfClass:[NSArray class]] ||
        ![groupHeaders isKindOfClass:[NSArray class]]) return NO;
    if (groupStarts.count != groupHeaders.count) return NO;
    if (groupStarts.count == 0) return NO;
    if (subgroupStarts && ![subgroupStarts isKindOfClass:[NSArray class]]) return NO;
    if (subgroupHeaders && ![subgroupHeaders isKindOfClass:[NSArray class]]) return NO;
    if (subgroupStarts.count != subgroupHeaders.count) return NO;
    if (!validCachedIndexArray(groupStarts, itemCount) ||
        !validCachedStringArray(groupHeaders)) return NO;
    // PlaylistLayoutModel requires the first group to start at 0 (see the
    // preconditions in PlaylistLayoutModel.h): a cache claiming otherwise makes
    // playlistIndexForRow: return wrong negative indices for the leading tracks.
    if ([groupStarts.firstObject integerValue] != 0) return NO;
    if (subgroupStarts &&
        (!validCachedIndexArray(subgroupStarts, itemCount) ||
         !validCachedStringArray(subgroupHeaders))) return NO;
    if (scrollAnchor && ![scrollAnchor isKindOfClass:[NSNumber class]]) scrollAnchor = nil;
    if (scrollOffset && ![scrollOffset isKindOfClass:[NSNumber class]]) scrollOffset = nil;

    // Generate placeholder art keys — the view only checks count, not values.
    // Actual art paths are resolved from track handles by the delegate.
    NSMutableArray<NSString *> *groupArtKeys = [NSMutableArray arrayWithCapacity:groupStarts.count];
    for (NSUInteger i = 0; i < groupStarts.count; i++) {
        [groupArtKeys addObject:@""];
    }

    // Apply cached data to view. Padding is recomputed from current display
    // settings rather than restored — it depends on runtime layout, not the
    // cache. Frame sizing is left to the caller, which sizes the view once the
    // rest of the restore completes.
    _playlistView.itemCount = itemCount;
    [self applyGroupData:groupStarts
                 headers:groupHeaders
                 artKeys:groupArtKeys
          subgroupStarts:subgroupStarts
         subgroupHeaders:subgroupHeaders
            lastGroupEnd:(NSInteger)itemCount
         updateFrameSize:NO];

    // Seed the scroll anchor from the persisted cache ONLY when this session
    // has none yet (cold start). The in-memory anchor is always fresher than
    // the persisted one - the cache write is async and can lose an A-B-A race.
    if (!_scrollAnchorIndices[@(playlist)] && scrollAnchor && [scrollAnchor integerValue] >= 0) {
        _scrollAnchorIndices[@(playlist)] = @{kAnchorIndexKey: scrollAnchor,
                                              kAnchorOffsetKey: scrollOffset ?: @0};
    }

    return YES;
}

// Background re-detection that validates cached groups without clearing the current display.
// If results differ from what's currently shown, applies the new data + reloads.
- (void)detectGroupsForPlaylistBackground:(t_size)playlist itemCount:(t_size)itemCount preset:(GroupPreset *)preset {
    auto generationCounter = _groupDetectionGeneration;
    NSInteger currentGeneration = ++(*generationCounter);

    // Get all handles on main thread
    auto pm = playlist_manager::get();
    metadb_handle_list handles;
    pm->playlist_get_all_items(playlist, handles);

    auto handlesPtr = std::make_shared<metadb_handle_list>(std::move(handles));
    NSString *headerPattern = preset.headerPattern;
    NSString *subgroupPattern = [preset subgroupPattern];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (*generationCounter != currentGeneration) return;

        // Compile patterns
        titleformat_object::ptr headerScript =
            simplaylist::TitleFormatHelper::compileWithFallback([headerPattern UTF8String], nullptr);

        titleformat_object::ptr subgroupScript;
        BOOL hasSubgroups = (subgroupPattern && subgroupPattern.length > 0);
        if (hasSubgroups) {
            subgroupScript = simplaylist::TitleFormatHelper::compileWithFallback(
                [subgroupPattern UTF8String], nullptr);
        }

        // Detect groups
        NSMutableArray<NSNumber *> *groupStarts = [NSMutableArray array];
        NSMutableArray<NSString *> *groupHeaders = [NSMutableArray array];
        NSMutableArray<NSString *> *groupArtKeys = [NSMutableArray array];
        NSMutableArray<NSNumber *> *subgroupStarts = [NSMutableArray array];
        NSMutableArray<NSString *> *subgroupHeaders = [NSMutableArray array];

        bool showFirstSubgroup = simplaylist_config::getConfigBool(
            simplaylist_config::kShowFirstSubgroupHeader,
            simplaylist_config::kDefaultShowFirstSubgroupHeader);
        SubgroupDetector subgroupDetector(showFirstSubgroup, g_subgroupDebugEnabled);

        std::string currentHeader;
        pfc::string8 formattedHeader;
        pfc::string8 formattedSubgroup;

        simplaylist::GroupBuildCallbacks buildCb;
        buildCb.formatHeader = [&](size_t i) {
            (*handlesPtr)[i]->format_title(nullptr, formattedHeader, headerScript, nullptr);
            return formattedHeader.c_str();
        };
        if (hasSubgroups) {
            buildCb.formatSubgroup = [&](size_t i) {
                (*handlesPtr)[i]->format_title(nullptr, formattedSubgroup, subgroupScript, nullptr);
                return formattedSubgroup.c_str();
            };
        }
        buildCb.artKey = [&](size_t i) { return (*handlesPtr)[i]->get_path(); };
        buildCb.isCancelled = [&]() { return *generationCounter != currentGeneration; };

        if (!simplaylist::buildGroups(0, handlesPtr->get_count(),
                                      hasSubgroups, /* forceFirstNewGroup */ true,
                                      currentHeader, subgroupDetector, buildCb,
                                      groupStarts, groupHeaders, groupArtKeys,
                                      subgroupStarts, subgroupHeaders)) {
            return;
        }

        if (*generationCounter != currentGeneration) return;

        // Compare with current cached data on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (*generationCounter != currentGeneration) return;

            // Check if groups changed. groupArtKeys are deliberately EXCLUDED:
            // after a cache load the view holds placeholder art keys (paths are
            // not persisted), so comparing them against freshly detected paths
            // would flag "changed" on every cache hit and force a pointless
            // reapply - which used to shift the viewport (no re-anchor) and
            // corrupt the saved scroll anchor on the way out.
            BOOL groupsChanged = ![groupStarts isEqualToArray:strongSelf.playlistView.groupStarts] ||
                                 ![groupHeaders isEqualToArray:strongSelf.playlistView.groupHeaders];
            BOOL subgroupsChanged = ![subgroupStarts isEqualToArray:strongSelf.playlistView.subgroupStarts] ||
                                    ![subgroupHeaders isEqualToArray:strongSelf.playlistView.subgroupHeaders];

            BOOL dataChanged = (groupsChanged || subgroupsChanged);
            strongSelf->_currentPlaylistInitialized = YES;

            if (dataChanged) {
                // Data changed (e.g. stale cache entry was applied on switch-in).
                // Capture the viewport position against the OLD layout first so
                // it can be re-established pixel-exactly in the new one.
                NSDictionary *applyAnchor = [strongSelf captureScrollAnchor];

                [strongSelf applyGroupData:groupStarts
                                   headers:groupHeaders
                                   artKeys:groupArtKeys
                            subgroupStarts:subgroupStarts
                           subgroupHeaders:subgroupHeaders
                              lastGroupEnd:(NSInteger)itemCount
                           updateFrameSize:YES];

                // Re-establish the viewport position in the corrected layout
                if (applyAnchor) {
                    [strongSelf scrollToPlaylistIndex:[applyAnchor[kAnchorIndexKey] integerValue]
                                          pixelOffset:[applyAnchor[kAnchorOffsetKey] doubleValue]];
                }

                [strongSelf recomputeGroupDurations];
                [strongSelf.playlistView reloadData];

                // Persist the corrected layout. When nothing changed the stored
                // cache already matches what was just verified, so re-serializing
                // and rewriting it is pure work.
                [strongSelf saveGroupCacheForPlaylist:playlist synchronous:NO];
            }
        });
    });
}

- (void)syncSelectionFromPlaylist {
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) return;

    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    [_playlistView.selectedIndices removeAllIndexes];

    // Use batch selection query - ONE SDK call instead of N
    pfc::bit_array_bittable selectionMask(itemCount);
    pm->playlist_get_selection_mask(activePlaylist, selectionMask);

    // Iterate set bits as contiguous runs - one addIndexesInRange: per run
    // instead of one message per selected index (select-all on a large
    // playlist would otherwise send N messages).
    t_size i = selectionMask.find_first(true, 0, itemCount);
    while (i < itemCount) {
        t_size runEnd = selectionMask.find_first(false, i + 1, itemCount);
        [_playlistView.selectedIndices addIndexesInRange:NSMakeRange((NSUInteger)i, (NSUInteger)(runEnd - i))];
        i = selectionMask.find_first(true, runEnd, itemCount);
    }
}

- (void)updatePlayingIndicator {
    auto pm = playlist_manager::get();
    t_size playingPlaylist, playingItem;

    _playlistView.playingIndex = -1;
    if (pm->get_playing_item_location(&playingPlaylist, &playingItem)) {
        if (playingPlaylist == (t_size)_currentPlaylistIndex) {
            // In both flat and sparse group mode, we can use playlist index directly
            // The view will handle the row mapping
            _playlistView.playingIndex = (NSInteger)playingItem;
        }
    }
}

#pragma mark - Playlist Event Handlers

- (void)handlePlaylistSwitched {
    [self rebuildFromPlaylist];
    [self refreshSelectionTracking];
}

- (void)handleItemsAdded:(NSInteger)base count:(NSInteger)count addedHandles:(std::shared_ptr<metadb_handle_list>)handles {
    // Detect Finder-open replacement pattern before doing the standard rebuild.
    if (base == 0 && count > 0 && _activePlaylistJustCleared && !_internalModification) {
        [self maybeApplyFinderOpenOverride:handles];
    }
    _activePlaylistJustCleared = NO;
    [self rebuildFromPlaylist];
}

- (void)handleItemsRemoved:(NSInteger)newCount {
    // Track full clear of active playlist as part of Finder-open detection.
    // The single-impl callback fires only for the active playlist, so newCount==0
    // means the active playlist is now empty.
    //
    // The flag is reset on the next run loop iteration so an items_added enqueued
    // by the same SDK operation still sees it; unrelated later events do not.
    if (newCount == 0 && !_internalModification) {
        _activePlaylistJustCleared = YES;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.activePlaylistJustCleared = NO;
        });
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self rebuildFromPlaylist];
    [CATransaction commit];
}

- (void)handleItemsReordered {
    [self rebuildFromPlaylist];
}

- (void)handleSelectionChanged {
    // Always sync from the SDK. A previous generation-counter optimization
    // skipped "our own" changes here, but it leaked: pushing a selection that
    // matches pm's current state fires NO callback, leaving a generation
    // pending that swallowed the NEXT external change (e.g. Focus Playing Now
    // appearing to do nothing while stale albums stayed highlighted). The
    // sync is a cheap batch mask read; self-initiated changes are visual
    // no-ops because pm already holds exactly what the view shows.
    [self syncSelectionFromPlaylist];
    [_playlistView setNeedsDisplay:YES];
}

- (void)handleFocusChanged:(NSInteger)fromPlaylistIndex to:(NSInteger)toPlaylistIndex {
    _playlistView.focusIndex = toPlaylistIndex;
    if (toPlaylistIndex >= 0) {
        NSInteger row = [_playlistView rowForPlaylistIndex:toPlaylistIndex];
        if (row >= 0) {
            [_playlistView scrollRowToVisible:row];
        }
    }
    [_playlistView setNeedsDisplay:YES];
}

- (void)handleEnsureVisible:(NSInteger)playlistIndex {
    if (playlistIndex < 0) return;
    NSInteger row = [_playlistView rowForPlaylistIndex:playlistIndex];
    if (row >= 0) {
        [_playlistView scrollRowToVisible:row];
    }
}

- (void)handleItemsModified {
    // Metadata changed - rebuild groups since discovery can change grouping
    // (e.g. tracks going from unknown to resolved album/artist)
    // rebuildFromPlaylist preserves scroll position via anchor mechanism
    [self rebuildFromPlaylist];
}

#pragma mark - Playback Event Handlers

- (void)handlePlaybackNewTrack:(metadb_handle_ptr)track {
    // Clear cached column values so %isplaying%-based columns (e.g. ">" in the Playing
    // column) are re-evaluated for the new track rather than showing stale results.
    [_playlistView clearFormattedValuesCache];
    [self updatePlayingIndicator];
    [self refreshSelectionTracking];
}

- (void)handlePlaybackStopped {
    [_playlistView clearFormattedValuesCache];
    _playlistView.playingIndex = -1;
}

- (void)refreshSelectionTracking {
    // Acquire holder lazily (once), then restart tracking each time.
    // set_playlist_selection_tracking() auto-follows the active playlist's selection,
    // keeping Selection Properties (sections=metadata) in sync after playlist switches.
    // Tracking can end if another component calls a set method on its own holder, so we
    // re-call here on every playlist switch and new-track event to reclaim it.
    if (!_selectionHolder.is_valid()) {
        auto mgr = ui_selection_manager::tryGet();
        if (mgr.is_valid()) {
            _selectionHolder = mgr->acquire();
        }
    }
    if (_selectionHolder.is_valid()) {
        _selectionHolder->set_playlist_selection_tracking();
    }
}

#pragma mark - Queue Event Handlers

- (void)handleQueueChanged {
    _queuePositionMap = nil;
    if (_hasQueueColumn) {
        [_playlistView clearFormattedValuesCache];
        [_playlistView setNeedsDisplay:YES];
    }
}

#pragma mark - Metadb Event Handlers

- (void)handleMetadbChanged:(std::shared_ptr<metadb_handle_list>)changed {
    // Refresh when foobar2000 reads/updates tags for any track in the current
    // playlist (e.g., on first playback of an unanalyzed file). Filter to only
    // changes that affect our current playlist to avoid unnecessary rebuilds.
    if (_currentPlaylistIndex < 0 || !changed || changed->get_count() == 0) return;

    // Cached decorations for changed handles are stale regardless of whether
    // the change also triggers a grouping rebuild below.
    if (_decorationCoordinator) {
        [_decorationCoordinator handleMetadbChanged:*changed];
        _decorPreparedRange = NSMakeRange(NSNotFound, 0);
    }

    auto pm = playlist_manager::get();
    metadb_handle_list playlistHandles;
    pm->playlist_get_all_items((t_size)_currentPlaylistIndex, playlistHandles);
    if (playlistHandles.get_count() == 0) return;

    // Use a hash set of the changed handles for O(1) lookup
    std::unordered_set<metadb_handle*> changedSet;
    changedSet.reserve(changed->get_count());
    for (t_size i = 0; i < changed->get_count(); i++) {
        changedSet.insert((*changed)[i].get_ptr());
    }
    BOOL anyMatch = NO;
    for (t_size i = 0; i < playlistHandles.get_count(); i++) {
        if (changedSet.count(playlistHandles[i].get_ptr())) {
            anyMatch = YES;
            break;
        }
    }
    if (!anyMatch) return;

    // Metadata may have changed grouping (e.g., album/artist resolved from ?).
    // rebuildFromPlaylist preserves scroll position via its anchor mechanism.
    [self rebuildFromPlaylist];
}

- (NSDictionary<NSNumber *, NSNumber *> *)buildQueuePositionMap {
    if (_currentPlaylistIndex < 0) return @{};
    auto pm = playlist_manager::get();
    t_size queueCount = pm->queue_get_count();
    if (queueCount == 0) return @{};

    pfc::list_t<t_playback_queue_item> queueItems;
    pm->queue_get_contents(queueItems);

    NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionaryWithCapacity:queueCount];
    t_size currentPlaylist = (t_size)_currentPlaylistIndex;
    for (t_size i = 0; i < queueItems.get_count(); i++) {
        const auto& item = queueItems[i];
        if (item.m_playlist == currentPlaylist) {
            // 1-based position; if same item queued multiple times, show first position
            NSNumber *key = @(item.m_item);
            if (!map[key]) {
                map[key] = @(i + 1);
            }
        }
    }
    return map;
}

#pragma mark - SimPlaylistViewDelegate

- (void)playlistView:(SimPlaylistView *)view selectionDidChange:(NSIndexSet *)selectedPlaylistIndices {
    // Sync selection back to playlist_manager
    // SDK calls must be on main thread - callbacks trigger UI updates in fb2k core

    // Copy indices and capture current playlist for the async block
    NSIndexSet *indicesCopy = [selectedPlaylistIndices copy];
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) return;

    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    if (itemCount == 0) return;

    // Deferred one runloop turn (SDK calls must be on the main thread)
    dispatch_async(dispatch_get_main_queue(), ^{
        // Build new state bit array directly from NSIndexSet - O(selection count)
        __block bit_array_bittable newState(itemCount);

        // Mark new selections
        [indicesCopy enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            if (idx < itemCount) {
                newState.set((t_size)idx, true);
            }
        }];

        pm->playlist_set_selection(activePlaylist, bit_array_true(), newState);
    });
}

- (void)playlistView:(SimPlaylistView *)view didDoubleClickRow:(NSInteger)row {
    if (_currentPlaylistIndex < 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;

    // Get playlist index using the view's row mapping
    NSInteger playlistIndex = [view playlistIndexForRow:row];
    if (playlistIndex < 0) return;  // Header row or invalid

    bool preserveQueue = simplaylist_config::getConfigBool(
        simplaylist_config::kDoubleClickPreservesQueue,
        simplaylist_config::kDefaultDoubleClickPreservesQueue);

    if (preserveQueue && pm->queue_get_count() > 0) {
        // Save queue, play track (flushes queue), restore queue next run loop
        pfc::list_t<t_playback_queue_item> savedQueue;
        pm->queue_get_contents(savedQueue);

        pm->playlist_execute_default_action(activePlaylist, playlistIndex);

        // Restore after default action's async flush completes
        dispatch_async(dispatch_get_main_queue(), ^{
            auto pm2 = playlist_manager::get();
            for (t_size i = 0; i < savedQueue.get_count(); i++) {
                const auto& item = savedQueue[i];
                // Playlists can mutate between capture and this turn; re-validate
                // the saved location (and that it still holds the same track)
                // before replaying it, else fall back to the handle.
                bool locationValid = false;
                if (item.m_playlist != pfc_infinite &&
                    item.m_playlist < pm2->get_playlist_count() &&
                    item.m_item < pm2->playlist_get_item_count(item.m_playlist)) {
                    metadb_handle_ptr current;
                    locationValid = pm2->playlist_get_item_handle(current, item.m_playlist, item.m_item)
                        && current == item.m_handle;
                }
                if (locationValid)
                    pm2->queue_add_item_playlist(item.m_playlist, item.m_item);
                else
                    pm2->queue_add_item(item.m_handle);
            }
        });
    } else {
        pm->playlist_execute_default_action(activePlaylist, playlistIndex);
    }
}

- (void)playlistView:(SimPlaylistView *)view requestContextMenuForRows:(NSIndexSet *)playlistIndices atPoint:(NSPoint)point {
    if (_currentPlaylistIndex < 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);

    // Collect indices to array first (can't modify C++ objects in blocks)
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    [playlistIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < itemCount) {
            [indices addObject:@(idx)];
        }
    }];

    // Now collect handles
    metadb_handle_list handles;
    for (NSNumber *num in indices) {
        metadb_handle_ptr handle;
        if (pm->playlist_get_item_handle(handle, activePlaylist, (t_size)[num integerValue])) {
            handles.add_item(handle);
        }
    }

    if (handles.get_count() == 0) return;

    // Build context menu
    [self showContextMenuForHandles:handles atPoint:point inView:view];
}

// SDK failures surface as C++ exceptions, which @catch (NSException *) cannot
// intercept — both handler kinds are needed around every SDK menu call.
static void runGuardedSDKAction(const char *what, void (NS_NOESCAPE ^block)(void)) {
    try {
    @try {
        block();
    } @catch (NSException *exception) {
        FB2K_console_formatter() << "[SimPlaylist] " << what << " failed: "
                                 << (exception.reason.UTF8String ?: "unknown");
    }
    } catch (const std::exception &e) {
        FB2K_console_formatter() << "[SimPlaylist] " << what << " failed: " << e.what();
    } catch (...) {
        FB2K_console_formatter() << "[SimPlaylist] " << what << " failed: unknown exception";
    }
}

- (void)showContextMenuForHandles:(metadb_handle_list_cref)handles atPoint:(NSPoint)point inView:(NSView *)view {
    runGuardedSDKAction("Context menu build", ^{
        // Clear previous managers
        _contextMenuManager.release();
        _contextMenuManagerV1.release();

        // Store handles for custom menu actions
        _contextMenuHandles = handles;

        // Create context menu manager
        auto cmm = contextmenu_manager_v2::tryGet();
        if (!cmm.is_valid()) {
            // Fall back to v1
            _contextMenuManagerV1 = contextmenu_manager::g_create();
            _contextMenuManagerV1->init_context(handles, 0);
            [self showContextMenuWithManagerV1:_contextMenuManagerV1 atPoint:point inView:view];
            return;
        }

        // Store for use in click handler
        _contextMenuManager = cmm;
        _contextMenuManager->init_context(handles, 0);
        menu_tree_item::ptr root = _contextMenuManager->build_menu();

        if (!root.is_valid()) return;

        // Build NSMenu from menu_tree_item
        NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
        [menu setAutoenablesItems:NO];

        [self appendReloadSectionToMenu:menu];

        [self buildNSMenu:menu fromMenuItem:root contextManager:_contextMenuManager];

        // Decorator provider actions (e.g. intake propose/approve)
        [_decorationCoordinator appendContextActionsToMenu:menu forHandles:_contextMenuHandles];

        [self appendFocusPlayingNowItemToMenu:menu];

        // Show menu
        NSPoint screenPoint = [view.window convertPointToScreen:[view convertPoint:point toView:nil]];
        [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];
    });
}

- (void)showContextMenuWithManagerV1:(contextmenu_manager::ptr)cmm atPoint:(NSPoint)point inView:(NSView *)view {
    contextmenu_node *root = cmm->get_root();
    if (!root) return;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    [menu setAutoenablesItems:NO];

    [self appendReloadSectionToMenu:menu];

    [self buildNSMenuFromNode:menu parentNode:root contextManager:cmm baseID:0];

    // Decorator provider actions (e.g. intake propose/approve)
    [_decorationCoordinator appendContextActionsToMenu:menu forHandles:_contextMenuHandles];

    [self appendFocusPlayingNowItemToMenu:menu];

    NSPoint screenPoint = [view.window convertPointToScreen:[view convertPoint:point toView:nil]];
    [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];
}

// Shared context-menu preamble (v2 and v1 builders): the "Reload Info" item,
// progress rows for in-flight reload operations, and a trailing separator.
// Completed operations are compacted out before display.
- (void)appendReloadSectionToMenu:(NSMenu *)menu {
    NSMenuItem *reloadItem = [[NSMenuItem alloc] initWithTitle:@"Reload Info"
                                                        action:@selector(reloadInfoClicked:)
                                                 keyEquivalent:@""];
    reloadItem.target = self;
    [menu addItem:reloadItem];

    _reloadOperations.erase(
        std::remove_if(_reloadOperations.begin(), _reloadOperations.end(),
            [](const ReloadOperation& op) { return op.completed; }),
        _reloadOperations.end());

    for (size_t i = 0; i < _reloadOperations.size(); i++) {
        const auto& op = _reloadOperations[i];
        NSString *progressText = [NSString stringWithFormat:@"Reloading: %zu / %zu",
                                  op.processedCount, op.totalCount];
        NSMenuItem *progressItem = [[NSMenuItem alloc] initWithTitle:progressText
                                                              action:nil
                                                       keyEquivalent:@""];
        progressItem.enabled = NO;  // Non-selectable
        [menu addItem:progressItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];
}

// Append the custom "Focus Playing Now" navigation item at the very bottom of
// the context menu (both the v2 and v1 menu builders call this last).
- (void)appendFocusPlayingNowItemToMenu:(NSMenu *)menu {
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *focusItem = [[NSMenuItem alloc] initWithTitle:@"Focus Playing Now"
                                                       action:@selector(focusPlayingNowClicked:)
                                                keyEquivalent:@""];
    focusItem.target = self;

    // Enabled only while a track with a known playlist location is playing
    t_size playingPlaylist = SIZE_MAX, playingItem = SIZE_MAX;
    focusItem.enabled = playlist_manager::get()->get_playing_item_location(&playingPlaylist, &playingItem);

    [menu addItem:focusItem];
}

// Select + focus the currently playing track and scroll it to the vertical
// center of the view, switching to its playlist first when necessary.
- (void)focusPlayingNowClicked:(id)sender {
    auto pm = playlist_manager::get();
    t_size playingPlaylist = SIZE_MAX, playingItem = SIZE_MAX;
    if (!pm->get_playing_item_location(&playingPlaylist, &playingItem)) return;
    if (playingPlaylist == SIZE_MAX || playingItem == SIZE_MAX) return;

    t_size count = pm->playlist_get_item_count(playingPlaylist);
    if (playingItem >= count) return;

    // Focus + select the playing track (valid on non-active playlists too);
    // the playlist callbacks propagate this into the view.
    pm->playlist_set_focus_item(playingPlaylist, playingItem);
    bit_array_bittable selection(count);
    selection.set(playingItem, true);
    pm->playlist_set_selection(playingPlaylist, pfc::bit_array_true(), selection);

    if ((NSInteger)playingPlaylist != _currentPlaylistIndex) {
        // Center once the target playlist has rebuilt - consumed by
        // performScrollRestore with priority over the saved anchor.
        _pendingCenterIndex = (NSInteger)playingItem;
        _pendingCenterPlaylist = (NSInteger)playingPlaylist;
        pm->set_active_playlist(playingPlaylist);
    } else {
        [self scrollPlaylistIndexToCenter:(NSInteger)playingItem];
    }
}

- (void)buildNSMenu:(NSMenu *)menu fromMenuItem:(menu_tree_item::ptr)item contextManager:(contextmenu_manager_v2::ptr)cmm {
    for (size_t i = 0; i < item->childCount(); i++) {
        menu_tree_item::ptr child = item->childAt(i);

        switch (child->type()) {
            case menu_tree_item::itemSeparator: {
                [menu addItem:[NSMenuItem separatorItem]];
                break;
            }

            case menu_tree_item::itemCommand: {
                // nil on invalid UTF-8 — initWithTitle:nil would throw
                NSString *title = [NSString stringWithUTF8String:child->name()] ?: @"";
                NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                  action:@selector(contextMenuItemClicked:)
                                                           keyEquivalent:@""];
                menuItem.target = self;
                menuItem.tag = child->commandID();

                menu_flags_t flags = child->flags();
                menuItem.enabled = !(flags & menu_flags::disabled);
                menuItem.state = (flags & menu_flags::checked) ? NSControlStateValueOn : NSControlStateValueOff;

                [menu addItem:menuItem];
                break;
            }

            case menu_tree_item::itemSubmenu: {
                NSString *title = [NSString stringWithUTF8String:child->name()] ?: @"";
                NSMenuItem *submenuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                     action:nil
                                                              keyEquivalent:@""];

                NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
                [submenu setAutoenablesItems:NO];
                [self buildNSMenu:submenu fromMenuItem:child contextManager:cmm];

                submenuItem.submenu = submenu;
                [menu addItem:submenuItem];
                break;
            }
        }
    }
}

- (void)buildNSMenuFromNode:(NSMenu *)menu parentNode:(contextmenu_node *)parent contextManager:(contextmenu_manager::ptr)cmm baseID:(int)baseID {
    for (t_size i = 0; i < parent->get_num_children(); i++) {
        contextmenu_node *child = parent->get_child(i);

        switch (child->get_type()) {
            case contextmenu_item_node::TYPE_SEPARATOR: {
                [menu addItem:[NSMenuItem separatorItem]];
                break;
            }

            case contextmenu_item_node::TYPE_COMMAND: {
                // nil on invalid UTF-8 — initWithTitle:nil would throw
                NSString *title = [NSString stringWithUTF8String:child->get_name()] ?: @"";
                NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                  action:@selector(contextMenuItemClickedV1:)
                                                           keyEquivalent:@""];
                menuItem.target = self;
                menuItem.tag = child->get_id();

                unsigned flags = child->get_display_flags();
                menuItem.enabled = !(flags & contextmenu_item_node::FLAG_DISABLED);
                menuItem.state = (flags & contextmenu_item_node::FLAG_CHECKED) ? NSControlStateValueOn : NSControlStateValueOff;

                [menu addItem:menuItem];
                break;
            }

            case contextmenu_item_node::TYPE_POPUP: {
                NSString *title = [NSString stringWithUTF8String:child->get_name()] ?: @"";
                NSMenuItem *submenuItem = [[NSMenuItem alloc] initWithTitle:title
                                                                     action:nil
                                                              keyEquivalent:@""];

                NSMenu *submenu = [[NSMenu alloc] initWithTitle:title];
                [submenu setAutoenablesItems:NO];
                [self buildNSMenuFromNode:submenu parentNode:child contextManager:cmm baseID:baseID];

                submenuItem.submenu = submenu;
                [menu addItem:submenuItem];
                break;
            }

            default:
                break;
        }
    }
}

- (void)contextMenuItemClicked:(NSMenuItem *)sender {
    // Execute using the stored contextmenu_manager_v2
    // The command ID is stored in the tag
    unsigned commandID = (unsigned)sender.tag;
    runGuardedSDKAction("Context menu command", ^{
        if (_contextMenuManager.is_valid()) {
            _contextMenuManager->execute_by_id(commandID);
        }
    });
}

- (void)contextMenuItemClickedV1:(NSMenuItem *)sender {
    // Execute using the stored contextmenu_manager (v1)
    unsigned commandID = (unsigned)sender.tag;
    runGuardedSDKAction("Context menu command", ^{
        if (_contextMenuManagerV1.is_valid()) {
            _contextMenuManagerV1->execute_by_id(commandID);
        }
    });
}

- (void)reloadInfoClicked:(NSMenuItem *)sender {
    if (_contextMenuHandles.get_count() == 0) return;

    // Create a new reload operation to track progress. Main-thread only (menu
    // action), so the counter needs no synchronisation.
    static uint64_t sNextReloadOpID = 1;
    uint64_t opID = sNextReloadOpID++;
    _reloadOperations.push_back({
        .opID = opID,
        .totalCount = _contextMenuHandles.get_count(),
        .processedCount = 0,
        .completed = false
    });

    // Copy handles for the async operation
    metadb_handle_list handles = _contextMenuHandles;

    // Use async background reload - no modal dialog
    // The SDK doesn't provide per-item progress, so we mark complete when done
    __weak SimPlaylistController *weakSelf = self;

    // Create completion callback
    auto notify = fb2k::makeCompletionNotify([weakSelf, opID](unsigned status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SimPlaylistController *strongSelf = weakSelf;
            if (!strongSelf) return;
            for (auto &op : strongSelf->_reloadOperations) {
                if (op.opID != opID) continue;
                op.completed = true;
                op.processedCount = op.totalCount;
                break;
            }
        });
    });

    // Run in background with no modal UI
    metadb_io_v2::get()->load_info_async(
        handles,
        metadb_io::load_info_force,
        core_api::get_main_window(),
        metadb_io_v2::op_flag_background | metadb_io_v2::op_flag_delay_ui,
        notify
    );
}

- (void)playlistViewDidRequestRemoveSelection:(SimPlaylistView *)view {
    // Empty selection: nothing to remove. Without this guard, lastIndex below
    // returns NSNotFound and the focus-recalculation loop runs ~2^63 times,
    // freezing the app.
    if (view.selectedIndices.count == 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();

    if (activePlaylist == SIZE_MAX) return;

    // Check if playlist is locked
    if (pm->playlist_lock_is_present(activePlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(activePlaylist);
        if (lockMask & playlist_lock::filter_remove) {
            console::info("[SimPlaylist] Cannot remove items - playlist is locked");
            return;
        }
    }

    // Create undo point
    pm->playlist_undo_backup(activePlaylist);

    // Build removal mask from selected playlist indices
    // Note: selectedIndices contains playlist indices directly (not row indices)
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    __block bit_array_bittable mask(itemCount);
    __block t_size removedCount = 0;

    [view.selectedIndices enumerateIndexesUsingBlock:^(NSUInteger playlistIndex, BOOL *stop) {
        if (playlistIndex < itemCount) {
            mask.set((t_size)playlistIndex, true);
            removedCount++;
        }
    }];

    // The view selection can be stale relative to the playlist - out-of-range
    // indices are dropped above, so derive all counts from what actually goes
    // into the mask (itemCount - selectedIndices.count could wrap otherwise).
    if (removedCount == 0) return;

    // Calculate new focus position BEFORE removal
    // Focus should move to the next item after the last selected, or previous if at end
    NSInteger lastSelectedIndex = (NSInteger)[view.selectedIndices lastIndex];
    NSInteger firstSelectedIndex = (NSInteger)[view.selectedIndices firstIndex];
    if ((t_size)lastSelectedIndex >= itemCount) lastSelectedIndex = (NSInteger)itemCount - 1;
    t_size newItemCount = itemCount - removedCount;

    t_size newFocusIndex = SIZE_MAX;
    if (newItemCount > 0) {
        // Try to focus the item that will be at the position after the last selected item
        // After removal, items shift down, so next item after lastSelected becomes lastSelected - (items removed before it)
        t_size itemsRemovedBeforeLast = 0;
        for (t_size i = 0; i < (t_size)lastSelectedIndex; i++) {
            if (mask.get(i)) itemsRemovedBeforeLast++;
        }
        // The item after lastSelectedIndex (if it exists) will be at position: lastSelectedIndex - itemsRemovedBeforeLast
        // But we need to check if there IS an item after lastSelectedIndex
        if ((t_size)(lastSelectedIndex + 1) < itemCount) {
            // There's an item after - it will move to this position
            newFocusIndex = (t_size)lastSelectedIndex - itemsRemovedBeforeLast;
        } else {
            // No item after - focus the item before first selected (which is firstSelectedIndex - 1)
            // After removal, that item's position is: (firstSelectedIndex - 1) - (items removed before it) = firstSelectedIndex - 1
            // Since nothing is removed before firstSelectedIndex, the position stays the same
            if (firstSelectedIndex > 0) {
                newFocusIndex = (t_size)(firstSelectedIndex - 1);
            } else {
                // Everything was at the start, focus first remaining item
                newFocusIndex = 0;
            }
        }
        // Clamp to valid range
        if (newFocusIndex >= newItemCount) {
            newFocusIndex = newItemCount - 1;
        }
    }

    // Remove items
    pm->playlist_remove_items(activePlaylist, mask);

    // Set focus to calculated position (also selects it)
    if (newFocusIndex != SIZE_MAX && newItemCount > 0) {
        pm->playlist_set_focus_item(activePlaylist, newFocusIndex);
        // Select only the focused item
        pm->playlist_set_selection(activePlaylist, pfc::bit_array_true(), pfc::bit_array_one(newFocusIndex));
    }
}

#pragma mark - Album Art

// Check if path is a remote URL that could block
static BOOL isRemotePath(const char *path) {
    if (!path) return NO;
    return (strncmp(path, "http://", 7) == 0 ||
            strncmp(path, "https://", 8) == 0 ||
            strncmp(path, "ftp://", 6) == 0 ||
            strncmp(path, "cdda://", 7) == 0 ||
            strncmp(path, "mms://", 6) == 0 ||
            strncmp(path, "rtsp://", 7) == 0);
}

- (NSImage *)playlistView:(SimPlaylistView *)view albumArtForGroupAtPlaylistIndex:(NSInteger)playlistIndex {
    if (playlistIndex < 0 || _currentPlaylistIndex < 0) return nil;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;

    metadb_handle_ptr handle;
    if (!pm->playlist_get_item_handle(handle, activePlaylist, (t_size)playlistIndex)) {
        return nil;
    }

    const char *path = handle->get_path();

    // Skip album art loading for remote files - they block the main thread
    if (isRemotePath(path)) {
        return nil;  // Just show placeholder for remote files
    }

    // nil on invalid UTF-8 — a nil key would throw inside the cache
    NSString *cacheKey = [NSString stringWithUTF8String:path];
    if (!cacheKey) return nil;
    AlbumArtCache *cache = [AlbumArtCache sharedCache];
    NSImage *cached = [cache cachedImageForKey:cacheKey];
    if (cached) {
        return cached;
    }

    // Check if already known to have no image
    if ([cache hasNoImageForKey:cacheKey]) {
        return nil;  // No album art for this track
    }

    // Start async load if not already loading
    if (![cache isLoadingKey:cacheKey]) {
        __weak SimPlaylistController *weakSelf = self;
        [cache loadImageForKey:cacheKey handle:handle completion:^(NSImage *image) {
            // Only trigger redraw if we actually got an image
            if (image) {
                // Coalesce redraws with small delay to batch multiple image loads
                SimPlaylistController *strongSelf = weakSelf;
                if (strongSelf && !strongSelf.artRedrawScheduled) {
                    strongSelf.artRedrawScheduled = YES;
                    // Use performSelector with delay to batch multiple completions
                    [NSObject cancelPreviousPerformRequestsWithTarget:strongSelf
                                                             selector:@selector(performDelayedRedraw)
                                                               object:nil];
                    [strongSelf performSelector:@selector(performDelayedRedraw)
                                     withObject:nil
                                     afterDelay:0.05];  // 50ms batch window
                }
            }
        }];
    }

    // Always return placeholder while loading to prevent blink
    // (previously returned nil for first-time loads, causing flash when image appeared)
    return [AlbumArtCache placeholderImage];
}

- (void)performDelayedRedraw {
    _artRedrawScheduled = NO;
    [_playlistView setNeedsDisplay:YES];
}

- (void)playlistView:(SimPlaylistView *)view didRequestQueueTracks:(NSIndexSet *)playlistIndices {
    if (_currentPlaylistIndex < 0 || playlistIndices.count == 0) return;
    auto pm = playlist_manager::get();
    t_size playlist = (t_size)_currentPlaylistIndex;
    // The view selection can be stale relative to the playlist - skip
    // out-of-range indices, matching the other selection consumers.
    t_size itemCount = pm->playlist_get_item_count(playlist);
    [playlistIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < itemCount) {
            pm->queue_add_item_playlist(playlist, (t_size)idx);
        }
    }];
}

- (void)playlistView:(SimPlaylistView *)view didChangeGroupColumnWidth:(CGFloat)newWidth {
    // Persist the new width to config
    simplaylist_config::setConfigInt(simplaylist_config::kGroupColumnWidth, (int64_t)newWidth);

    // Update header bar
    _headerBar.groupColumnWidth = newWidth;
    [_headerBar setNeedsDisplay:YES];
}

static NSString *const kQueuePositionSentinel = @"__queue_position__";

- (void)recompileColumnScripts {
    _compiledColumnScripts.clear();
    _compiledColumnScripts.reserve(_columns.count);
    _hasQueueColumn = NO;
    for (ColumnDefinition *col in _columns) {
        if ([col.pattern isEqualToString:kQueuePositionSentinel]) {
            _hasQueueColumn = YES;
            // Push a dummy script — queue values are resolved via SDK, not title format
            _compiledColumnScripts.push_back(nullptr);
        } else {
            _compiledColumnScripts.push_back(
                simplaylist::TitleFormatHelper::compile([col.pattern UTF8String])
            );
        }
    }
    // Rebuild queue map if we now have (or lost) a queue column
    _queuePositionMap = nil;
}

- (NSArray<NSString *> *)playlistView:(SimPlaylistView *)view columnValuesForPlaylistIndex:(NSInteger)playlistIndex {
    // Lazy load column values for a track - only called when drawing visible rows
    auto pm = playlist_manager::get();
    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == SIZE_MAX) return nil;

    // Check if playlistIndex is within valid range
    t_size playlistItemCount = pm->playlist_get_item_count(activePlaylist);
    if (playlistIndex < 0 || (t_size)playlistIndex >= playlistItemCount) {
        return nil;
    }

    // Lazily build queue position map if we have a queue column
    if (_hasQueueColumn && !_queuePositionMap) {
        _queuePositionMap = [self buildQueuePositionMap];
    }

    // The view caches this setting (refreshed on settings-changed notification);
    // avoid a configStore round-trip per formatted row.
    NSInteger queueStyle = _playlistView.queueDisplayStyle;

    // Format column values using pre-compiled scripts
    NSMutableArray<NSString *> *columnValues = [NSMutableArray arrayWithCapacity:_compiledColumnScripts.size()];
    for (size_t i = 0; i < _compiledColumnScripts.size(); i++) {
        if (!_compiledColumnScripts[i].is_valid()) {
            // Queue position sentinel — resolve from queue map
            NSNumber *queuePos = _queuePositionMap[@(playlistIndex)];
            if (queuePos) {
                if (queueStyle == 0) {
                    [columnValues addObject:[NSString stringWithFormat:@"[%@]", queuePos]];
                } else {
                    [columnValues addObject:[NSString stringWithFormat:@"%@", queuePos]];
                }
            } else {
                [columnValues addObject:@""];
            }
        } else {
            std::string value = simplaylist::TitleFormatHelper::formatWithPlaylistContext(
                activePlaylist, playlistIndex, _compiledColumnScripts[i]);
            // nil on invalid UTF-8 in tags; addObject:nil would throw on every
            // redraw of the row — an effective crash loop from one corrupt file
            [columnValues addObject:([NSString stringWithUTF8String:value.c_str()] ?: @"")];
        }
    }

    return columnValues;
}

#pragma mark - Row decorations (SimPlaylistViewDelegate)

// Cache-only lookups: the store is populated asynchronously by the prepare
// pass; unresolved rows render undecorated and repaint on invalidation.
// These are only reached when a decorator provider exists (view guard).

- (RowDecoration *)playlistView:(SimPlaylistView *)view rowDecorationForPlaylistIndex:(NSInteger)playlistIndex {
    return [_decorationCoordinator.store decorationForIndex:playlistIndex];
}

- (GroupDecoration *)playlistView:(SimPlaylistView *)view groupDecorationForGroupIndex:(NSInteger)groupIndex {
    return [_decorationCoordinator.store groupDecorationForGroupIndex:groupIndex];
}

- (void)playlistView:(SimPlaylistView *)view prepareDecorationsForRowRange:(NSRange)rowRange {
    if (!_decorationCoordinator || _currentPlaylistIndex < 0) return;
    if (NSEqualRanges(rowRange, _decorPreparedRange)) return;  // Steady state: no scroll

    NSArray<NSNumber *> *groupStarts = view.groupStarts;
    NSArray<NSString *> *groupHeaders = view.groupHeaders;
    NSInteger itemCount = view.itemCount;
    NSMutableIndexSet *trackIndices = [NSMutableIndexSet indexSet];

    // Only rows that newly entered the range need index mapping; rows kept
    // from the previous range are already bound (bindings reset together
    // with _decorPreparedRange on any invalidation).
    for (NSInteger row = (NSInteger)rowRange.location; row < (NSInteger)NSMaxRange(rowRange); row++) {
        if (NSLocationInRange((NSUInteger)row, _decorPreparedRange)) continue;

        if ([view isRowGroupHeader:row]) {
            NSInteger groupIndex = [view groupIndexForRow:row];
            if (groupIndex >= 0 && groupIndex < (NSInteger)groupStarts.count) {
                NSInteger start = [groupStarts[groupIndex] integerValue];
                NSInteger end = (groupIndex + 1 < (NSInteger)groupStarts.count)
                    ? [groupStarts[groupIndex + 1] integerValue] : itemCount;
                NSString *header = (groupIndex < (NSInteger)groupHeaders.count)
                    ? groupHeaders[groupIndex] : @"";
                [_decorationCoordinator prepareGroup:groupIndex
                                              header:header
                                          indexRange:NSMakeRange(start, end - start)
                                          inPlaylist:(t_size)_currentPlaylistIndex];
            }
        } else {
            NSInteger playlistIndex = [view playlistIndexForRow:row];
            if (playlistIndex >= 0) {
                [trackIndices addIndex:(NSUInteger)playlistIndex];
            }
        }
    }

    _decorPreparedRange = rowRange;
    if (trackIndices.count > 0) {
        [_decorationCoordinator prepareTrackIndices:trackIndices
                                         inPlaylist:(t_size)_currentPlaylistIndex];
    }
}

#pragma mark - SimPlaylistHeaderBarDelegate

- (void)headerBar:(SimPlaylistHeaderBar *)bar didResizeColumn:(NSInteger)columnIndex toWidth:(CGFloat)newWidth {
    if (columnIndex < 0 || columnIndex >= (NSInteger)_columns.count) return;

    // Update column definition; disable auto-resize so this width is preserved on view resize
    ColumnDefinition *col = _columns[columnIndex];
    col.width = newWidth;
    col.autoResize = NO;

    // Update playlist view
    [_playlistView reloadData];
}

// Single writer for the persisted column layout. An empty serialization must
// never reach setConfigString: writing "" is the DELETE idiom (ConfigHelper.h),
// so a failed serialize would wipe the user's columns back to the defaults.
- (void)persistColumns {
    NSString *columnsJSON = [ColumnDefinition columnsToJSON:_columns];
    if (columnsJSON.length == 0) {
        FB2K_console_formatter() << "[SimPlaylist] Column layout not saved: serialization failed";
        return;
    }
    simplaylist_config::setConfigString(simplaylist_config::kColumns, columnsJSON.UTF8String);
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didFinishResizingColumn:(NSInteger)columnIndex {
    // Persist column widths
    [self persistColumns];
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didReorderColumnFrom:(NSInteger)fromIndex to:(NSInteger)toIndex {
    if (fromIndex < 0 || fromIndex >= (NSInteger)_columns.count) return;
    if (toIndex < 0 || toIndex > (NSInteger)_columns.count) return;

    // Reorder columns array
    NSMutableArray *mutableColumns = [_columns mutableCopy];
    ColumnDefinition *movedCol = mutableColumns[fromIndex];
    [mutableColumns removeObjectAtIndex:fromIndex];

    NSInteger insertIndex = toIndex;
    if (toIndex > fromIndex) {
        insertIndex--;
    }
    insertIndex = MAX(0, MIN((NSInteger)mutableColumns.count, insertIndex));

    [mutableColumns insertObject:movedCol atIndex:insertIndex];
    _columns = [mutableColumns copy];
    [self recompileColumnScripts];

    // Update both views
    _headerBar.columns = _columns;
    _playlistView.columns = _columns;
    [_headerBar setNeedsDisplay:YES];
    [_playlistView clearFormattedValuesCache];  // Clear cache - values are in old column order
    [_playlistView setNeedsDisplay:YES];

    // Persist column order
    [self persistColumns];
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didClickColumn:(NSInteger)columnIndex {
    // Could implement sorting here in the future
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didResizeGroupColumnToWidth:(CGFloat)newWidth {
    _playlistView.groupColumnWidth = newWidth;
    [_playlistView setNeedsDisplay:YES];
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar didFinishResizingGroupColumn:(CGFloat)finalWidth {
    // Persist the width
    simplaylist_config::setConfigInt(simplaylist_config::kGroupColumnWidth, (int64_t)finalWidth);
}

- (void)headerBar:(SimPlaylistHeaderBar *)bar showColumnMenuAtPoint:(NSPoint)screenPoint {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Columns"];

    // Get available column templates (basic columns)
    NSArray<ColumnDefinition *> *templates = [ColumnDefinition availableColumnTemplates];

    // Get columns from SDK providers (playback stats from components)
    NSArray<ColumnDefinition *> *sdkColumns = [ColumnDefinition columnsFromSDKProviders];

    // Get user-defined custom columns
    NSArray<ColumnDefinition *> *customColumns = [ColumnDefinition customColumns];

    // Build set of currently visible column names
    NSMutableSet<NSString *> *visibleColumnNames = [NSMutableSet set];
    for (ColumnDefinition *col in _columns) {
        [visibleColumnNames addObject:col.name];
    }

    // Combine all columns for lookup by index (templates + sdk + custom)
    NSMutableArray<ColumnDefinition *> *allColumns = [NSMutableArray arrayWithArray:templates];
    [allColumns addObjectsFromArray:sdkColumns];
    [allColumns addObjectsFromArray:customColumns];
    _availableColumnTemplates = allColumns;

    // Helper to add section header
    void (^addSectionHeader)(NSString *) = ^(NSString *title) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        header.enabled = NO;
        [menu addItem:header];
    };

    // Helper to add column item
    void (^addColumnItem)(ColumnDefinition *, NSInteger) = ^(ColumnDefinition *col, NSInteger tag) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:col.name
                                                      action:@selector(columnMenuItemClicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = tag;
        item.state = [visibleColumnNames containsObject:col.name] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    };

    // All basic columns in one section (no header for first section)
    for (NSInteger i = 0; i < (NSInteger)templates.count; i++) {
        addColumnItem(templates[i], i);
    }

    // SDK columns from components (playback stats, etc.)
    NSInteger templateCount = templates.count;
    if (sdkColumns.count > 0) {
        addSectionHeader(@"From Components");
        for (NSInteger i = 0; i < (NSInteger)sdkColumns.count; i++) {
            addColumnItem(sdkColumns[i], templateCount + i);
        }
    }

    // Custom columns defined in SimPlaylist
    NSInteger sdkOffset = templateCount + sdkColumns.count;
    if (customColumns.count > 0) {
        addSectionHeader(@"Custom");
        for (NSInteger i = 0; i < (NSInteger)customColumns.count; i++) {
            addColumnItem(customColumns[i], sdkOffset + i);
        }
    }

    // Edit Custom Columns... opens preferences page
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *editCustomItem = [[NSMenuItem alloc] initWithTitle:@"Edit Custom Columns..."
                                                            action:@selector(showCustomColumnsPreferences:)
                                                     keyEquivalent:@""];
    editCustomItem.target = self;
    [menu addItem:editCustomItem];

    [menu popUpMenuPositioningItem:nil atLocation:screenPoint inView:nil];
}

- (void)columnMenuItemClicked:(NSMenuItem *)sender {
    // Tags were assigned against the combined templates + SDK + custom array
    // built in showColumnMenuAtPoint:; any other array indexes a different
    // column, so there is no usable fallback.
    NSArray<ColumnDefinition *> *templates = _availableColumnTemplates;
    if (!templates) return;
    NSInteger templateIndex = sender.tag;

    if (templateIndex < 0 || templateIndex >= (NSInteger)templates.count) return;

    ColumnDefinition *colTemplate = templates[templateIndex];

    // Check if column is currently visible
    NSInteger existingIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)_columns.count; i++) {
        if ([_columns[i].name isEqualToString:colTemplate.name]) {
            existingIndex = i;
            break;
        }
    }

    NSMutableArray<ColumnDefinition *> *newColumns = [_columns mutableCopy];

    if (existingIndex >= 0) {
        // Remove the column
        [newColumns removeObjectAtIndex:existingIndex];
    } else {
        // Add the column (at end)
        [newColumns addObject:[colTemplate copy]];
    }

    _columns = newColumns;
    [self recompileColumnScripts];

    // Update UI
    _headerBar.columns = _columns;
    _playlistView.columns = _columns;
    [_headerBar setNeedsDisplay:YES];
    [_playlistView clearFormattedValuesCache];
    [_playlistView setNeedsDisplay:YES];

    // Save to config
    [self persistColumns];
}

// GUID for custom columns preferences page
static const GUID guid_simplaylist_custom_columns =
    { 0x7b8e1c32, 0x4a6d, 0x5e43, { 0x8f, 0x2b, 0x6d, 0x9a, 0x4e, 0x7f, 0x5c, 0x3b } };

- (void)showCustomColumnsPreferences:(id)sender {
    @try {
        auto uiControl = ui_control::get();
        if (uiControl.is_valid()) {
            uiControl->show_preferences(guid_simplaylist_custom_columns);
        }
    } @catch (...) {
        FB2K_console_formatter() << "[SimPlaylist] Failed to open custom columns preferences";
    }
}

#pragma mark - Drag & Drop

// Convert a drop row to the playlist index the drop should insert before.
// Header/subgroup/padding rows resolve to the next track row. Returns -1 when
// the row is out of range or no track row follows (callers append at end).
static NSInteger insertionIndexForDropRow(SimPlaylistView *view, NSInteger row) {
    NSInteger totalRows = [view rowCount];
    if (row < 0 || row >= totalRows) return -1;
    NSInteger playlistIdx = [view playlistIndexForRow:row];
    if (playlistIdx >= 0) return playlistIdx;
    // Row is header/subgroup/padding - find next valid track
    for (NSInteger r = row + 1; r < totalRows; r++) {
        NSInteger idx = [view playlistIndexForRow:r];
        if (idx >= 0) return idx;
    }
    return -1;
}

- (void)playlistView:(SimPlaylistView *)view didReorderRows:(NSIndexSet *)sourceRowIndices toRow:(NSInteger)destinationRow operation:(NSDragOperation)operation {
    if (_currentPlaylistIndex < 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;
    BOOL isDuplicate = (operation == NSDragOperationCopy);

    // Check if playlist is locked
    if (pm->playlist_lock_is_present(activePlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(activePlaylist);
        if (isDuplicate) {
            // For duplicate, check add permission
            if (lockMask & playlist_lock::filter_add) {
                return;
            }
        } else {
            // For reorder, check reorder permission
            if (lockMask & playlist_lock::filter_reorder) {
                return;
            }
        }
    }

    t_size itemCount = pm->playlist_get_item_count(activePlaylist);
    if (itemCount == 0) return;

    // sourceRowIndices actually contains playlist indices (from _selectedIndices in view)
    // They're already playlist indices, no conversion needed
    NSMutableArray<NSNumber *> *sourcePlaylistIndices = [NSMutableArray array];
    [sourceRowIndices enumerateIndexesUsingBlock:^(NSUInteger playlistIdx, BOOL *stop) {
        if (playlistIdx < itemCount) {
            [sourcePlaylistIndices addObject:@(playlistIdx)];
        }
    }];

    if (sourcePlaylistIndices.count == 0) return;

    // Already sorted: NSIndexSet enumerates in ascending index order.

    // Convert destination row to playlist index
    NSInteger dropIdx = insertionIndexForDropRow(view, destinationRow);
    NSInteger destPlaylistIndex = (dropIdx >= 0) ? dropIdx : (NSInteger)itemCount;

    pm->playlist_undo_backup(activePlaylist);

    if (isDuplicate) {
        // COPY: Duplicate items at destination (insert copies, keep originals)
        metadb_handle_list items;
        for (NSNumber *num in sourcePlaylistIndices) {
            metadb_handle_ptr item;
            if (pm->playlist_get_item_handle(item, activePlaylist, [num unsignedLongValue])) {
                items.add_item(item);
            }
        }

        if (items.get_count() > 0) {
            t_size insertPos = (destPlaylistIndex < itemCount) ? destPlaylistIndex : itemCount;
            pm->playlist_insert_items(activePlaylist, insertPos, items, pfc::bit_array_false());

            // Select the duplicated items
            t_size newItemCount = pm->playlist_get_item_count(activePlaylist);
            bit_array_bittable selMask(newItemCount);
            for (t_size i = 0; i < items.get_count(); i++) {
                selMask.set(insertPos + i, true);
            }
            pm->playlist_set_selection(activePlaylist, pfc::bit_array_true(), selMask);
            pm->playlist_set_focus_item(activePlaylist, insertPos);
        }
    } else {
        // MOVE: permutation planned by Core/ReorderPlanner (pure, unit-tested)
        std::vector<size_t> sources;
        sources.reserve(sourcePlaylistIndices.count);
        for (NSNumber *num in sourcePlaylistIndices) {
            sources.push_back([num unsignedLongValue]);
        }

        std::vector<size_t> order =
            simplaylist::planReorder(itemCount, sources, (size_t)destPlaylistIndex);
        size_t adjustedDest =
            simplaylist::adjustedReorderDestination(sources, (size_t)destPlaylistIndex);

        static_assert(sizeof(t_size) == sizeof(size_t), "reorder array assumes t_size == size_t");
        pm->playlist_reorder_items(activePlaylist, order.data(), itemCount);

        // Set focus and selection to the moved items at their new position
        if (sourcePlaylistIndices.count > 0) {
            t_size newFocusPos = adjustedDest;
            pm->playlist_set_focus_item(activePlaylist, newFocusPos);

            // Select all moved items
            bit_array_bittable selMask(itemCount);
            for (t_size i = 0; i < sourcePlaylistIndices.count; i++) {
                selMask.set(adjustedDest + i, true);
            }
            pm->playlist_set_selection(activePlaylist, pfc::bit_array_true(), selMask);
        }
    }
}

- (void)playlistView:(SimPlaylistView *)view didReceiveDroppedURLs:(NSArray<NSURL *> *)urls atRow:(NSInteger)row {
    if (_currentPlaylistIndex < 0) return;
    if (urls.count == 0) return;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;

    // Check if playlist is locked
    if (pm->playlist_lock_is_present(activePlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(activePlaylist);
        if (lockMask & playlist_lock::filter_add) {
            return;
        }
    }

    // Convert row index to playlist index for insertion point
    NSInteger dropIdx = insertionIndexForDropRow(view, row);
    t_size insertAt = (dropIdx >= 0) ? (t_size)dropIdx : SIZE_MAX;  // SIZE_MAX: append at end

    // Use async import to avoid crash from synchronous process_location
    importFilesToPlaylistAsync(activePlaylist, insertAt, urls);
}

- (NSArray<NSString *> *)playlistView:(SimPlaylistView *)view filePathsForPlaylistIndices:(NSIndexSet *)indices {
    if (_currentPlaylistIndex < 0) return nil;

    auto pm = playlist_manager::get();
    t_size activePlaylist = (t_size)_currentPlaylistIndex;
    t_size itemCount = pm->playlist_get_item_count(activePlaylist);

    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:indices.count];

    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < itemCount) {
            metadb_handle_ptr handle;
            if (pm->playlist_get_item_handle(handle, activePlaylist, idx)) {
                const char* path = handle->get_path();
                if (path) {
                    // nil on invalid UTF-8 — addObject:nil would throw at drag start
                    NSString *pathStr = [NSString stringWithUTF8String:path];
                    if (pathStr) [paths addObject:pathStr];
                }
            }
        }
    }];

    return paths;
}

- (void)playlistView:(SimPlaylistView *)view didReceiveDroppedPaths:(NSArray<NSString *> *)paths fromPlaylist:(NSInteger)sourcePlaylist sourceIndices:(NSIndexSet *)sourceIndices atRow:(NSInteger)row operation:(NSDragOperation)operation {
    if (_currentPlaylistIndex < 0) return;
    if (paths.count == 0) return;

    auto pm = playlist_manager::get();
    t_size destPlaylist = (t_size)_currentPlaylistIndex;
    BOOL isMove = (operation == NSDragOperationMove);

    // Check if destination playlist is locked for add
    if (pm->playlist_lock_is_present(destPlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(destPlaylist);
        if (lockMask & playlist_lock::filter_add) {
            FB2K_console_formatter() << "[SimPlaylist] Cross-playlist drop: destination is locked";
            return;
        }
    }

    // Check if source playlist is locked for remove (only for move operations)
    t_size srcPlaylist = (t_size)sourcePlaylist;
    if (isMove && srcPlaylist < pm->get_playlist_count() && pm->playlist_lock_is_present(srcPlaylist)) {
        t_uint32 lockMask = pm->playlist_lock_get_filter_mask(srcPlaylist);
        if (lockMask & playlist_lock::filter_remove) {
            FB2K_console_formatter() << "[SimPlaylist] Cross-playlist drop: source is locked for removal, falling back to copy";
            isMove = NO;  // Fall back to copy
        }
    }

    // Convert row index to playlist index for insertion point
    NSInteger dropIdx = insertionIndexForDropRow(view, row);
    t_size insertAt = (dropIdx >= 0) ? (t_size)dropIdx : SIZE_MAX;  // SIZE_MAX: append at end

    // For MOVE: remove items from source playlist (do this before inserting)
    if (isMove && srcPlaylist < pm->get_playlist_count() && sourceIndices.count > 0) {
        pm->playlist_undo_backup(srcPlaylist);

        // Build bit_array for removal
        t_size srcItemCount = pm->playlist_get_item_count(srcPlaylist);
        pfc::bit_array_bittable removeMask(srcItemCount);

        NSUInteger idx = [sourceIndices firstIndex];
        while (idx != NSNotFound) {
            if (idx < srcItemCount) {
                removeMask.set(idx, true);
            }
            idx = [sourceIndices indexGreaterThanIndex:idx];
        }

        pm->playlist_remove_items(srcPlaylist, removeMask);
    }

    // Insert into destination playlist using foobar2000 native paths
    importFb2kPathsToPlaylistAsync(destPlaylist, insertAt, paths);
}

@end
