//
//  RemoteArtworkSearchController.mm
//  foo_jl_album_art_mac
//
//  Search controller implementation
//

#import "RemoteArtworkSearchController.h"
#import "CoverArtArchiveProvider.h"
#import "iTunesProvider.h"
#import "DeezerProvider.h"
#import "TidalProvider.h"
#import "../../../../shared/NetworkReachability.h"

static const NSTimeInterval kGlobalSearchTimeout = 45.0;

@interface RemoteArtworkSearchController ()

@property (nonatomic, assign) BOOL searching;
@property (nonatomic, strong, nullable) TrackMetadata *currentMetadata;

// Track pending source searches (mutated on serialQueue only)
@property (nonatomic, assign) NSInteger pendingSearchCount;
@property (nonatomic, strong) NSMutableArray<ArtworkResult *> *aggregatedResults;
@property (nonatomic, strong) NSMutableSet<NSString *> *seenURLs;
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingSourceNames;

// Generation counter: incremented on every search start and cancel.
// Provider completions capture the generation they belong to; stale
// completions (from a cancelled or superseded search) are dropped so they
// can never corrupt the pending count or results of a newer search.
@property (atomic, assign) NSUInteger searchGeneration;

@property (nonatomic, strong) dispatch_queue_t serialQueue;

@end

@implementation RemoteArtworkSearchController

- (instancetype)init {
    NSMutableArray<id<ArtworkSourceProvider>> *providers = [NSMutableArray arrayWithArray:@[
        [CoverArtArchiveProvider sharedInstance],
        [iTunesProvider sharedInstance],
        [DeezerProvider sharedInstance],
        [TidalProvider sharedInstance],
    ]];
    return [self initWithProviders:providers];
}

- (instancetype)initWithProviders:(NSArray<id<ArtworkSourceProvider>> *)providers {
    self = [super init];
    if (self) {
        _providers = [providers copy];
        _serialQueue = dispatch_queue_create("com.foobar2000.albumart.search",
                                             DISPATCH_QUEUE_SERIAL);
        _aggregatedResults = [NSMutableArray array];
        _seenURLs = [NSMutableSet set];
        _pendingSourceNames = [NSMutableArray array];
        _searchGeneration = 0;
    }
    return self;
}

#pragma mark - Public API

- (void)searchForArtworkWithMetadata:(TrackMetadata *)metadata {
    // Cancel any existing search
    [self cancel];

    // Validate metadata
    if (!metadata.isSearchable) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate searchDidFailWithError:
                [NSError errorWithDomain:ArtworkFetchErrorDomain
                                    code:ArtworkFetchErrorInvalidMetadata
                                userInfo:@{NSLocalizedDescriptionKey: @"Missing artist or album"}]];
        });
        return;
    }

    // Check network availability
    if (![[JLNetworkReachability sharedInstance] isReachable]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate searchDidFailWithError:
                [NSError errorWithDomain:ArtworkFetchErrorDomain
                                    code:ArtworkFetchErrorNetworkUnavailable
                                userInfo:@{NSLocalizedDescriptionKey: @"Network unavailable"}]];
        });
        return;
    }

    NSArray<id<ArtworkSourceProvider>> *activeProviders = [self configuredProviders];
    if (activeProviders.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate searchDidFailWithError:
                [NSError errorWithDomain:ArtworkFetchErrorDomain
                                    code:ArtworkFetchErrorAPIError
                                userInfo:@{NSLocalizedDescriptionKey: @"No artwork sources configured"}]];
        });
        return;
    }

    // Reset state
    self.searching = YES;
    self.currentMetadata = metadata;
    self.searchGeneration += 1;
    NSUInteger generation = self.searchGeneration;

    dispatch_async(self.serialQueue, ^{
        [self.aggregatedResults removeAllObjects];
        [self.seenURLs removeAllObjects];
        [self.pendingSourceNames removeAllObjects];
        self.pendingSearchCount = (NSInteger)activeProviders.count;
        for (id<ArtworkSourceProvider> provider in activeProviders) {
            [self.pendingSourceNames addObject:provider.displayName];
        }
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.searchGeneration != generation) return;
        [self.delegate searchDidStart];

        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (id<ArtworkSourceProvider> provider in activeProviders) {
            [names addObject:provider.displayName];
        }
        [self.delegate searchDidUpdateProgress:
            [NSString stringWithFormat:@"Searching %@...", [names componentsJoinedByString:@", "]]];
    });

    // Schedule global timeout
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kGlobalSearchTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self handleGlobalTimeoutForGeneration:generation];
    });

    // Start parallel searches
    for (id<ArtworkSourceProvider> provider in activeProviders) {
        NSString *sourceName = provider.displayName;
        [provider searchWithMetadata:metadata
                          completion:^(NSArray<ArtworkResult *> *results, NSError *error) {
            [self handleResultsFromSource:sourceName
                                  results:results
                                    error:error
                               generation:generation];
        }];
    }
}

- (void)cancel {
    if (!self.searching) {
        return;
    }

    self.searching = NO;
    self.currentMetadata = nil;
    self.searchGeneration += 1;  // Invalidate pending completions and timeout

    for (id<ArtworkSourceProvider> provider in self.providers) {
        [provider cancel];
    }
}

#pragma mark - Providers

- (NSArray<id<ArtworkSourceProvider>> *)configuredProviders {
    NSMutableArray<id<ArtworkSourceProvider>> *active = [NSMutableArray array];
    for (id<ArtworkSourceProvider> provider in self.providers) {
        if ([provider respondsToSelector:@selector(isConfigured)] && !provider.isConfigured) {
            continue;
        }
        [active addObject:provider];
    }
    return active;
}

#pragma mark - Result Handling

- (void)handleResultsFromSource:(NSString *)source
                        results:(NSArray<ArtworkResult *> *)results
                          error:(NSError *)error
                     generation:(NSUInteger)generation {

    dispatch_async(self.serialQueue, ^{
        // Drop completions that belong to a cancelled or superseded search
        if (self.searchGeneration != generation) {
            return;
        }

        if (error) {
            NSLog(@"[AlbumArt] %@ search failed: %@", source, error.localizedDescription);
        }

        [self.pendingSourceNames removeObject:source];

        // Add non-duplicate results (deduplicate by full-resolution URL;
        // content hashes are not available until images are downloaded)
        for (ArtworkResult *result in results) {
            NSString *urlKey = result.fullResolutionURL.absoluteString;
            if (urlKey.length == 0 || [self.seenURLs containsObject:urlKey]) {
                continue;
            }
            [self.seenURLs addObject:urlKey];
            [self.aggregatedResults addObject:result];
        }

        NSArray<ArtworkResult *> *sortedResults = [self sortedResults];
        NSArray<NSString *> *remaining = [self.pendingSourceNames copy];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.searchGeneration != generation) return;

            if (sortedResults.count > 0) {
                [self.delegate searchDidFindResults:sortedResults];
            }

            if (remaining.count > 0) {
                NSString *progressMsg = [NSString stringWithFormat:@"Searching %@...",
                                         [remaining componentsJoinedByString:@", "]];
                [self.delegate searchDidUpdateProgress:progressMsg];
            } else {
                NSString *countMsg = [NSString stringWithFormat:@"Found %lu images",
                                      (unsigned long)sortedResults.count];
                [self.delegate searchDidUpdateProgress:countMsg];
            }
        });

        // Decrement pending count and check for completion
        self.pendingSearchCount--;

        if (self.pendingSearchCount <= 0) {
            NSUInteger resultCount = sortedResults.count;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.searchGeneration != generation) return;

                self.searching = NO;

                if (resultCount == 0) {
                    [self.delegate searchDidFailWithError:
                        [NSError errorWithDomain:ArtworkFetchErrorDomain
                                            code:ArtworkFetchErrorNoResults
                                        userInfo:@{NSLocalizedDescriptionKey: @"No artwork found"}]];
                }

                [self.delegate searchDidComplete];
            });
        }
    });
}

#pragma mark - Global Timeout

- (void)handleGlobalTimeoutForGeneration:(NSUInteger)generation {
    // Only fire if this is still the same search
    if (self.searchGeneration != generation || !self.searching) {
        return;
    }

    NSLog(@"[AlbumArt] Global search timeout after %.0fs", kGlobalSearchTimeout);

    // Cancel all providers and report timeout
    [self cancel];

    [self.delegate searchDidFailWithError:
        [NSError errorWithDomain:ArtworkFetchErrorDomain
                            code:ArtworkFetchErrorTimeout
                        userInfo:@{NSLocalizedDescriptionKey: @"Search timed out"}]];
    [self.delegate searchDidComplete];
}

#pragma mark - Result Sorting

- (NSArray<ArtworkResult *> *)sortedResults {
    // Sort by:
    // 1. Artwork type (Front first, then Back, Disc, etc.)
    // 2. Resolution (higher first)
    // 3. Source priority (provider order)

    return [self.aggregatedResults sortedArrayUsingComparator:
        ^NSComparisonResult(ArtworkResult *a, ArtworkResult *b) {

        // Primary: artwork type
        if (a.artworkType != b.artworkType) {
            return [@(a.artworkType) compare:@(b.artworkType)];
        }

        // Secondary: resolution (descending)
        CGFloat aRes = a.resolution.width * a.resolution.height;
        CGFloat bRes = b.resolution.width * b.resolution.height;
        if (aRes != bRes) {
            return bRes > aRes ? NSOrderedDescending : NSOrderedAscending;
        }

        // Tertiary: source priority
        NSInteger aPriority = [self priorityForSource:a.sourceIdentifier];
        NSInteger bPriority = [self priorityForSource:b.sourceIdentifier];
        return [@(aPriority) compare:@(bPriority)];
    }];
}

- (NSInteger)priorityForSource:(NSString *)source {
    // Lower is better; matches the order providers were registered in
    NSUInteger index = 0;
    for (id<ArtworkSourceProvider> provider in self.providers) {
        if ([provider.identifier isEqualToString:source]) {
            return (NSInteger)index;
        }
        index++;
    }
    return 99;
}

@end
