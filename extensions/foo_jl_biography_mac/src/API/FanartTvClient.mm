//
//  FanartTvClient.mm
//  foo_jl_biography_mac
//
//  API client for Fanart.tv artist images
//

#import "FanartTvClient.h"
#import "BiographyAPIConstants.h"
#import "SecretConfig.h"
#import "../Core/BiographyRequest.h"
#import "../Core/RateLimiter.h"
#import "../Core/ArtistImage.h"

NSString * const FanartTvErrorDomain = @"com.foobar2000.biography.fanarttv";

// API timeout (10 seconds as per plan)
static const NSTimeInterval kFanartTvRequestTimeout = 10.0;

// Logging macro
#define GALLERY_LOG(fmt, ...) NSLog(@"[Gallery/FanartTV] " fmt, ##__VA_ARGS__)

@interface FanartTvClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) BiographyRateLimiter *rateLimiter;
@property (nonatomic, strong) dispatch_queue_t requestQueue;

@end

@implementation FanartTvClient

#pragma mark - Singleton

+ (instancetype)shared {
    static FanartTvClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FanartTvClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Configure URL session with shorter timeout
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kFanartTvRequestTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kBiographyUserAgent
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        // Configure rate limiter
        _rateLimiter = [[BiographyRateLimiter alloc] initWithTokensPerSecond:kFanartTvRatePerSecond
                                                               burstCapacity:kFanartTvBurstCapacity];

        // Serial queue for API requests
        _requestQueue = dispatch_queue_create("com.foobar2000.biography.fanarttv", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Public API

- (void)fetchImagesForMBID:(NSString *)mbid
                     token:(BiographyRequest *)token
                completion:(FanartTvCompletion)completion {

    // Validate MBID
    if (!mbid || mbid.length == 0) {
        NSError *error = [self errorWithCode:FanartTvErrorCodeNoMBID message:@"MusicBrainz ID required"];
        completion(nil, error);
        return;
    }

    dispatch_async(self.requestQueue, ^{
        // Check cancellation
        if (token.isCancelled) {
            NSError *error = [self errorWithCode:FanartTvErrorCodeCancelled message:@"Request cancelled"];
            completion(nil, error);
            return;
        }

        // Wait for rate limiter
        [self waitForRateLimiter:token];

        // Check cancellation again after wait
        if (token.isCancelled) {
            NSError *error = [self errorWithCode:FanartTvErrorCodeCancelled message:@"Request cancelled"];
            completion(nil, error);
            return;
        }

        // Build request URL
        NSURL *url = [self artistURLForMBID:mbid];
#if DEBUG
        GALLERY_LOG(@"Fetching from: %@", url);
#endif

        NSDate *startTime = [NSDate date];

        // Make request
        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            NSTimeInterval duration = -[startTime timeIntervalSinceNow];

            if (token.isCancelled) {
                NSError *cancelError = [self errorWithCode:FanartTvErrorCodeCancelled message:@"Request cancelled"];
                completion(nil, cancelError);
                return;
            }

            if (error) {
                if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorTimedOut) {
                    GALLERY_LOG(@"Timeout after %.2fs", duration);
                    NSError *timeoutError = [self errorWithCode:FanartTvErrorCodeTimeout message:@"Request timed out"];
                    completion(nil, timeoutError);
                } else {
                    GALLERY_LOG(@"Network error: %@", error.localizedDescription);
                    NSError *networkError = [self errorWithCode:FanartTvErrorCodeNetworkError
                                                        message:error.localizedDescription];
                    completion(nil, networkError);
                }
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            if (httpResponse.statusCode == 404) {
                GALLERY_LOG(@"Artist not found for MBID: %@", mbid);
                NSError *notFoundError = [self errorWithCode:FanartTvErrorCodeArtistNotFound
                                                     message:@"Artist not found"];
                completion(nil, notFoundError);
                return;
            }

            if (httpResponse.statusCode == 429) {
                GALLERY_LOG(@"Rate limited");
                NSError *rateLimitError = [self errorWithCode:FanartTvErrorCodeRateLimited
                                                      message:@"Rate limited"];
                completion(nil, rateLimitError);
                return;
            }

            if (httpResponse.statusCode != 200) {
                GALLERY_LOG(@"HTTP %ld", (long)httpResponse.statusCode);
                NSError *httpError = [self errorWithCode:FanartTvErrorCodeNetworkError
                                                 message:[NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]];
                completion(nil, httpError);
                return;
            }

            // Parse JSON
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                GALLERY_LOG(@"Invalid JSON response");
                NSError *parseError = [self errorWithCode:FanartTvErrorCodeInvalidResponse
                                                  message:@"Invalid JSON response"];
                completion(nil, parseError);
                return;
            }

            // Parse images
            NSArray<ArtistImage *> *images = [self parseImagesFromResponse:json];
            GALLERY_LOG(@"%lu images in %.2fs", (unsigned long)images.count, duration);

            completion(images, nil);
        }];

        [task resume];
    });
}

- (void)cancelAllRequests {
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        for (NSURLSessionTask *task in tasks) {
            [task cancel];
        }
    }];
}

#pragma mark - URL Building

- (NSURL *)artistURLForMBID:(NSString *)mbid {
    // Validate MBID is a proper UUID to prevent path injection
    static NSRegularExpression *uuidRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uuidRegex = [NSRegularExpression regularExpressionWithPattern:
                     @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
    });

    if ([uuidRegex numberOfMatchesInString:mbid options:0 range:NSMakeRange(0, mbid.length)] == 0) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:
        [NSString stringWithFormat:@"%@%@", kFanartTvApiBaseUrl, mbid]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"api_key" value:@FANARTTV_API_KEY]
    ];
    return components.URL;
}

#pragma mark - Response Parsing

- (NSArray<ArtistImage *> *)parseImagesFromResponse:(NSDictionary *)response {
    NSMutableArray<ArtistImage *> *images = [NSMutableArray array];

    // Parse artist backgrounds (high priority)
    NSArray *backgrounds = response[@"artistbackground"];
    if ([backgrounds isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in backgrounds) {
            ArtistImage *image = [self parseImageItem:item type:ArtistImageTypeBackground];
            if (image) [images addObject:image];
        }
    }

    // Parse artist thumbs
    NSArray *thumbs = response[@"artistthumb"];
    if ([thumbs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in thumbs) {
            ArtistImage *image = [self parseImageItem:item type:ArtistImageTypeThumbnail];
            if (image) [images addObject:image];
        }
    }

    // Parse HD music logos
    NSArray *hdLogos = response[@"hdmusiclogo"];
    if ([hdLogos isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in hdLogos) {
            ArtistImage *image = [self parseImageItem:item type:ArtistImageTypeLogo];
            if (image) [images addObject:image];
        }
    }

    // Parse regular music logos (fallback)
    NSArray *logos = response[@"musiclogo"];
    if ([logos isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in logos) {
            ArtistImage *image = [self parseImageItem:item type:ArtistImageTypeLogo];
            if (image) [images addObject:image];
        }
    }

    // Parse music banners
    NSArray *banners = response[@"musicbanner"];
    if ([banners isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in banners) {
            ArtistImage *image = [self parseImageItem:item type:ArtistImageTypeBanner];
            if (image) [images addObject:image];
        }
    }

    return [images copy];
}

- (nullable ArtistImage *)parseImageItem:(NSDictionary *)item type:(ArtistImageType)type {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;

    NSString *urlString = item[@"url"];
    if (!urlString || ![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return nil;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    // FanartTV provides likes count
    NSInteger likes = 0;
    id likesValue = item[@"likes"];
    if ([likesValue respondsToSelector:@selector(integerValue)]) {
        likes = [likesValue integerValue];
    }

    return [[ArtistImage alloc] initWithURL:url
                               thumbnailURL:nil  // FanartTV doesn't provide thumbs
                                  imageType:type
                                     source:BiographySourceFanartTv
                                      likes:likes];
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

- (NSError *)errorWithCode:(FanartTvErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:FanartTvErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

@end
