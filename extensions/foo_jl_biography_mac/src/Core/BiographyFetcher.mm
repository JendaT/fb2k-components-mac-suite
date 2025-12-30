//
//  BiographyFetcher.mm
//  foo_jl_biography_mac
//
//  Request coordinator implementation
//

#import "BiographyFetcher.h"
#import "BiographyData.h"
#import "BiographyRequest.h"
#import "BiographyCache.h"
#import "../API/LastFmBioClient.h"
#import "../API/BiographyAPIConstants.h"

NSString * const BiographyFetcherErrorDomain = @"com.foobar2000.biography.fetcher";

@interface BiographyFetcher ()

@property (nonatomic, strong, readwrite) dispatch_queue_t fetchQueue;
@property (nonatomic, strong, readwrite, nullable) BiographyRequest *currentRequest;
@property (nonatomic, strong) BiographyCache *cache;

@end

@implementation BiographyFetcher

+ (instancetype)shared {
    static BiographyFetcher *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BiographyFetcher alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fetchQueue = dispatch_queue_create("com.foobar2000.biography.fetcher", DISPATCH_QUEUE_SERIAL);
        _cache = [[BiographyCache alloc] init];
    }
    return self;
}

- (BOOL)isFetching {
    return self.currentRequest != nil && !self.currentRequest.isCancelled;
}

- (void)fetchBiographyForArtist:(NSString *)artistName
                          force:(BOOL)ignoreCache
                     completion:(BiographyCompletion)completion {

    if (!artistName || artistName.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [self errorWithCode:BiographyFetcherErrorCodeArtistNotFound
                                        message:@"Artist name is required"]);
        });
        return;
    }

    // Cancel any existing request
    [self cancelCurrentRequest];

    // Create new request token
    BiographyRequest *request = [[BiographyRequest alloc] initWithArtistName:artistName];
    self.currentRequest = request;

    dispatch_async(self.fetchQueue, ^{
        // Check cancellation
        if (request.isCancelled) {
            [self completeWithError:[self cancelledError] completion:completion];
            return;
        }

        // Check cache first (unless force refresh)
        if (!ignoreCache) {
            BiographyData *cached = [self.cache fetchCachedBiographyForArtist:artistName];
            if (cached && !cached.isStale) {
                [self completeWithData:cached completion:completion];
                return;
            }

            // If we have stale data, we'll return it later if the fetch fails
            if (cached.isStale) {
                // Store for potential fallback
                NSLog(@"[Biography] Have stale cache for %@, will fetch fresh", artistName);
            }
        }

        // Fetch from Last.fm
        NSLog(@"[Biography] Fetching artist info for: %@", artistName);
        [[LastFmBioClient shared] fetchArtistInfo:artistName
                                            token:request
                                       completion:^(NSDictionary * _Nullable response, NSError * _Nullable error) {
            NSLog(@"[Biography] Got completion - error: %@, response: %@", error, response ? @"YES" : @"NO");

            if (request.isCancelled) {
                [self completeWithError:[self cancelledError] completion:completion];
                return;
            }

            if (error) {
                // Try to return stale cache if available
                BiographyData *stale = [self.cache fetchCachedBiographyForArtist:artistName];
                if (stale) {
                    NSLog(@"[Biography] API error, returning stale cache for %@", artistName);
                    [self completeWithData:stale completion:completion];
                } else {
                    [self completeWithError:[self networkError:error.localizedDescription]
                                 completion:completion];
                }
                return;
            }

            // Parse response and build BiographyData
            BiographyData *data = [self buildBiographyDataFromResponse:response
                                                            artistName:artistName];

            // Cache the result
            [self.cache cacheBiography:data forArtist:artistName];

            // Clear current request before completing
            if (self.currentRequest == request) {
                self.currentRequest = nil;
            }

            [self completeWithData:data completion:completion];
        }];
    });
}

- (void)cancelCurrentRequest {
    BiographyRequest *current = self.currentRequest;
    if (current) {
        [current cancel];
        self.currentRequest = nil;
    }
    [[LastFmBioClient shared] cancelAllRequests];
}

- (void)prefetchBiographyForArtist:(NSString *)artistName {
    // Low priority prefetch - check cache first
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BiographyData *cached = [self.cache fetchCachedBiographyForArtist:artistName];
        if (cached && !cached.isStale) {
            return;  // Already cached
        }

        // Fetch in background with no completion
        [self fetchBiographyForArtist:artistName force:NO completion:^(BiographyData *data, NSError *error) {
            // Silent - just populates cache
        }];
    });
}

#pragma mark - Response Building

- (BiographyData *)buildBiographyDataFromResponse:(NSDictionary *)response
                                       artistName:(NSString *)artistName {

    NSDictionary *parsed = [LastFmBioClient parseArtistInfoResponse:response];

    BiographyDataBuilder *builder = [[BiographyDataBuilder alloc] initWithArtistName:artistName];

    // Use corrected name if available
    if (parsed[@"name"]) {
        builder.artistName = parsed[@"name"];
    }

    builder.musicBrainzId = parsed[@"mbid"];
    builder.biography = parsed[@"biography"];
    builder.biographySummary = parsed[@"biographySummary"];
    builder.biographySource = BiographySourceLastFm;
    builder.language = @"en";

    // Image URL (will need to be downloaded separately)
    if (parsed[@"imageURL"]) {
        builder.artistImageURL = parsed[@"imageURL"];
        builder.imageSource = BiographySourceLastFm;
        builder.imageType = BiographyImageTypeThumb;
    }

    // Tags
    builder.tags = parsed[@"tags"];

    // Stats
    builder.listeners = [parsed[@"listeners"] unsignedIntegerValue];
    builder.playcount = [parsed[@"playcount"] unsignedIntegerValue];

    // Similar artists
    NSArray *similarRaw = parsed[@"similarArtists"];
    if (similarRaw.count > 0) {
        NSMutableArray<SimilarArtistRef *> *similar = [NSMutableArray array];
        for (NSDictionary *artistDict in similarRaw) {
            NSString *name = artistDict[@"name"];
            if (name.length > 0) {
                NSURL *thumbURL = nil;
                NSArray *images = artistDict[@"image"];
                if ([images isKindOfClass:[NSArray class]]) {
                    for (NSDictionary *img in images) {
                        if ([img[@"size"] isEqualToString:@"medium"]) {
                            NSString *urlStr = img[@"#text"];
                            if (urlStr.length > 0) {
                                thumbURL = [NSURL URLWithString:urlStr];
                            }
                            break;
                        }
                    }
                }

                SimilarArtistRef *ref = [[SimilarArtistRef alloc] initWithName:name
                                                                  thumbnailURL:thumbURL
                                                                 musicBrainzId:artistDict[@"mbid"]];
                [similar addObject:ref];
            }
        }
        builder.similarArtists = [similar copy];
    }

    builder.fetchedAt = [NSDate date];
    builder.isFromCache = NO;
    builder.isStale = NO;

    return [builder build];
}

#pragma mark - Completion Helpers

- (void)completeWithData:(BiographyData *)data completion:(BiographyCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(data, nil);
    });
}

- (void)completeWithError:(NSError *)error completion:(BiographyCompletion)completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(nil, error);
    });
}

#pragma mark - Error Helpers

- (NSError *)cancelledError {
    return [self errorWithCode:BiographyFetcherErrorCodeCancelled message:@"Request cancelled"];
}

- (NSError *)networkError:(NSString *)message {
    return [self errorWithCode:BiographyFetcherErrorCodeNetworkError message:message];
}

- (NSError *)errorWithCode:(BiographyFetcherErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:BiographyFetcherErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

@end
