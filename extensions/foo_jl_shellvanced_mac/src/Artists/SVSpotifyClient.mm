//
//  SVSpotifyClient.mm
//  foo_jl_shellvanced_mac
//

#import "SVSpotifyClient.h"
#import "SVSpotifyCredentials.h"

static NSString *const kTokenURL = @"https://accounts.spotify.com/api/token";
static NSString *const kApiHost = @"api.spotify.com";
static const NSTimeInterval kMinSpacing = 2.0;
static const NSTimeInterval kRequestTimeout = 15.0;

static NSURL *BlockFileURL(void) {
    NSURL *caches = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [[caches URLByAppendingPathComponent:@"foo_jl_shellvanced" isDirectory:YES]
                     URLByAppendingPathComponent:@"artists" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"spotify-block.json"];
}

static std::string Str(id v) {
    return [v isKindOfClass:[NSString class]] ? std::string([(NSString *)v UTF8String] ?: "") : std::string();
}

@implementation SVSpotifyClient {
    NSURLSession *_session;
    NSURLSession *_cdnSession;
    dispatch_queue_t _queue;       // serial: every Spotify API/token request runs here, one at a time
    NSObject *_stateLock;
    NSString *_token;              // _queue only
    NSDate *_tokenExpiry;          // _queue only
    NSDate *_lastRequestEnd;       // _queue only
    NSTimeInterval _blockUntil;    // _stateLock
    BOOL _authFailed;              // _stateLock
}

+ (instancetype)shared {
    static SVSpotifyClient *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[SVSpotifyClient alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = kRequestTimeout;
        config.HTTPAdditionalHeaders = @{@"User-Agent": @"foobar2000-component"};
        _session = [NSURLSession sessionWithConfiguration:config];
        _cdnSession = [NSURLSession sessionWithConfiguration:config];
        _queue = dispatch_queue_create("foo_jl_shellvanced.spotify", DISPATCH_QUEUE_SERIAL);
        _stateLock = [[NSObject alloc] init];
        NSData *data = [NSData dataWithContentsOfURL:BlockFileURL()];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"until"] isKindOfClass:[NSNumber class]])
            _blockUntil = [json[@"until"] doubleValue];
    }
    return self;
}

#pragma mark - State

- (BOOL)isBlocked {
    @synchronized (_stateLock) { return _blockUntil > [NSDate date].timeIntervalSince1970; }
}

- (BOOL)isAvailable {
    @synchronized (_stateLock) {
        if (_authFailed || _blockUntil > [NSDate date].timeIntervalSince1970) return NO;
    }
    return [SVSpotifyCredentials isConfigured];
}

- (void)blockForSeconds:(long)seconds {
    NSTimeInterval until = [NSDate date].timeIntervalSince1970 + seconds;
    @synchronized (_stateLock) { _blockUntil = until; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"until": @(until)} options:0 error:nil];
    [data writeToURL:BlockFileURL() atomically:YES];
}

- (void)credentialsChanged {
    @synchronized (_stateLock) { _blockUntil = 0; _authFailed = NO; }
    [[NSFileManager defaultManager] removeItemAtURL:BlockFileURL() error:nil];
    dispatch_async(_queue, ^{ self->_token = nil; self->_tokenExpiry = nil; });
}

#pragma mark - Transport (all on _queue)

// Waits for the >= 2 s spacing, performs the request synchronously. Returns nil on transport error.
- (NSData *)perform:(NSURLRequest *)req response:(NSHTTPURLResponse **)outResp {
    if (_lastRequestEnd) {
        NSTimeInterval wait = kMinSpacing + [_lastRequestEnd timeIntervalSinceNow];  // timeIntervalSinceNow < 0
        if (wait > 0) [NSThread sleepForTimeInterval:wait];
    }
    __block NSData *result = nil;
    __block NSHTTPURLResponse *resp = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
        if (!error && [r isKindOfClass:[NSHTTPURLResponse class]]) { result = data ?: [NSData data]; resp = (NSHTTPURLResponse *)r; }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kRequestTimeout + 5) * NSEC_PER_SEC)));
    _lastRequestEnd = [NSDate date];
    if (outResp) *outResp = resp;
    return result;
}

- (void)noteRateLimit:(NSHTTPURLResponse *)resp {
    NSString *ra = [resp valueForHTTPHeaderField:@"Retry-After"];
    [self blockForSeconds:spmatch::parseRetryAfter(ra.UTF8String ?: "")];
}

// Token request. On failure `message` describes it (never contains credentials).
- (SVSpotifyStatus)fetchTokenId:(NSString *)cid secret:(NSString *)secret
                          token:(NSString **)outToken expiry:(NSDate **)outExpiry message:(NSString **)message {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kTokenURL]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [@"grant_type=client_credentials" dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithUTF8String:spmatch::basicAuthValue(cid.UTF8String ?: "", secret.UTF8String ?: "").c_str()]
        forHTTPHeaderField:@"Authorization"];
    NSHTTPURLResponse *resp = nil;
    NSData *data = [self perform:req response:&resp];
    if (!data) { if (message) *message = @"Network error"; return SVSpotifyStatusFailed; }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (resp.statusCode == 429) {
        [self noteRateLimit:resp];
        if (message) *message = @"Rate limited by Spotify";
        return SVSpotifyStatusBlocked;
    }
    if (resp.statusCode == 200 && [json isKindOfClass:[NSDictionary class]] &&
        [json[@"access_token"] isKindOfClass:[NSString class]]) {
        double ttl = [json[@"expires_in"] respondsToSelector:@selector(doubleValue)] ? [json[@"expires_in"] doubleValue] : 3600;
        if (outToken) *outToken = json[@"access_token"];
        if (outExpiry) *outExpiry = [NSDate dateWithTimeIntervalSinceNow:MAX(60.0, ttl - 60.0)];
        return SVSpotifyStatusOK;
    }
    NSString *detail = nil;
    if ([json isKindOfClass:[NSDictionary class]]) {
        id d = json[@"error_description"] ?: json[@"error"];
        if ([d isKindOfClass:[NSString class]]) detail = d;
    }
    if (message) *message = [NSString stringWithFormat:@"HTTP %ld%@%@", (long)resp.statusCode, detail ? @": " : @"", detail ?: @""];
    return (resp.statusCode == 400 || resp.statusCode == 401) ? SVSpotifyStatusAuthFailed : SVSpotifyStatusFailed;
}

// Authenticated GET returning parsed JSON dictionary. Refreshes the token once on 401.
- (SVSpotifyStatus)getPath:(NSString *)path query:(NSArray<NSURLQueryItem *> *)items json:(NSDictionary **)outJson {
    if ([self isBlocked]) return SVSpotifyStatusBlocked;
    NSString *cid = [SVSpotifyCredentials clientId], *secret = [SVSpotifyCredentials clientSecret];
    if (cid.length == 0 || secret.length == 0) return SVSpotifyStatusAuthFailed;
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.scheme = @"https"; c.host = kApiHost; c.path = path; c.queryItems = items;
    NSURL *url = c.URL;
    if (!url) return SVSpotifyStatusFailed;

    for (int attempt = 0; attempt < 2; attempt++) {
        if (!_token || [_tokenExpiry timeIntervalSinceNow] <= 0) {
            NSString *tok = nil; NSDate *exp = nil;
            SVSpotifyStatus st = [self fetchTokenId:cid secret:secret token:&tok expiry:&exp message:nil];
            if (st == SVSpotifyStatusAuthFailed) { @synchronized (_stateLock) { _authFailed = YES; } }
            if (st != SVSpotifyStatusOK) return st;
            _token = tok; _tokenExpiry = exp;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:[@"Bearer " stringByAppendingString:_token] forHTTPHeaderField:@"Authorization"];
        NSHTTPURLResponse *resp = nil;
        NSData *data = [self perform:req response:&resp];
        if (!data) return SVSpotifyStatusFailed;
        if (resp.statusCode == 429) { [self noteRateLimit:resp]; return SVSpotifyStatusBlocked; }
        if (resp.statusCode == 401 && attempt == 0) { _token = nil; _tokenExpiry = nil; continue; }
        if (resp.statusCode != 200) return SVSpotifyStatusFailed;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) return SVSpotifyStatusFailed;
        if (outJson) *outJson = json;
        return SVSpotifyStatusOK;
    }
    return SVSpotifyStatusFailed;
}

#pragma mark - Public

- (void)searchArtist:(NSString *)name
          completion:(void (^)(std::vector<spmatch::Candidate>, SVSpotifyStatus))completion {
    if (name.length == 0) { completion({}, SVSpotifyStatusOK); return; }
    dispatch_async(_queue, ^{
        NSDictionary *json = nil;
        SVSpotifyStatus st = [self getPath:@"/v1/search" query:@[
            [NSURLQueryItem queryItemWithName:@"type" value:@"artist"],
            [NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
            [NSURLQueryItem queryItemWithName:@"q" value:name]] json:&json];
        if (st != SVSpotifyStatusOK) { completion({}, st); return; }
        NSArray *items = [json[@"artists"] isKindOfClass:[NSDictionary class]] ? json[@"artists"][@"items"] : nil;
        if (![items isKindOfClass:[NSArray class]]) { completion({}, SVSpotifyStatusFailed); return; }
        std::vector<spmatch::Candidate> out;
        for (id item in items) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = item;
            spmatch::Candidate cand;
            cand.id = Str(d[@"id"]);
            cand.name = Str(d[@"name"]);
            std::vector<spmatch::Image> images;
            if ([d[@"images"] isKindOfClass:[NSArray class]])
                for (id im in d[@"images"]) {
                    if (![im isKindOfClass:[NSDictionary class]]) continue;
                    spmatch::Image img;
                    img.url = Str(im[@"url"]);
                    img.width = [im[@"width"] respondsToSelector:@selector(intValue)] ? [im[@"width"] intValue] : 0;
                    images.push_back(std::move(img));
                }
            cand.imageUrl = spmatch::pickImageUrl(images);
            if (!cand.id.empty()) out.push_back(std::move(cand));
        }
        completion(std::move(out), SVSpotifyStatusOK);
    });
}

- (void)albumsForArtistId:(NSString *)artistId
               completion:(void (^)(NSArray<NSString *> *, long, SVSpotifyStatus))completion {
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    if (artistId.length == 0 || artistId.length > 40 || [artistId rangeOfCharacterFromSet:bad].location != NSNotFound) {
        completion(nil, 0, SVSpotifyStatusFailed);
        return;
    }
    dispatch_async(_queue, ^{
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        long total = 0;
        for (int page = 0; page < 2; page++) {
            NSDictionary *json = nil;
            SVSpotifyStatus st = [self getPath:[NSString stringWithFormat:@"/v1/artists/%@/albums", artistId] query:@[
                [NSURLQueryItem queryItemWithName:@"include_groups" value:@"album,single,appears_on,compilation"],
                [NSURLQueryItem queryItemWithName:@"limit" value:@"50"],
                [NSURLQueryItem queryItemWithName:@"offset" value:[NSString stringWithFormat:@"%d", page * 50]]]
                                  json:&json];
            if (st != SVSpotifyStatusOK) { completion(nil, 0, st); return; }
            if (page == 0 && [json[@"total"] respondsToSelector:@selector(longValue)]) total = [json[@"total"] longValue];
            NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
            for (id item in items) {
                NSString *t = [item isKindOfClass:[NSDictionary class]] ? item[@"name"] : nil;
                if ([t isKindOfClass:[NSString class]] && t.length) [titles addObject:t];
            }
            if (![json[@"next"] isKindOfClass:[NSString class]]) break;
        }
        completion(titles, total, SVSpotifyStatusOK);
    });
}

- (void)downloadImageAtURL:(NSURL *)url completion:(void (^)(NSData *_Nullable))completion {
    NSString *host = url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || ![host hasSuffix:@".scdn.co"]) { completion(nil); return; }
    [[_cdnSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
        NSInteger status = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        completion((error || status != 200) ? nil : data);
    }] resume];
}

- (void)testClientId:(NSString *)clientId secret:(NSString *)secret
          completion:(void (^)(BOOL, NSString *))completion {
    if (clientId.length == 0 || secret.length == 0) { completion(NO, @"Enter both Client ID and Client Secret"); return; }
    if ([self isBlocked]) { completion(NO, @"Spotify is rate-limiting this app; try again later"); return; }
    dispatch_async(_queue, ^{
        NSString *msg = nil;
        SVSpotifyStatus st = [self fetchTokenId:clientId secret:secret token:nil expiry:nil message:&msg];
        completion(st == SVSpotifyStatusOK, st == SVSpotifyStatusOK ? @"OK" : (msg ?: @"Failed"));
    });
}

@end
