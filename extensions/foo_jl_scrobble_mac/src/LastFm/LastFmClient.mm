//
//  LastFmClient.mm
//  foo_scrobble_mac
//
//  Last.fm API client implementation
//

#import "LastFmClient.h"
#import "LastFmClient+Private.h"
#import "LastFmConstants.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/TopAlbum.h"
#import "../Core/RecentTrack.h"
#import "../Core/ScrobbleConfig.h"
#import "../Core/MD5.h"

// Discovery state implementation
@implementation LastFmStreakDiscoveryState
@end

@interface LastFmClient ()
@property (nonatomic, strong) NSURLSession* urlSession;
@end

@implementation LastFmClient

#pragma mark - Singleton

+ (instancetype)shared {
    static LastFmClient* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LastFmClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = LastFm::kRequestTimeout;
        config.timeoutIntervalForResource = LastFm::kRequestTimeout * 2;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
        _activeDiscoveries = [NSMutableDictionary dictionary];
        _artistImageCache = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Request Signing

- (NSString*)signatureForParameters:(NSDictionary<NSString*, NSString*>*)params {
    // Sort keys alphabetically, excluding "format" and "callback"
    NSMutableArray* sortedKeys = [[params.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    [sortedKeys removeObject:@"format"];
    [sortedKeys removeObject:@"callback"];

    // Build signature base: key1value1key2value2...secret
    NSMutableString* signatureBase = [NSMutableString string];
    for (NSString* key in sortedKeys) {
        [signatureBase appendString:key];
        [signatureBase appendString:params[key]];
    }
    [signatureBase appendString:@(LastFm::kApiSecret)];

    // Return MD5 hash
    return MD5Hash(signatureBase);
}

#pragma mark - URL Building

- (NSString*)urlEncode:(NSString*)string {
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=+#"];
    return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

- (NSString*)buildPostBody:(NSDictionary<NSString*, NSString*>*)params {
    NSMutableArray* pairs = [NSMutableArray array];
    for (NSString* key in params) {
        NSString* encodedKey = [self urlEncode:key];
        NSString* encodedValue = [self urlEncode:params[key]];
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", encodedKey, encodedValue]];
    }
    return [pairs componentsJoinedByString:@"&"];
}

#pragma mark - Request Execution

- (void)executeSignedRequest:(NSDictionary<NSString*, NSString*>*)baseParams
                  completion:(void(^)(NSDictionary* _Nullable response, NSError* _Nullable error))completion {

    // Add common parameters
    NSMutableDictionary* params = [baseParams mutableCopy];
    params[@"api_key"] = @(LastFm::kApiKey);
    params[@"format"] = @"json";

    // Add signature
    NSString* signature = [self signatureForParameters:params];
    params[@"api_sig"] = signature;

    // Build POST request
    NSURL* url = [NSURL URLWithString:@(LastFm::kBaseUrl)];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [[self buildPostBody:params] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"foo_scrobble_mac/1.0" forHTTPHeaderField:@"User-Agent"];

    // Execute
    [[_urlSession dataTaskWithRequest:request
                    completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }

        // Parse JSON response
        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, jsonError ?: [NSError errorWithDomain:LastFmErrorDomain
                                                                 code:LastFmErrorOperationFailed
                                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            });
            return;
        }

        // Check for API error
        if (json[@"error"]) {
            NSInteger errorCode = [json[@"error"] integerValue];
            NSString* message = json[@"message"] ?: @"Unknown error";
            NSError* apiError = LastFmMakeError((LastFmErrorCode)errorCode, message);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, apiError);
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(json, nil);
        });
    }] resume];
}

- (void)executeUnsignedGETRequest:(NSDictionary<NSString*, NSString*>*)baseParams
                       completion:(void(^)(NSDictionary* _Nullable response, NSError* _Nullable error))completion {
    // Build URL with query parameters (no signing needed for public API methods)
    NSMutableDictionary* params = [baseParams mutableCopy];
    params[@"api_key"] = @(LastFm::kApiKey);
    params[@"format"] = @"json";

    NSURLComponents* components = [NSURLComponents componentsWithString:@(LastFm::kBaseUrl)];
    NSMutableArray* queryItems = [NSMutableArray array];
    for (NSString* key in params) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:params[key]]];
    }
    components.queryItems = queryItems;

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:components.URL];
    request.HTTPMethod = @"GET";
    [request setValue:@"foo_scrobble_mac/1.0" forHTTPHeaderField:@"User-Agent"];

    [[_urlSession dataTaskWithRequest:request
                    completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }

        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:0
                                                               error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, jsonError ?: [NSError errorWithDomain:LastFmErrorDomain
                                                                 code:LastFmErrorOperationFailed
                                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid response"}]);
            });
            return;
        }

        if (json[@"error"]) {
            NSInteger errorCode = [json[@"error"] integerValue];
            NSString* message = json[@"message"] ?: @"Unknown error";
            NSError* apiError = LastFmMakeError((LastFmErrorCode)errorCode, message);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, apiError);
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(json, nil);
        });
    }] resume];
}

#pragma mark - Authentication

- (void)requestAuthTokenWithCompletion:(LastFmTokenCompletion)completion {
    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetToken)
    };

    [self executeSignedRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSString* token = response[@"token"];
        if ([token isKindOfClass:[NSString class]] && token.length > 0) {
            completion(token, nil);
        } else {
            completion(nil, LastFmMakeError(LastFmErrorOperationFailed, @"No token in response"));
        }
    }];
}

- (void)requestSessionWithToken:(NSString*)token
                     completion:(LastFmSessionCompletion)completion {
    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetSession),
        @"token": token
    };

    [self executeSignedRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, error);
            return;
        }

        LastFmSession* session = [LastFmSession sessionFromResponse:response];
        if (session) {
            completion(session, nil);
        } else {
            completion(nil, LastFmMakeError(LastFmErrorOperationFailed, @"Invalid session response"));
        }
    }];
}

- (NSURL*)authorizationURLWithToken:(NSString*)token {
    NSString* urlString = [NSString stringWithFormat:@"%s?api_key=%s&token=%@",
                           LastFm::kAuthUrl,
                           LastFm::kApiKey,
                           [self urlEncode:token]];
    return [NSURL URLWithString:urlString];
}

- (void)validateSessionWithCompletion:(LastFmValidationCompletion)completion {
    if (!_session || !_session.isValid) {
        completion(NO, nil, nil);
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetUserInfo),
        @"sk": _session.sessionKey
    };

    [self executeSignedRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            // Check if session is invalid
            if (error.code == LastFmErrorInvalidSessionKey ||
                error.code == LastFmErrorAuthenticationFailed) {
                completion(NO, nil, error);
            } else {
                // Other errors (network, etc) - don't invalidate session
                completion(YES, self.session.username, error);
            }
            return;
        }

        NSDictionary* user = response[@"user"];
        NSString* name = user[@"name"];
        completion(YES, name, nil);
    }];
}

- (void)fetchUserInfoWithCompletion:(LastFmUserInfoCompletion)completion {
    if (!_session || !_session.isValid) {
        completion(nil, nil, LastFmMakeError(LastFmErrorAuthenticationFailed, @"Not authenticated"));
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetUserInfo),
        @"sk": _session.sessionKey
    };

    [self executeSignedRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }

        NSDictionary* user = response[@"user"];
        NSString* name = user[@"name"];

        // Get profile image URL - Last.fm returns array of images in different sizes
        // We want "large" (174x174) or "extralarge" (300x300)
        NSURL* imageURL = nil;
        NSArray* images = user[@"image"];
        if ([images isKindOfClass:[NSArray class]]) {
            for (NSDictionary* img in images) {
                NSString* size = img[@"size"];
                NSString* urlStr = img[@"#text"];
                if ([size isEqualToString:@"large"] || [size isEqualToString:@"extralarge"]) {
                    if (urlStr.length > 0) {
                        imageURL = [NSURL URLWithString:urlStr];
                        if ([size isEqualToString:@"extralarge"]) {
                            break;  // Prefer extralarge
                        }
                    }
                }
            }
        }

        completion(name, imageURL, nil);
    }];
}

#pragma mark - Recent Tracks

- (void)fetchRecentTracks:(NSString*)username
                    limit:(NSInteger)limit
               completion:(LastFmRecentTracksCompletion)completion {
    [self fetchRecentTracksPage:username from:0 to:0 page:1 limit:limit
                     completion:^(NSArray *trackDicts, NSInteger totalPages, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSMutableArray<RecentTrack *> *tracks = [NSMutableArray array];
        for (NSDictionary *dict in trackDicts) {
            RecentTrack *track = [RecentTrack trackFromDictionary:dict];
            if (track) {
                [tracks addObject:track];
            }
        }
        completion(tracks, nil);
    }];
}

#pragma mark - Artist Image Scraping

- (void)scrapeArtistImageURL:(NSString*)artistName
                  completion:(LastFmArtistImageCompletion)completion {

    if (!artistName || artistName.length == 0) {
        completion(nil, nil);
        return;
    }

    // Check cache first (using lowercase key for case-insensitive matching)
    NSString *cacheKey = [artistName lowercaseString];
    id cached = _artistImageCache[cacheKey];
    if (cached) {
        if ([cached isKindOfClass:[NSURL class]]) {
            completion((NSURL*)cached, nil);
        } else {
            // NSNull means we tried and found nothing
            completion(nil, nil);
        }
        return;
    }

    // Build artist page URL
    // URL encode the artist name for the path
    NSString *encodedArtist = [artistName stringByAddingPercentEncodingWithAllowedCharacters:
        [NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"https://www.last.fm/music/%@", encodedArtist];
    NSURL *url = [NSURL URLWithString:urlString];

    if (!url) {
        _artistImageCache[cacheKey] = [NSNull null];
        completion(nil, nil);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 10.0;

    [[_urlSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            // Don't cache network errors - might be temporary
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }

        NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!html) {
            self->_artistImageCache[cacheKey] = [NSNull null];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, nil);
            });
            return;
        }

        // Look for header-new-background-image with background-image style
        // Pattern: class="header-new-background-image"... style="background-image: url(https://...)"
        NSURL *imageURL = nil;

        // Try multiple patterns since Last.fm HTML structure may vary
        NSArray *patterns = @[
            // Pattern 1: header-new-background-image with inline style
            @"header-new-background-image[^>]*style=\"[^\"]*background-image:\\s*url\\(([^)]+)\\)",
            // Pattern 2: og:image meta tag
            @"<meta[^>]+property=\"og:image\"[^>]+content=\"([^\"]+)\"",
            @"<meta[^>]+content=\"([^\"]+)\"[^>]+property=\"og:image\"",
            // Pattern 3: Any lastfm image URL in avatar format (artist photos section)
            @"\"(https://lastfm\\.freetls\\.fastly\\.net/i/u/avatar[^\"]+)\"",
            // Pattern 4: ar0 sized images (full artist images)
            @"\"(https://lastfm\\.freetls\\.fastly\\.net/i/u/ar0/[^\"]+)\""
        ];

        for (NSString *pattern in patterns) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                   options:NSRegularExpressionCaseInsensitive
                                                                                     error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
            if (match && match.numberOfRanges > 1) {
                NSString *urlStr = [html substringWithRange:[match rangeAtIndex:1]];
                // Clean up URL (remove escapes, trim whitespace)
                urlStr = [urlStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                urlStr = [urlStr stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];

                // Skip placeholder images
                if ([urlStr containsString:@"2a96cbd8b46e442fc41c2b86b821562f"]) {
                    continue;
                }

                // Upgrade to larger size if it's an avatar URL
                if ([urlStr containsString:@"avatar170s"]) {
                    urlStr = [urlStr stringByReplacingOccurrencesOfString:@"avatar170s" withString:@"avatar300s"];
                }

                imageURL = [NSURL URLWithString:urlStr];
                if (imageURL) {
                    NSLog(@"[LastFmClient] Scraped artist image for '%@': %@", artistName, urlStr);
                    break;
                }
            }
        }

        // Cache the result (or NSNull if not found)
        if (imageURL) {
            self->_artistImageCache[cacheKey] = imageURL;
        } else {
            self->_artistImageCache[cacheKey] = [NSNull null];
            NSLog(@"[LastFmClient] No artist image found for '%@'", artistName);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(imageURL, nil);
        });
    }] resume];
}

#pragma mark - Scrobbling

- (void)sendNowPlaying:(ScrobbleTrack*)track
            completion:(LastFmNowPlayingCompletion)completion {
    if (!_session || !_session.isValid) {
        completion(NO, LastFmMakeError(LastFmErrorAuthenticationFailed, @"Not authenticated"));
        return;
    }

    if (!track || !track.isValid) {
        completion(NO, LastFmMakeError(LastFmErrorInvalidParameters, @"Invalid track"));
        return;
    }

    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    params[@"method"] = @(LastFm::kMethodNowPlaying);
    params[@"sk"] = _session.sessionKey;
    params[@"artist"] = track.artist;
    params[@"track"] = track.title;

    if (track.album.length > 0) {
        params[@"album"] = track.album;
    }
    if (track.albumArtist.length > 0) {
        params[@"albumArtist"] = track.albumArtist;
    }
    if (track.duration > 0) {
        params[@"duration"] = [NSString stringWithFormat:@"%ld", (long)track.duration];
    }
    if (track.trackNumber > 0) {
        params[@"trackNumber"] = [NSString stringWithFormat:@"%ld", (long)track.trackNumber];
    }

    [self executeSignedRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(NO, error);
            return;
        }

        // Check for nowplaying response
        NSDictionary* nowplaying = response[@"nowplaying"];
        completion(nowplaying != nil, nil);
    }];
}

- (void)scrobbleTracks:(NSArray<ScrobbleTrack*>*)tracks
            completion:(LastFmScrobbleCompletion)completion {
    if (!_session || !_session.isValid) {
        completion(0, 0, LastFmMakeError(LastFmErrorAuthenticationFailed, @"Not authenticated"));
        return;
    }

    if (tracks.count == 0) {
        completion(0, 0, nil);
        return;
    }

    // Limit to max batch size
    NSArray* batch = tracks;
    if (batch.count > LastFm::kMaxScrobblesPerBatch) {
        batch = [tracks subarrayWithRange:NSMakeRange(0, LastFm::kMaxScrobblesPerBatch)];
    }

    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    params[@"method"] = @(LastFm::kMethodScrobble);
    params[@"sk"] = _session.sessionKey;

    // Add indexed parameters for each track
    for (NSUInteger i = 0; i < batch.count; i++) {
        ScrobbleTrack* track = batch[i];
        NSString* suffix = [NSString stringWithFormat:@"[%lu]", (unsigned long)i];

        params[[@"artist" stringByAppendingString:suffix]] = track.artist;
        params[[@"track" stringByAppendingString:suffix]] = track.title;
        params[[@"timestamp" stringByAppendingString:suffix]] = [NSString stringWithFormat:@"%lld", track.timestamp];

        if (track.album.length > 0) {
            params[[@"album" stringByAppendingString:suffix]] = track.album;
        }
        if (track.albumArtist.length > 0) {
            params[[@"albumArtist" stringByAppendingString:suffix]] = track.albumArtist;
        }
        if (track.duration > 0) {
            params[[@"duration" stringByAppendingString:suffix]] = [NSString stringWithFormat:@"%ld", (long)track.duration];
        }
        if (track.trackNumber > 0) {
            params[[@"trackNumber" stringByAppendingString:suffix]] = [NSString stringWithFormat:@"%ld", (long)track.trackNumber];
        }
    }

    [self executeSignedRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(0, 0, error);
            return;
        }

        // Parse scrobble response
        NSDictionary* scrobbles = response[@"scrobbles"];
        NSInteger accepted = [scrobbles[@"@attr"][@"accepted"] integerValue];
        NSInteger ignored = [scrobbles[@"@attr"][@"ignored"] integerValue];

        completion(accepted, ignored, nil);
    }];
}

#pragma mark - Statistics

- (void)fetchTopAlbums:(NSString*)username
                period:(NSString*)period
                 limit:(NSInteger)limit
            completion:(LastFmTopAlbumsCompletion)completion {

    if (!username || username.length == 0) {
        completion(nil, LastFmMakeError(LastFmErrorInvalidParameters, @"Username required"));
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetTopAlbums),
        @"user": username,
        @"period": period ?: @"7day",
        @"limit": [NSString stringWithFormat:@"%ld", (long)MIN(limit, 50)]
    };

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSMutableArray<TopAlbum*>* albums = [NSMutableArray array];
        NSDictionary* topAlbums = response[@"topalbums"];
        NSArray* albumArray = topAlbums[@"album"];

        if ([albumArray isKindOfClass:[NSArray class]]) {
            for (NSDictionary* albumDict in albumArray) {
                TopAlbum* album = [TopAlbum albumFromDictionary:albumDict];
                if (album) {
                    [albums addObject:album];
                }
            }
        }

        completion(albums, nil);
    }];
}

- (void)fetchTopArtists:(NSString*)username
                 period:(NSString*)period
                  limit:(NSInteger)limit
             completion:(LastFmTopAlbumsCompletion)completion {

    if (!username || username.length == 0) {
        completion(nil, LastFmMakeError(LastFmErrorInvalidParameters, @"Username required"));
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetTopArtists),
        @"user": username,
        @"period": period ?: @"7day",
        @"limit": [NSString stringWithFormat:@"%ld", (long)MIN(limit, 50)]
    };

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSMutableArray<TopAlbum*>* artists = [NSMutableArray array];
        NSDictionary* topArtists = response[@"topartists"];
        NSArray* artistArray = topArtists[@"artist"];

        if ([artistArray isKindOfClass:[NSArray class]]) {
            for (NSDictionary* artistDict in artistArray) {
                TopAlbum* item = [TopAlbum albumFromDictionary:artistDict];
                if (item) {
                    // For artists, set artist = name (the item IS the artist)
                    item.artist = item.name;
                    [artists addObject:item];
                }
            }
        }

        completion(artists, nil);
    }];
}

- (void)fetchTopTracks:(NSString*)username
                period:(NSString*)period
                 limit:(NSInteger)limit
            completion:(LastFmTopAlbumsCompletion)completion {

    if (!username || username.length == 0) {
        completion(nil, LastFmMakeError(LastFmErrorInvalidParameters, @"Username required"));
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetTopTracks),
        @"user": username,
        @"period": period ?: @"7day",
        @"limit": [NSString stringWithFormat:@"%ld", (long)MIN(limit, 50)]
    };

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSMutableArray<TopAlbum*>* tracks = [NSMutableArray array];
        NSDictionary* topTracks = response[@"toptracks"];
        NSArray* trackArray = topTracks[@"track"];

        if ([trackArray isKindOfClass:[NSArray class]]) {
            for (NSDictionary* trackDict in trackArray) {
                TopAlbum* item = [TopAlbum albumFromDictionary:trackDict];
                if (item) {
                    [tracks addObject:item];
                }
            }
        }

        completion(tracks, nil);
    }];
}

- (void)fetchRecentTracksCount:(NSString*)username
                          from:(NSTimeInterval)fromTimestamp
                    completion:(LastFmRecentTracksCountCompletion)completion {

    if (!username || username.length == 0) {
        completion(0, LastFmMakeError(LastFmErrorInvalidParameters, @"Username required"));
        return;
    }

    // Request just 1 track to get total count from pagination info
    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetRecentTracks),
        @"user": username,
        @"from": [NSString stringWithFormat:@"%.0f", fromTimestamp],
        @"limit": @"1"
    };

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(0, error);
            return;
        }

        // Total count is in the @attr pagination info
        NSDictionary* recentTracks = response[@"recenttracks"];
        NSDictionary* attr = recentTracks[@"@attr"];
        NSInteger total = [attr[@"total"] integerValue];

        completion(total, nil);
    }];
}

- (void)fetchAlbumInfo:(NSString*)artist
                 album:(NSString*)album
            completion:(LastFmAlbumInfoCompletion)completion {

    if (!artist || artist.length == 0 || !album || album.length == 0) {
        completion(nil, LastFmMakeError(LastFmErrorInvalidParameters, @"Artist and album required"));
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetAlbumInfo),
        @"artist": artist,
        @"album": album
    };

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSDictionary* albumInfo = response[@"album"];
        if (![albumInfo isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil);
            return;
        }

        // Extract image URL using the same helper
        NSArray* images = albumInfo[@"image"];
        NSURL* imageURL = [TopAlbum bestImageURLFromArray:images];

        completion(imageURL, nil);
    }];
}

- (void)fetchTrackInfo:(NSString*)artist
                 track:(NSString*)track
            completion:(LastFmTrackInfoCompletion)completion {

    if (!artist || artist.length == 0 || !track || track.length == 0) {
        completion(nil, nil, LastFmMakeError(LastFmErrorInvalidParameters, @"Artist and track required"));
        return;
    }

    NSDictionary* params = @{
        @"method": @(LastFm::kMethodGetTrackInfo),
        @"artist": artist,
        @"track": track
    };

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, nil, error);
            return;
        }

        NSDictionary* trackInfo = response[@"track"];
        if (![trackInfo isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil, nil);
            return;
        }

        // Extract album name
        NSString* albumName = nil;
        NSDictionary* albumDict = trackInfo[@"album"];
        if ([albumDict isKindOfClass:[NSDictionary class]]) {
            albumName = albumDict[@"title"];
            if (![albumName isKindOfClass:[NSString class]]) {
                albumName = nil;
            }
        }

        // Extract image URL (album image)
        NSArray* images = albumDict[@"image"];
        NSURL* imageURL = [TopAlbum bestImageURLFromArray:images];

        completion(albumName, imageURL, nil);
    }];
}

#pragma mark - Streak Discovery

- (void)estimateDailyScrobbleRate:(NSString*)username
                       completion:(LastFmDailyRateCompletion)completion {
    if (!username || username.length == 0) {
        completion(-1.0, LastFmMakeError(LastFmErrorInvalidParameters, @"Username required"));
        return;
    }

    // Fetch scrobble count for last 7 days using existing method
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDate *sevenDaysAgo = [calendar dateByAddingUnit:NSCalendarUnitDay value:-7 toDate:now options:0];
    NSTimeInterval fromTimestamp = [sevenDaysAgo timeIntervalSince1970];

    [self fetchRecentTracksCount:username from:fromTimestamp completion:^(NSInteger count, NSError* error) {
        if (error) {
            completion(-1.0, error);
            return;
        }

        CGFloat avgPerDay = (CGFloat)count / 7.0;
        completion(avgPerDay, nil);
    }];
}

- (void)fetchRecentTracksPage:(NSString*)username
                         from:(NSTimeInterval)fromTimestamp
                           to:(NSTimeInterval)toTimestamp
                         page:(NSInteger)page
                        limit:(NSInteger)limit
                   completion:(void(^)(NSArray* _Nullable tracks, NSInteger totalPages, NSError* _Nullable error))completion {

    if (!username || username.length == 0) {
        completion(nil, 0, LastFmMakeError(LastFmErrorInvalidParameters, @"Username required"));
        return;
    }

    NSMutableDictionary* params = [NSMutableDictionary dictionary];
    params[@"method"] = @(LastFm::kMethodGetRecentTracks);
    params[@"user"] = username;
    params[@"limit"] = [NSString stringWithFormat:@"%ld", (long)MIN(limit, 200)];
    params[@"page"] = [NSString stringWithFormat:@"%ld", (long)page];

    if (fromTimestamp > 0) {
        params[@"from"] = [NSString stringWithFormat:@"%.0f", fromTimestamp];
    }
    if (toTimestamp > 0) {
        params[@"to"] = [NSString stringWithFormat:@"%.0f", toTimestamp];
    }

    [self executeUnsignedGETRequest:params completion:^(NSDictionary* response, NSError* error) {
        if (error) {
            completion(nil, 0, error);
            return;
        }

        NSDictionary* recentTracks = response[@"recenttracks"];
        NSDictionary* attr = recentTracks[@"@attr"];
        NSInteger totalPages = [attr[@"totalPages"] integerValue];

        // Parse tracks
        NSMutableArray* tracks = [NSMutableArray array];
        id trackData = recentTracks[@"track"];

        if ([trackData isKindOfClass:[NSArray class]]) {
            for (NSDictionary* trackDict in trackData) {
                [tracks addObject:trackDict];
            }
        } else if ([trackData isKindOfClass:[NSDictionary class]]) {
            // Single track is returned as object, not array
            [tracks addObject:trackData];
        }

        completion(tracks, totalPages, nil);
    }];
}

- (void)checkDayHasScrobbles:(NSString*)username
                        date:(NSDate*)date
                  completion:(void(^)(BOOL hasScrobbles, NSError* _Nullable error))completion {

    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *dayStart = [calendar startOfDayForDate:date];
    NSDate *dayEnd = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:dayStart options:0];

    NSTimeInterval fromTimestamp = [dayStart timeIntervalSince1970];
    NSTimeInterval toTimestamp = [dayEnd timeIntervalSince1970];

    // Request just 1 track to check if any exist
    [self fetchRecentTracksPage:username from:fromTimestamp to:toTimestamp page:1 limit:1
                     completion:^(NSArray* tracks, NSInteger totalPages, NSError* error) {
        if (error) {
            completion(NO, error);
            return;
        }

        // Filter out "now playing" tracks (no timestamp)
        NSArray* actualTracks = [tracks filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary* track, NSDictionary* bindings) {
                return track[@"@attr"][@"nowplaying"] == nil;
            }]];

        completion(actualTracks.count > 0, nil);
    }];
}

- (NSUUID*)startStreakDiscovery:(NSString*)username
                       progress:(LastFmStreakProgressBlock _Nullable)progress
                     completion:(LastFmStreakCompletion)completion {

    NSUUID *token = [NSUUID UUID];

    // Create discovery state
    LastFmStreakDiscoveryState *state = [[LastFmStreakDiscoveryState alloc] init];
    state.username = username;
    state.token = token;
    state.cancelled = NO;
    state.currentStreak = 0;
    state.daysChecked = 0;
    state.scrobbledToday = NO;
    state.useBatchStrategy = YES;  // Will be determined after sampling
    state.estimatedDailyRate = 0;
    state.retryCount = 0;
    state.currentBackoff = 0;
    state.progressBlock = progress;
    state.completionBlock = completion;

    _activeDiscoveries[token] = state;

    // Start by estimating daily rate to choose strategy
    [self estimateDailyScrobbleRate:username completion:^(CGFloat avgPerDay, NSError* error) {
        if (state.cancelled) {
            [self handleStreakDiscoveryCancelled:state];
            return;
        }

        if (error) {
            // If sampling fails, default to batch strategy and continue
            state.estimatedDailyRate = 50;  // Assume moderate user
            state.useBatchStrategy = YES;
        } else {
            state.estimatedDailyRate = avgPerDay;
            // Use batch strategy for light users (<100/day), daily queries for heavy users
            state.useBatchStrategy = (avgPerDay < 100);
        }

        // Check if scrobbled today
        NSDate *today = [NSDate date];
        [self checkDayHasScrobbles:username date:today completion:^(BOOL hasScrobbles, NSError* error) {
            if (state.cancelled) {
                [self handleStreakDiscoveryCancelled:state];
                return;
            }

            state.scrobbledToday = hasScrobbles;

            // If scrobbled today, streak includes today. Otherwise we start from yesterday.
            if (hasScrobbles) {
                state.currentStreak = 1;
                state.daysChecked = 1;
            }

            // Report initial progress
            if (state.progressBlock) {
                state.progressBlock(state.currentStreak, NO, state.daysChecked);
            }

            // Schedule first discovery request with rate limiting
            [self scheduleNextRequest:state];
        }];
    }];

    return token;
}

- (void)cancelStreakDiscovery:(NSUUID* _Nullable)token {
    if (!token) return;

    LastFmStreakDiscoveryState *state = _activeDiscoveries[token];
    if (!state || state.cancelled) return;

    state.cancelled = YES;
    [self handleStreakDiscoveryCancelled:state];
}

- (void)handleStreakDiscoveryCancelled:(LastFmStreakDiscoveryState*)state {
    // Remove from active discoveries
    [_activeDiscoveries removeObjectForKey:state.token];

    // Call completion with cancellation error
    NSError *cancelError = [NSError errorWithDomain:NSCocoaErrorDomain
                                               code:NSUserCancelledError
                                           userInfo:@{NSLocalizedDescriptionKey: @"Streak discovery cancelled"}];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (state.completionBlock) {
            state.completionBlock(state.currentStreak, state.scrobbledToday, NO, [NSDate date], cancelError);
        }
    });
}

- (void)scheduleNextRequest:(LastFmStreakDiscoveryState*)state {
    if (state.cancelled) {
        [self handleStreakDiscoveryCancelled:state];
        return;
    }

    // Rate limiting: wait configured interval between requests
    NSTimeInterval interval = scrobble_config::getStreakRequestInterval();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (state.cancelled) {
            [self handleStreakDiscoveryCancelled:state];
            return;
        }
        [self continueStreakDiscovery:state];
    });
}

- (void)continueStreakDiscovery:(LastFmStreakDiscoveryState*)state {
    if (state.cancelled) {
        [self handleStreakDiscoveryCancelled:state];
        return;
    }

    // Calculate which day to check next
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *today = [NSDate date];
    NSInteger daysBack = state.daysChecked;
    if (!state.scrobbledToday && state.daysChecked == 0) {
        // If no scrobbles today, start from yesterday
        daysBack = 1;
    } else {
        daysBack = state.daysChecked;
    }

    NSDate *dayToCheck = [calendar dateByAddingUnit:NSCalendarUnitDay value:-daysBack toDate:today options:0];

    [self checkDayHasScrobbles:state.username date:dayToCheck completion:^(BOOL hasScrobbles, NSError* error) {
        if (state.cancelled) {
            [self handleStreakDiscoveryCancelled:state];
            return;
        }

        if (error) {
            // Handle error with retry logic
            state.retryCount++;
            if (state.retryCount >= 3) {
                // Max retries reached - complete with partial results
                [self completeStreakDiscovery:state complete:NO error:error];
                return;
            }

            // Exponential backoff: 2s, 4s, 8s
            NSTimeInterval backoff = pow(2, state.retryCount);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(backoff * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self continueStreakDiscovery:state];  // Retry same day
            });
            return;
        }

        // Reset retry count on success
        state.retryCount = 0;
        state.daysChecked++;

        if (hasScrobbles) {
            // Day had scrobbles - extend streak
            state.currentStreak++;

            // Report progress
            dispatch_async(dispatch_get_main_queue(), ^{
                if (state.progressBlock) {
                    state.progressBlock(state.currentStreak, NO, state.daysChecked);
                }
            });

            // Continue checking older days
            [self scheduleNextRequest:state];
        } else {
            // Gap found - streak is complete
            [self completeStreakDiscovery:state complete:YES error:nil];
        }
    }];
}

- (void)completeStreakDiscovery:(LastFmStreakDiscoveryState*)state
                       complete:(BOOL)isComplete
                          error:(NSError* _Nullable)error {
    // Remove from active discoveries
    [_activeDiscoveries removeObjectForKey:state.token];

    NSDate *calculatedAt = [NSDate date];

    dispatch_async(dispatch_get_main_queue(), ^{
        // Final progress callback
        if (state.progressBlock) {
            state.progressBlock(state.currentStreak, YES, state.daysChecked);
        }

        // Completion callback
        if (state.completionBlock) {
            state.completionBlock(state.currentStreak, state.scrobbledToday, isComplete, calculatedAt, error);
        }
    });
}

#pragma mark - Lifecycle

- (void)cancelAllRequests {
    [_urlSession invalidateAndCancel];

    // Recreate session
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = LastFm::kRequestTimeout;
    _urlSession = [NSURLSession sessionWithConfiguration:config];
}

@end
