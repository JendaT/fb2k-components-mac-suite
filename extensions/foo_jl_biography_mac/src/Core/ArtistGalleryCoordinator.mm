//
//  ArtistGalleryCoordinator.mm
//  foo_jl_biography_mac
//
//  Orchestrates fetching artist images from multiple sources
//

#import "ArtistGalleryCoordinator.h"
#import "ArtistImage.h"
#import "ArtistGalleryData.h"
#import "ArtistImageCache.h"
#import "BiographyRequest.h"
#import "../API/FanartTvClient.h"
#import "../API/AudioDbClient.h"
#import "../API/DeezerClient.h"
#import "../API/BiographyAPIConstants.h"

// Timeout for overall fetch (both APIs)
static const NSTimeInterval kOverallFetchTimeout = 15.0;

// Logging macro
#define GALLERY_LOG(fmt, ...) NSLog(@"[Gallery/Coordinator] " fmt, ##__VA_ARGS__)

@interface ArtistGalleryCoordinator ()

@property (nonatomic, copy, readwrite, nullable) NSString *currentArtistName;
@property (nonatomic, assign, readwrite) BOOL isLoading;
@property (nonatomic, strong, readwrite, nullable) ArtistGalleryData *galleryData;

// Current request tracking
@property (nonatomic, strong, nullable) BiographyRequest *currentRequest;
@property (nonatomic, copy, nullable) NSString *currentRequestId;
@property (nonatomic, copy, nullable) NSURL *fallbackImageURL;

@end

@implementation ArtistGalleryCoordinator

#pragma mark - Public API

- (void)fetchImagesForArtist:(NSString *)artistName
                        mbid:(nullable NSString *)mbid
            fallbackImageURL:(nullable NSURL *)fallbackImageURL {
    if (!artistName || artistName.length == 0) {
        return;
    }

    // Generate unique request ID
    NSString *requestId = [NSString stringWithFormat:@"%@_%f", artistName, [NSDate timeIntervalSinceReferenceDate]];

    // Check if same artist already loading
    if ([artistName isEqualToString:self.currentArtistName] && self.isLoading) {
        GALLERY_LOG(@"Already loading %@, skipping", artistName);
        return;
    }

    // Cancel previous request
    [self cancelCurrentFetch];

    self.currentArtistName = artistName;
    self.currentRequestId = requestId;
    self.currentRequest = [[BiographyRequest alloc] initWithArtistName:artistName];
    self.fallbackImageURL = fallbackImageURL;

    GALLERY_LOG(@"Fetching for %@ (mbid: %@, fallback: %@)", artistName, mbid ?: @"nil", fallbackImageURL ? @"yes" : @"no");

    // Check cache first
    ArtistGalleryData *cached = [[ArtistImageCache shared] cachedGalleryDataForArtist:artistName];
    if (cached && !cached.isEmpty) {
        GALLERY_LOG(@"Using cached gallery data (%lu images)", (unsigned long)cached.imageCount);
        self.galleryData = cached;
        [self notifyDelegateWithImages:cached.images];
        return;
    }

    // Start loading
    self.isLoading = YES;
    [self notifyDelegateLoadingStarted];

    // Create builder for results
    ArtistGalleryDataBuilder *builder = [[ArtistGalleryDataBuilder alloc] initWithArtistName:artistName];
    builder.mbid = mbid;

    // Track completion of all APIs
    __block BOOL fanartDone = NO;
    __block BOOL audioDbDone = NO;
    __block BOOL deezerDone = NO;
    __block NSError *fanartError = nil;
    __block NSError *audioDbError = nil;
    __block NSError *deezerError = nil;

    // Weak reference for async callbacks
    __weak typeof(self) weakSelf = self;
    BiographyRequest *request = self.currentRequest;
    NSString *reqId = requestId;

    // Dispatch group for parallel fetches
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // Completion guard to prevent double-fire between timeout and group_notify
    __block BOOL fetchCompleted = NO;

    // Timeout handler - route through main queue to avoid data races
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOverallFetchTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Check if this request is still current
        if (![strongSelf.currentRequestId isEqualToString:reqId]) return;

        if (!fetchCompleted && strongSelf.isLoading) {
            fetchCompleted = YES;
            GALLERY_LOG(@"Overall timeout reached");
            [strongSelf finishFetchWithBuilder:builder
                                   fanartError:fanartError
                                  audioDbError:audioDbError
                                   deezerError:deezerError];
        }
    });

    // Fetch from FanartTV (if MBID available)
    if (mbid && mbid.length > 0) {
        dispatch_group_enter(group);
        [[FanartTvClient shared] fetchImagesForMBID:mbid
                                              token:request
                                         completion:^(NSArray<ArtistImage *> *images, NSError *error) {
            fanartDone = YES;
            fanartError = error;

            if (images.count > 0) {
                @synchronized(builder) {
                    [builder addImages:images];
                }
            }

            dispatch_group_leave(group);
        }];
    } else {
        fanartDone = YES;
        GALLERY_LOG(@"Skipping FanartTV (no MBID)");
    }

    // Fetch from AudioDB
    dispatch_group_enter(group);
    [[AudioDbClient shared] fetchImagesForArtist:artistName
                                           token:request
                                      completion:^(NSArray<ArtistImage *> *images, NSError *error) {
        audioDbDone = YES;
        audioDbError = error;

        if (images.count > 0) {
            @synchronized(builder) {
                [builder addImages:images];
            }
        }

        dispatch_group_leave(group);
    }];

    // Fetch from Deezer
    dispatch_group_enter(group);
    [[DeezerClient shared] fetchImagesForArtist:artistName
                                          token:request
                                     completion:^(NSArray<ArtistImage *> *images, NSError *error) {
        deezerDone = YES;
        deezerError = error;

        if (images.count > 0) {
            @synchronized(builder) {
                [builder addImages:images];
            }
        }

        dispatch_group_leave(group);
    }];

    // Wait for all to complete
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Check if this request is still current
        if (![strongSelf.currentRequestId isEqualToString:reqId]) {
            GALLERY_LOG(@"Request stale, discarding results");
            return;
        }

        if (!fetchCompleted) {
            fetchCompleted = YES;
            [strongSelf finishFetchWithBuilder:builder
                                   fanartError:fanartError
                                  audioDbError:audioDbError
                                   deezerError:deezerError];
        }
    });
}

- (void)cancelCurrentFetch {
    if (self.currentRequest) {
        [self.currentRequest cancel];
        self.currentRequest = nil;
    }

    if (self.isLoading) {
        self.isLoading = NO;
        [self notifyDelegateLoadingFinished];
    }

    self.currentRequestId = nil;
}

- (void)clearCache {
    // ARCH-9: Actually clear the cached gallery data
    self.galleryData = nil;
    if (self.currentArtistName) {
        GALLERY_LOG(@"Cache cleared for %@", self.currentArtistName);
    }
}

- (void)clearAllCaches {
    [[ArtistImageCache shared] clearAllCaches];
    self.galleryData = nil;
}

#pragma mark - Private

- (void)finishFetchWithBuilder:(ArtistGalleryDataBuilder *)builder
                   fanartError:(NSError *)fanartError
                  audioDbError:(NSError *)audioDbError
                   deezerError:(NSError *)deezerError {

    self.isLoading = NO;

    // Sort images by preference
    [builder sortImagesByPreference];

    // Build gallery data
    ArtistGalleryData *data = [builder build];

    GALLERY_LOG(@"Fetch complete: %lu images (FanartTV: %@, AudioDB: %@, Deezer: %@)",
                (unsigned long)data.imageCount,
                fanartError ? fanartError.localizedDescription : @"OK",
                audioDbError ? audioDbError.localizedDescription : @"OK",
                deezerError ? deezerError.localizedDescription : @"OK");

    // If no images from APIs but we have a fallback URL, use it
    // Skip Last.fm default placeholder (star icon) - hash 2a96cbd8b46e442fc41c2b86b821562f
    BOOL isDefaultPlaceholder = [self.fallbackImageURL.absoluteString containsString:kLastFmPlaceholderHash];

    if (data.isEmpty && self.fallbackImageURL && !isDefaultPlaceholder) {
        GALLERY_LOG(@"No API images, using Last.fm fallback URL: %@", self.fallbackImageURL.absoluteString);
        ArtistImage *fallbackImage = [[ArtistImage alloc] initWithURL:self.fallbackImageURL
                                                         thumbnailURL:nil
                                                            imageType:ArtistImageTypeThumbnail
                                                               source:BiographySourceLastFm
                                                                likes:0
                                                         originalSize:CGSizeZero];
        [builder addImages:@[fallbackImage]];
        data = [builder build];
        GALLERY_LOG(@"After adding fallback: %lu images", (unsigned long)data.imageCount);
    } else if (data.isEmpty && isDefaultPlaceholder) {
        GALLERY_LOG(@"No API images, Last.fm fallback is default placeholder - skipping");
    } else if (data.isEmpty) {
        GALLERY_LOG(@"No API images and no fallback URL available");
    }

    self.galleryData = data;

    // Cache if we got any images
    if (!data.isEmpty) {
        [[ArtistImageCache shared] cacheGalleryData:data];
    }

    // Notify delegate
    [self notifyDelegateLoadingFinished];

    if (data.isEmpty && fanartError && audioDbError && deezerError) {
        // All failed and no fallback
        [self notifyDelegateWithError:fanartError];
    } else {
        [self notifyDelegateWithImages:data.images];
    }
}

#pragma mark - Delegate Notifications

- (void)notifyDelegateLoadingStarted {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(coordinatorDidStartLoading:)]) {
            [self.delegate coordinatorDidStartLoading:self];
        }
    });
}

- (void)notifyDelegateLoadingFinished {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(coordinatorDidFinishLoading:)]) {
            [self.delegate coordinatorDidFinishLoading:self];
        }
    });
}

- (void)notifyDelegateWithImages:(NSArray<ArtistImage *> *)images {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(coordinator:didUpdateImages:)]) {
            [self.delegate coordinator:self didUpdateImages:images];
        }
    });
}

- (void)notifyDelegateWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(coordinator:didFailWithError:)]) {
            [self.delegate coordinator:self didFailWithError:error];
        }
    });
}

@end
