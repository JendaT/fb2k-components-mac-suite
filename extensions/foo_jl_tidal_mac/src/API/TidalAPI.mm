//
//  TidalAPI.mm
//  foo_jl_tidal_mac
//
//  HTTP client implementation for Tidal API
//

#import "TidalAPI.h"
#import "RateLimiter.h"
#import "../Core/TidalErrors.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalModels.h"
#import "../Core/HTTPResponsePolicy.h"
#import "../Core/PaginationPolicy.h"
#import "../Core/ResponseParser.h"
#import "../Services/TidalAuthService.h"

#pragma mark - Pagination

// Hard cap per collection. Hitting it fails the fetch (see
// JLTidalPaginationPolicy) — the sync engine must never see a
// truncated-but-"complete" list.
static const NSInteger kTidalPaginationCeiling = 10000;

typedef void (^JLTidalPageCompletion)(NSArray * _Nullable items, NSError * _Nullable error);
typedef void (^JLTidalPageFetch)(NSInteger limit, NSInteger offset, JLTidalPageCompletion pageCompletion);

@implementation JLTidalDeviceCode

- (instancetype)initWithDeviceCode:(NSString *)deviceCode
                          userCode:(NSString *)userCode
                   verificationURI:(NSURL *)verificationURI
           verificationURIComplete:(NSURL *)verificationURIComplete
                         expiresIn:(NSTimeInterval)expiresIn
                          interval:(NSTimeInterval)interval {
    self = [super init];
    if (self) {
        _deviceCode = [deviceCode copy];
        _userCode = [userCode copy];
        _verificationURI = [verificationURI copy];
        _verificationURIComplete = [verificationURIComplete copy];
        _expiresIn = expiresIn;
        _interval = interval;
    }
    return self;
}

@end

#pragma mark - Form Encoding

// Percent-encode a value for an application/x-www-form-urlencoded body.
// URLQueryAllowedCharacterSet minus the characters that break form parsing:
// "&" (pair separator), "+" (decodes to space), "?" and "/". "=" stays
// allowed to keep the request bytes identical to the previous inline
// builders (servers split each pair on the first "=", so a literal "="
// inside a value — e.g. base64 padding in the client secret — is safe).
static NSString *JLTidalFormEncode(NSString *value) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@"&+?/"];
        allowed = [set copy];
    });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

// Percent-encode a value used inside a URL query string. Stricter than
// URLQueryAllowedCharacterSet (used previously), which leaves "&", "=",
// "+", "?" and "/" raw — a crafted value (e.g. a malicious ISRC tag read
// from a local file) could otherwise inject extra query parameters into
// an authenticated request.
static NSString *JLTidalQueryValueEncode(NSString *value) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableCharacterSet *set = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [set removeCharactersInString:@"&=+?/"];
        allowed = [set copy];
    });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

// Build an OAuth form body from ordered key/value pairs
// (@[key1, value1, key2, value2, ...]). Every value is form-encoded.
static NSData *JLTidalOAuthFormBody(NSArray<NSString *> *keysAndValues) {
    NSMutableArray<NSString *> *pairs = [NSMutableArray arrayWithCapacity:keysAndValues.count / 2];
    for (NSUInteger i = 0; i + 1 < keysAndValues.count; i += 2) {
        [pairs addObject:[NSString stringWithFormat:@"%@=%@",
                          keysAndValues[i], JLTidalFormEncode(keysAndValues[i + 1])]];
    }
    return [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - JSON Access

// Defensive json[key][@"items"] lookup for search responses — returns nil
// unless every level has the expected type.
static NSArray *JLTidalItemsArray(id json, NSString *key) {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id container = ((NSDictionary *)json)[key];
    if (![container isKindOfClass:[NSDictionary class]]) return nil;
    id items = ((NSDictionary *)container)[@"items"];
    return [items isKindOfClass:[NSArray class]] ? (NSArray *)items : nil;
}

@interface JLTidalAPI ()
@property (nonatomic, strong) NSURLSession *urlSession;
@end

@implementation JLTidalAPI

+ (instancetype)shared {
    static JLTidalAPI *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalAPI alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30;
        config.timeoutIntervalForResource = 60;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - Pagination Driver

// Sequentially fetch pages via pageFetch, accumulating until a short page.
// On any page error or on hitting the ceiling the whole fetch fails —
// a partial list is never returned as if complete.
- (void)fetchAllPagesWithLimit:(NSInteger)limit
                        offset:(NSInteger)offset
                   accumulated:(NSMutableArray *)accumulated
                   description:(NSString *)what
                     pageFetch:(JLTidalPageFetch)pageFetch
                    completion:(JLTidalPageCompletion)completion {
    pageFetch(limit, offset, ^(NSArray *items, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        if (items.count > 0) {
            [accumulated addObjectsFromArray:items];
        }
        JLTidalPageAction action =
            [JLTidalPaginationPolicy actionAfterPageCount:(NSInteger)items.count
                                              accumulated:(NSInteger)accumulated.count
                                                    limit:limit
                                                  ceiling:kTidalPaginationCeiling];
        switch (action) {
            case JLTidalPageActionDone:
                completion([accumulated copy], nil);
                break;
            case JLTidalPageActionFailCeiling:
                tidal::logError([[NSString stringWithFormat:
                    @"Pagination ceiling (%ld) hit fetching %@ - treating fetch as failed",
                    (long)kTidalPaginationCeiling, what] UTF8String]);
                completion(nil, JLTidalError(JLTidalErrorInternal,
                    [NSString stringWithFormat:@"%@ exceeds %ld items",
                     what, (long)kTidalPaginationCeiling]));
                break;
            case JLTidalPageActionContinue:
                [self fetchAllPagesWithLimit:limit
                                      offset:(NSInteger)accumulated.count
                                 accumulated:accumulated
                                 description:what
                                   pageFetch:pageFetch
                                  completion:completion];
                break;
        }
    });
}

#pragma mark - OAuth Device Authorization

- (void)requestDeviceCodeWithCompletion:(JLTidalDeviceCodeCompletion)completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",
                                       kTidalAuthBaseURL, kTidalDeviceAuthEndpoint]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    request.HTTPBody = JLTidalOAuthFormBody(@[@"client_id", kTidalClientID,
                                              @"client_secret", kTidalClientSecret,
                                              @"scope", kTidalOAuthScopes]);

    tidal::logDebug("Requesting device code...");

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            tidal::logError([[NSString stringWithFormat:@"Device code request failed: %@", error.localizedDescription] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        if (httpResponse.statusCode != 200) {
            tidal::logError([[NSString stringWithFormat:@"Device code request failed with status: %ld", (long)httpResponse.statusCode] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorServerError,
                [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;
        if (jsonError || !json) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Invalid JSON response"));
            return;
        }

        NSString *deviceCode = json[@"deviceCode"];
        NSString *userCode = json[@"userCode"];
        NSString *verificationUri = json[@"verificationUri"];
        NSString *verificationUriComplete = json[@"verificationUriComplete"];
        NSNumber *expiresIn = json[@"expiresIn"] ?: @(300);
        NSNumber *interval = json[@"interval"] ?: @(5);

        // verificationURI is declared nonnull; an unparseable URL string is a
        // missing-field error, not a nil passed through the contract.
        NSURL *verificationURL = verificationUri ? [NSURL URLWithString:verificationUri] : nil;
        if (!deviceCode || !userCode || !verificationURL) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Missing required fields"));
            return;
        }

        JLTidalDeviceCode *code = [[JLTidalDeviceCode alloc]
            initWithDeviceCode:deviceCode
                      userCode:userCode
               verificationURI:verificationURL
       verificationURIComplete:verificationUriComplete ? [NSURL URLWithString:verificationUriComplete] : nil
                     expiresIn:expiresIn.doubleValue
                      interval:interval.doubleValue];

        tidal::logDebug("Got device code response");
        completion(code, nil);
    }];

    [task resume];
}

- (void)pollForTokenWithDeviceCode:(NSString *)deviceCode
                        completion:(JLTidalSessionCompletion)completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",
                                       kTidalAuthBaseURL, kTidalTokenEndpoint]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    request.HTTPBody = JLTidalOAuthFormBody(@[@"client_id", kTidalClientID,
                                              @"client_secret", kTidalClientSecret,
                                              @"device_code", deviceCode,
                                              @"grant_type", @"urn:ietf:params:oauth:grant-type:device_code",
                                              @"scope", kTidalOAuthScopes]);

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;

        if (httpResponse.statusCode == 400) {
            // Check for pending/expired errors
            NSString *errorCode = json[@"error"];
            if ([errorCode isEqualToString:@"authorization_pending"]) {
                completion(nil, JLTidalError(JLTidalErrorDeviceCodePending, @"Waiting for user authorization"));
                return;
            } else if ([errorCode isEqualToString:@"expired_token"]) {
                completion(nil, JLTidalError(JLTidalErrorDeviceCodeExpired, @"Device code expired"));
                return;
            } else if ([errorCode isEqualToString:@"access_denied"]) {
                completion(nil, JLTidalError(JLTidalErrorAuthorizationDenied, @"User denied authorization"));
                return;
            }
        }

        if (httpResponse.statusCode != 200) {
            completion(nil, JLTidalError(JLTidalErrorServerError,
                [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        if (jsonError || !json) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Invalid JSON response"));
            return;
        }

        // Parse successful token response
        JLTidalSession *session = [JLTidalResponseParser sessionFromTokenResponse:json];
        if (session) {
            [[JLTidalRateLimiter shared] recordSuccess];
            tidal::logInfo("Successfully obtained access token");
        }
        completion(session, session ? nil : JLTidalError(JLTidalErrorInvalidResponse, @"Failed to parse token response"));
    }];

    [task resume];
}

- (void)refreshTokenWithCompletion:(JLTidalSessionCompletion)completion {
    if (!self.session.refreshToken) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"No refresh token available"));
        return;
    }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",
                                       kTidalAuthBaseURL, kTidalTokenEndpoint]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    request.HTTPBody = JLTidalOAuthFormBody(@[@"client_id", kTidalClientID,
                                              @"client_secret", kTidalClientSecret,
                                              @"refresh_token", self.session.refreshToken,
                                              @"grant_type", @"refresh_token",
                                              @"scope", kTidalOAuthScopes]);

    tidal::logDebug("Refreshing access token...");

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        if (httpResponse.statusCode != 200) {
            // Log response body for debugging refresh failures
            NSString *errorDetail = @"";
            if (data.length > 0) {
                NSDictionary *errorJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![errorJson isKindOfClass:[NSDictionary class]]) errorJson = nil;
                if (errorJson) {
                    errorDetail = [NSString stringWithFormat:@" (%@: %@)",
                                   errorJson[@"error"] ?: @"unknown",
                                   errorJson[@"error_description"] ?: errorJson[@"sub_status"] ?: @""];
                }
            }
            tidal::logError([[NSString stringWithFormat:@"Token refresh HTTP %ld%@",
                              (long)httpResponse.statusCode, errorDetail] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorTokenRefreshFailed,
                [NSString stringWithFormat:@"HTTP %ld%@", (long)httpResponse.statusCode, errorDetail]));
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;
        if (jsonError || !json) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Invalid JSON response"));
            return;
        }

        // Parse refreshed token (handles refresh-token rotation)
        JLTidalSession *newSession = [JLTidalResponseParser sessionFromRefreshResponse:json
                                                                        currentSession:self.session];
        if (!newSession) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Missing access token"));
            return;
        }
        self.session = newSession;
        [[JLTidalRateLimiter shared] recordSuccess];
        tidal::logDebug([[NSString stringWithFormat:@"Token refreshed, expires in %.0fs",
                          [newSession.expiryDate timeIntervalSinceNow]] UTF8String]);
        completion(newSession, nil);
    }];

    [task resume];
}

#pragma mark - Track API

- (void)getPlaybackInfoForTrackID:(NSString *)trackID
                          quality:(JLTidalQuality)quality
                       completion:(JLTidalDataCompletion)completion {
    NSString *qualityStr = JLTidalQualityToString(quality);

    NSString *urlStr = [NSString stringWithFormat:@"%@%@?audioquality=%@&playbackmode=STREAM&assetpresentation=FULL",
                        kTidalAPIBaseURL,
                        [NSString stringWithFormat:kTidalPlaybackInfoEndpoint, trackID],
                        qualityStr];

    NSURL *url = [NSURL URLWithString:urlStr];
    [self requestWithURL:url method:@"GET" body:nil completion:completion];
}

- (void)getTrackMetadataForTrackID:(NSString *)trackID
                        completion:(JLTidalDataCompletion)completion {
    NSString *urlStr = [NSString stringWithFormat:@"%@%@",
                        kTidalAPIBaseURL,
                        [NSString stringWithFormat:kTidalTrackMetadataEndpoint, trackID]];

    NSURL *url = [NSURL URLWithString:urlStr];
    [self requestWithURL:url method:@"GET" body:nil completion:completion];
}

#pragma mark - Search API

- (void)searchTracksWithQuery:(NSString *)query
                        limit:(NSInteger)limit
                       offset:(NSInteger)offset
                   completion:(JLTidalTracksCompletion)completion {
    if (!query.length) {
        completion(@[], nil);
        return;
    }

    NSString *encodedQuery = JLTidalQueryValueEncode(query);

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/search?query=%@&types=TRACKS&limit=%ld&offset=%ld",
                        kTidalAPIBaseURL,
                        encodedQuery,
                        (long)limit,
                        (long)offset];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalTrack *> *tracks =
            [JLTidalResponseParser tracksFromItems:JLTidalItemsArray(json, @"tracks")];
        tidal::logDebug([[NSString stringWithFormat:@"Search returned %lu tracks", (unsigned long)tracks.count] UTF8String]);
        completion(tracks, nil);
    }];
}

- (void)searchAlbumsWithQuery:(NSString *)query
                        limit:(NSInteger)limit
                       offset:(NSInteger)offset
                   completion:(JLTidalAlbumsCompletion)completion {
    if (!query.length) {
        completion(@[], nil);
        return;
    }

    NSString *encodedQuery = JLTidalQueryValueEncode(query);

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/search?query=%@&types=ALBUMS&limit=%ld&offset=%ld",
                        kTidalAPIBaseURL, encodedQuery, (long)limit, (long)offset];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalAlbum *> *albums =
            [JLTidalResponseParser albumsFromItems:JLTidalItemsArray(json, @"albums")];
        tidal::logDebug([[NSString stringWithFormat:@"Album search returned %lu results",
                          (unsigned long)albums.count] UTF8String]);
        completion(albums, nil);
    }];
}

- (void)searchArtistsWithQuery:(NSString *)query
                         limit:(NSInteger)limit
                        offset:(NSInteger)offset
                    completion:(JLTidalArtistsCompletion)completion {
    if (!query.length) {
        completion(@[], nil);
        return;
    }

    NSString *encodedQuery = JLTidalQueryValueEncode(query);

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/search?query=%@&types=ARTISTS&limit=%ld&offset=%ld",
                        kTidalAPIBaseURL, encodedQuery, (long)limit, (long)offset];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalArtist *> *artists =
            [JLTidalResponseParser artistsFromItems:JLTidalItemsArray(json, @"artists")];
        tidal::logDebug([[NSString stringWithFormat:@"Artist search returned %lu results",
                          (unsigned long)artists.count] UTF8String]);
        completion(artists, nil);
    }];
}

#pragma mark - Album API

- (void)getAlbumTracksForAlbumID:(NSString *)albumID
                      completion:(JLTidalTracksCompletion)completion {
    if (!albumID.length) {
        completion(@[], nil);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/albums/%@/tracks?limit=100",
                        kTidalAPIBaseURL, albumID];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalTrack *> *tracks =
            [JLTidalResponseParser tracksFromItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Album %@ has %lu tracks",
                          albumID, (unsigned long)tracks.count] UTF8String]);
        completion(tracks, nil);
    }];
}

#pragma mark - Artist API

- (void)getArtistTopTracksForArtistID:(NSString *)artistID
                                limit:(NSInteger)limit
                           completion:(JLTidalTracksCompletion)completion {
    if (!artistID.length) {
        completion(@[], nil);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/artists/%@/toptracks?limit=%ld",
                        kTidalAPIBaseURL, artistID, (long)limit];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalTrack *> *tracks =
            [JLTidalResponseParser tracksFromItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Artist %@ has %lu top tracks",
                          artistID, (unsigned long)tracks.count] UTF8String]);
        completion(tracks, nil);
    }];
}

- (void)getArtistAlbumsForArtistID:(NSString *)artistID
                             limit:(NSInteger)limit
                        completion:(JLTidalAlbumsCompletion)completion {
    if (!artistID.length) {
        completion(@[], nil);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/artists/%@/albums?limit=%ld",
                        kTidalAPIBaseURL, artistID, (long)limit];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalAlbum *> *albums =
            [JLTidalResponseParser albumsFromItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Artist %@ has %lu albums",
                          artistID, (unsigned long)albums.count] UTF8String]);
        completion(albums, nil);
    }];
}

#pragma mark - Favorites API

- (void)getFavoriteTracksWithLimit:(NSInteger)limit
                            offset:(NSInteger)offset
                        completion:(JLTidalTracksCompletion)completion {
    NSString *userId = self.session.userId;
    if (!userId.length) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"No user ID available"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/users/%@/favorites/tracks?limit=%ld&offset=%ld",
                        kTidalAPIBaseURL, userId, (long)limit, (long)offset];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        // Favorites API wraps each track in an "item" key
        NSArray<JLTidalTrack *> *tracks =
            [JLTidalResponseParser tracksFromWrappedItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Got %lu favorite tracks",
                          (unsigned long)tracks.count] UTF8String]);
        completion(tracks, nil);
    }];
}

- (void)getAllFavoriteTracksWithCompletion:(JLTidalTracksCompletion)completion {
    JLTidalPageFetch pageFetch = ^(NSInteger limit, NSInteger offset, JLTidalPageCompletion pageCompletion) {
        [self getFavoriteTracksWithLimit:limit offset:offset
                              completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
            pageCompletion(tracks, error);
        }];
    };

    [self fetchAllPagesWithLimit:200
                          offset:0
                     accumulated:[NSMutableArray array]
                     description:@"favorite tracks"
                       pageFetch:pageFetch
                      completion:^(NSArray *tracks, NSError *error) {
        completion((NSArray<JLTidalTrack *> *)tracks, error);
    }];
}

- (void)getFavoriteAlbumsWithLimit:(NSInteger)limit
                            offset:(NSInteger)offset
                        completion:(JLTidalAlbumsCompletion)completion {
    NSString *userId = self.session.userId;
    if (!userId.length) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"No user ID available"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/users/%@/favorites/albums?limit=%ld&offset=%ld",
                        kTidalAPIBaseURL, userId, (long)limit, (long)offset];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalAlbum *> *albums =
            [JLTidalResponseParser albumsFromWrappedItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Got %lu favorite albums",
                          (unsigned long)albums.count] UTF8String]);
        completion(albums, nil);
    }];
}

- (void)getAllFavoriteAlbumsWithCompletion:(JLTidalAlbumsCompletion)completion {
    JLTidalPageFetch pageFetch = ^(NSInteger limit, NSInteger offset, JLTidalPageCompletion pageCompletion) {
        [self getFavoriteAlbumsWithLimit:limit offset:offset
                              completion:^(NSArray<JLTidalAlbum *> *albums, NSError *error) {
            pageCompletion(albums, error);
        }];
    };

    [self fetchAllPagesWithLimit:100
                          offset:0
                     accumulated:[NSMutableArray array]
                     description:@"favorite albums"
                       pageFetch:pageFetch
                      completion:^(NSArray *albums, NSError *error) {
        completion((NSArray<JLTidalAlbum *> *)albums, error);
    }];
}

- (void)addTrackToFavorites:(NSString *)trackID
                 completion:(JLTidalBoolCompletion)completion {
    NSString *userId = self.session.userId;
    if (!userId.length) {
        completion(NO, JLTidalError(JLTidalErrorNotAuthenticated, @"No user ID available"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/users/%@/favorites/tracks",
                        kTidalAPIBaseURL, userId];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"POST" body:@{@"trackIds": trackID}
              completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            // 200 or 201 both indicate success; some errors may still be "already favorited"
            completion(NO, error);
        } else {
            tidal::logDebug([[NSString stringWithFormat:@"Added track %@ to favorites", trackID] UTF8String]);
            completion(YES, nil);
        }
    }];
}

- (void)removeTrackFromFavorites:(NSString *)trackID
                      completion:(JLTidalBoolCompletion)completion {
    NSString *userId = self.session.userId;
    if (!userId.length) {
        completion(NO, JLTidalError(JLTidalErrorNotAuthenticated, @"No user ID available"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/users/%@/favorites/tracks/%@",
                        kTidalAPIBaseURL, userId, trackID];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"DELETE" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, error);
        } else {
            tidal::logDebug([[NSString stringWithFormat:@"Removed track %@ from favorites", trackID] UTF8String]);
            completion(YES, nil);
        }
    }];
}

#pragma mark - Playlists API

- (void)getUserPlaylistsWithCompletion:(JLTidalPlaylistsCompletion)completion {
    NSString *userId = self.session.userId;
    if (!userId.length) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"No user ID available"));
        return;
    }

    JLTidalPageFetch pageFetch = ^(NSInteger limit, NSInteger offset, JLTidalPageCompletion pageCompletion) {
        NSString *urlStr = [NSString stringWithFormat:@"%@/v1/users/%@/playlists?limit=%ld&offset=%ld",
                            kTidalAPIBaseURL, userId, (long)limit, (long)offset];
        [self requestWithURL:[NSURL URLWithString:urlStr] method:@"GET" body:nil
                  completion:^(NSDictionary *json, NSError *error) {
            if (error) {
                pageCompletion(nil, error);
                return;
            }
            pageCompletion([JLTidalResponseParser playlistsFromItems:json[@"items"]], nil);
        }];
    };

    [self fetchAllPagesWithLimit:50
                          offset:0
                     accumulated:[NSMutableArray array]
                     description:@"user playlists"
                       pageFetch:pageFetch
                      completion:^(NSArray *playlists, NSError *error) {
        if (!error) {
            tidal::logDebug([[NSString stringWithFormat:@"Got %lu playlists",
                              (unsigned long)playlists.count] UTF8String]);
        }
        completion((NSArray<JLTidalPlaylist *> *)playlists, error);
    }];
}

- (void)getPlaylistTracksForPlaylistID:(NSString *)playlistUUID
                                 limit:(NSInteger)limit
                                offset:(NSInteger)offset
                            completion:(JLTidalTracksCompletion)completion {
    if (!playlistUUID.length) {
        completion(@[], nil);
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/playlists/%@/tracks?limit=%ld&offset=%ld",
                        kTidalAPIBaseURL, playlistUUID, (long)limit, (long)offset];

    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        // Playlist tracks API wraps each track in an "item" key
        NSArray<JLTidalTrack *> *tracks =
            [JLTidalResponseParser tracksFromWrappedItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Playlist %@ has %lu tracks",
                          playlistUUID, (unsigned long)tracks.count] UTF8String]);
        completion(tracks, nil);
    }];
}

- (void)getAllPlaylistTracksForPlaylistID:(NSString *)playlistUUID
                               completion:(JLTidalTracksCompletion)completion {
    if (!playlistUUID.length) {
        completion(@[], nil);
        return;
    }

    JLTidalPageFetch pageFetch = ^(NSInteger limit, NSInteger offset, JLTidalPageCompletion pageCompletion) {
        [self getPlaylistTracksForPlaylistID:playlistUUID limit:limit offset:offset
                                  completion:^(NSArray<JLTidalTrack *> *tracks, NSError *error) {
            pageCompletion(tracks, error);
        }];
    };

    [self fetchAllPagesWithLimit:200
                          offset:0
                     accumulated:[NSMutableArray array]
                     description:[NSString stringWithFormat:@"playlist %@ tracks", playlistUUID]
                       pageFetch:pageFetch
                      completion:^(NSArray *tracks, NSError *error) {
        completion((NSArray<JLTidalTrack *> *)tracks, error);
    }];
}

- (void)createPlaylistWithTitle:(NSString *)title
                    description:(NSString *)description
                     completion:(JLTidalPlaylistCompletion)completion {
    NSString *userId = self.session.userId;
    if (!userId.length) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"No user ID available"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/users/%@/playlists",
                        kTidalAPIBaseURL, userId];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"title"] = title ?: @"Untitled";
    if (description.length > 0) {
        body[@"description"] = description;
    }

    [self requestWithURL:url method:@"POST" body:body completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        JLTidalPlaylist *playlist = [[JLTidalPlaylist alloc] initWithDictionary:json];
        tidal::logDebug([[NSString stringWithFormat:@"Created playlist: %@ (%@)",
                          playlist.title, playlist.playlistUUID] UTF8String]);
        completion(playlist, nil);
    }];
}

- (void)addTrackIDs:(NSArray<NSString *> *)trackIDs
       toPlaylistID:(NSString *)playlistUUID
               etag:(NSString *)etag
         completion:(JLTidalBoolCompletion)completion {
    if (!playlistUUID.length || trackIDs.count == 0) {
        completion(NO, JLTidalError(JLTidalErrorInvalidURL, @"Missing playlist UUID or track IDs"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/playlists/%@/items",
                        kTidalAPIBaseURL, playlistUUID];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSDictionary *body = @{
        @"trackIds": [trackIDs componentsJoinedByString:@","],
        @"onArtifactNotFound": @"SKIP",
        @"onDupes": @"SKIP"
    };

    NSDictionary *headers = etag.length > 0 ? @{@"If-None-Match": etag} : nil;

    [self requestWithURL:url method:@"POST" body:body headers:headers completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, error);
        } else {
            tidal::logDebug([[NSString stringWithFormat:@"Added %lu tracks to playlist %@",
                              (unsigned long)trackIDs.count, playlistUUID] UTF8String]);
            completion(YES, nil);
        }
    }];
}

- (void)removeTrackAtIndices:(NSIndexSet *)indices
              fromPlaylistID:(NSString *)playlistUUID
                        etag:(NSString *)etag
                  completion:(JLTidalBoolCompletion)completion {
    if (!playlistUUID.length || indices.count == 0) {
        completion(NO, JLTidalError(JLTidalErrorInvalidURL, @"Missing playlist UUID or indices"));
        return;
    }

    // Build comma-separated index string
    NSMutableArray<NSString *> *indexStrings = [NSMutableArray array];
    [indices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        [indexStrings addObject:[NSString stringWithFormat:@"%lu", (unsigned long)idx]];
    }];
    NSString *indicesStr = [indexStrings componentsJoinedByString:@","];

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/playlists/%@/items/%@",
                        kTidalAPIBaseURL, playlistUUID, indicesStr];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSDictionary *headers = etag.length > 0 ? @{@"If-None-Match": etag} : nil;

    [self requestWithURL:url method:@"DELETE" body:nil headers:headers completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, error);
        } else {
            tidal::logDebug([[NSString stringWithFormat:@"Removed %lu tracks from playlist %@",
                              (unsigned long)indices.count, playlistUUID] UTF8String]);
            completion(YES, nil);
        }
    }];
}

- (void)deletePlaylistWithID:(NSString *)playlistUUID
                  completion:(JLTidalBoolCompletion)completion {
    if (!playlistUUID.length) {
        completion(NO, JLTidalError(JLTidalErrorInvalidURL, @"Missing playlist UUID"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/playlists/%@",
                        kTidalAPIBaseURL, playlistUUID];
    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"DELETE" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(NO, error);
        } else {
            tidal::logDebug([[NSString stringWithFormat:@"Deleted playlist %@", playlistUUID] UTF8String]);
            completion(YES, nil);
        }
    }];
}

- (void)getPlaylistETagForID:(NSString *)playlistUUID
                  completion:(JLTidalETagCompletion)completion {
    if (!playlistUUID.length) {
        completion(nil, JLTidalError(JLTidalErrorInvalidURL, @"Missing playlist UUID"));
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/playlists/%@",
                        kTidalAPIBaseURL, playlistUUID];
    NSURL *url = [NSURL URLWithString:urlStr];

    // We need the raw response headers, so do a manual request
    if (!self.session.isValid) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"Not authenticated"));
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.session.accessToken]
   forHTTPHeaderField:@"Authorization"];

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;
        if (httpResponse.statusCode != 200) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse,
                [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        NSString *etag = httpResponse.allHeaderFields[@"ETag"]
                      ?: httpResponse.allHeaderFields[@"etag"];
        if (!etag.length) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"No ETag in response"));
            return;
        }

        tidal::logDebug([[NSString stringWithFormat:@"ETag for playlist %@: %@",
                          playlistUUID, etag] UTF8String]);
        completion(etag, nil);
    }];
    [task resume];
}

- (void)getPlaylistFoldersWithCompletion:(JLTidalFoldersCompletion)completion {
    NSString *urlStr = [NSString stringWithFormat:@"%@/my-collection/playlists/folders",
                        kTidalAPIv2BaseURL];
    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalPlaylistFolder *> *folders =
            [JLTidalResponseParser foldersFromItems:json[@"items"]];
        tidal::logDebug([[NSString stringWithFormat:@"Got %lu playlist folders",
                          (unsigned long)folders.count] UTF8String]);
        completion(folders, nil);
    }];
}

- (void)getTrackByISRC:(NSString *)isrc
            completion:(JLTidalTracksCompletion)completion {
    if (!isrc.length) {
        completion(@[], nil);
        return;
    }

    // Use search API with ISRC as query (v1 approach)
    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/search/tracks?query=%@&limit=5",
                        kTidalAPIBaseURL,
                        JLTidalQueryValueEncode(isrc)];
    NSURL *url = [NSURL URLWithString:urlStr];

    [self requestWithURL:url method:@"GET" body:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSArray<JLTidalTrack *> *matches =
            [JLTidalResponseParser tracksFromItems:json[@"items"] matchingISRC:isrc];
        tidal::logDebug([[NSString stringWithFormat:@"ISRC lookup %@: %lu matches",
                          isrc, (unsigned long)matches.count] UTF8String]);
        completion(matches, nil);
    }];
}

#pragma mark - Generic Request

- (void)requestWithURL:(NSURL *)url
                method:(NSString *)method
                  body:(NSDictionary *)body
            completion:(JLTidalDataCompletion)completion {
    [self requestWithURL:url method:method body:body headers:nil completion:completion];
}

- (void)requestWithURL:(NSURL *)url
                method:(NSString *)method
                  body:(NSDictionary *)body
               headers:(NSDictionary<NSString *, NSString *> *)extraHeaders
            completion:(JLTidalDataCompletion)completion {
    // Check rate limiting
    NSTimeInterval delay = [[JLTidalRateLimiter shared] currentDelay];
    if (delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self performRequestWithURL:url method:method body:body headers:extraHeaders completion:completion];
        });
    } else {
        [self performRequestWithURL:url method:method body:body headers:extraHeaders completion:completion];
    }
}

- (void)performRequestWithURL:(NSURL *)url
                       method:(NSString *)method
                         body:(NSDictionary *)body
                      headers:(NSDictionary<NSString *, NSString *> *)extraHeaders
                   completion:(JLTidalDataCompletion)completion {
    [self performRequestWithURL:url method:method body:body headers:extraHeaders isRetry:NO completion:completion];
}

- (void)performRequestWithURL:(NSURL *)url
                       method:(NSString *)method
                         body:(NSDictionary *)body
                      headers:(NSDictionary<NSString *, NSString *> *)extraHeaders
                      isRetry:(BOOL)isRetry
                   completion:(JLTidalDataCompletion)completion {
    if (!self.session.isValid) {
        // Token expired - try refresh before giving up (unless already retrying)
        if (!isRetry && self.session.refreshToken.length > 0) {
            tidal::logDebug("Session expired, attempting token refresh before request");
            [[JLTidalAuthService shared] refreshTokenIfNeededWithCompletion:^(BOOL success) {
                if (success) {
                    [self performRequestWithURL:url method:method body:body
                                       headers:extraHeaders isRetry:YES completion:completion];
                } else {
                    completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"Not authenticated"));
                }
            }];
            return;
        }
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"Not authenticated"));
        return;
    }

    // Log host + path only — query strings can carry signed-URL tokens.
    tidal::logDebug([[NSString stringWithFormat:@"API request: %@ %@%@ (countryCode=%@)",
                      method, url.host ?: @"?", url.path ?: @"",
                      self.session.countryCode ?: @"(nil)"] UTF8String]);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.session.accessToken]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    // Apply extra headers (e.g., If-None-Match for ETag)
    for (NSString *key in extraHeaders) {
        [request setValue:extraHeaders[key] forHTTPHeaderField:key];
    }

    if (self.session.countryCode) {
        // Add country code as query parameter if not already present
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSMutableArray *queryItems = [components.queryItems mutableCopy] ?: [NSMutableArray array];
        BOOL hasCountry = NO;
        for (NSURLQueryItem *item in queryItems) {
            if ([item.name isEqualToString:@"countryCode"]) {
                hasCountry = YES;
                break;
            }
        }
        if (!hasCountry) {
            [queryItems addObject:[NSURLQueryItem queryItemWithName:@"countryCode" value:self.session.countryCode]];
            components.queryItems = queryItems;
            request.URL = components.URL;
        }
    }

    if (body) {
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        NSError *jsonError;
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
        if (jsonError) {
            completion(nil, JLTidalError(JLTidalErrorInternal, @"Failed to serialize request body"));
            return;
        }
    }

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (NSHTTPURLResponse *)response : nil;

        // Status -> action mapping lives in JLTidalHTTPResponsePolicy (pure,
        // unit-tested); this block applies the decision (limiter bookkeeping,
        // token refresh, completion).
        NSString *retryAfterHeader = httpResponse.allHeaderFields[@"Retry-After"]
                                  ?: httpResponse.allHeaderFields[@"retry-after"];
        JLTidalHTTPDecision *decision =
            [JLTidalHTTPResponsePolicy decisionForStatusCode:httpResponse.statusCode
                                            retryAfterHeader:retryAfterHeader
                                                     isRetry:isRetry];

        if (decision.action == JLTidalHTTPActionRateLimited) {
            NSTimeInterval retryAfter;
            if (decision.retryAfterSeconds >= 0) {
                retryAfter = decision.retryAfterSeconds;
                [[JLTidalRateLimiter shared] recordRateLimitHit];
            } else {
                retryAfter = [[JLTidalRateLimiter shared] recordRateLimitHit];
            }
            tidal::logDebug([[NSString stringWithFormat:@"Rate limited, retry after %.1fs", retryAfter] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorRateLimited,
                [NSString stringWithFormat:@"Rate limited, retry after %.0f seconds", retryAfter]));
            return;
        }

        if (decision.action == JLTidalHTTPActionRetryAuth) {
            tidal::logDebug("Got 401, attempting token refresh and retry");
            [[JLTidalAuthService shared] refreshTokenIfNeededWithCompletion:^(BOOL success) {
                if (success) {
                    [self performRequestWithURL:url method:method body:body
                                       headers:extraHeaders isRetry:YES completion:completion];
                } else {
                    completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"Authentication required"));
                }
            }];
            return;
        }

        if (decision.action == JLTidalHTTPActionFail) {
            completion(nil, JLTidalError(decision.errorCode, decision.message));
            return;
        }

        [[JLTidalRateLimiter shared] recordSuccess];

        // 204 No Content or empty body - return empty dict
        if (httpResponse.statusCode == 204 || !data || data.length == 0) {
            completion(@{}, nil);
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (![json isKindOfClass:[NSDictionary class]]) json = nil;
        if (jsonError || !json) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Invalid JSON response"));
            return;
        }

        completion(json, nil);
    }];

    [task resume];
}

@end
