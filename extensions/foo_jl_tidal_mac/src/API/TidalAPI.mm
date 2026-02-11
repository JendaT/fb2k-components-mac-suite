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

#pragma mark - OAuth Device Authorization

- (void)requestDeviceCodeWithCompletion:(JLTidalDeviceCodeCompletion)completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@",
                                       kTidalAuthBaseURL, kTidalDeviceAuthEndpoint]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    NSString *body = [NSString stringWithFormat:@"client_id=%@&client_secret=%@&scope=%@",
                      kTidalClientID,
                      [kTidalClientSecret stringByAddingPercentEncodingWithAllowedCharacters:
                       [NSCharacterSet URLQueryAllowedCharacterSet]],
                      [kTidalOAuthScopes stringByAddingPercentEncodingWithAllowedCharacters:
                       [NSCharacterSet URLQueryAllowedCharacterSet]]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    tidal::logDebug("Requesting device code...");

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            tidal::logError([[NSString stringWithFormat:@"Device code request failed: %@", error.localizedDescription] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            tidal::logError([[NSString stringWithFormat:@"Device code request failed with status: %ld", (long)httpResponse.statusCode] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorServerError,
                [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
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

        if (!deviceCode || !userCode || !verificationUri) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Missing required fields"));
            return;
        }

        JLTidalDeviceCode *code = [[JLTidalDeviceCode alloc]
            initWithDeviceCode:deviceCode
                      userCode:userCode
               verificationURI:[NSURL URLWithString:verificationUri]
       verificationURIComplete:verificationUriComplete ? [NSURL URLWithString:verificationUriComplete] : nil
                     expiresIn:expiresIn.doubleValue
                      interval:interval.doubleValue];

        tidal::logDebug([[NSString stringWithFormat:@"Got device code, user code: %@", userCode] UTF8String]);
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

    NSString *body = [NSString stringWithFormat:
        @"client_id=%@&client_secret=%@&device_code=%@&grant_type=urn:ietf:params:oauth:grant-type:device_code&scope=%@",
        kTidalClientID,
        [kTidalClientSecret stringByAddingPercentEncodingWithAllowedCharacters:
         [NSCharacterSet URLQueryAllowedCharacterSet]],
        deviceCode,
        [kTidalOAuthScopes stringByAddingPercentEncodingWithAllowedCharacters:
         [NSCharacterSet URLQueryAllowedCharacterSet]]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

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
        JLTidalSession *session = [self parseTokenResponse:json error:nil];
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

    NSString *body = [NSString stringWithFormat:
        @"client_id=%@&client_secret=%@&refresh_token=%@&grant_type=refresh_token&scope=%@",
        kTidalClientID,
        [kTidalClientSecret stringByAddingPercentEncodingWithAllowedCharacters:
         [NSCharacterSet URLQueryAllowedCharacterSet]],
        self.session.refreshToken,
        [kTidalOAuthScopes stringByAddingPercentEncodingWithAllowedCharacters:
         [NSCharacterSet URLQueryAllowedCharacterSet]]];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];

    tidal::logDebug("Refreshing access token...");

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(nil, JLTidalError(JLTidalErrorNetworkFailure, error.localizedDescription));
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            // Refresh failed - token likely revoked
            completion(nil, JLTidalError(JLTidalErrorTokenRefreshFailed,
                [NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || !json) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Invalid JSON response"));
            return;
        }

        // Parse refreshed token - keep existing refresh token if not provided
        NSString *accessToken = json[@"access_token"];
        NSNumber *expiresIn = json[@"expires_in"] ?: @(86400);

        if (!accessToken) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Missing access token"));
            return;
        }

        JLTidalSession *newSession = [self.session sessionByUpdatingAccessToken:accessToken
                                                                       expiresIn:expiresIn.doubleValue];
        self.session = newSession;
        [[JLTidalRateLimiter shared] recordSuccess];
        tidal::logDebug("Token refreshed successfully");
        completion(newSession, nil);
    }];

    [task resume];
}

- (JLTidalSession *)parseTokenResponse:(NSDictionary *)json error:(NSError **)error {
    NSString *accessToken = json[@"access_token"];
    NSString *refreshToken = json[@"refresh_token"];
    NSNumber *expiresIn = json[@"expires_in"] ?: @(86400);

    if (!accessToken || !refreshToken) {
        return nil;
    }

    // Extract user info if present
    NSDictionary *user = json[@"user"];
    NSString *userId = [user[@"userId"] description];
    NSString *username = user[@"username"];
    NSString *countryCode = user[@"countryCode"];

    return [[JLTidalSession alloc] initWithAccessToken:accessToken
                                          refreshToken:refreshToken
                                             expiresIn:expiresIn.doubleValue
                                                userId:userId
                                              username:username
                                           countryCode:countryCode];
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

    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:
                              [NSCharacterSet URLQueryAllowedCharacterSet]];

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

        // Parse tracks from response
        NSMutableArray<JLTidalTrack *> *tracks = [NSMutableArray array];

        NSDictionary *tracksData = json[@"tracks"];
        NSArray *items = tracksData[@"items"];

        for (NSDictionary *trackDict in items) {
            JLTidalTrack *track = [[JLTidalTrack alloc] initWithDictionary:trackDict];
            if (track) {
                [tracks addObject:track];
            }
        }

        tidal::logDebug([[NSString stringWithFormat:@"Search returned %lu tracks", (unsigned long)tracks.count] UTF8String]);
        completion([tracks copy], nil);
    }];
}

#pragma mark - Generic Request

- (void)requestWithURL:(NSURL *)url
                method:(NSString *)method
                  body:(NSDictionary *)body
            completion:(JLTidalDataCompletion)completion {
    // Check rate limiting
    NSTimeInterval delay = [[JLTidalRateLimiter shared] currentDelay];
    if (delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self performRequestWithURL:url method:method body:body completion:completion];
        });
    } else {
        [self performRequestWithURL:url method:method body:body completion:completion];
    }
}

- (void)performRequestWithURL:(NSURL *)url
                       method:(NSString *)method
                         body:(NSDictionary *)body
                   completion:(JLTidalDataCompletion)completion {
    if (!self.session.isValid) {
        completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"Not authenticated"));
        return;
    }

    tidal::logDebug([[NSString stringWithFormat:@"API request: %@ %@ (countryCode=%@)",
                      method, url.absoluteString, self.session.countryCode ?: @"(nil)"] UTF8String]);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.session.accessToken]
   forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

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

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

        // Handle rate limiting
        if (httpResponse.statusCode == 429) {
            NSTimeInterval retryAfter = [[JLTidalRateLimiter shared] recordRateLimitHit];
            tidal::logDebug([[NSString stringWithFormat:@"Rate limited, retry after %.1fs", retryAfter] UTF8String]);
            completion(nil, JLTidalError(JLTidalErrorRateLimited,
                [NSString stringWithFormat:@"Rate limited, retry after %.0f seconds", retryAfter]));
            return;
        }

        // Handle auth errors
        if (httpResponse.statusCode == 401) {
            completion(nil, JLTidalError(JLTidalErrorNotAuthenticated, @"Authentication required"));
            return;
        }

        if (httpResponse.statusCode == 403) {
            completion(nil, JLTidalError(JLTidalErrorSubscriptionRequired, @"Subscription required"));
            return;
        }

        if (httpResponse.statusCode == 404) {
            completion(nil, JLTidalError(JLTidalErrorTrackNotFound, @"Track not found"));
            return;
        }

        if (httpResponse.statusCode >= 500) {
            completion(nil, JLTidalError(JLTidalErrorServerError,
                [NSString stringWithFormat:@"Server error: HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        if (httpResponse.statusCode != 200) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse,
                [NSString stringWithFormat:@"Unexpected status: HTTP %ld", (long)httpResponse.statusCode]));
            return;
        }

        NSError *jsonError;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            completion(nil, JLTidalError(JLTidalErrorInvalidResponse, @"Invalid JSON response"));
            return;
        }

        [[JLTidalRateLimiter shared] recordSuccess];
        completion(json, nil);
    }];

    [task resume];
}

@end
