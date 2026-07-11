//
//  AudioDbClient.mm
//  foo_jl_biography_mac
//
//  API client for TheAudioDB artist images
//

#import "AudioDbClient.h"
#import "BiographyAPIConstants.h"
#import "SecretConfig.h"
#import "../Core/BiographyRequest.h"
#import "../Core/RateLimiter.h"
#import "../Core/ArtistImage.h"

NSString * const AudioDbErrorDomain = @"com.foobar2000.biography.audiodb";

// API timeout (10 seconds as per plan)
static const NSTimeInterval kAudioDbRequestTimeout = 10.0;

// Logging macro
#define GALLERY_LOG(fmt, ...) NSLog(@"[Gallery/AudioDB] " fmt, ##__VA_ARGS__)

@interface AudioDbClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) BiographyRateLimiter *rateLimiter;
@property (nonatomic, strong) dispatch_queue_t requestQueue;

@end

@implementation AudioDbClient

#pragma mark - Singleton

+ (instancetype)shared {
    static AudioDbClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AudioDbClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Configure URL session with shorter timeout
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kAudioDbRequestTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kBiographyUserAgent
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        // Configure rate limiter (stricter for AudioDB free tier)
        _rateLimiter = [[BiographyRateLimiter alloc] initWithTokensPerSecond:kAudioDbRatePerSecond
                                                               burstCapacity:kAudioDbBurstCapacity];

        // Serial queue for API requests
        _requestQueue = dispatch_queue_create("com.foobar2000.biography.audiodb", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Public API

- (void)fetchImagesForArtist:(NSString *)artistName
                       token:(BiographyRequest *)token
                  completion:(AudioDbCompletion)completion {

    if (!artistName || artistName.length == 0) {
        NSError *error = [self errorWithCode:AudioDbErrorCodeInvalidResponse message:@"Artist name required"];
        completion(nil, error);
        return;
    }

    dispatch_async(self.requestQueue, ^{
        // Check cancellation
        if (token.isCancelled) {
            NSError *error = [self errorWithCode:AudioDbErrorCodeCancelled message:@"Request cancelled"];
            completion(nil, error);
            return;
        }

        // Wait for rate limiter
        [self waitForRateLimiter:token];

        // Check cancellation again after wait
        if (token.isCancelled) {
            NSError *error = [self errorWithCode:AudioDbErrorCodeCancelled message:@"Request cancelled"];
            completion(nil, error);
            return;
        }

        // Build request URL
        NSURL *url = [self searchURLForArtist:artistName];
#if DEBUG
        GALLERY_LOG(@"Fetching from: %@", url);
#endif

        NSDate *startTime = [NSDate date];

        // Make request
        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            NSTimeInterval duration = -[startTime timeIntervalSinceNow];

            if (token.isCancelled) {
                NSError *cancelError = [self errorWithCode:AudioDbErrorCodeCancelled message:@"Request cancelled"];
                completion(nil, cancelError);
                return;
            }

            if (error) {
                if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorTimedOut) {
                    GALLERY_LOG(@"Timeout after %.2fs", duration);
                    NSError *timeoutError = [self errorWithCode:AudioDbErrorCodeTimeout message:@"Request timed out"];
                    completion(nil, timeoutError);
                } else {
                    GALLERY_LOG(@"Network error: %@", error.localizedDescription);
                    NSError *networkError = [self errorWithCode:AudioDbErrorCodeNetworkError
                                                        message:error.localizedDescription];
                    completion(nil, networkError);
                }
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;

            if (httpResponse.statusCode == 429) {
                GALLERY_LOG(@"Rate limited");
                NSError *rateLimitError = [self errorWithCode:AudioDbErrorCodeRateLimited
                                                      message:@"Rate limited"];
                completion(nil, rateLimitError);
                return;
            }

            if (httpResponse.statusCode != 200) {
                GALLERY_LOG(@"HTTP %ld", (long)httpResponse.statusCode);
                NSError *httpError = [self errorWithCode:AudioDbErrorCodeNetworkError
                                                 message:[NSString stringWithFormat:@"HTTP %ld", (long)httpResponse.statusCode]];
                completion(nil, httpError);
                return;
            }

            // Parse JSON
            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                GALLERY_LOG(@"Invalid JSON response");
                NSError *parseError = [self errorWithCode:AudioDbErrorCodeInvalidResponse
                                                  message:@"Invalid JSON response"];
                completion(nil, parseError);
                return;
            }

            // Check for artists array
            NSArray *artists = json[@"artists"];
            if (!artists || ![artists isKindOfClass:[NSArray class]] || artists.count == 0) {
                GALLERY_LOG(@"Artist not found: %@", artistName);
                NSError *notFoundError = [self errorWithCode:AudioDbErrorCodeArtistNotFound
                                                     message:@"Artist not found"];
                completion(nil, notFoundError);
                return;
            }

            // Get first artist
            NSDictionary *artist = artists.firstObject;
            if (![artist isKindOfClass:[NSDictionary class]]) {
                NSError *parseError = [self errorWithCode:AudioDbErrorCodeInvalidResponse
                                                  message:@"Invalid artist data"];
                completion(nil, parseError);
                return;
            }

            // Disambiguation: validate returned artist matches request
            NSString *returnedName = artist[@"strArtist"];
            if (returnedName && ![self artistName:returnedName matchesRequest:artistName]) {
                GALLERY_LOG(@"Artist mismatch: '%@' vs '%@', discarding", returnedName, artistName);
                NSError *mismatchError = [self errorWithCode:AudioDbErrorCodeArtistMismatch
                                                     message:@"Artist name mismatch"];
                completion(nil, mismatchError);
                return;
            }

            // Parse images
            NSArray<ArtistImage *> *images = [self parseImagesFromArtist:artist];
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

- (NSURL *)searchURLForArtist:(NSString *)artistName {
    // Endpoint: https://www.theaudiodb.com/api/v1/json/{key}/search.php?s={artist_name}
    NSString *encodedArtist = [artistName stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"%@%s/search.php?s=%@",
                           kAudioDbApiBaseUrl,
                           AUDIODB_API_KEY,
                           encodedArtist];
    return [NSURL URLWithString:urlString];
}

#pragma mark - Response Parsing

- (NSArray<ArtistImage *> *)parseImagesFromArtist:(NSDictionary *)artist {
    NSMutableArray<ArtistImage *> *images = [NSMutableArray array];

    // Parse fanart images (strArtistFanart, strArtistFanart2, strArtistFanart3, strArtistFanart4)
    NSArray *fanartKeys = @[@"strArtistFanart", @"strArtistFanart2", @"strArtistFanart3", @"strArtistFanart4"];
    for (NSString *key in fanartKeys) {
        ArtistImage *image = [self parseImageFromArtist:artist key:key type:ArtistImageTypeBackground];
        if (image) [images addObject:image];
    }

    // Parse thumbnail
    ArtistImage *thumb = [self parseImageFromArtist:artist key:@"strArtistThumb" type:ArtistImageTypeThumbnail];
    if (thumb) [images addObject:thumb];

    // Parse logo
    ArtistImage *logo = [self parseImageFromArtist:artist key:@"strArtistLogo" type:ArtistImageTypeLogo];
    if (logo) [images addObject:logo];

    // Parse wide thumb (use as thumbnail)
    ArtistImage *wideThumb = [self parseImageFromArtist:artist key:@"strArtistWideThumb" type:ArtistImageTypeThumbnail];
    if (wideThumb) [images addObject:wideThumb];

    // Parse banner
    ArtistImage *banner = [self parseImageFromArtist:artist key:@"strArtistBanner" type:ArtistImageTypeBanner];
    if (banner) [images addObject:banner];

    // Parse cutout (use as thumbnail)
    ArtistImage *cutout = [self parseImageFromArtist:artist key:@"strArtistCutout" type:ArtistImageTypeThumbnail];
    if (cutout) [images addObject:cutout];

    // Parse clearart (use as logo)
    ArtistImage *clearart = [self parseImageFromArtist:artist key:@"strArtistClearart" type:ArtistImageTypeLogo];
    if (clearart) [images addObject:clearart];

    return [images copy];
}

- (nullable ArtistImage *)parseImageFromArtist:(NSDictionary *)artist
                                           key:(NSString *)key
                                          type:(ArtistImageType)type {
    id value = artist[key];
    if (!value || value == [NSNull null]) return nil;
    if (![value isKindOfClass:[NSString class]]) return nil;

    NSString *urlString = (NSString *)value;
    if (urlString.length == 0) return nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    // AudioDB provides /preview suffix for thumbnails
    NSURL *thumbnailURL = nil;
    if (type == ArtistImageTypeBackground) {
        NSString *thumbUrlString = [urlString stringByAppendingString:@"/preview"];
        thumbnailURL = [NSURL URLWithString:thumbUrlString];
    }

    return [[ArtistImage alloc] initWithURL:url
                               thumbnailURL:thumbnailURL
                                  imageType:type
                                     source:BiographySourceAudioDb
                                      likes:0];  // AudioDB doesn't provide likes
}

#pragma mark - Artist Name Matching

- (BOOL)artistName:(NSString *)returnedName matchesRequest:(NSString *)requestedName {
    if (!returnedName || !requestedName) return NO;

    // Case-insensitive comparison
    NSString *normalizedReturned = [returnedName lowercaseString];
    NSString *normalizedRequested = [requestedName lowercaseString];

    // Exact match
    if ([normalizedReturned isEqualToString:normalizedRequested]) {
        return YES;
    }

    // QUAL-16: Only use containsString for names >= 4 chars to avoid false positives
    if (normalizedRequested.length >= 4 && normalizedReturned.length >= 4) {
        if ([normalizedReturned containsString:normalizedRequested] ||
            [normalizedRequested containsString:normalizedReturned]) {
            return YES;
        }
    }

    // Remove common prefixes and compare
    NSArray *prefixes = @[@"the ", @"a ", @"an "];
    NSString *strippedReturned = normalizedReturned;
    NSString *strippedRequested = normalizedRequested;

    for (NSString *prefix in prefixes) {
        if ([strippedReturned hasPrefix:prefix]) {
            strippedReturned = [strippedReturned substringFromIndex:prefix.length];
        }
        if ([strippedRequested hasPrefix:prefix]) {
            strippedRequested = [strippedRequested substringFromIndex:prefix.length];
        }
    }

    return [strippedReturned isEqualToString:strippedRequested];
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

- (NSError *)errorWithCode:(AudioDbErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:AudioDbErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

@end
