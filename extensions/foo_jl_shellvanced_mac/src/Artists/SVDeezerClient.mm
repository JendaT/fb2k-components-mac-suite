//
//  SVDeezerClient.mm
//  foo_jl_shellvanced_mac
//

#import "SVDeezerClient.h"
#import "SVRateLimiter.h"
#import "SVRedirectGuard.h"

static NSString *const kSVDeezerApiHost = @"api.deezer.com";
static NSString *const kSVDeezerUserAgent = @"foobar2000-component";
static const NSTimeInterval kSVDeezerTimeout = 10.0;
static const NSTimeInterval kSVDeezerTokenWait = 10.0;

@implementation SVDeezerClient {
    NSURLSession *_session;
    SVRateLimiter *_limiter;
    dispatch_queue_t _queue;  // serial: waits for rate-limit tokens off the main thread
}

+ (instancetype)shared {
    static SVDeezerClient *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[SVDeezerClient alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = kSVDeezerTimeout;
        config.HTTPAdditionalHeaders = @{@"User-Agent": kSVDeezerUserAgent};
        _session = [NSURLSession sessionWithConfiguration:config];
        _limiter = [[SVRateLimiter alloc] initWithTokensPerSecond:8.0 burstCapacity:1];  // burst 1 = at most one request per 125 ms
        _queue = dispatch_queue_create("foo_jl_shellvanced.deezer", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

// Waits for a rate-limit token on the serial queue, then starts the request.
- (void)request:(NSURL *)url completion:(void (^)(NSData *_Nullable data))completion {
    [self request:url redirectGuard:nil completion:completion];
}

- (void)request:(NSURL *)url redirectGuard:(SVRedirectGuard *_Nullable)guard
     completion:(void (^)(NSData *_Nullable data))completion {
    dispatch_async(_queue, ^{
        if (![self->_limiter acquireWithTimeout:kSVDeezerTokenWait]) { completion(nil); return; }
        NSURLSessionDataTask *task = [self->_session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
                    ? ((NSHTTPURLResponse *)response).statusCode : 0;
                completion((error || status != 200) ? nil : data);
            }];
        if (guard) task.delegate = guard;  // re-checks the host on every redirect
        [task resume];
    });
}

static NSURL *APIURL(NSString *path, NSArray<NSURLQueryItem *> *items) {
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.scheme = @"https";
    c.host = kSVDeezerApiHost;
    c.path = path;
    c.queryItems = items;
    return c.URL;
}

// Parses {"data":[...]} ; returns nil on parse failure or API error object.
static NSArray *DataArray(NSData *data) {
    if (!data) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]] || json[@"error"]) return nil;
    NSArray *arr = json[@"data"];
    return [arr isKindOfClass:[NSArray class]] ? arr : nil;
}

static std::string Str(id v) {
    if ([v isKindOfClass:[NSString class]]) return std::string([(NSString *)v UTF8String] ?: "");
    if ([v isKindOfClass:[NSNumber class]]) return std::string([[(NSNumber *)v stringValue] UTF8String]);
    return std::string();
}

- (void)searchArtist:(NSString *)name
          completion:(void (^)(std::vector<deezermatch::Candidate>, BOOL))completion {
    if (name.length == 0) { completion({}, YES); return; }
    NSURL *url = APIURL(@"/search/artist", @[[NSURLQueryItem queryItemWithName:@"q" value:name],
                                             [NSURLQueryItem queryItemWithName:@"limit" value:@"5"]]);
    [self request:url completion:^(NSData *data) {
        NSArray *arr = DataArray(data);
        if (!arr) { completion({}, NO); return; }
        std::vector<deezermatch::Candidate> out;
        for (id item in arr) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = item;
            deezermatch::Candidate c;
            c.id = Str(d[@"id"]);
            c.name = Str(d[@"name"]);
            std::string pic = Str(d[@"picture_big"]);
            if (pic.empty()) pic = Str(d[@"picture_medium"]);
            c.pictureUrl = pic;
            c.fans = [d[@"nb_fan"] respondsToSelector:@selector(longValue)] ? [d[@"nb_fan"] longValue] : 0;
            c.nbAlbum = [d[@"nb_album"] respondsToSelector:@selector(longValue)] ? [d[@"nb_album"] longValue] : -1;
            if (!c.id.empty()) out.push_back(std::move(c));
        }
        completion(std::move(out), YES);
    }];
}

- (void)albumsForArtistId:(NSString *)artistId
               completion:(void (^)(NSArray<NSString *> *_Nullable, NSArray<NSString *> *))completion {
    // The id is interpolated into a path: accept digits only.
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (artistId.length == 0 || [artistId rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        completion(nil, @[]);
        return;
    }
    NSURL *url = APIURL([NSString stringWithFormat:@"/artist/%@/albums", artistId],
                        @[[NSURLQueryItem queryItemWithName:@"limit" value:@"100"]]);
    [self request:url completion:^(NSData *data) {
        NSArray *arr = DataArray(data);
        if (!arr) { completion(nil, @[]); return; }
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        NSMutableArray<NSString *> *covers = [NSMutableArray array];
        for (id item in arr) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = item;
            NSString *t = d[@"title"];
            if ([t isKindOfClass:[NSString class]] && t.length) [titles addObject:t];
            NSString *c = [d[@"cover_small"] isKindOfClass:[NSString class]] ? d[@"cover_small"] : nil;
            if (c.length == 0) c = [d[@"cover_medium"] isKindOfClass:[NSString class]] ? d[@"cover_medium"] : nil;
            if (c.length && covers.count < 10 && ![covers containsObject:c]) [covers addObject:c];
        }
        completion(titles, covers);
    }];
}

- (void)albumCountForArtistId:(NSString *)artistId completion:(void (^)(long))completion {
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (artistId.length == 0 || [artistId rangeOfCharacterFromSet:nonDigits].location != NSNotFound) {
        completion(-1);
        return;
    }
    NSURL *url = APIURL([NSString stringWithFormat:@"/artist/%@", artistId], nil);
    [self request:url completion:^(NSData *data) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]] || json[@"error"]) { completion(-1); return; }
        id n = json[@"nb_album"];
        completion([n respondsToSelector:@selector(longValue)] ? [n longValue] : -1);
    }];
}

- (void)downloadImageAtURL:(NSURL *)url completion:(void (^)(NSData *_Nullable))completion {
    static NSArray<NSString *> *hosts;
    static SVRedirectGuard *guard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[@"dzcdn.net", kSVDeezerApiHost];
        guard = [SVRedirectGuard guardWithHosts:hosts];
    });
    if (![SVRedirectGuard url:url isAllowedForHosts:hosts]) { completion(nil); return; }
    [self request:url redirectGuard:guard completion:completion];
}

@end
