//
//  DeezerClient.mm
//  foo_jl_biography_mac
//
//  Deezer API client for artist images
//

#import "DeezerClient.h"
#import "BiographyAPIConstants.h"
#import "../Core/BiographyRequest.h"
#import "../Core/ArtistImage.h"
#import "../Core/ArtistNameMatcher.h"
#import "../Core/GalleryImageParsing.h"

static NSString * const kDeezerApiBaseUrl = @"https://api.deezer.com";
static const NSTimeInterval kDeezerTimeout = 10.0;

// QUAL-15: Use named constant from BiographyAPIConstants.h

#define DEEZER_LOG(fmt, ...) NSLog(@"[Gallery/Deezer] " fmt, ##__VA_ARGS__)

@interface DeezerClient ()

@property (nonatomic, strong) NSURLSession *session;

@end

@implementation DeezerClient

+ (instancetype)shared {
    static DeezerClient *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DeezerClient alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kDeezerTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": kBiographyUserAgent
        };
        _session = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

- (void)fetchImagesForArtist:(NSString *)artistName
                       token:(BiographyRequest *)token
                  completion:(DeezerImageCompletion)completion {

    if (!artistName || artistName.length == 0) {
        completion(@[], nil);
        return;
    }

    // Build search URL
    NSURLComponents *components = [NSURLComponents componentsWithString:kDeezerApiBaseUrl];
    components.path = @"/search/artist";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"q" value:artistName],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"5"]
    ];

    NSURL *url = components.URL;
    DEEZER_LOG(@"Searching: %@", url.absoluteString);

    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {

        if (token.isCancelled) {
            completion(@[], nil);
            return;
        }

        if (error) {
            DEEZER_LOG(@"Network error: %@", error.localizedDescription);
            completion(nil, error);
            return;
        }

        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (httpResponse.statusCode != 200) {
            DEEZER_LOG(@"HTTP %ld", (long)httpResponse.statusCode);
            completion(@[], nil);
            return;
        }

        // Parse JSON
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];

        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            DEEZER_LOG(@"JSON parse error");
            completion(@[], nil);
            return;
        }

        // Find matching artist
        NSArray *results = json[@"data"];
        if (![results isKindOfClass:[NSArray class]] || results.count == 0) {
            DEEZER_LOG(@"No results for %@", artistName);
            completion(@[], nil);
            return;
        }

        // SEC-9: Only accept exact match or close match (not arbitrary first result)
        NSDictionary *matchedArtist = [ArtistNameMatcher bestMatchInResults:results
                                                                    forName:artistName
                                                                    nameKey:@"name"];
        if (!matchedArtist) {
            DEEZER_LOG(@"No acceptable match for %@", artistName);
            completion(@[], nil);
            return;
        }
        DEEZER_LOG(@"Matched: %@", matchedArtist[@"name"]);

        // Extract the single best picture (skips the default placeholder)
        ArtistImage *image = [GalleryImageParsing imageFromDeezerArtist:matchedArtist];
        NSArray<ArtistImage *> *images = image ? @[image] : @[];

        DEEZER_LOG(@"%lu images for %@", (unsigned long)images.count, artistName);
        completion(images, nil);
    }];

    [task resume];
}

// QUAL-7: Cancel support consistent with other API clients
- (void)cancelAllRequests {
    [self.session getAllTasksWithCompletionHandler:^(NSArray<__kindof NSURLSessionTask *> *tasks) {
        for (NSURLSessionTask *task in tasks) {
            [task cancel];
        }
    }];
}

@end
