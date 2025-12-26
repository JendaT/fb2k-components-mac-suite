//
//  LastFmClient.mm
//  foo_scrobble_mac
//
//  Last.fm API client implementation
//

#import "LastFmClient.h"
#import "LastFmConstants.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/MD5.h"

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
    return [string stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]];
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

#pragma mark - Lifecycle

- (void)cancelAllRequests {
    [_urlSession invalidateAndCancel];

    // Recreate session
    NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = LastFm::kRequestTimeout;
    _urlSession = [NSURLSession sessionWithConfiguration:config];
}

@end
