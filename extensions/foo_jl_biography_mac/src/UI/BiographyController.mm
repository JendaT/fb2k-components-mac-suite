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
#import "BiographyContentView.h"
#import "BiographyLoadingView.h"
#import "BiographyErrorView.h"
#import "BiographyEmptyView.h"
#import <QuartzCore/QuartzCore.h>

// Debounce delay for rapid track changes (in seconds)
static const NSTimeInterval kDebounceDelay = 0.3;

@interface BiographyController () <BiographyErrorViewDelegate>

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
    [self.currentRequest cancel];
    BiographyCallbackManager::instance().unregisterController(self);
}

- (void)loadView {
    // Create container view with zero frame - parent will set the size
    self.containerView = [[NSView alloc] initWithFrame:NSZeroRect];

    // Create state views with zero frame
    self.contentView = [[BiographyContentView alloc] initWithFrame:NSZeroRect];
    self.loadingView = [[BiographyLoadingView alloc] initWithFrame:NSZeroRect];
    self.errorView = [[BiographyErrorView alloc] initWithFrame:NSZeroRect];
    self.errorView.delegate = self;
    self.emptyView = [[BiographyEmptyView alloc] initWithFrame:NSZeroRect];

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

    self.debounceTimer = [NSTimer scheduledTimerWithTimeInterval:kDebounceDelay
                                                          target:self
                                                        selector:@selector(processPendingArtist)
                                                        userInfo:nil
                                                         repeats:NO];
}

- (void)processPendingArtist {
    NSString *artistName = self.pendingArtist;
    self.pendingArtist = nil;

    if (!artistName) return;

    // Cancel any in-flight request
    [self.currentRequest cancel];

    // Update current artist
    self.currentArtist = artistName;

    // Show loading state
    [self transitionToState:BiographyViewStateLoading];
    [self.loadingView setArtistName:artistName];

    // Create new request token
    self.currentRequest = [[BiographyRequest alloc] initWithArtistName:artistName];

    // Fetch biography (placeholder - will be connected to BiographyFetcher)
    [self fetchBiographyForRequest:self.currentRequest force:NO];
}

- (void)handlePlaybackStop {
    [self.debounceTimer invalidate];
    self.debounceTimer = nil;
    self.pendingArtist = nil;

    [self.currentRequest cancel];
    self.currentRequest = nil;

    self.currentArtist = nil;
    self.biographyData = nil;

    [self transitionToState:BiographyViewStateEmpty];
}

#pragma mark - Fetching

- (void)fetchBiographyForRequest:(BiographyRequest *)request force:(BOOL)force {
    [[BiographyFetcher shared] fetchBiographyForArtist:request.artistName
                                                 force:force
                                            completion:^(BiographyData * _Nullable data, NSError * _Nullable error) {
        // Check if this request is still current
        if (self.currentRequest != request || request.isCancelled) {
            return;
        }

        if (error) {
            // Handle error
            if (error.code == BiographyFetcherErrorCodeCancelled) {
                return;  // Silent - cancelled by user action
            }

            NSString *errorMessage = @"Unable to load biography";
            NSString *errorDetail = error.localizedDescription;

            if (error.code == BiographyFetcherErrorCodeArtistNotFound) {
                errorMessage = @"Artist not found";
                errorDetail = [NSString stringWithFormat:@"No biography found for %@", request.artistName];
            } else if (error.code == BiographyFetcherErrorCodeNetworkError) {
                errorDetail = @"Check your internet connection and try again.";
            }

            [self.errorView setErrorMessage:errorMessage];
            [self.errorView setErrorDetail:errorDetail];
            [self transitionToState:BiographyViewStateError];
            return;
        }

        if (!data || !data.hasBiography) {
            // No biography available
            [self.errorView setErrorMessage:@"No biography available"];
            [self.errorView setErrorDetail:[NSString stringWithFormat:@"No biography found for %@", request.artistName]];
            [self transitionToState:BiographyViewStateError];
            return;
        }

        // Success - update UI
        self.biographyData = data;
        [self.contentView updateWithBiographyData:data];

        if (data.isStale) {
            [self transitionToState:BiographyViewStateOffline];
        } else {
            [self transitionToState:BiographyViewStateContent];
        }
    }];
}

- (void)forceRefresh {
    if (self.currentArtist) {
        [self.currentRequest cancel];
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

@end
