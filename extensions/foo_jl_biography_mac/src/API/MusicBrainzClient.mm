//
//  MusicBrainzClient.mm
//  foo_jl_biography_mac
//
//  MusicBrainz ws/2 client
//

#import "MusicBrainzClient.h"
#import "BiographyAPIConstants.h"
#import "../Core/BiographyRequest.h"
#import "../Core/RateLimiter.h"
#import "../Core/MusicBrainzParsing.h"
#import "../Core/GalleryImageParsing.h"

NSString * const MusicBrainzErrorDomain = @"com.foobar2000.biography.musicbrainz";

static const NSTimeInterval kMusicBrainzRequestTimeout = 10.0;

@interface MusicBrainzClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) BiographyRateLimiter *rateLimiter;
@property (nonatomic, strong) dispatch_queue_t requestQueue;

@end

@implementation MusicBrainzClient

#pragma mark - Singleton

+ (instancetype)shared {
    static MusicBrainzClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MusicBrainzClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // MusicBrainz requires a meaningful User-Agent and enforces 1 req/s
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kMusicBrainzRequestTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kBiographyUserAgent,
            @"Accept": @"application/json"
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        _rateLimiter = [[BiographyRateLimiter alloc] initWithTokensPerSecond:kMusicBrainzRatePerSecond
                                                               burstCapacity:kMusicBrainzBurstCapacity];

        _requestQueue = dispatch_queue_create("com.foobar2000.biography.musicbrainz", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Public API

- (void)lookupMBIDForArtist:(NSString *)artistName
                      token:(BiographyRequest *)token
                 completion:(MusicBrainzMBIDCompletion)completion {

    if (artistName.length == 0) {
        completion(nil, [self errorWithCode:MusicBrainzErrorCodeInvalidResponse
                                    message:@"Artist name required"]);
        return;
    }

    // Lucene query with the name quoted; escape embedded quotes and backslashes
    NSString *escaped = [artistName stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *query = [NSString stringWithFormat:@"artist:\"%@\"", escaped];

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"%@artist", kMusicBrainzApiBaseUrl]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:query],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"5"],
    ];

    [self performRequestWithURL:components.URL token:token completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSString *mbid = [MusicBrainzParsing bestMBIDFromSearchResponse:json
                                                          requestedName:artistName];
        completion(mbid, nil);
    }];
}

- (void)lookupWikidataQIDForMBID:(NSString *)mbid
                           token:(BiographyRequest *)token
                      completion:(MusicBrainzQIDCompletion)completion {

    if (![GalleryImageParsing isValidMBID:mbid]) {
        completion(nil, [self errorWithCode:MusicBrainzErrorCodeInvalidResponse
                                    message:@"Malformed MusicBrainz ID"]);
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"%@artist/%@", kMusicBrainzApiBaseUrl, mbid]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"inc" value:@"url-rels"],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"],
    ];

    [self performRequestWithURL:components.URL token:token completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        completion([MusicBrainzParsing wikidataQIDFromArtistResponse:json], nil);
    }];
}

- (void)cancelAllRequests {
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        for (NSURLSessionTask *task in tasks) {
            [task cancel];
        }
    }];
}

#pragma mark - Request Plumbing

- (void)performRequestWithURL:(NSURL *)url
                        token:(BiographyRequest *)token
                   completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {

    dispatch_async(self.requestQueue, ^{
        if (token.isCancelled) {
            completion(nil, [self errorWithCode:MusicBrainzErrorCodeCancelled message:@"Request cancelled"]);
            return;
        }

        [self waitForRateLimiter:token];

        if (token.isCancelled) {
            completion(nil, [self errorWithCode:MusicBrainzErrorCodeCancelled message:@"Request cancelled"]);
            return;
        }

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            if (token.isCancelled) {
                completion(nil, [self errorWithCode:MusicBrainzErrorCodeCancelled message:@"Request cancelled"]);
                return;
            }

            if (error) {
                completion(nil, [self errorWithCode:MusicBrainzErrorCodeNetworkError
                                            message:error.localizedDescription]);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode == 404) {
                completion(nil, [self errorWithCode:MusicBrainzErrorCodeNotFound message:@"Not found"]);
                return;
            }
            if (httpResponse.statusCode == 503 || httpResponse.statusCode == 429) {
                completion(nil, [self errorWithCode:MusicBrainzErrorCodeRateLimited message:@"Rate limited"]);
                return;
            }
            if (httpResponse.statusCode != 200) {
                completion(nil, [self errorWithCode:MusicBrainzErrorCodeNetworkError
                                            message:[NSString stringWithFormat:@"HTTP %ld",
                                                     (long)httpResponse.statusCode]]);
                return;
            }

            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                completion(nil, [self errorWithCode:MusicBrainzErrorCodeInvalidResponse
                                            message:@"Invalid JSON response"]);
                return;
            }

            completion(json, nil);
        }];

        [task resume];
    });
}

#pragma mark - Helpers

- (void)waitForRateLimiter:(BiographyRequest *)token {
    NSTimeInterval totalWaited = 0;
    static const NSTimeInterval kMaxSleepInterval = 0.1;
    static const NSTimeInterval kMaxTotalWait = 5.0;

    while (![self.rateLimiter tryAcquire]) {
        if (token.isCancelled || totalWaited >= kMaxTotalWait) return;
        NSTimeInterval waitTime = MIN(self.rateLimiter.waitTimeForNextToken, kMaxSleepInterval);
        if (waitTime > 0) {
            [NSThread sleepForTimeInterval:waitTime];
            totalWaited += waitTime;
        }
    }
}

- (NSError *)errorWithCode:(MusicBrainzErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:MusicBrainzErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

@end
