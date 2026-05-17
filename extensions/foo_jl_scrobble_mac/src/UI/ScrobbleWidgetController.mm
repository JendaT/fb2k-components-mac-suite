//
//  ScrobbleWidgetController.mm
//  foo_jl_scrobble_mac
//
//  Controller for the Last.fm stats layout widget
//

#import "ScrobbleWidgetController.h"
#import "ScrobbleWidgetView.h"
#import "../Core/ScrobbleConfig.h"
#import "../Core/ScrobbleStreakCache.h"
#import "../Core/ScrobbleNotifications.h"
#import "../Core/TopAlbum.h"
#import "../Core/RecentTrack.h"
#import "../Core/ScrobbleTrack.h"
#import "../LastFm/LastFmClient.h"
#import "../LastFm/LastFmAuth.h"
#import "../Services/ScrobbleService.h"

// Image cache for album artwork
@interface ScrobbleWidgetImageCache : NSObject
+ (instancetype)shared;
- (NSImage *)cachedImageForURL:(NSURL *)url;
- (void)cacheImage:(NSImage *)image forURL:(NSURL *)url;
- (void)clearCache;
@end

@implementation ScrobbleWidgetImageCache {
    NSCache<NSURL*, NSImage*> *_cache;
}

+ (instancetype)shared {
    static ScrobbleWidgetImageCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScrobbleWidgetImageCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 100;  // Increased for multiple pages
    }
    return self;
}

- (NSImage *)cachedImageForURL:(NSURL *)url {
    return [_cache objectForKey:url];
}

- (void)cacheImage:(NSImage *)image forURL:(NSURL *)url {
    if (image && url) {
        [_cache setObject:image forKey:url];
    }
}

- (void)clearCache {
    [_cache removeAllObjects];
}

@end

// Cached API result with timestamp
@interface ScrobbleWidgetCacheEntry : NSObject
@property (nonatomic, strong) NSArray<TopAlbum *> *albums;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, assign) NSInteger scrobbledToday;
@property (nonatomic, strong) NSDictionary<NSURL*, NSImage*> *albumImages;
@end

@implementation ScrobbleWidgetCacheEntry
@end

@interface ScrobbleWidgetController () <ScrobbleWidgetViewDelegate>
@property (nonatomic, strong) ScrobbleWidgetView *widgetView;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSMutableDictionary<NSURL*, NSImage*> *loadedImages;
@property (nonatomic, assign) BOOL isVisible;
@property (nonatomic, assign) ScrobbleChartPeriod currentPeriod;
@property (nonatomic, assign) ScrobbleChartType currentType;
@property (nonatomic, assign) ScrobbleWidgetViewMode currentViewMode;
@property (nonatomic, assign) NSInteger currentRecentTrackCount;
// API result cache keyed by "period_type" (e.g., "7day_albums")
@property (nonatomic, strong) NSMutableDictionary<NSString*, ScrobbleWidgetCacheEntry*> *resultCache;
// Streak discovery token for cancellation
@property (nonatomic, strong, nullable) NSUUID *streakDiscoveryToken;
// Debounce timer for post-scrobble recent tracks refresh
@property (nonatomic, strong, nullable) NSTimer *scrobbleRefreshDebounceTimer;
@end

@implementation ScrobbleWidgetController

- (void)pruneLoadedImagesToRecentTracks:(NSArray<RecentTrack *> *)tracks {
    if (_loadedImages.count == 0) return;

    NSMutableSet<NSURL *> *activeURLs = [NSMutableSet set];
    for (RecentTrack *track in tracks) {
        if (track.imageURL) {
            [activeURLs addObject:track.imageURL];
        }
    }

    if (activeURLs.count == 0) {
        [_loadedImages removeAllObjects];
        _widgetView.albumImages = nil;
        return;
    }

    NSArray<NSURL *> *allKeys = [_loadedImages allKeys];
    for (NSURL *url in allKeys) {
        if (![activeURLs containsObject:url]) {
            [_loadedImages removeObjectForKey:url];
        }
    }

    _widgetView.albumImages = (_loadedImages.count > 0) ? [_loadedImages copy] : nil;
}

- (instancetype)init {
    return [self initWithParameters:nil];
}

- (instancetype)initWithParameters:(NSDictionary<NSString*, NSString*>*)params {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _loadedImages = [NSMutableDictionary dictionary];
        _resultCache = [NSMutableDictionary dictionary];
        _currentPeriod = ScrobbleChartPeriodWeekly;
        _currentType = ScrobbleChartTypeAlbums;
        _currentViewMode = ScrobbleWidgetViewModeCharts;
        _currentRecentTrackCount = 10;
    }
    return self;
}

// Legacy accessor
- (ScrobbleChartPage)currentPage {
    return _currentPeriod;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refreshTimer invalidate];
    [_scrobbleRefreshDebounceTimer invalidate];
}

#pragma mark - View Lifecycle

- (void)loadView {
    _widgetView = [[ScrobbleWidgetView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
    _widgetView.delegate = self;
    _widgetView.maxAlbums = scrobble_config::getWidgetMaxAlbums();
    _widgetView.currentPeriod = _currentPeriod;
    _widgetView.currentType = _currentType;
    _widgetView.periodTitle = [ScrobbleWidgetView titleForPeriod:_currentPeriod];
    _widgetView.typeTitle = [ScrobbleWidgetView titleForType:_currentType];
    _widgetView.streakEnabled = scrobble_config::isStreakDisplayEnabled();

    // Set view mode from config
    std::string viewModeStr = scrobble_config::getWidgetViewMode();
    if (viewModeStr == "tracks") {
        _currentViewMode = ScrobbleWidgetViewModeTracks;
    } else {
        _currentViewMode = ScrobbleWidgetViewModeCharts;
    }
    _currentRecentTrackCount = scrobble_config::getWidgetRecentTrackCount();
    _widgetView.viewMode = _currentViewMode;
    _widgetView.viewModeTitle = [ScrobbleWidgetView titleForViewMode:_currentViewMode];
    _widgetView.recentTrackCount = _currentRecentTrackCount;

    // Set display style from config
    std::string styleStr = scrobble_config::getWidgetDisplayStyle();
    if (styleStr == "playback2025") {
        _widgetView.displayStyle = ScrobbleDisplayStylePlayback2025;
    } else {
        _widgetView.displayStyle = ScrobbleDisplayStyleDefault;
    }

    // Set background settings from config
    _widgetView.useGlassBackground = scrobble_config::isWidgetGlassBackground();
    int64_t bgColor = scrobble_config::getWidgetBackgroundColor();
    if (bgColor != 0) {
        _widgetView.backgroundColor = [self colorFromARGB:(uint32_t)bgColor];
    }

    // Don't set autoresizingMask - let foobar2000's layout system handle it
    // (matching AlbumArtController behavior which works correctly)

    self.view = _widgetView;

    NSLog(@"[ScrobbleWidget] loadView complete - view frame: %@", NSStringFromRect(_widgetView.frame));
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSLog(@"[ScrobbleWidget] viewDidLoad - view bounds: %@", NSStringFromRect(self.view.bounds));

    // Register for notifications
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authStateDidChange:)
                                                 name:LastFmAuthStateDidChangeNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrobbleServiceDidUpdate:)
                                                 name:ScrobbleServiceDidScrobbleNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scrobbleServiceDidUpdate:)
                                                 name:ScrobbleServiceStateDidChangeNotification
                                               object:nil];

    // Streak and count updates on scrobble
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleScrobbleSubmitted:)
                                                 name:ScrobbleServiceDidScrobbleNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAccountChanged:)
                                                 name:ScrobbleDidChangeAccountNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleSettingsChanged:)
                                                 name:ScrobbleSettingsDidChangeNotification
                                               object:nil];

    // Now Playing changes for live tracks list updates
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleNowPlayingChanged:)
                                                 name:ScrobbleServiceNowPlayingDidChangeNotification
                                               object:nil];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    _isVisible = YES;

    // Initial load
    [self updateAuthState];
    if ([[LastFmAuth shared] isAuthenticated]) {
        if (_currentViewMode == ScrobbleWidgetViewModeTracks) {
            [self fetchRecentTracks];
        } else {
            [self refreshStats];
        }
        [self startStreakDiscoveryIfNeeded];
    }

    // Start refresh timer
    [self startRefreshTimer];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    _isVisible = NO;

    // Stop refresh timer when not visible
    [self stopRefreshTimer];

    // Cancel debounce timer
    [_scrobbleRefreshDebounceTimer invalidate];
    _scrobbleRefreshDebounceTimer = nil;

    // Cancel in-progress streak discovery
    if (_streakDiscoveryToken) {
        [[LastFmClient shared] cancelStreakDiscovery:_streakDiscoveryToken];
        _streakDiscoveryToken = nil;
    }

    // Release per-view image references while hidden; global NSCache remains warm.
    [_loadedImages removeAllObjects];
    _widgetView.albumImages = nil;
}

#pragma mark - Timer Management

- (void)startRefreshTimer {
    [self stopRefreshTimer];

    NSInteger interval = scrobble_config::getWidgetRefreshInterval();
    if (interval > 0) {
        _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                         target:self
                                                       selector:@selector(refreshTimerFired:)
                                                       userInfo:nil
                                                        repeats:YES];
    }
}

- (void)stopRefreshTimer {
    [_refreshTimer invalidate];
    _refreshTimer = nil;
}

- (void)refreshTimerFired:(NSTimer *)timer {
    if (_isVisible && [[LastFmAuth shared] isAuthenticated]) {
        if (_currentViewMode == ScrobbleWidgetViewModeTracks) {
            [self fetchRecentTracks];
        } else {
            [self refreshStats];
        }
    }
}

#pragma mark - Notification Handlers

- (void)authStateDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAuthState];
        if ([[LastFmAuth shared] isAuthenticated]) {
            [self refreshStats];
        }
    });
}

- (void)scrobbleServiceDidUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateQueueStatus];
    });
}

#pragma mark - State Updates

- (void)updateAuthState {
    LastFmAuth *auth = [LastFmAuth shared];

    if (!auth.isAuthenticated) {
        _widgetView.state = ScrobbleWidgetStateNotAuth;
        _widgetView.username = nil;
        _widgetView.profileImage = nil;
        _widgetView.topAlbums = nil;
        [_widgetView refreshDisplay];
        return;
    }

    // Update profile info
    _widgetView.username = auth.username;
    _widgetView.profileImage = auth.profileImage;
}

- (void)updateQueueStatus {
    ScrobbleService *service = [ScrobbleService shared];
    _widgetView.queueCount = service.pendingCount + service.inFlightCount;
    [_widgetView refreshDisplay];
}

#pragma mark - Navigation

- (void)switchToPeriod:(ScrobbleChartPeriod)period {
    _currentPeriod = period;
    _widgetView.currentPeriod = period;
    _widgetView.periodTitle = [ScrobbleWidgetView titleForPeriod:period];

    // Keep existing content visible, show loading overlay
    _widgetView.isRefreshing = YES;
    [_widgetView refreshDisplay];

    [self refreshStatsKeepingContent:YES];
}

- (void)switchToType:(ScrobbleChartType)type {
    _currentType = type;
    _widgetView.currentType = type;
    _widgetView.typeTitle = [ScrobbleWidgetView titleForType:type];

    // Keep existing content visible, show loading overlay
    _widgetView.isRefreshing = YES;
    [_widgetView refreshDisplay];

    [self refreshStatsKeepingContent:YES];
}

// Legacy method
- (void)switchToPage:(ScrobbleChartPage)page {
    [self switchToPeriod:page];
}

- (void)switchToViewMode:(ScrobbleWidgetViewMode)mode {
    if (_currentViewMode == mode) return;

    _currentViewMode = mode;
    _widgetView.viewMode = mode;
    _widgetView.viewModeTitle = [ScrobbleWidgetView titleForViewMode:mode];

    scrobble_config::setWidgetViewMode(mode == ScrobbleWidgetViewModeTracks ? "tracks" : "charts");

    _widgetView.isRefreshing = YES;
    [_widgetView refreshDisplay];

    if (mode == ScrobbleWidgetViewModeTracks) {
        [self fetchRecentTracks];
    } else {
        [self refreshStatsKeepingContent:YES];
    }
}

- (void)switchToTrackCount:(NSInteger)count {
    if (_currentRecentTrackCount == count) return;

    _currentRecentTrackCount = count;
    _widgetView.recentTrackCount = count;

    scrobble_config::setWidgetRecentTrackCount(count);

    _widgetView.isRefreshing = YES;
    [_widgetView refreshDisplay];
    [self fetchRecentTracks];
}

- (void)fetchRecentTracks {
    LastFmAuth *auth = [LastFmAuth shared];
    if (!auth.isAuthenticated || !auth.username) {
        _widgetView.isRefreshing = NO;
        return;
    }

    NSInteger limit = _currentRecentTrackCount;

    [[LastFmClient shared] fetchRecentTracks:auth.username limit:limit
        completion:^(NSArray<RecentTrack *> *tracks, NSError *error) {
            self.widgetView.isRefreshing = NO;

            if (error) {
                if (self.widgetView.recentTracks.count == 0) {
                    self.widgetView.state = ScrobbleWidgetStateError;
                    self.widgetView.errorMessage = error.localizedDescription;
                }
                [self.widgetView refreshDisplay];
                return;
            }

            self.widgetView.errorMessage = nil;
            self.widgetView.recentTracks = tracks;
            self.widgetView.lastUpdated = [NSDate date];
            self.widgetView.state = (tracks.count > 0) ? ScrobbleWidgetStateReady : ScrobbleWidgetStateEmpty;

            // Prevent unbounded growth when new tracks/albums keep arriving over long sessions.
            [self pruneLoadedImagesToRecentTracks:tracks];

            [self loadRecentTrackImages:tracks];
            [self.widgetView refreshDisplay];
    }];
}

- (void)loadRecentTrackImages:(NSArray<RecentTrack *> *)tracks {
    for (RecentTrack *track in tracks) {
        if (!track.imageURL) continue;

        NSImage *cached = [[ScrobbleWidgetImageCache shared] cachedImageForURL:track.imageURL];
        if (cached) {
            [_loadedImages setObject:cached forKey:track.imageURL];
            continue;
        }

        NSURL *url = track.imageURL;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:url];
            if (data) {
                NSImage *image = [[NSImage alloc] initWithData:data];
                if (image) {
                    [[ScrobbleWidgetImageCache shared] cacheImage:image forURL:url];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        [strongSelf.loadedImages setObject:image forKey:url];
                        strongSelf.widgetView.albumImages = [strongSelf.loadedImages copy];
                        [strongSelf.widgetView refreshDisplay];
                    });
                }
            }
        });
    }

    if (_loadedImages.count > 0) {
        _widgetView.albumImages = [_loadedImages copy];
        [_widgetView refreshDisplay];
    }
}

#pragma mark - Cache Management

- (NSString *)cacheKeyForPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    NSString *periodStr = [ScrobbleWidgetView apiPeriodForPeriod:period];
    NSString *typeStr = [ScrobbleWidgetView titleForType:type];
    return [NSString stringWithFormat:@"%@_%@", periodStr, typeStr];
}

- (ScrobbleWidgetCacheEntry *)cachedEntryForPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    NSString *key = [self cacheKeyForPeriod:period type:type];
    ScrobbleWidgetCacheEntry *entry = _resultCache[key];

    if (!entry) {
        return nil;
    }

    // Check if cache is still valid
    NSTimeInterval cacheDuration = scrobble_config::getWidgetCacheDuration();
    NSTimeInterval age = [[NSDate date] timeIntervalSinceDate:entry.timestamp];

    if (age > cacheDuration) {
        // Cache expired
        [_resultCache removeObjectForKey:key];
        return nil;
    }

    return entry;
}

- (void)cacheEntry:(ScrobbleWidgetCacheEntry *)entry forPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    NSString *key = [self cacheKeyForPeriod:period type:type];
    _resultCache[key] = entry;
}

- (void)invalidateCache {
    [_resultCache removeAllObjects];
}

#pragma mark - Data Loading

- (void)refreshStats {
    [self refreshStatsKeepingContent:NO];
}

- (void)refreshStatsKeepingContent:(BOOL)keepContent {
    [self refreshStatsKeepingContent:keepContent forceRefresh:NO];
}

- (void)refreshStatsKeepingContent:(BOOL)keepContent forceRefresh:(BOOL)forceRefresh {
    if (!scrobble_config::isWidgetStatsEnabled()) {
        _widgetView.isRefreshing = NO;
        _widgetView.state = ScrobbleWidgetStateEmpty;
        [_widgetView refreshDisplay];
        return;
    }

    LastFmAuth *auth = [LastFmAuth shared];
    if (!auth.isAuthenticated || !auth.username) {
        _widgetView.isRefreshing = NO;
        _widgetView.state = ScrobbleWidgetStateNotAuth;
        [_widgetView refreshDisplay];
        return;
    }

    // Check cache first (unless force refresh)
    if (!forceRefresh) {
        ScrobbleWidgetCacheEntry *cached = [self cachedEntryForPeriod:_currentPeriod type:_currentType];
        if (cached) {
            NSLog(@"[ScrobbleWidget] Using cached data for %@", [self cacheKeyForPeriod:_currentPeriod type:_currentType]);
            _widgetView.isRefreshing = NO;
            _widgetView.topAlbums = cached.albums;
            _widgetView.scrobbledToday = cached.scrobbledToday;
            _widgetView.lastUpdated = cached.timestamp;
            _widgetView.albumImages = cached.albumImages;
            [_loadedImages removeAllObjects];
            if (cached.albumImages) {
                [_loadedImages addEntriesFromDictionary:cached.albumImages];
            }

            if (cached.albums.count > 0) {
                _widgetView.state = ScrobbleWidgetStateReady;
            } else {
                _widgetView.state = ScrobbleWidgetStateEmpty;
            }
            [_widgetView refreshDisplay];

            // Update queue status (always current)
            [self updateQueueStatus];
            return;
        }
    }

    // Only show full loading state if not keeping content
    if (!keepContent) {
        _widgetView.state = ScrobbleWidgetStateLoading;
        [_widgetView refreshDisplay];
    }

    NSString *username = auth.username;
    NSInteger maxAlbums = scrobble_config::getWidgetMaxAlbums();
    NSString *period = [ScrobbleWidgetView apiPeriodForPeriod:_currentPeriod];
    ScrobbleChartPeriod fetchPeriod = _currentPeriod;
    ScrobbleChartType fetchType = _currentType;

    // Fetch top items for current period and type
    LastFmTopAlbumsCompletion fetchCompletion = ^(NSArray<TopAlbum *> *albums, NSError *error) {
        // Clear refreshing state
        self.widgetView.isRefreshing = NO;

        if (error) {
            // Only show full-screen error if we have NO data at all
            if (self.widgetView.topAlbums.count == 0) {
                self.widgetView.state = ScrobbleWidgetStateError;
                self.widgetView.errorMessage = error.localizedDescription;
            } else {
                // Have data - show error in footer instead, keep showing data
                self.widgetView.state = ScrobbleWidgetStateReady;
                self.widgetView.errorMessage = [NSString stringWithFormat:@"Refresh failed: %@",
                    error.localizedDescription];
            }
            [self.widgetView refreshDisplay];
            return;
        }

        // Success - clear any previous error
        self.widgetView.errorMessage = nil;
        self.widgetView.topAlbums = albums;
        self.widgetView.lastUpdated = [NSDate date];

        if (albums.count > 0) {
            self.widgetView.state = ScrobbleWidgetStateReady;
        } else {
            self.widgetView.state = ScrobbleWidgetStateEmpty;
        }

        // Reset image state completely for new content
        [self.loadedImages removeAllObjects];
        self.widgetView.albumImages = nil;

        // Populate from cache and update view
        [self loadAlbumImages:albums forPeriod:fetchPeriod type:fetchType];

        // Display with whatever images we have from cache
        [self.widgetView refreshDisplay];
    };

    switch (fetchType) {
        case ScrobbleChartTypeArtists:
            [[LastFmClient shared] fetchTopArtists:username period:period limit:maxAlbums completion:fetchCompletion];
            break;
        case ScrobbleChartTypeTracks:
            [[LastFmClient shared] fetchTopTracks:username period:period limit:maxAlbums completion:fetchCompletion];
            break;
        case ScrobbleChartTypeAlbums:
        default:
            [[LastFmClient shared] fetchTopAlbums:username period:period limit:maxAlbums completion:fetchCompletion];
            break;
    }

    // Fetch scrobbled today count
    [self fetchScrobbledTodayCount:username forPeriod:fetchPeriod type:fetchType];

    // Update queue status
    [self updateQueueStatus];
}

- (void)fetchScrobbledTodayCount:(NSString *)username forPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    // Get midnight today (local time)
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *components = [calendar components:(NSCalendarUnitYear |
                                                         NSCalendarUnitMonth |
                                                         NSCalendarUnitDay)
                                               fromDate:now];
    NSDate *midnight = [calendar dateFromComponents:components];
    NSTimeInterval fromTimestamp = [midnight timeIntervalSince1970];

    [[LastFmClient shared] fetchRecentTracksCount:username
                                             from:fromTimestamp
                                       completion:^(NSInteger count, NSError *error) {
        if (!error) {
            self.widgetView.scrobbledToday = count;
            [self.widgetView refreshDisplay];

            // Update or create cache entry with scrobbled today count
            ScrobbleWidgetCacheEntry *entry = [self cachedEntryForPeriod:period type:type];
            if (entry) {
                entry.scrobbledToday = count;
            }
        }
    }];
}

- (void)loadAlbumImages:(NSArray<TopAlbum *> *)albums forPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    // Create cache entry for this fetch
    ScrobbleWidgetCacheEntry *cacheEntry = [[ScrobbleWidgetCacheEntry alloc] init];
    cacheEntry.albums = albums;
    cacheEntry.timestamp = [NSDate date];
    cacheEntry.scrobbledToday = _widgetView.scrobbledToday;
    [self cacheEntry:cacheEntry forPeriod:period type:type];

    BOOL needsArtistScraping = (type == ScrobbleChartTypeArtists);
    BOOL needsAlbumImageForTracks = (type == ScrobbleChartTypeTracks);

    for (TopAlbum *album in albums) {
        // For artists without API images, try scraping from website
        if (needsArtistScraping && !album.imageURL && album.artist.length > 0) {
            [self scrapeAndLoadArtistImage:album forPeriod:period type:type];
            continue;
        }

        // For tracks without API images, fetch track info to get album image
        // Note: user.getTopTracks doesn't return album info, so we need track.getInfo
        if (needsAlbumImageForTracks && !album.imageURL) {
            [self fetchTrackImageViaTrackInfo:album forPeriod:period type:type];
            continue;
        }

        if (!album.imageURL) continue;

        // Check cache first
        NSImage *cached = [[ScrobbleWidgetImageCache shared] cachedImageForURL:album.imageURL];
        if (cached) {
            [_loadedImages setObject:cached forKey:album.imageURL];
            continue;
        }

        // Load asynchronously
        NSURL *url = album.imageURL;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:url];
            if (data) {
                NSImage *image = [[NSImage alloc] initWithData:data];
                if (image) {
                    [[ScrobbleWidgetImageCache shared] cacheImage:image forURL:url];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.loadedImages setObject:image forKey:url];
                        self.widgetView.albumImages = [self.loadedImages copy];
                        [self.widgetView refreshDisplay];

                        // Update cache entry with loaded images
                        ScrobbleWidgetCacheEntry *entry = [self cachedEntryForPeriod:period type:type];
                        if (entry) {
                            entry.albumImages = [self.loadedImages copy];
                        }
                    });
                }
            }
        });
    }

    // Update view with any cached images
    if (_loadedImages.count > 0) {
        _widgetView.albumImages = [_loadedImages copy];
        [_widgetView refreshDisplay];

        // Update cache entry with loaded images
        cacheEntry.albumImages = [_loadedImages copy];
    }
}

- (void)scrapeAndLoadArtistImage:(TopAlbum *)album forPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    NSString *artistName = album.artist;
    if (!artistName || artistName.length == 0) return;

    [[LastFmClient shared] scrapeArtistImageURL:artistName completion:^(NSURL *imageURL, NSError *error) {
        if (!imageURL) return;

        // Store the scraped URL in the album object for future reference
        album.imageURL = imageURL;

        // Check if already in cache
        NSImage *cached = [[ScrobbleWidgetImageCache shared] cachedImageForURL:imageURL];
        if (cached) {
            [self.loadedImages setObject:cached forKey:imageURL];
            self.widgetView.albumImages = [self.loadedImages copy];
            [self.widgetView refreshDisplay];
            return;
        }

        // Load the image
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:imageURL];
            if (data) {
                NSImage *image = [[NSImage alloc] initWithData:data];
                if (image) {
                    [[ScrobbleWidgetImageCache shared] cacheImage:image forURL:imageURL];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.loadedImages setObject:image forKey:imageURL];
                        self.widgetView.albumImages = [self.loadedImages copy];
                        [self.widgetView refreshDisplay];

                        // Update cache entry
                        ScrobbleWidgetCacheEntry *entry = [self cachedEntryForPeriod:period type:type];
                        if (entry) {
                            entry.albumImages = [self.loadedImages copy];
                        }
                    });
                }
            }
        });
    }];
}

- (void)fetchTrackImageViaTrackInfo:(TopAlbum *)track forPeriod:(ScrobbleChartPeriod)period type:(ScrobbleChartType)type {
    NSString *artistName = track.artist;
    NSString *trackName = track.name;
    if (!artistName || artistName.length == 0 || !trackName || trackName.length == 0) return;

    // Use track.getInfo to get album name and image (user.getTopTracks doesn't provide album info)
    [[LastFmClient shared] fetchTrackInfo:artistName track:trackName completion:^(NSString *albumName, NSURL *imageURL, NSError *error) {
        if (!imageURL) return;

        // Store album name and image URL in the track object
        if (albumName) {
            track.albumName = albumName;
        }
        track.imageURL = imageURL;

        // Check if already in cache
        NSImage *cached = [[ScrobbleWidgetImageCache shared] cachedImageForURL:imageURL];
        if (cached) {
            [self.loadedImages setObject:cached forKey:imageURL];
            self.widgetView.albumImages = [self.loadedImages copy];
            [self.widgetView refreshDisplay];
            return;
        }

        // Load the image
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:imageURL];
            if (data) {
                NSImage *image = [[NSImage alloc] initWithData:data];
                if (image) {
                    [[ScrobbleWidgetImageCache shared] cacheImage:image forURL:imageURL];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.loadedImages setObject:image forKey:imageURL];
                        self.widgetView.albumImages = [self.loadedImages copy];
                        [self.widgetView refreshDisplay];

                        // Update cache entry
                        ScrobbleWidgetCacheEntry *entry = [self cachedEntryForPeriod:period type:type];
                        if (entry) {
                            entry.albumImages = [self.loadedImages copy];
                        }
                    });
                }
            }
        });
    }];
}

#pragma mark - ScrobbleWidgetViewDelegate

- (void)widgetViewRequestsRefresh:(ScrobbleWidgetView *)view {
    if (_currentViewMode == ScrobbleWidgetViewModeTracks) {
        _widgetView.isRefreshing = YES;
        [_widgetView refreshDisplay];
        [self fetchRecentTracks];
    } else {
        // User-initiated refresh bypasses cache
        [self refreshStatsKeepingContent:NO forceRefresh:YES];
    }
}

- (void)widgetViewNavigatePreviousPeriod:(ScrobbleWidgetView *)view {
    ScrobbleChartPeriod prev = (_currentPeriod == 0)
        ? (ScrobbleChartPeriod)(ScrobbleChartPeriodCount - 1)
        : (ScrobbleChartPeriod)(_currentPeriod - 1);
    [self switchToPeriod:prev];
}

- (void)widgetViewNavigateNextPeriod:(ScrobbleWidgetView *)view {
    ScrobbleChartPeriod next = (ScrobbleChartPeriod)((_currentPeriod + 1) % ScrobbleChartPeriodCount);
    [self switchToPeriod:next];
}

- (void)widgetViewNavigatePreviousType:(ScrobbleWidgetView *)view {
    ScrobbleChartType prev = (_currentType == 0)
        ? (ScrobbleChartType)(ScrobbleChartTypeCount - 1)
        : (ScrobbleChartType)(_currentType - 1);
    [self switchToType:prev];
}

- (void)widgetViewNavigateNextType:(ScrobbleWidgetView *)view {
    ScrobbleChartType next = (ScrobbleChartType)((_currentType + 1) % ScrobbleChartTypeCount);
    [self switchToType:next];
}

- (void)widgetView:(ScrobbleWidgetView *)view didSelectPeriod:(ScrobbleChartPeriod)period {
    [self switchToPeriod:period];
}

- (void)widgetView:(ScrobbleWidgetView *)view didSelectType:(ScrobbleChartType)type {
    [self switchToType:type];
}

- (void)widgetViewOpenLastFmProfile:(ScrobbleWidgetView *)view {
    LastFmAuth *auth = [LastFmAuth shared];
    if (auth.username.length > 0) {
        // Map current period to Last.fm date_preset parameter
        NSString *datePreset;
        switch (_currentPeriod) {
            case ScrobbleChartPeriodWeekly:
                datePreset = @"LAST_7_DAYS";
                break;
            case ScrobbleChartPeriodMonthly:
                datePreset = @"LAST_30_DAYS";
                break;
            case ScrobbleChartPeriodOverall:
            default:
                datePreset = @"ALL";
                break;
        }

        // Map current type to Last.fm library path
        NSString *typePath;
        switch (_currentType) {
            case ScrobbleChartTypeArtists:
                typePath = @"artists";
                break;
            case ScrobbleChartTypeTracks:
                typePath = @"tracks";
                break;
            case ScrobbleChartTypeAlbums:
            default:
                typePath = @"albums";
                break;
        }

        // Open the user's library page on Last.fm with correct date preset and type
        NSString *urlString = [NSString stringWithFormat:@"https://www.last.fm/user/%@/library/%@?date_preset=%@",
                               [auth.username stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]],
                               typePath,
                               datePreset];
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }
}

- (void)widgetView:(ScrobbleWidgetView *)view didClickAlbumAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_widgetView.topAlbums.count) {
        return;
    }

    TopAlbum *album = _widgetView.topAlbums[index];
    if (album.lastfmURL) {
        [[NSWorkspace sharedWorkspace] openURL:album.lastfmURL];
    } else if (album.artist.length > 0 && album.name.length > 0) {
        // Construct URL manually if not available
        NSString *artistEncoded = [album.artist stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *albumEncoded = [album.name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        NSString *urlString = [NSString stringWithFormat:@"https://www.last.fm/music/%@/%@", artistEncoded, albumEncoded];
        NSURL *url = [NSURL URLWithString:urlString];
        if (url) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }
}

- (void)widgetView:(ScrobbleWidgetView *)view didSelectViewMode:(ScrobbleWidgetViewMode)mode {
    [self switchToViewMode:mode];
}

- (void)widgetView:(ScrobbleWidgetView *)view didSelectTrackCount:(NSInteger)count {
    [self switchToTrackCount:count];
}

- (void)widgetViewNavigatePreviousViewMode:(ScrobbleWidgetView *)view {
    ScrobbleWidgetViewMode prev = (_currentViewMode == 0)
        ? (ScrobbleWidgetViewMode)(ScrobbleWidgetViewModeCount - 1)
        : (ScrobbleWidgetViewMode)(_currentViewMode - 1);
    [self switchToViewMode:prev];
}

- (void)widgetViewNavigateNextViewMode:(ScrobbleWidgetView *)view {
    ScrobbleWidgetViewMode next = (ScrobbleWidgetViewMode)((_currentViewMode + 1) % ScrobbleWidgetViewModeCount);
    [self switchToViewMode:next];
}

- (void)widgetView:(ScrobbleWidgetView *)view didClickRecentTrackAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_widgetView.recentTracks.count) return;

    RecentTrack *track = _widgetView.recentTracks[index];
    if (track.lastfmURL) {
        [[NSWorkspace sharedWorkspace] openURL:track.lastfmURL];
    }
}

- (void)widgetViewRequestsContextMenu:(ScrobbleWidgetView *)view atPoint:(NSPoint)point {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Last.fm Widget"];

    // Chart period submenu
    NSMenuItem *periodItem = [[NSMenuItem alloc] initWithTitle:@"Chart Period"
                                                        action:nil
                                                 keyEquivalent:@""];
    NSMenu *periodSubmenu = [[NSMenu alloc] init];

    NSMenuItem *weeklyItem = [[NSMenuItem alloc] initWithTitle:@"Weekly"
                                                        action:@selector(menuSelectWeekly:)
                                                 keyEquivalent:@""];
    weeklyItem.target = self;
    weeklyItem.state = (_currentPeriod == ScrobbleChartPeriodWeekly) ? NSControlStateValueOn : NSControlStateValueOff;
    [periodSubmenu addItem:weeklyItem];

    NSMenuItem *monthlyItem = [[NSMenuItem alloc] initWithTitle:@"Monthly"
                                                         action:@selector(menuSelectMonthly:)
                                                  keyEquivalent:@""];
    monthlyItem.target = self;
    monthlyItem.state = (_currentPeriod == ScrobbleChartPeriodMonthly) ? NSControlStateValueOn : NSControlStateValueOff;
    [periodSubmenu addItem:monthlyItem];

    NSMenuItem *overallItem = [[NSMenuItem alloc] initWithTitle:@"All Time"
                                                         action:@selector(menuSelectOverall:)
                                                  keyEquivalent:@""];
    overallItem.target = self;
    overallItem.state = (_currentPeriod == ScrobbleChartPeriodOverall) ? NSControlStateValueOn : NSControlStateValueOff;
    [periodSubmenu addItem:overallItem];

    periodItem.submenu = periodSubmenu;
    [menu addItem:periodItem];

    // Display style submenu
    NSMenuItem *styleItem = [[NSMenuItem alloc] initWithTitle:@"Display Style"
                                                       action:nil
                                                keyEquivalent:@""];
    NSMenu *styleSubmenu = [[NSMenu alloc] init];

    std::string currentStyle = scrobble_config::getWidgetDisplayStyle();

    NSMenuItem *defaultStyleItem = [[NSMenuItem alloc] initWithTitle:@"Grid (Default)"
                                                              action:@selector(menuSelectDefaultStyle:)
                                                       keyEquivalent:@""];
    defaultStyleItem.target = self;
    defaultStyleItem.state = (currentStyle != "playback2025") ? NSControlStateValueOn : NSControlStateValueOff;
    [styleSubmenu addItem:defaultStyleItem];

    NSMenuItem *bubbleStyleItem = [[NSMenuItem alloc] initWithTitle:@"Bubbles (Playback 2025)"
                                                             action:@selector(menuSelectBubbleStyle:)
                                                      keyEquivalent:@""];
    bubbleStyleItem.target = self;
    bubbleStyleItem.state = (currentStyle == "playback2025") ? NSControlStateValueOn : NSControlStateValueOff;
    [styleSubmenu addItem:bubbleStyleItem];

    styleItem.submenu = styleSubmenu;
    [menu addItem:styleItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Refresh
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh Now"
                                                         action:@selector(menuRefresh:)
                                                  keyEquivalent:@""];
    refreshItem.target = self;
    [menu addItem:refreshItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Stats enabled toggle
    NSMenuItem *statsItem = [[NSMenuItem alloc] initWithTitle:@"Show Stats"
                                                       action:@selector(menuToggleStats:)
                                                keyEquivalent:@""];
    statsItem.target = self;
    statsItem.state = scrobble_config::isWidgetStatsEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:statsItem];

    [menu popUpMenuPositioningItem:nil atLocation:point inView:view];
}

#pragma mark - Menu Actions

- (void)menuRefresh:(id)sender {
    // Menu-initiated refresh bypasses cache
    [self refreshStatsKeepingContent:NO forceRefresh:YES];
}

- (void)menuToggleStats:(id)sender {
    bool current = scrobble_config::isWidgetStatsEnabled();
    scrobble_config::setWidgetStatsEnabled(!current);
    [self refreshStats];
}

- (void)menuSelectWeekly:(id)sender {
    [self switchToPage:ScrobbleChartPageWeekly];
}

- (void)menuSelectMonthly:(id)sender {
    [self switchToPage:ScrobbleChartPageMonthly];
}

- (void)menuSelectOverall:(id)sender {
    [self switchToPage:ScrobbleChartPageOverall];
}

- (void)menuSelectDefaultStyle:(id)sender {
    scrobble_config::setWidgetDisplayStyle("default");
    [_widgetView setDisplayStyle:ScrobbleDisplayStyleDefault animated:YES];
}

- (void)menuSelectBubbleStyle:(id)sender {
    scrobble_config::setWidgetDisplayStyle("playback2025");
    [_widgetView setDisplayStyle:ScrobbleDisplayStylePlayback2025 animated:YES];
}

#pragma mark - Streak Management

- (void)startStreakDiscoveryIfNeeded {
    LastFmAuth *auth = [LastFmAuth shared];
    if (!auth.isAuthenticated || !auth.username) {
        return;
    }

    ScrobbleStreakCache *cache = [ScrobbleStreakCache shared];

    // Update display with cached values first
    [self updateStreakDisplay];

    // Check if we need to start discovery
    if (![cache needsMoreDiscovery] && [cache isValid]) {
        NSLog(@"[ScrobbleWidget] Streak cache valid, skipping discovery");
        return;
    }

    // Don't start if already running
    if (_streakDiscoveryToken) {
        NSLog(@"[ScrobbleWidget] Streak discovery already in progress");
        return;
    }

    NSLog(@"[ScrobbleWidget] Starting streak discovery for %@", auth.username);
    cache.discoveryInProgress = YES;
    [cache setDiscoveryToken:nil];  // Will be set when we get the token

    __weak typeof(self) weakSelf = self;
    _streakDiscoveryToken = [[LastFmClient shared] startStreakDiscovery:auth.username
        progress:^(NSInteger currentStreak, BOOL isComplete, NSInteger daysChecked) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            // Update cache with progress
            ScrobbleStreakCache *progressCache = [ScrobbleStreakCache shared];
            progressCache.streakDays = currentStreak;
            progressCache.lastCheckedDay = daysChecked;

            // Update UI
            [strongSelf updateStreakDisplay];
        }
        completion:^(NSInteger streakDays, BOOL scrobbledToday, BOOL isComplete,
                    NSDate * _Nullable calculatedAt, NSError * _Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.streakDiscoveryToken = nil;

            ScrobbleStreakCache *completeCache = [ScrobbleStreakCache shared];
            completeCache.discoveryInProgress = NO;
            [completeCache setDiscoveryToken:nil];

            if (error && error.code != NSUserCancelledError) {
                NSLog(@"[ScrobbleWidget] Streak discovery error: %@", error.localizedDescription);
                // Keep any partial results, just stop discovery state
            } else if (!error) {
                NSLog(@"[ScrobbleWidget] Streak discovery complete: %ld days, scrobbledToday=%d, complete=%d",
                      (long)streakDays, scrobbledToday, isComplete);

                completeCache.streakDays = streakDays;
                completeCache.scrobbledToday = scrobbledToday;
                completeCache.isDiscoveryComplete = isComplete;
                completeCache.calculatedAt = calculatedAt;

                // Store current timezone for validity checking
                completeCache.calculatedTimezone = [NSTimeZone localTimeZone];

                // Calculate today midnight for day rollover detection
                NSCalendar *calendar = [NSCalendar currentCalendar];
                NSDateComponents *components = [calendar components:(NSCalendarUnitYear |
                                                                     NSCalendarUnitMonth |
                                                                     NSCalendarUnitDay)
                                                           fromDate:[NSDate date]];
                completeCache.todayMidnight = [calendar dateFromComponents:components];
            }

            [strongSelf updateStreakDisplay];
        }];

    // Store token in cache for external cancellation reference
    [cache setDiscoveryToken:_streakDiscoveryToken];
}

- (void)handleScrobbleSubmitted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Optimistic update: user just scrobbled, so they've scrobbled today
        ScrobbleStreakCache *cache = [ScrobbleStreakCache shared];

        if (!cache.scrobbledToday) {
            // Was at risk, now saved - streak continues
            cache.scrobbledToday = YES;
            NSLog(@"[ScrobbleWidget] Optimistic streak update: user scrobbled today");
        }

        // Increment scrobbled today count
        // Check if notification has accepted count (from ScrobbleServiceDidScrobbleNotification)
        NSNumber *accepted = notification.userInfo[@"accepted"];
        if (accepted) {
            self.widgetView.scrobbledToday += [accepted integerValue];
            NSLog(@"[ScrobbleWidget] Scrobbled today: %ld (+%ld)",
                  (long)self.widgetView.scrobbledToday, (long)[accepted integerValue]);
        } else {
            // Fallback: assume 1 track
            self.widgetView.scrobbledToday += 1;
        }

        [self updateStreakDisplay];
        [self.widgetView refreshDisplay];

        // Schedule debounced recent tracks refresh (only in tracks mode)
        if (self.currentViewMode == ScrobbleWidgetViewModeTracks && self.isVisible) {
            [self.scrobbleRefreshDebounceTimer invalidate];
            self.scrobbleRefreshDebounceTimer =
                [NSTimer scheduledTimerWithTimeInterval:15.0
                                                target:self
                                              selector:@selector(debouncedScrobbleRefresh)
                                              userInfo:nil
                                               repeats:NO];
        }
    });
}

- (void)handleNowPlayingChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Only update if in tracks view mode and visible
        if (self.currentViewMode != ScrobbleWidgetViewModeTracks || !self.isVisible) return;

        ScrobbleTrack *track = notification.userInfo[@"track"];
        NSMutableArray<RecentTrack *> *tracks =
            [self.widgetView.recentTracks mutableCopy] ?: [NSMutableArray new];

        // Remove any existing now-playing entry
        NSIndexSet *nowPlayingIndices = [tracks indexesOfObjectsPassingTest:
            ^BOOL(RecentTrack *t, NSUInteger idx, BOOL *stop) {
                return t.isNowPlaying;
            }];
        [tracks removeObjectsAtIndexes:nowPlayingIndices];

        // Insert new now-playing entry at top (if track provided)
        if (track) {
            RecentTrack *npTrack = [RecentTrack trackFromScrobbleTrack:track];
            [tracks insertObject:npTrack atIndex:0];
        }

        self.widgetView.recentTracks = tracks;
        [self.widgetView refreshDisplay];
    });
}

- (void)debouncedScrobbleRefresh {
    _scrobbleRefreshDebounceTimer = nil;
    [self fetchRecentTracks];
}

- (void)handleAccountChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Cancel any in-progress discovery
        if (self.streakDiscoveryToken) {
            [[LastFmClient shared] cancelStreakDiscovery:self.streakDiscoveryToken];
            self.streakDiscoveryToken = nil;
        }

        // Invalidate streak cache
        [[ScrobbleStreakCache shared] invalidate];

        // Clear streak display
        self.widgetView.streakDays = 0;
        self.widgetView.streakNeedsContinuation = NO;
        self.widgetView.streakDiscoveryInProgress = NO;
        self.widgetView.streakDaysChecked = 0;
        [self.widgetView refreshDisplay];

        // Start fresh discovery if still authenticated
        if ([[LastFmAuth shared] isAuthenticated]) {
            [self startStreakDiscoveryIfNeeded];
        }
    });
}

- (void)updateStreakDisplay {
    ScrobbleStreakCache *cache = [ScrobbleStreakCache shared];

    _widgetView.streakDays = cache.streakDays;
    _widgetView.streakNeedsContinuation = (!cache.scrobbledToday && cache.streakDays > 0);
    _widgetView.streakDiscoveryInProgress = cache.discoveryInProgress;
    _widgetView.streakDaysChecked = cache.lastCheckedDay;

    [_widgetView refreshDisplay];
}

- (void)handleSettingsChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *setting = notification.userInfo[@"setting"];

        if ([setting isEqualToString:@"displayStyle"]) {
            // Update display style with animation
            std::string styleStr = scrobble_config::getWidgetDisplayStyle();
            ScrobbleDisplayStyle newStyle = (styleStr == "playback2025")
                ? ScrobbleDisplayStylePlayback2025
                : ScrobbleDisplayStyleDefault;
            [self.widgetView setDisplayStyle:newStyle animated:YES];
        } else if ([setting isEqualToString:@"streakDisplay"]) {
            // Update streak display
            self.widgetView.streakEnabled = scrobble_config::isStreakDisplayEnabled();
            [self.widgetView refreshDisplay];
        } else if ([setting isEqualToString:@"glassBackground"]) {
            // Update glass background
            self.widgetView.useGlassBackground = scrobble_config::isWidgetGlassBackground();
            [self.widgetView refreshDisplay];
        } else if ([setting isEqualToString:@"backgroundColor"]) {
            // Update background color
            int64_t argb = scrobble_config::getWidgetBackgroundColor();
            if (argb != 0) {
                self.widgetView.backgroundColor = [self colorFromARGB:(uint32_t)argb];
            } else {
                self.widgetView.backgroundColor = nil;  // Use system default
            }
            [self.widgetView refreshDisplay];
        }
    });
}

#pragma mark - Color Conversion

- (NSColor *)colorFromARGB:(uint32_t)argb {
    return [NSColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:((argb >> 24) & 0xFF) / 255.0];
}

@end
