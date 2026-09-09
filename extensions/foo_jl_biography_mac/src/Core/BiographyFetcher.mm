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
#import "LastFmParsing.h"
#import "../API/LastFmBioClient.h"
#import "../API/MusicBrainzClient.h"
#import "../API/WikipediaBioClient.h"
#import "../API/BiographyAPIConstants.h"

NSString * const BiographyFetcherErrorDomain = @"com.foobar2000.biography.fetcher";

@interface BiographyFetcher ()

@property (nonatomic, strong, readwrite) dispatch_queue_t fetchQueue;
@property (atomic, strong, readwrite, nullable) BiographyRequest *currentRequest;
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
        // PERF-15: Explicit QoS to prevent priority inversion from audio callback threads
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _fetchQueue = dispatch_queue_create("com.foobar2000.biography.fetcher", attr);
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
            BiographyData *data = [LastFmParsing biographyDataFromArtistInfoResponse:response
                                                                          artistName:artistName];

            // Enrich: resolve a missing MBID via MusicBrainz (Fanart.tv needs it)
            // and fall back to Wikipedia when Last.fm has no biography text
            [self enrichBiographyData:data request:request completion:^(BiographyData *enriched) {
                // Cache the result
                [self.cache cacheBiography:enriched forArtist:artistName];

                // Clear current request before completing
                if (self.currentRequest == request) {
                    self.currentRequest = nil;
                }

                [self completeWithData:enriched completion:completion];
            }];
        }];
    });
}

#pragma mark - Enrichment (MusicBrainz + Wikipedia)

- (void)enrichBiographyData:(BiographyData *)data
                    request:(BiographyRequest *)request
                 completion:(void (^)(BiographyData *))completion {

    BOOL needsMbid = data.musicBrainzId.length == 0;
    BOOL needsBio = !data.hasBiography;

    if ((!needsMbid && !needsBio) || request.isCancelled) {
        completion(data);
        return;
    }

    if (needsMbid) {
        [[MusicBrainzClient shared] lookupMBIDForArtist:data.artistName
                                                  token:request
                                             completion:^(NSString *mbid, NSError *error) {
            BiographyData *current = data;
            if (mbid.length > 0) {
                NSLog(@"[Biography] MusicBrainz resolved MBID for %@", data.artistName);
                BiographyDataBuilder *builder = [[BiographyDataBuilder alloc] initWithData:data];
                builder.musicBrainzId = mbid;
                current = [builder build];
            }

            if (needsBio && current.musicBrainzId.length > 0 && !request.isCancelled) {
                [self fetchWikipediaBioForData:current request:request completion:completion];
            } else {
                completion(current);
            }
        }];
        return;
    }

    // Has MBID already, only the biography is missing
    [self fetchWikipediaBioForData:data request:request completion:completion];
}

- (void)fetchWikipediaBioForData:(BiographyData *)data
                         request:(BiographyRequest *)request
                      completion:(void (^)(BiographyData *))completion {

    [[MusicBrainzClient shared] lookupWikidataQIDForMBID:data.musicBrainzId
                                                   token:request
                                              completion:^(NSString *qid, NSError *error) {
        if (qid.length == 0 || request.isCancelled) {
            completion(data);
            return;
        }

        [[WikipediaBioClient shared] fetchBioForWikidataQID:qid
                                                      token:request
                                                 completion:^(NSString *bioText, NSError *bioError) {
            if (bioText.length == 0) {
                completion(data);
                return;
            }

            NSLog(@"[Biography] Using Wikipedia biography for %@", data.artistName);
            BiographyDataBuilder *builder = [[BiographyDataBuilder alloc] initWithData:data];
            builder.biography = bioText;
            builder.biographySource = BiographySourceWikipedia;
            builder.language = @"en";
            completion([builder build]);
        }];
    }];
}

- (void)cancelCurrentRequest {
    BiographyRequest *current = self.currentRequest;
    if (current) {
        [current cancel];
        self.currentRequest = nil;
    }
    [[LastFmBioClient shared] cancelAllRequests];
    [[MusicBrainzClient shared] cancelAllRequests];
    [[WikipediaBioClient shared] cancelAllRequests];
}

- (void)prefetchBiographyForArtist:(NSString *)artistName {
    // ARCH-12: Skip prefetch if a user-initiated fetch is in progress
    if (self.isFetching) return;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BiographyData *cached = [self.cache fetchCachedBiographyForArtist:artistName];
        if (cached && !cached.isStale) {
            return;
        }

        [self fetchBiographyForArtist:artistName force:NO completion:^(BiographyData *data, NSError *error) {
            // Silent - just populates cache
        }];
    });
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
