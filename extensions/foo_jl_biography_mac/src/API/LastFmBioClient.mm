//
//  LastFmBioClient.mm
//  foo_jl_biography_mac
//
//  Last.fm API client implementation
//

#import "LastFmBioClient.h"
#import "BiographyAPIConstants.h"
#import "SecretConfig.h"
#import "../Core/BiographyRequest.h"
#import "../Core/RateLimiter.h"

NSString * const LastFmBioErrorDomain = @"com.foobar2000.biography.lastfm";

@interface LastFmBioClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) BiographyRateLimiter *rateLimiter;
@property (nonatomic, strong) dispatch_queue_t requestQueue;

@end

@implementation LastFmBioClient

+ (instancetype)shared {
    static LastFmBioClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LastFmBioClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Configure URL session
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kDefaultRequestTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kBiographyUserAgent
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        // Configure rate limiter
        _rateLimiter = [[BiographyRateLimiter alloc] initWithTokensPerSecond:kLastFmRatePerSecond
                                                               burstCapacity:kLastFmBurstCapacity];

        // Serial queue for API requests
        _requestQueue = dispatch_queue_create("com.foobar2000.biography.lastfm", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Public API

- (void)fetchArtistInfo:(NSString *)artistName
                  token:(BiographyRequest *)token
             completion:(LastFmArtistInfoCompletion)completion {

    dispatch_async(self.requestQueue, ^{
        // Check cancellation
        if (token.isCancelled) {
            NSError *error = [self errorWithCode:LastFmBioErrorCodeCancelled
                                         message:@"Request cancelled"];
            completion(nil, error);
            return;
        }

        // Wait for rate limiter
        [self waitForRateLimiter];

        // Check cancellation again after wait
        if (token.isCancelled) {
            NSError *error = [self errorWithCode:LastFmBioErrorCodeCancelled
                                         message:@"Request cancelled"];
            completion(nil, error);
            return;
        }

        // Build request URL
        NSURL *url = [self artistInfoURLForArtist:artistName];
        NSLog(@"[Biography] Fetching from URL: %@", url);

        // Make request
        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            if (token.isCancelled) {
                NSError *cancelError = [self errorWithCode:LastFmBioErrorCodeCancelled
                                                   message:@"Request cancelled"];
                completion(nil, cancelError);
                return;
            }

            if (error) {
                NSLog(@"[Biography] Network error: %@", error);
                NSError *networkError = [self errorWithCode:LastFmBioErrorCodeNetworkError
                                                    message:error.localizedDescription];
                completion(nil, networkError);
                return;
            }

            NSLog(@"[Biography] Got response, data length: %lu", (unsigned long)data.length);

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode != 200) {
                NSError *httpError = [self errorWithCode:LastFmBioErrorCodeNetworkError
                                                 message:[NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]];
                completion(nil, httpError);
                return;
            }

            // Parse JSON
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                NSError *parseError = [self errorWithCode:LastFmBioErrorCodeInvalidResponse
                                                  message:@"Invalid JSON response"];
                completion(nil, parseError);
                return;
            }

            // Check for Last.fm error response
            if (json[@"error"]) {
                NSInteger errorCode = [json[@"error"] integerValue];
                NSString *message = json[@"message"] ?: @"Unknown error";

                LastFmBioErrorCode code = LastFmBioErrorCodeUnknown;
                if (errorCode == 6) {  // Artist not found
                    code = LastFmBioErrorCodeArtistNotFound;
                } else if (errorCode == 29) {  // Rate limit exceeded
                    code = LastFmBioErrorCodeRateLimited;
                }

                NSError *apiError = [self errorWithCode:code message:message];
                completion(nil, apiError);
                return;
            }

            // Extract artist info
            NSDictionary *artist = json[@"artist"];
            if (!artist) {
                NSError *parseError = [self errorWithCode:LastFmBioErrorCodeInvalidResponse
                                                  message:@"Missing artist data"];
                completion(nil, parseError);
                return;
            }

            completion(artist, nil);
        }];

        [task resume];
    });
}

- (void)fetchSimilarArtists:(NSString *)artistName
                      token:(BiographyRequest *)token
                 completion:(LastFmSimilarArtistsCompletion)completion {

    dispatch_async(self.requestQueue, ^{
        if (token.isCancelled) {
            completion(nil, [self errorWithCode:LastFmBioErrorCodeCancelled message:@"Request cancelled"]);
            return;
        }

        [self waitForRateLimiter];

        if (token.isCancelled) {
            completion(nil, [self errorWithCode:LastFmBioErrorCodeCancelled message:@"Request cancelled"]);
            return;
        }

        NSURL *url = [self similarArtistsURLForArtist:artistName];

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            if (token.isCancelled) {
                completion(nil, [self errorWithCode:LastFmBioErrorCodeCancelled message:@"Request cancelled"]);
                return;
            }

            if (error) {
                completion(nil, [self errorWithCode:LastFmBioErrorCodeNetworkError message:error.localizedDescription]);
                return;
            }

            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

            if (jsonError) {
                completion(nil, [self errorWithCode:LastFmBioErrorCodeInvalidResponse message:@"Invalid JSON"]);
                return;
            }

            NSArray *artists = json[@"similarartists"][@"artist"];
            completion(artists ?: @[], nil);
        }];

        [task resume];
    });
}

- (void)cancelAllRequests {
    [self.session invalidateAndCancel];

    // Create new session for future requests
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = kDefaultRequestTimeout;
    config.HTTPAdditionalHeaders = @{@"User-Agent": kBiographyUserAgent};
    self.session = [NSURLSession sessionWithConfiguration:config];
}

#pragma mark - URL Building

- (NSURL *)artistInfoURLForArtist:(NSString *)artistName {
    NSURLComponents *components = [NSURLComponents componentsWithString:kLastFmApiBaseUrl];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"method" value:@"artist.getinfo"],
        [NSURLQueryItem queryItemWithName:@"artist" value:artistName],
        [NSURLQueryItem queryItemWithName:@"api_key" value:@LASTFM_API_KEY],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"autocorrect" value:@"1"],
        [NSURLQueryItem queryItemWithName:@"lang" value:@"en"],
    ];
    return components.URL;
}

- (NSURL *)similarArtistsURLForArtist:(NSString *)artistName {
    NSURLComponents *components = [NSURLComponents componentsWithString:kLastFmApiBaseUrl];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"method" value:@"artist.getsimilar"],
        [NSURLQueryItem queryItemWithName:@"artist" value:artistName],
        [NSURLQueryItem queryItemWithName:@"api_key" value:@LASTFM_API_KEY],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
    ];
    return components.URL;
}

#pragma mark - Response Parsing

+ (NSDictionary *)parseArtistInfoResponse:(NSDictionary *)response {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // Artist name (may be corrected)
    result[@"name"] = response[@"name"] ?: @"";

    // MusicBrainz ID
    if (response[@"mbid"] && [response[@"mbid"] length] > 0) {
        result[@"mbid"] = response[@"mbid"];
    }

    // Biography
    NSDictionary *bio = response[@"bio"];
    if (bio) {
        NSString *content = bio[@"content"];
        NSString *summary = bio[@"summary"];

        // Clean up HTML from biography
        if (content.length > 0) {
            result[@"biography"] = [self cleanBiographyText:content];
        }
        if (summary.length > 0) {
            result[@"biographySummary"] = [self cleanBiographyText:summary];
        }
    }

    // Tags
    NSArray *tags = response[@"tags"][@"tag"];
    if ([tags isKindOfClass:[NSArray class]] && tags.count > 0) {
        NSMutableArray *tagNames = [NSMutableArray array];
        for (NSDictionary *tag in tags) {
            if ([tag isKindOfClass:[NSDictionary class]] && tag[@"name"]) {
                [tagNames addObject:tag[@"name"]];
            }
        }
        result[@"tags"] = [tagNames copy];
    }

    // Images (get largest available)
    NSArray *images = response[@"image"];
    if ([images isKindOfClass:[NSArray class]]) {
        NSURL *imageURL = nil;
        for (NSDictionary *image in [images reverseObjectEnumerator]) {
            NSString *urlString = image[@"#text"];
            if (urlString.length > 0) {
                imageURL = [NSURL URLWithString:urlString];
                if (imageURL) break;
            }
        }
        if (imageURL) {
            result[@"imageURL"] = imageURL;
        }
    }

    // Stats
    NSDictionary *stats = response[@"stats"];
    if (stats) {
        result[@"listeners"] = @([stats[@"listeners"] integerValue]);
        result[@"playcount"] = @([stats[@"playcount"] integerValue]);
    }

    // Similar artists (if included)
    NSArray *similar = response[@"similar"][@"artist"];
    if ([similar isKindOfClass:[NSArray class]]) {
        result[@"similarArtists"] = similar;
    }

    return [result copy];
}

+ (NSString *)cleanBiographyText:(NSString *)text {
    if (!text) return nil;

    // Remove HTML tags
    NSRegularExpression *htmlRegex = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>"
                                                                               options:0
                                                                                 error:nil];
    NSString *cleaned = [htmlRegex stringByReplacingMatchesInString:text
                                                            options:0
                                                              range:NSMakeRange(0, text.length)
                                                       withTemplate:@""];

    // Decode HTML entities
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"&lt;" withString:@"<"];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"&gt;" withString:@">"];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"&quot;" withString:@"\""];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"&#39;" withString:@"'"];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];

    // Trim whitespace
    cleaned = [cleaned stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Remove "Read more on Last.fm" suffix
    NSRange readMoreRange = [cleaned rangeOfString:@"Read more on Last.fm"
                                           options:NSCaseInsensitiveSearch | NSBackwardsSearch];
    if (readMoreRange.location != NSNotFound) {
        cleaned = [[cleaned substringToIndex:readMoreRange.location]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    return cleaned;
}

#pragma mark - Helpers

- (void)waitForRateLimiter {
    while (![self.rateLimiter tryAcquire]) {
        NSTimeInterval waitTime = self.rateLimiter.waitTimeForNextToken;
        if (waitTime > 0) {
            [NSThread sleepForTimeInterval:waitTime];
        }
    }
}

- (NSError *)errorWithCode:(LastFmBioErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:LastFmBioErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

@end
