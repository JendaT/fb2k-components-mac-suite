//
//  TidalProvider.mm
//  foo_jl_album_art_mac
//
//  TIDAL API implementation
//
//  Auth: OAuth2 client-credentials flow against auth.tidal.com; the token is
//  cached until shortly before expiry.
//
//  Search is two-step (JSON:API v2): searchResults returns album resources
//  without artwork; a second /albums request with include=coverArt returns
//  the artworks resources whose attributes.files[] carry image URLs.
//

#import "TidalProvider.h"

NSString *const kTidalClientIDDefaultsKey = @"JLAlbumArtTidalClientID";
NSString *const kTidalClientSecretDefaultsKey = @"JLAlbumArtTidalClientSecret";

static NSString *const kTidalTokenURL = @"https://auth.tidal.com/v1/oauth2/token";
static NSString *const kTidalAPIBaseURL = @"https://openapi.tidal.com/v2";
static const NSTimeInterval kTidalTimeout = 30.0;
static const NSTimeInterval kTokenExpiryMargin = 60.0;
static const NSUInteger kMaxAlbumResults = 5;
static const NSUInteger kMaxAccessTokenLength = 8192;

/// An OAuth token is interpolated into an Authorization header, so reject
/// anything outside the token68 character set before it gets there.
static BOOL TidalAccessTokenIsWellFormed(NSString *token) {
    if (token.length == 0 || token.length > kMaxAccessTokenLength) {
        return NO;
    }

    static NSCharacterSet *disallowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/="];
        disallowed = [allowed invertedSet];
    });

    return [token rangeOfCharacterFromSet:disallowed].location == NSNotFound;
}

@interface TidalProvider () <NSURLSessionTaskDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionTask *tokenTask;

// Cached OAuth token
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic, strong, nullable) NSDate *tokenExpiry;

@end

@implementation TidalProvider

#pragma mark - Protocol Properties

- (NSString *)identifier {
    return @"tidal";
}

- (NSString *)displayName {
    return @"TIDAL";
}

- (BOOL)requiresAPIKey {
    return YES;
}

- (NSTimeInterval)rateLimitInterval {
    return 0;
}

- (BOOL)isConfigured {
    return [self clientID].length > 0 && [self clientSecret].length > 0;
}

#pragma mark - Singleton

+ (TidalProvider *)sharedInstance {
    static TidalProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TidalProvider alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kTidalTimeout;
        // Delegate is needed for the redirect handling below; both the token
        // and the API requests carry an Authorization header.
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

#pragma mark - NSURLSessionTaskDelegate

/// CFNetwork forwards manually-set headers across hosts on a 30x, which would
/// hand the Basic client secret (or the bearer token) to the redirect target.
/// Strip the Authorization header whenever the host changes.
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {

    NSString *originalHost = task.originalRequest.URL.host;
    NSString *newHost = request.URL.host;

    if (originalHost.length > 0 && newHost.length > 0 &&
        [originalHost caseInsensitiveCompare:newHost] == NSOrderedSame) {
        completionHandler(request);
        return;
    }

    NSMutableURLRequest *stripped = [request mutableCopy];
    [stripped setValue:nil forHTTPHeaderField:@"Authorization"];
    completionHandler(stripped);
}

#pragma mark - Credentials

- (nullable NSString *)clientID {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kTidalClientIDDefaultsKey];
}

- (nullable NSString *)clientSecret {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kTidalClientSecretDefaultsKey];
}

#pragma mark - ArtworkSourceProvider Protocol

- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(ArtworkSearchCompletion)completion {

    [self resetCancelledState];

    if (!self.isConfigured) {
        completion(@[], [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorAPIError
                                                         message:@"TIDAL credentials not configured"]);
        return;
    }

    if (!metadata.isSearchable) {
        completion(@[], [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorInvalidMetadata
                                                         message:@"Missing artist or album"]);
        return;
    }

    [self obtainAccessTokenWithCompletion:^(NSString *token, NSError *error) {
        if (self.isCancelled) {
            return;
        }

        if (!token) {
            completion(@[], error);
            return;
        }

        [self performSearchWithMetadata:metadata token:token completion:completion];
    }];
}

- (void)cancel {
    [super cancel];
    [self.tokenTask cancel];
    self.tokenTask = nil;
}

#pragma mark - OAuth Token

- (void)obtainAccessTokenWithCompletion:(void (^)(NSString *_Nullable token,
                                                  NSError *_Nullable error))completion {

    // Reuse cached token when still valid
    if (self.accessToken &&
        self.tokenExpiry &&
        [self.tokenExpiry timeIntervalSinceNow] > kTokenExpiryMargin) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(self.accessToken, nil);
        });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kTidalTokenURL]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [@"grant_type=client_credentials" dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    NSString *credentials = [NSString stringWithFormat:@"%@:%@", [self clientID], [self clientSecret]];
    NSString *basicAuth = [[credentials dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [request setValue:[NSString stringWithFormat:@"Basic %@", basicAuth] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                completion(nil, [ArtworkSourceProviderBase errorFromURLError:error]);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200) {
                completion(nil, [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorAPIError
                    message:[NSString stringWithFormat:@"TIDAL auth error: %ld", (long)httpResponse.statusCode]]);
                return;
            }

            NSString *token = nil;
            NSTimeInterval expiresIn = 0;
            if ([strongSelf parseTokenFromData:data token:&token expiresIn:&expiresIn]) {
                strongSelf.accessToken = token;
                strongSelf.tokenExpiry = [NSDate dateWithTimeIntervalSinceNow:expiresIn];
                completion(token, nil);
            } else {
                completion(nil, [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorAPIError
                                                                 message:@"TIDAL auth: invalid token response"]);
            }
        });
    }];

    self.tokenTask = task;
    [task resume];
}

- (BOOL)parseTokenFromData:(NSData *)data
                     token:(NSString **)outToken
                 expiresIn:(NSTimeInterval *)outExpiresIn {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSString *token = json[@"access_token"];
    if (![token isKindOfClass:[NSString class]] || !TidalAccessTokenIsWellFormed(token)) {
        return NO;
    }

    NSNumber *expiresIn = json[@"expires_in"];
    NSTimeInterval expiry = [expiresIn isKindOfClass:[NSNumber class]] ? expiresIn.doubleValue : 300.0;

    *outToken = token;
    *outExpiresIn = expiry;
    return YES;
}

#pragma mark - Search (Step 1: find album IDs)

- (void)performSearchWithMetadata:(TrackMetadata *)metadata
                            token:(NSString *)token
                       completion:(ArtworkSearchCompletion)completion {

    NSURL *url = [self searchURLForArtist:metadata.albumArtist album:metadata.album];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:[self apiRequestForURL:url token:token]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *apiError = [strongSelf apiErrorForResponse:response error:error];
            if (apiError) {
                completion(@[], apiError);
                return;
            }

            NSArray<NSString *> *albumIDs = [strongSelf parseAlbumIDsFromSearchData:data];
            if (albumIDs.count == 0) {
                completion(@[], nil);
                return;
            }

            [strongSelf fetchCoverArtForAlbumIDs:albumIDs token:token completion:completion];
        });
    }];

    self.currentTask = task;
    [task resume];
}

- (NSURL *)searchURLForArtist:(NSString *)artist album:(NSString *)album {
    NSString *query = [NSString stringWithFormat:@"%@ %@", artist, album];
    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:
                              [NSCharacterSet alphanumericCharacterSet]];

    NSURLComponents *components = [[NSURLComponents alloc] initWithString:
                                   [NSString stringWithFormat:@"%@/searchResults/%@", kTidalAPIBaseURL, encodedQuery]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"countryCode" value:[self countryCode]],
        [NSURLQueryItem queryItemWithName:@"include" value:@"albums"],
    ];
    return components.URL;
}

/// Extract album resource IDs from a searchResults response, preserving
/// the relationship order (relevance) when available
- (NSArray<NSString *> *)parseAlbumIDsFromSearchData:(NSData *)data {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSMutableArray<NSString *> *albumIDs = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    void (^collectID)(id) = ^(id ref) {
        if (![ref isKindOfClass:[NSDictionary class]]) return;
        if (![ref[@"type"] isEqual:@"albums"]) return;
        NSString *albumID = ref[@"id"];
        if (![albumID isKindOfClass:[NSString class]] || albumID.length == 0) return;
        if ([seen containsObject:albumID]) return;
        if (albumIDs.count >= kMaxAlbumResults) return;
        [seen addObject:albumID];
        [albumIDs addObject:albumID];
    };

    // Preferred: relationship linkage on the search result (relevance order)
    NSDictionary *dataObj = json[@"data"];
    if ([dataObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *relationships = dataObj[@"relationships"];
        if ([relationships isKindOfClass:[NSDictionary class]]) {
            NSDictionary *albums = relationships[@"albums"];
            if ([albums isKindOfClass:[NSDictionary class]]) {
                NSArray *refs = albums[@"data"];
                if ([refs isKindOfClass:[NSArray class]]) {
                    for (id ref in refs) collectID(ref);
                }
            }
        }
    }

    // Fallback: album resources in "included"
    NSArray *included = json[@"included"];
    if ([included isKindOfClass:[NSArray class]]) {
        for (id resource in included) collectID(resource);
    }

    return [albumIDs copy];
}

#pragma mark - Search (Step 2: fetch cover art)

- (void)fetchCoverArtForAlbumIDs:(NSArray<NSString *> *)albumIDs
                           token:(NSString *)token
                      completion:(ArtworkSearchCompletion)completion {

    NSURLComponents *components = [[NSURLComponents alloc] initWithString:
                                   [NSString stringWithFormat:@"%@/albums", kTidalAPIBaseURL]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"countryCode" value:[self countryCode]],
        [NSURLQueryItem queryItemWithName:@"filter[id]" value:[albumIDs componentsJoinedByString:@","]],
        [NSURLQueryItem queryItemWithName:@"include" value:@"coverArt"],
    ];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:[self apiRequestForURL:components.URL token:token]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isCancelled) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *apiError = [strongSelf apiErrorForResponse:response error:error];
            if (apiError) {
                completion(@[], apiError);
                return;
            }

            completion([strongSelf parseArtworkFromAlbumsData:data], nil);
        });
    }];

    self.currentTask = task;
    [task resume];
}

/// Parse an /albums?include=coverArt response into ArtworkResults.
/// Albums arrive in "data" with a coverArt relationship; the referenced
/// artworks resources in "included" carry attributes.files[] with
/// href + meta.width/height.
- (NSArray<ArtworkResult *> *)parseArtworkFromAlbumsData:(NSData *)data {
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    // Index artworks resources by id
    NSMutableDictionary<NSString *, NSDictionary *> *artworksByID = [NSMutableDictionary dictionary];
    NSArray *included = json[@"included"];
    if ([included isKindOfClass:[NSArray class]]) {
        for (NSDictionary *resource in included) {
            if (![resource isKindOfClass:[NSDictionary class]]) continue;
            if (![resource[@"type"] isEqual:@"artworks"]) continue;
            NSString *resourceID = resource[@"id"];
            if ([resourceID isKindOfClass:[NSString class]]) {
                artworksByID[resourceID] = resource;
            }
        }
    }

    NSArray *albums = json[@"data"];
    if (![albums isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableArray<ArtworkResult *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seenURLs = [NSMutableSet set];

    for (NSDictionary *album in albums) {
        if (![album isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *relationships = album[@"relationships"];
        if (![relationships isKindOfClass:[NSDictionary class]]) continue;

        NSDictionary *coverArt = relationships[@"coverArt"];
        if (![coverArt isKindOfClass:[NSDictionary class]]) continue;

        // coverArt.data may be a single ref or an array of refs
        NSMutableArray *refs = [NSMutableArray array];
        id refData = coverArt[@"data"];
        if ([refData isKindOfClass:[NSArray class]]) {
            [refs addObjectsFromArray:refData];
        } else if ([refData isKindOfClass:[NSDictionary class]]) {
            [refs addObject:refData];
        }

        for (NSDictionary *ref in refs) {
            if (![ref isKindOfClass:[NSDictionary class]]) continue;
            NSString *artworkID = ref[@"id"];
            if (![artworkID isKindOfClass:[NSString class]]) continue;

            NSDictionary *artwork = artworksByID[artworkID];
            ArtworkResult *result = [self artworkResultFromArtworkResource:artwork seenURLs:seenURLs];
            if (result) {
                [results addObject:result];
            }
        }
    }

    return [results copy];
}

- (nullable ArtworkResult *)artworkResultFromArtworkResource:(nullable NSDictionary *)artwork
                                                     seenURLs:(NSMutableSet<NSString *> *)seenURLs {
    if (![artwork isKindOfClass:[NSDictionary class]]) return nil;

    NSDictionary *attributes = artwork[@"attributes"];
    if (![attributes isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *files = attributes[@"files"];
    if (![files isKindOfClass:[NSArray class]] || files.count == 0) return nil;

    // Pick the largest file as full resolution and the one closest to
    // 500px wide as the thumbnail
    NSDictionary *best = nil;
    NSDictionary *thumb = nil;
    double bestArea = -1;
    double thumbDistance = DBL_MAX;

    for (NSDictionary *file in files) {
        if (![file isKindOfClass:[NSDictionary class]]) continue;
        NSString *href = file[@"href"];
        if (![href isKindOfClass:[NSString class]] || href.length == 0) continue;

        NSDictionary *meta = file[@"meta"];
        double width = 0, height = 0;
        if ([meta isKindOfClass:[NSDictionary class]]) {
            width = [meta[@"width"] isKindOfClass:[NSNumber class]] ? [meta[@"width"] doubleValue] : 0;
            height = [meta[@"height"] isKindOfClass:[NSNumber class]] ? [meta[@"height"] doubleValue] : 0;
        }

        double area = width * height;
        if (area > bestArea) {
            bestArea = area;
            best = file;
        }

        double distance = fabs(width - 500.0);
        if (distance < thumbDistance) {
            thumbDistance = distance;
            thumb = file;
        }
    }

    if (!best) return nil;

    NSString *fullURLString = best[@"href"];
    if ([seenURLs containsObject:fullURLString]) return nil;
    [seenURLs addObject:fullURLString];

    NSURL *fullURL = [NSURL URLWithString:fullURLString];
    if (!fullURL) return nil;

    NSString *thumbURLString = thumb[@"href"];
    NSURL *thumbURL = thumbURLString ? [NSURL URLWithString:thumbURLString] : nil;

    NSDictionary *bestMeta = best[@"meta"];
    CGSize resolution = CGSizeZero;
    if ([bestMeta isKindOfClass:[NSDictionary class]]) {
        double w = [bestMeta[@"width"] isKindOfClass:[NSNumber class]] ? [bestMeta[@"width"] doubleValue] : 0;
        double h = [bestMeta[@"height"] isKindOfClass:[NSNumber class]] ? [bestMeta[@"height"] doubleValue] : 0;
        resolution = CGSizeMake(w, h);
    }

    return [[ArtworkResult alloc] initWithSourceIdentifier:self.identifier
                                                sourceName:self.displayName
                                              thumbnailURL:(thumbURL ?: fullURL)
                                         fullResolutionURL:fullURL
                                                resolution:resolution
                                               artworkType:RemoteArtworkTypeFront];
}

#pragma mark - Request Helpers

- (NSURLRequest *)apiRequestForURL:(NSURL *)url token:(NSString *)token {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/vnd.api+json" forHTTPHeaderField:@"Accept"];
    return request;
}

- (NSString *)countryCode {
    NSString *code = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return (code.length == 2) ? [code uppercaseString] : @"US";
}

/// Map a transport error or non-200 status to an NSError; nil when OK.
/// A 401 also invalidates the cached token so the next search re-authenticates.
- (nullable NSError *)apiErrorForResponse:(NSURLResponse *)response error:(NSError *)error {
    if (error) {
        return [ArtworkSourceProviderBase errorFromURLError:error];
    }

    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode == 200) {
        return nil;
    }

    if (httpResponse.statusCode == 401) {
        self.accessToken = nil;
        self.tokenExpiry = nil;
    }

    if (httpResponse.statusCode == 429) {
        return [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorRateLimited
                                                message:@"Rate limited by TIDAL"];
    }

    return [ArtworkSourceProviderBase errorWithCode:ArtworkFetchErrorAPIError
        message:[NSString stringWithFormat:@"TIDAL error: %ld", (long)httpResponse.statusCode]];
}

@end
