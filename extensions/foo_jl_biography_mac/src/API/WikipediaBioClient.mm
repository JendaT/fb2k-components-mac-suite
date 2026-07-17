//
//  WikipediaBioClient.mm
//  foo_jl_biography_mac
//
//  Wikipedia biography client (Wikidata sitelink -> REST summary)
//

#import "WikipediaBioClient.h"
#import "BiographyAPIConstants.h"
#import "../Core/BiographyRequest.h"
#import "../Core/RateLimiter.h"
#import "../Core/WikipediaParsing.h"

NSString * const WikipediaBioErrorDomain = @"com.foobar2000.biography.wikipedia";

static NSString * const kWikidataApiBaseUrl = @"https://www.wikidata.org/w/api.php";
static const NSTimeInterval kWikipediaRequestTimeout = 10.0;

@interface WikipediaBioClient ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) BiographyRateLimiter *rateLimiter;
@property (nonatomic, strong) dispatch_queue_t requestQueue;

@end

@implementation WikipediaBioClient

#pragma mark - Singleton

+ (instancetype)shared {
    static WikipediaBioClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[WikipediaBioClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kWikipediaRequestTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kBiographyUserAgent,
            @"Accept": @"application/json"
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        _rateLimiter = [[BiographyRateLimiter alloc] initWithTokensPerSecond:kWikipediaRatePerSecond
                                                               burstCapacity:kWikipediaBurstCapacity];

        _requestQueue = dispatch_queue_create("com.foobar2000.biography.wikipedia", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Public API

- (void)fetchBioForWikidataQID:(NSString *)qid
                         token:(BiographyRequest *)token
                    completion:(WikipediaBioCompletion)completion {

    if (qid.length == 0) {
        completion(nil, [self errorWithCode:WikipediaBioErrorCodeInvalidResponse
                                    message:@"Wikidata QID required"]);
        return;
    }

    // Step 1: Wikidata entity -> enwiki article title
    NSURLComponents *components = [NSURLComponents componentsWithString:kWikidataApiBaseUrl];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"action" value:@"wbgetentities"],
        [NSURLQueryItem queryItemWithName:@"ids" value:qid],
        [NSURLQueryItem queryItemWithName:@"props" value:@"sitelinks"],
        [NSURLQueryItem queryItemWithName:@"sitefilter" value:@"enwiki"],
        [NSURLQueryItem queryItemWithName:@"format" value:@"json"],
    ];

    __weak typeof(self) weakSelf = self;
    [self performRequestWithURL:components.URL token:token completion:^(NSDictionary *json, NSError *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            completion(nil, error);
            return;
        }

        NSString *title = [WikipediaParsing enwikiTitleFromWikidataResponse:json];
        if (title.length == 0) {
            completion(nil, [strongSelf errorWithCode:WikipediaBioErrorCodeNoArticle
                                              message:@"No English Wikipedia article"]);
            return;
        }

        // Step 2: article title -> REST summary extract
        [strongSelf fetchSummaryForTitle:title token:token completion:completion];
    }];
}

- (void)fetchSummaryForTitle:(NSString *)title
                       token:(BiographyRequest *)token
                  completion:(WikipediaBioCompletion)completion {

    // REST path segment: spaces become underscores, then percent-encode
    NSString *pathTitle = [title stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSCharacterSet *allowed = [NSCharacterSet URLPathAllowedCharacterSet];
    pathTitle = [pathTitle stringByAddingPercentEncodingWithAllowedCharacters:allowed];

    NSString *urlString = [NSString stringWithFormat:@"%@page/summary/%@",
                           kWikipediaApiBaseUrl, pathTitle];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        completion(nil, [self errorWithCode:WikipediaBioErrorCodeInvalidResponse
                                    message:@"Invalid article title"]);
        return;
    }

    [self performRequestWithURL:url token:token completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }

        NSString *extract = [WikipediaParsing summaryExtractFromResponse:json];
        if (extract.length == 0) {
            completion(nil, [self errorWithCode:WikipediaBioErrorCodeNoArticle
                                        message:@"Article has no usable summary"]);
            return;
        }

        completion(extract, nil);
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
            completion(nil, [self errorWithCode:WikipediaBioErrorCodeCancelled message:@"Request cancelled"]);
            return;
        }

        [self waitForRateLimiter:token];

        if (token.isCancelled) {
            completion(nil, [self errorWithCode:WikipediaBioErrorCodeCancelled message:@"Request cancelled"]);
            return;
        }

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

            if (token.isCancelled) {
                completion(nil, [self errorWithCode:WikipediaBioErrorCodeCancelled message:@"Request cancelled"]);
                return;
            }

            if (error) {
                completion(nil, [self errorWithCode:WikipediaBioErrorCodeNetworkError
                                            message:error.localizedDescription]);
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode == 404) {
                completion(nil, [self errorWithCode:WikipediaBioErrorCodeNoArticle message:@"Not found"]);
                return;
            }
            if (httpResponse.statusCode != 200) {
                completion(nil, [self errorWithCode:WikipediaBioErrorCodeNetworkError
                                            message:[NSString stringWithFormat:@"HTTP %ld",
                                                     (long)httpResponse.statusCode]]);
                return;
            }

            NSError *jsonError = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
                completion(nil, [self errorWithCode:WikipediaBioErrorCodeInvalidResponse
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

- (NSError *)errorWithCode:(WikipediaBioErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:WikipediaBioErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

@end
