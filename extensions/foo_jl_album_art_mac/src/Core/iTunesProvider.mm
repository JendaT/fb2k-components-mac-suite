//
//  iTunesProvider.mm
//  foo_jl_album_art_mac
//
//  iTunes Search API implementation
//

#import "iTunesProvider.h"

static NSString *const kiTunesSearchURL = @"https://itunes.apple.com/search";
static const NSTimeInterval kiTunesTimeout = 30.0;

@interface iTunesProvider ()

@property (nonatomic, strong) NSURLSession *session;

@end

@implementation iTunesProvider

#pragma mark - Protocol Properties

- (NSString *)identifier {
    return @"itunes";
}

- (NSString *)displayName {
    return @"iTunes";
}

- (BOOL)requiresAPIKey {
    return NO;
}

- (NSTimeInterval)rateLimitInterval {
    return 0;  // No rate limiting for iTunes API
}

#pragma mark - Singleton

+ (iTunesProvider *)sharedInstance {
    static iTunesProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[iTunesProvider alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kiTunesTimeout;
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - ArtworkSourceProvider Protocol

- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(ArtworkSearchCompletion)completion {

    [self resetCancelledState];

    // Network check is done by RemoteArtworkSearchController before calling providers

    // Need artist and album
    if (!metadata.isSearchable) {
        completion(@[], [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorInvalidMetadata
                                                         message:@"Missing artist or album"]);
        return;
    }

    // Build search URL
    NSString *searchTerm = [NSString stringWithFormat:@"%@ %@", metadata.albumArtist, metadata.album];
    NSURL *url = [self searchURLForTerm:searchTerm];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(@[], [ArtworkSourceProviderBase errorFromURLError:error]);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200) {
                NSError *apiError = [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorAPIError
                    message:[NSString stringWithFormat:@"iTunes error: %ld", (long)httpResponse.statusCode]];
                completion(@[], apiError);
                return;
            }

            // Parse JSON and create ArtworkResult objects
            NSArray<ArtworkResult *> *results = [strongSelf parseArtworkFromData:data];
            completion(results, nil);
        });
    }];

    self.currentTask = task;
    [task resume];
}

#pragma mark - URL Building

- (NSURL *)searchURLForTerm:(NSString *)term {
    NSURLComponents *components = [[NSURLComponents alloc] initWithString:kiTunesSearchURL];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:term],
        [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
        [NSURLQueryItem queryItemWithName:@"entity" value:@"album"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"10"]
    ];
    return components.URL;
}

#pragma mark - Response Parsing

- (NSArray<ArtworkResult *> *)parseArtworkFromData:(NSData *)data {
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSArray *results = json[@"results"];
    if (![results isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ArtworkResult *> *artworkResults = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    for (NSDictionary *result in results) {
        if (![result isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        NSString *artworkURL = result[@"artworkUrl100"];
        if (![artworkURL isKindOfClass:[NSString class]] || artworkURL.length == 0) {
            continue;
        }

        // Get high-res version (1200x1200) by modifying URL
        NSString *highResURL = [self highResURLFromThumbnail:artworkURL];
        CGSize resolution;

        // Validate the transformation actually worked
        if ([highResURL isEqualToString:artworkURL]) {
            // URL doesn't contain expected pattern - use original as-is
            resolution = CGSizeMake(100, 100);
        } else {
            resolution = CGSizeMake(1200, 1200);
        }

        // Deduplicate by URL
        if ([seenURLs containsObject:highResURL]) {
            continue;
        }
        [seenURLs addObject:highResURL];

        // Get 500px thumbnail (falls back to original if pattern doesn't match)
        NSString *thumbnailURL = [self thumbnailURLFromOriginal:artworkURL size:500];

        ArtworkResult *artwork = [[ArtworkResult alloc]
            initWithSourceIdentifier:self.identifier
                          sourceName:self.displayName
                        thumbnailURL:[NSURL URLWithString:thumbnailURL]
                   fullResolutionURL:[NSURL URLWithString:highResURL]
                          resolution:resolution
                         artworkType:RemoteArtworkTypeFront];

        [artworkResults addObject:artwork];
    }

    return [artworkResults copy];
}

- (NSString *)highResURLFromThumbnail:(NSString *)thumbnailURL {
    // iTunes URL pattern: ...100x100bb.jpg -> ...1200x1200bb.jpg
    return [thumbnailURL stringByReplacingOccurrencesOfString:@"100x100bb"
                                                   withString:@"1200x1200bb"];
}

- (NSString *)thumbnailURLFromOriginal:(NSString *)originalURL size:(NSInteger)size {
    NSString *sizeStr = [NSString stringWithFormat:@"%ldx%ldbb", (long)size, (long)size];
    return [originalURL stringByReplacingOccurrencesOfString:@"100x100bb"
                                                  withString:sizeStr];
}

@end
