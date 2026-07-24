//
//  MusicBrainzProvider.mm
//  foo_jl_album_art_mac
//
//  MusicBrainz API implementation
//

#import "MusicBrainzProvider.h"
#import "RemoteArtworkTypes.h"
#import "../../../../shared/RateLimiter.h"

static NSString *const kMusicBrainzBaseURL = @"https://musicbrainz.org/ws/2";
static const NSTimeInterval kMusicBrainzTimeout = 30.0;

@interface MusicBrainzProvider ()

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) JLRateLimiter *rateLimiter;
@property (nonatomic, strong) dispatch_queue_t requestQueue;
// currentTask is only touched on requestQueue (cancel dispatches onto it) so
// the background lookup and a main-thread cancel never race on the ivar
@property (nonatomic, strong, nullable) NSURLSessionTask *currentTask;
@property (atomic, assign) BOOL cancelled;

@end

@implementation MusicBrainzProvider

+ (MusicBrainzProvider *)sharedInstance {
    static MusicBrainzProvider *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MusicBrainzProvider alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        // Configure URL session with required User-Agent
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = kMusicBrainzTimeout;
        config.HTTPAdditionalHeaders = @{
            @"User-Agent": [self userAgent],
            @"Accept": @"application/json"
        };
        _session = [NSURLSession sessionWithConfiguration:config];

        // Strict 1 request per second per MusicBrainz policy
        _rateLimiter = [[JLRateLimiter alloc] initWithTokensPerSecond:1.0 burstCapacity:1];

        // Serial queue for rate-limited requests
        _requestQueue = dispatch_queue_create("com.foobar2000.albumart.musicbrainz",
                                              DISPATCH_QUEUE_SERIAL);
        _cancelled = NO;
    }
    return self;
}

- (NSString *)userAgent {
    // MusicBrainz requires contact info in User-Agent
    // Format: AppName/Version (contact-url-or-email)
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *appName = bundle.infoDictionary[@"CFBundleName"] ?: @"foobar2000-albumart";
    NSString *version = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"1.0";
    return [NSString stringWithFormat:@"%@/%@ (https://github.com/foo-plugins/foobar2000-components)",
            appName, version];
}

#pragma mark - Public API

- (void)lookupMBIDForMetadata:(TrackMetadata *)metadata
                   completion:(MusicBrainzMBIDCompletion)completion {

    // If we already have an MBID from the file tags, use it directly - but
    // only if it is a valid UUID. The tag is attacker-controllable, and an
    // invalid value would later crash the CAA request (nil URL) or inject a
    // path; reject it here so we fall through to a normal search instead.
    if (metadata.musicBrainzReleaseID.length > 0 &&
        [[NSUUID alloc] initWithUUIDString:metadata.musicBrainzReleaseID]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(metadata.musicBrainzReleaseID, nil);
        });
        return;
    }

    // Network check is done by RemoteArtworkSearchController before calling providers

    // Need artist and album to search. We query with albumArtist below, which
    // TrackMetadata guarantees falls back to artist when empty - so a non-empty
    // artist here implies a non-empty albumArtist.
    if (metadata.artist.length == 0 || metadata.album.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                                 code:ArtworkFetchErrorInvalidMetadata
                                             userInfo:@{NSLocalizedDescriptionKey: @"Missing artist or album"}];
            completion(nil, error);
        });
        return;
    }

    self.cancelled = NO;

    dispatch_async(self.requestQueue, ^{
        // Wait for rate limit token
        [self.rateLimiter acquireWithTimeout:30.0];

        if (self.cancelled) {
            return;
        }

        // Build search URL
        NSURL *url = [self searchURLForArtist:metadata.albumArtist album:metadata.album];

        NSURLSessionDataTask *task = [self.session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

            if (self.cancelled) {
                return;
            }

            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, [self networkError:error]);
                });
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode == 503) {
                // Rate limited
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *rateLimitError = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                                                  code:ArtworkFetchErrorRateLimited
                                                              userInfo:@{NSLocalizedDescriptionKey: @"Rate limited by MusicBrainz"}];
                    completion(nil, rateLimitError);
                });
                return;
            }

            if (httpResponse.statusCode != 200) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSError *apiError = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                                            code:ArtworkFetchErrorAPIError
                                                        userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"MusicBrainz error: %ld", (long)httpResponse.statusCode]}];
                    completion(nil, apiError);
                });
                return;
            }

            // Parse JSON response
            NSString *mbid = [self parseMBIDFromData:data];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (mbid) {
                    completion(mbid, nil);
                } else {
                    NSError *noResultsError = [NSError errorWithDomain:ArtworkFetchErrorDomain
                                                                  code:ArtworkFetchErrorNoResults
                                                              userInfo:@{NSLocalizedDescriptionKey: @"No matching release found"}];
                    completion(nil, noResultsError);
                }
            });
        }];

        self.currentTask = task;
        [task resume];
    });
}

- (void)cancel {
    self.cancelled = YES;
    dispatch_async(self.requestQueue, ^{
        [self.currentTask cancel];
        self.currentTask = nil;
    });
}

#pragma mark - URL Building

- (NSURL *)searchURLForArtist:(NSString *)artist album:(NSString *)album {
    // MusicBrainz Lucene query syntax
    // release:"album name" AND artist:"artist name"
    NSString *query = [NSString stringWithFormat:@"release:\"%@\" AND artist:\"%@\"",
                       [self escapeLucene:album],
                       [self escapeLucene:artist]];

    NSURLComponents *components = [[NSURLComponents alloc] initWithString:
                                   [NSString stringWithFormat:@"%@/release/", kMusicBrainzBaseURL]];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:query],
        [NSURLQueryItem queryItemWithName:@"fmt" value:@"json"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"5"]
    ];

    return components.URL;
}

- (NSString *)escapeLucene:(NSString *)input {
    // Escape Lucene special characters
    static NSCharacterSet *luceneChars = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        luceneChars = [NSCharacterSet characterSetWithCharactersInString:@"+-&|!(){}[]^\"~*?:\\/"];
    });

    NSMutableString *escaped = [NSMutableString string];
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if ([luceneChars characterIsMember:c]) {
            [escaped appendString:@"\\"];
        }
        [escaped appendString:[NSString stringWithCharacters:&c length:1]];
    }

    return escaped;
}

#pragma mark - Response Parsing

static const NSInteger kMinMusicBrainzScore = 80;

- (nullable NSString *)parseMBIDFromData:(NSData *)data {
    NSError *jsonError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:&jsonError];
    if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSArray *releases = json[@"releases"];
    if (![releases isKindOfClass:[NSArray class]] || releases.count == 0) {
        return nil;
    }

    // Find the first release with a high enough confidence score
    for (NSDictionary *release in releases) {
        if (![release isKindOfClass:[NSDictionary class]]) continue;

        // Check score (MusicBrainz returns 0-100)
        NSNumber *scoreNum = release[@"score"];
        if ([scoreNum isKindOfClass:[NSNumber class]] && scoreNum.integerValue < kMinMusicBrainzScore) {
            continue;
        }

        NSString *mbid = release[@"id"];
        if ([mbid isKindOfClass:[NSString class]] && mbid.length > 0) {
            return mbid;
        }
    }

    return nil;
}

#pragma mark - Error Handling

- (NSError *)networkError:(NSError *)urlError {
    if ([urlError.domain isEqualToString:NSURLErrorDomain]) {
        switch (urlError.code) {
            case NSURLErrorTimedOut:
                return [NSError errorWithDomain:ArtworkFetchErrorDomain
                                           code:ArtworkFetchErrorTimeout
                                       userInfo:@{NSLocalizedDescriptionKey: @"Request timed out"}];

            case NSURLErrorNotConnectedToInternet:
            case NSURLErrorNetworkConnectionLost:
                return [NSError errorWithDomain:ArtworkFetchErrorDomain
                                           code:ArtworkFetchErrorNetworkUnavailable
                                       userInfo:@{NSLocalizedDescriptionKey: @"Network unavailable"}];
        }
    }

    return [NSError errorWithDomain:ArtworkFetchErrorDomain
                               code:ArtworkFetchErrorAPIError
                           userInfo:@{NSLocalizedDescriptionKey: urlError.localizedDescription}];
}

@end
