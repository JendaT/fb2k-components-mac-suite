//
//  BiographyController.mm
//  foo_jl_biography_mac
//
//  Main controller implementation
//

#import "BiographyController.h"
#import "../Core/BiographyCallbackManager.h"
#import "../Core/BiographyData.h"
#import "../Core/BiographyRequest.h"
#import "../Core/BiographyFetcher.h"
#import "../Core/ArtistGalleryCoordinator.h"
#import "../Core/ArtistGalleryData.h"
#import "../Core/ArtistImage.h"
#import "BiographyContentView.h"
#import "BiographyLoadingView.h"
#import "BiographyErrorView.h"
#import "BiographyEmptyView.h"
#import "LightboxWindowController.h"
#import <QuartzCore/QuartzCore.h>

// Debounce delay for rapid track changes (in seconds)
static const NSTimeInterval kDebounceDelay = 0.3;

@interface BiographyController () <BiographyErrorViewDelegate, BiographyContentViewDelegate, ArtistGalleryCoordinatorDelegate>

// State views
@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) BiographyContentView *contentView;
@property (nonatomic, strong) BiographyLoadingView *loadingView;
@property (nonatomic, strong) BiographyErrorView *errorView;
@property (nonatomic, strong) BiographyEmptyView *emptyView;

// Current state
@property (nonatomic, assign, readwrite) BiographyViewState viewState;
@property (nonatomic, copy, readwrite, nullable) NSString *currentArtist;
@property (nonatomic, strong, readwrite, nullable) BiographyData *biographyData;

// Debouncing
@property (nonatomic, strong, nullable) NSTimer *debounceTimer;
@property (nonatomic, copy, nullable) NSString *pendingArtist;

// Current request (for cancellation)
@property (nonatomic, strong, nullable) BiographyRequest *currentRequest;

// Layout parameters
@property (nonatomic, copy, nullable) NSString *displayMode;

// Gallery coordinator
@property (nonatomic, strong) ArtistGalleryCoordinator *galleryCoordinator;

// Lightbox (retained while showing)
@property (nonatomic, strong, nullable) LightboxWindowController *lightboxController;

@end

@implementation BiographyController

- (instancetype)init {
    return [self initWithParameters:nil];
}

- (instancetype)initWithParameters:(NSDictionary<NSString*, NSString*>*)params {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _viewState = (BiographyViewState)-1;  // Uninitialized - forces first transition
        _displayMode = params[@"mode"] ?: @"full";
    }
    return self;
}

- (void)dealloc {
    [self.debounceTimer invalidate];
    [[BiographyFetcher shared] cancelCurrentRequest];
    [self.galleryCoordinator cancelCurrentFetch];
    BiographyCallbackManager::instance().unregisterController(self);
}

- (void)loadView {
    // Create container view with zero frame - parent will set the size
    self.containerView = [[NSView alloc] initWithFrame:NSZeroRect];

    // Create state views with zero frame
    self.contentView = [[BiographyContentView alloc] initWithFrame:NSZeroRect];
    self.contentView.delegate = self;
    self.loadingView = [[BiographyLoadingView alloc] initWithFrame:NSZeroRect];
    self.errorView = [[BiographyErrorView alloc] initWithFrame:NSZeroRect];
    self.errorView.delegate = self;
    self.emptyView = [[BiographyEmptyView alloc] initWithFrame:NSZeroRect];

    // Create gallery coordinator
    self.galleryCoordinator = [[ArtistGalleryCoordinator alloc] init];
    self.galleryCoordinator.delegate = self;

    // Configure autoresizing - views should resize with container
    NSAutoresizingMaskOptions resizing = NSViewWidthSizable | NSViewHeightSizable;
    self.containerView.autoresizingMask = resizing;
    self.contentView.autoresizingMask = resizing;
    self.loadingView.autoresizingMask = resizing;
    self.errorView.autoresizingMask = resizing;
    self.emptyView.autoresizingMask = resizing;

    // Hide all views initially
    self.contentView.hidden = YES;
    self.loadingView.hidden = YES;
    self.errorView.hidden = YES;
    self.emptyView.hidden = YES;

    // Add all views to container (only one visible at a time)
    [self.containerView addSubview:self.contentView];
    [self.containerView addSubview:self.loadingView];
    [self.containerView addSubview:self.errorView];
    [self.containerView addSubview:self.emptyView];

    self.view = self.containerView;

    // Show empty state initially
    [self transitionToState:BiographyViewStateEmpty];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Register for playback callbacks - will update when playback starts
    BiographyCallbackManager::instance().registerController(self);

    // Don't attempt to load anything on startup - just show empty state
    // and wait for playback events. This prevents layout issues.
}

#pragma mark - State Management

- (void)transitionToState:(BiographyViewState)newState {
    if (self.viewState == newState) return;

    self.viewState = newState;

    // Disable implicit animations to prevent UI blinking
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    // Hide all views
    self.contentView.hidden = YES;
    self.loadingView.hidden = YES;
    self.errorView.hidden = YES;
    self.emptyView.hidden = YES;

    // Show appropriate view
    switch (newState) {
        case BiographyViewStateEmpty:
            self.emptyView.hidden = NO;
            break;
        case BiographyViewStateLoading:
            self.loadingView.hidden = NO;
            [self.loadingView startAnimating];
            break;
        case BiographyViewStateContent:
            self.contentView.hidden = NO;
            break;
        case BiographyViewStateError:
            self.errorView.hidden = NO;
            break;
        case BiographyViewStateOffline:
            // Show content with offline indicator
            self.contentView.hidden = NO;
            break;
    }

    // Stop loading animation when not loading
    if (newState != BiographyViewStateLoading) {
        [self.loadingView stopAnimating];
    }

    [CATransaction commit];
}

#pragma mark - Artist Change Handling

- (void)handleArtistChange:(NSString *)artistName {
    if (!artistName || artistName.length == 0) {
        [self handlePlaybackStop];
        return;
    }

    // Check if same artist (no need to refetch)
    if ([artistName isEqualToString:self.currentArtist]) {
        return;
    }

    // Debounce rapid changes
    self.pendingArtist = artistName;
    [self.debounceTimer invalidate];

    // QUAL-14: Block-based timer avoids retaining self as target
    __weak typeof(self) weakSelf = self;
    self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:kDebounceDelay
                                                         repeats:NO
                                                           block:^(NSTimer * _Nonnull timer) {
        [weakSelf processPendingArtist];
    }];
}

- (void)processPendingArtist {
    NSString *artistName = self.pendingArtist;
    self.pendingArtist = nil;

    if (!artistName) return;

    // ARCH-5: Cancel via fetcher (single authoritative token system)
    [[BiographyFetcher shared] cancelCurrentRequest];

    // Update current artist
    self.currentArtist = artistName;

    // Show loading state
    [self transitionToState:BiographyViewStateLoading];
    [self.loadingView setArtistName:artistName];

    // Create request token for staleness checking in completion block
    self.currentRequest = [[BiographyRequest alloc] initWithArtistName:artistName];

    [self fetchBiographyForRequest:self.currentRequest force:NO];
}

- (void)handlePlaybackStop {
    [self.debounceTimer invalidate];
    self.debounceTimer = nil;
    self.pendingArtist = nil;

    [[BiographyFetcher shared] cancelCurrentRequest];
    self.currentRequest = nil;

    self.currentArtist = nil;
    self.biographyData = nil;

    [self transitionToState:BiographyViewStateEmpty];
}

#pragma mark - Fetching

- (void)fetchBiographyForRequest:(BiographyRequest *)request force:(BOOL)force {
    // QUAL-2: Use weak/strong dance to prevent retain cycle through singleton
    __weak typeof(self) weakSelf = self;
    [[BiographyFetcher shared] fetchBiographyForArtist:request.artistName
                                                 force:force
                                            completion:^(BiographyData * _Nullable data, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Check if this request is still current
        if (strongSelf.currentRequest != request || request.isCancelled) {
            return;
        }

        if (error) {
            if (error.code == BiographyFetcherErrorCodeCancelled) {
                return;
            }

            NSString *errorMessage = @"Unable to load biography";
            NSString *errorDetail = error.localizedDescription;

            if (error.code == BiographyFetcherErrorCodeArtistNotFound) {
                errorMessage = @"Artist not found";
                errorDetail = [NSString stringWithFormat:@"No biography found for %@", request.artistName];
            } else if (error.code == BiographyFetcherErrorCodeNetworkError) {
                errorDetail = @"Check your internet connection and try again.";
            }

            [strongSelf.errorView setErrorMessage:errorMessage];
            [strongSelf.errorView setErrorDetail:errorDetail];
            [strongSelf transitionToState:BiographyViewStateError];
            return;
        }

        // QUAL-13: No biography is not an error - show empty state
        if (!data || !data.hasBiography) {
            [strongSelf transitionToState:BiographyViewStateEmpty];
            return;
        }

        // Success - update UI
        strongSelf.biographyData = data;
        [strongSelf.contentView updateWithBiographyData:data];

        if (data.isStale) {
            [strongSelf transitionToState:BiographyViewStateOffline];
        } else {
            [strongSelf transitionToState:BiographyViewStateContent];
        }

        // Fetch gallery images after biography loads
        [strongSelf fetchGalleryImagesForData:data];
    }];
}

- (void)fetchGalleryImagesForData:(BiographyData *)data {
    if (!data || !data.artistName) {
        NSLog(@"[Gallery] fetchGalleryImagesForData: No data or artist name");
        return;
    }

    NSLog(@"[Gallery] Fetching gallery for: %@ (mbid: %@, fallback: %@)",
          data.artistName, data.musicBrainzId ?: @"nil", data.artistImageURL ? @"yes" : @"no");

    // Show loading state in gallery
    [self.contentView setGalleryLoading:YES];

    // Fetch from FanartTV + AudioDB, with Last.fm image as fallback
    [self.galleryCoordinator fetchImagesForArtist:data.artistName
                                             mbid:data.musicBrainzId
                                 fallbackImageURL:data.artistImageURL];
}

- (void)forceRefresh {
    if (self.currentArtist) {
        [[BiographyFetcher shared] cancelCurrentRequest];
        self.currentRequest = [[BiographyRequest alloc] initWithArtistName:self.currentArtist];
        [self transitionToState:BiographyViewStateLoading];
        [self.loadingView setArtistName:self.currentArtist];
        [self fetchBiographyForRequest:self.currentRequest force:YES];
    }
}

- (void)retryFetch {
    [self forceRefresh];
}

#pragma mark - BiographyErrorViewDelegate

- (void)errorViewDidTapRetry:(BiographyErrorView *)errorView {
    [self retryFetch];
}

#pragma mark - ArtistGalleryCoordinatorDelegate

- (void)coordinator:(ArtistGalleryCoordinator *)coordinator
    didUpdateImages:(NSArray<ArtistImage *> *)images {
    NSLog(@"[Gallery] Received %lu images from coordinator", (unsigned long)images.count);
    [self.contentView setGalleryLoading:NO];
    [self.contentView updateGalleryImages:images];
}

- (void)coordinatorDidStartLoading:(ArtistGalleryCoordinator *)coordinator {
    [self.contentView setGalleryLoading:YES];
}

- (void)coordinatorDidFinishLoading:(ArtistGalleryCoordinator *)coordinator {
    [self.contentView setGalleryLoading:NO];
}

- (void)coordinator:(ArtistGalleryCoordinator *)coordinator
   didFailWithError:(NSError *)error {
    NSLog(@"[Gallery] Coordinator failed with error: %@", error.localizedDescription);
    // Gallery failures are silent - just hide the gallery
    [self.contentView setGalleryLoading:NO];
    [self.contentView updateGalleryImages:@[]];
}

#pragma mark - BiographyContentViewDelegate

- (void)contentView:(BiographyContentView *)contentView didSelectGalleryImageAtIndex:(NSUInteger)index {
    NSLog(@"[Gallery/Controller] didSelectGalleryImageAtIndex:%lu", (unsigned long)index);
    NSArray<ArtistImage *> *images = self.galleryCoordinator.galleryData.images;
    NSLog(@"[Gallery/Controller] images count: %lu", (unsigned long)images.count);
    if (!images || index >= images.count) {
        NSLog(@"[Gallery/Controller] No images or index out of range, aborting");
        return;
    }

    // Show lightbox
    // QUAL-5: Set onDismiss to nil the strong reference
    self.lightboxController = [[LightboxWindowController alloc] initWithImages:images
                                                                  initialIndex:index];
    __weak typeof(self) weakSelf = self;
    self.lightboxController.onDismiss = ^{
        weakSelf.lightboxController = nil;
    };
    [self.lightboxController showRelativeToWindow:self.view.window];
}

@end
