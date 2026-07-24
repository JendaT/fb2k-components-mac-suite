//
//  DeezerProvider.mm
//  foo_jl_album_art_mac
//
//  Deezer API implementation
//

#import "DeezerProvider.h"

static NSString *const kDeezerSearchURL = @"https://api.deezer.com/search/album";
static const NSTimeInterval kDeezerTimeout = 30.0;

@interface DeezerProvider ()

@property (nonatomic, strong) NSURLSession *session;

@end

@implementation DeezerProvider

#pragma mark - Protocol Properties

- (NSString *)identifier {
    return @"deezer";
}

- (NSString *)displayName {
    return @"Deezer";
}

- (BOOL)requiresAPIKey {
    return NO;
}

- (NSTimeInterval)rateLimitInterval {
    return 0;  // No rate limiting for Deezer API
}

#pragma mark - Singleton

+ (DeezerProvider *)sharedInstance {
    static DeezerProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DeezerProvider alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kDeezerTimeout;
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

    // Build search URL - escape double quotes in metadata values
    NSString *escapedArtist = [self escapeDeezerQuotes:metadata.albumArtist];
    NSString *escapedAlbum = [self escapeDeezerQuotes:metadata.album];
    NSString *searchTerm = [NSString stringWithFormat:@"artist:\"%@\" album:\"%@\"",
                            escapedArtist, escapedAlbum];
    NSURL *url = [self searchURLForQuery:searchTerm];

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
                    message:[NSString stringWithFormat:@"Deezer error: %ld", (long)httpResponse.statusCode]];
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

#pragma mark - String Escaping

- (NSString *)escapeDeezerQuotes:(NSString *)input {
    // Deezer query uses "..." syntax - strip embedded double quotes to avoid breaking the query
    return [input stringByReplacingOccurrencesOfString:@"\"" withString:@""];
}

#pragma mark - URL Building

- (NSURL *)searchURLForQuery:(NSString *)query {
    NSURLComponents *components = [[NSURLComponents alloc] initWithString:kDeezerSearchURL];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:query],
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

    NSArray *results = json[@"data"];
    if (![results isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ArtworkResult *> *artworkResults = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    for (NSDictionary *result in results) {
        if (![result isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        // Deezer provides different sizes: cover, cover_medium, cover_big, cover_xl
        NSString *xlCoverURL = result[@"cover_xl"];
        NSString *mediumCoverURL = result[@"cover_medium"];

        if (![xlCoverURL isKindOfClass:[NSString class]] || xlCoverURL.length == 0) {
            continue;
        }

        // Deduplicate by URL
        if ([seenURLs containsObject:xlCoverURL]) {
            continue;
        }
        [seenURLs addObject:xlCoverURL];

        // Use medium as thumbnail (500px), or fall back to xl
        NSString *thumbnailURL = mediumCoverURL;
        if (![thumbnailURL isKindOfClass:[NSString class]] || thumbnailURL.length == 0) {
            thumbnailURL = xlCoverURL;
        }

        ArtworkResult *artwork = [[ArtworkResult alloc]
            initWithSourceIdentifier:self.identifier
                          sourceName:self.displayName
                        thumbnailURL:[NSURL URLWithString:thumbnailURL]
                   fullResolutionURL:[NSURL URLWithString:xlCoverURL]
                          resolution:CGSizeMake(1000, 1000)  // XL size
                         artworkType:RemoteArtworkTypeFront];

        [artworkResults addObject:artwork];
    }

    return [artworkResults copy];
}

@end
