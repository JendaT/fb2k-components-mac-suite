//
//  ScrobbleWidgetController.mm
//  foo_jl_scrobble_mac
//
//  Controller for the Last.fm stats layout widget
//

#import "ScrobbleWidgetController.h"
#import "ScrobbleWidgetView.h"
#import "../Core/ScrobbleConfig.h"
#import "../Core/TopAlbum.h"
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

@interface ScrobbleWidgetController () <ScrobbleWidgetViewDelegate>
@property (nonatomic, strong) ScrobbleWidgetView *widgetView;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) NSMutableDictionary<NSURL*, NSImage*> *loadedImages;
@property (nonatomic, assign) BOOL isVisible;
@property (nonatomic, assign) ScrobbleChartPeriod currentPeriod;
@property (nonatomic, assign) ScrobbleChartType currentType;
@end

@implementation ScrobbleWidgetController

- (instancetype)init {
    return [self initWithParameters:nil];
}

- (instancetype)initWithParameters:(NSDictionary<NSString*, NSString*>*)params {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _loadedImages = [NSMutableDictionary dictionary];
        _currentPeriod = ScrobbleChartPeriodWeekly;
        _currentType = ScrobbleChartTypeAlbums;
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
}

- (void)viewWillAppear {
    [super viewWillAppear];
    _isVisible = YES;

    // Initial load
    [self updateAuthState];
    if ([[LastFmAuth shared] isAuthenticated]) {
        [self refreshStats];
    }

    // Start refresh timer
    [self startRefreshTimer];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    _isVisible = NO;

    // Stop refresh timer when not visible
    [self stopRefreshTimer];
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
        [self refreshStats];
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

- (void)navigateToPreviousPeriod {
    NSInteger index = (NSInteger)_currentPeriod - 1;
    if (index < 0) {
        index = ScrobbleChartPeriodCount - 1;
    }
    [self switchToPeriod:(ScrobbleChartPeriod)index];
}

- (void)navigateToNextPeriod {
    NSInteger index = (NSInteger)_currentPeriod + 1;
    if (index >= ScrobbleChartPeriodCount) {
        index = 0;
    }
    [self switchToPeriod:(ScrobbleChartPeriod)index];
}

- (void)switchToPeriod:(ScrobbleChartPeriod)period {
    _currentPeriod = period;
    _widgetView.currentPeriod = period;
    _widgetView.periodTitle = [ScrobbleWidgetView titleForPeriod:period];

    // Keep existing content visible, show loading overlay
    _widgetView.isRefreshing = YES;
    [_widgetView refreshDisplay];

    [self refreshStatsKeepingContent:YES];
}

- (void)navigateToPreviousType {
    NSInteger index = (NSInteger)_currentType - 1;
    if (index < 0) {
        index = ScrobbleChartTypeCount - 1;
    }
    [self switchToType:(ScrobbleChartType)index];
}

- (void)navigateToNextType {
    NSInteger index = (NSInteger)_currentType + 1;
    if (index >= ScrobbleChartTypeCount) {
        index = 0;
    }
    [self switchToType:(ScrobbleChartType)index];
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

#pragma mark - Data Loading

- (void)refreshStats {
    [self refreshStatsKeepingContent:NO];
}

- (void)refreshStatsKeepingContent:(BOOL)keepContent {
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

    // Only show full loading state if not keeping content
    if (!keepContent) {
        _widgetView.state = ScrobbleWidgetStateLoading;
        [_widgetView refreshDisplay];
    }

    NSString *username = auth.username;
    NSInteger maxAlbums = scrobble_config::getWidgetMaxAlbums();
    NSString *period = [ScrobbleWidgetView apiPeriodForPeriod:_currentPeriod];

    // TODO: Support Artists and Tracks types - for now always fetch albums
    // Fetch top albums for current period
    [[LastFmClient shared] fetchTopAlbums:username
                                   period:period
                                    limit:maxAlbums
                               completion:^(NSArray<TopAlbum *> *albums, NSError *error) {
        // Clear refreshing state
        self.widgetView.isRefreshing = NO;

        if (error) {
            self.widgetView.state = ScrobbleWidgetStateError;
            self.widgetView.errorMessage = error.localizedDescription;
            [self.widgetView refreshDisplay];
            return;
        }

        // Clear old images when content changes
        [self.loadedImages removeAllObjects];
        self.widgetView.albumImages = nil;

        self.widgetView.topAlbums = albums;
        self.widgetView.lastUpdated = [NSDate date];

        if (albums.count > 0) {
            self.widgetView.state = ScrobbleWidgetStateReady;
        } else {
            self.widgetView.state = ScrobbleWidgetStateEmpty;
        }

        [self.widgetView refreshDisplay];

        // Load album images asynchronously
        [self loadAlbumImages:albums];
    }];

    // Fetch scrobbled today count
    [self fetchScrobbledTodayCount:username];

    // Update queue status
    [self updateQueueStatus];
}

- (void)fetchScrobbledTodayCount:(NSString *)username {
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
        }
    }];
}

- (void)loadAlbumImages:(NSArray<TopAlbum *> *)albums {
    for (TopAlbum *album in albums) {
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
                    });
                }
            }
        });
    }

    // Update view with any cached images
    if (_loadedImages.count > 0) {
        _widgetView.albumImages = [_loadedImages copy];
        [_widgetView refreshDisplay];
    }
}

#pragma mark - ScrobbleWidgetViewDelegate

- (void)widgetViewRequestsRefresh:(ScrobbleWidgetView *)view {
    [self refreshStats];
}

- (void)widgetViewNavigatePreviousPeriod:(ScrobbleWidgetView *)view {
    [self navigateToPreviousPeriod];
}

- (void)widgetViewNavigateNextPeriod:(ScrobbleWidgetView *)view {
    [self navigateToNextPeriod];
}

- (void)widgetViewNavigatePreviousType:(ScrobbleWidgetView *)view {
    [self navigateToPreviousType];
}

- (void)widgetViewNavigateNextType:(ScrobbleWidgetView *)view {
    [self navigateToNextType];
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
    [self refreshStats];
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

@end
