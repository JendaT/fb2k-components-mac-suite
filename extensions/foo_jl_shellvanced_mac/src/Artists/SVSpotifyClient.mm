//
//  SVSpotifyClient.mm
//  foo_jl_shellvanced_mac
//

#import "SVSpotifyClient.h"
#import "SVSpotifyCredentials.h"
#import "SVRedirectGuard.h"

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
    dispatch_queue_t _queue;       // serial: runs the worker loop
    NSObject *_jobLock;
    NSMutableArray<void (^)(void)> *_jobs;   // _jobLock
    BOOL _draining;                          // _jobLock
    NSObject *_stateLock;
    NSString *_token;              // _stateLock
    NSDate *_tokenExpiry;          // _stateLock
    NSDate *_lastRequestEnd;       // worker only
    NSTimeInterval _blockUntil;    // _stateLock
    NSString *_blockClientId;      // _stateLock: the Client ID whose requests were rate limited
    BOOL _authFailed;              // _stateLock
    BOOL _sessionDisabled;         // _stateLock: too many consecutive failures
    spmatch::FailureTracker _failures;  // _stateLock
    NSUInteger _generation;        // _stateLock
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
        _jobLock = [[NSObject alloc] init];
        _jobs = [NSMutableArray array];
        _stateLock = [[NSObject alloc] init];
        NSData *data = [NSData dataWithContentsOfURL:BlockFileURL()];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"until"] isKindOfClass:[NSNumber class]])
            _blockUntil = spmatch::clampBlockUntil([json[@"until"] doubleValue], [NSDate date].timeIntervalSince1970);
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"id"] isKindOfClass:[NSString class]])
            _blockClientId = json[@"id"];
    }
    return self;
}

#pragma mark - State

- (BOOL)isBlocked {
    @synchronized (_stateLock) { return _blockUntil > [NSDate date].timeIntervalSince1970; }
}

- (BOOL)isTemporarilyUnavailable {
    @synchronized (_stateLock) { return _sessionDisabled || _blockUntil > [NSDate date].timeIntervalSince1970; }
}

- (NSUInteger)generation {
    @synchronized (_stateLock) { return _generation; }
}

- (BOOL)isAvailable {
    @synchronized (_stateLock) {
        if (_authFailed || _sessionDisabled || _blockUntil > [NSDate date].timeIntervalSince1970) return NO;
    }
    return [SVSpotifyCredentials isConfigured];
}

- (void)blockForSeconds:(long)seconds {
    NSTimeInterval until = [NSDate date].timeIntervalSince1970 + seconds;
    NSString *cid = [SVSpotifyCredentials clientId] ?: @"";
    @synchronized (_stateLock) { _blockUntil = until; _blockClientId = cid; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"until": @(until), @"id": cid} options:0 error:nil];
    [data writeToURL:BlockFileURL() atomically:YES];
}

- (void)credentialsChangedWithNewClientId:(NSString *)newClientId {
    BOOL clearBlock = NO;
    @synchronized (_stateLock) {
        clearBlock = newClientId.length > 0 && ![newClientId isEqualToString:_blockClientId ?: @""];
    }
    @synchronized (_stateLock) {
        _generation++;
        _token = nil; _tokenExpiry = nil;
        _authFailed = NO; _sessionDisabled = NO; _failures = spmatch::FailureTracker();
        if (clearBlock) { _blockUntil = 0; _blockClientId = nil; }
    }
    if (clearBlock) [[NSFileManager defaultManager] removeItemAtURL:BlockFileURL() error:nil];
}

// Counts request outcomes; 5 consecutive Failed results stop Spotify for the session.
- (void)noteOutcome:(SVSpotifyStatus)st generation:(NSUInteger)gen {
    @synchronized (_stateLock) {
        if (gen != _generation) return;
        if (st == SVSpotifyStatusOK) _failures.record(false);
        else if (st == SVSpotifyStatusFailed) { _failures.record(true); if (_failures.tripped()) _sessionDisabled = YES; }
    }
}

#pragma mark - Queue

// `urgent` jobs run before everything already waiting.
- (void)schedule:(void (^)(void))job urgent:(BOOL)urgent {
    @synchronized (_jobLock) {
        if (urgent) [_jobs insertObject:[job copy] atIndex:0]; else [_jobs addObject:[job copy]];
        if (_draining) return;
        _draining = YES;
    }
    dispatch_async(_queue, ^{
        for (;;) {
            void (^next)(void) = nil;
            @synchronized (self->_jobLock) {
                if (self->_jobs.count == 0) { self->_draining = NO; return; }
                next = self->_jobs[0];
                [self->_jobs removeObjectAtIndex:0];
            }
            @autoreleasepool { next(); }
        }
    });
}

#pragma mark - Transport (worker only)

// Waits for the >= 2 s spacing, performs the request synchronously. Returns nil on transport error.
- (NSData *)perform:(NSURLRequest *)req response:(NSHTTPURLResponse **)outResp {
    if (_lastRequestEnd) {
        NSTimeInterval wait = kMinSpacing + [_lastRequestEnd timeIntervalSinceNow];  // timeIntervalSinceNow < 0
        if (wait > 0) [NSThread sleepForTimeInterval:wait];
    }
    __block NSData *result = nil;
    __block NSHTTPURLResponse *resp = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
        if (!error && [r isKindOfClass:[NSHTTPURLResponse class]]) { result = data ?: [NSData data]; resp = (NSHTTPURLResponse *)r; }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kRequestTimeout + 5) * NSEC_PER_SEC))) != 0) {
        [task cancel];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));  // let the handler finish
        result = nil; resp = nil;
    }
    _lastRequestEnd = [NSDate date];
    if (outResp) *outResp = resp;
    return result;
}

- (void)noteRateLimit:(NSHTTPURLResponse *)resp {
    NSString *ra = [resp valueForHTTPHeaderField:@"Retry-After"];
    [self blockForSeconds:spmatch::parseRetryAfter(ra.UTF8String ?: "")];
}

// Token request. On failure `message` describes it (never contains credentials).
- (SVSpotifyStatus)fetchTokenId:(NSString *)cid secret:(NSString *)secret recordBlock:(BOOL)recordBlock
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
        if (recordBlock) [self noteRateLimit:resp];  // a Test of an unsaved ID stays local to its result
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
    return (resp.statusCode == 400 || resp.statusCode == 401 || resp.statusCode == 403)
        ? SVSpotifyStatusAuthFailed : SVSpotifyStatusFailed;
}

// Authenticated GET returning a parsed JSON dictionary. Refreshes the token once on 401.
- (SVSpotifyStatus)getPath:(NSString *)path query:(NSArray<NSURLQueryItem *> *)items json:(NSDictionary **)outJson {
    NSUInteger gen;
    @synchronized (_stateLock) {
        if (_authFailed) return SVSpotifyStatusAuthFailed;
        if (_sessionDisabled) return SVSpotifyStatusFailed;
        gen = _generation;
    }
    if ([self isBlocked]) return SVSpotifyStatusBlocked;
    NSString *cid = [SVSpotifyCredentials clientId], *secret = [SVSpotifyCredentials clientSecret];
    if (cid.length == 0 || secret.length == 0) return SVSpotifyStatusAuthFailed;
    NSURLComponents *c = [[NSURLComponents alloc] init];
    c.scheme = @"https"; c.host = kApiHost; c.path = path; c.queryItems = items;
    NSURL *url = c.URL;
    if (!url) return SVSpotifyStatusFailed;

    SVSpotifyStatus result = SVSpotifyStatusFailed;
    for (int attempt = 0; attempt < 2; attempt++) {
        NSString *token = nil;
        @synchronized (_stateLock) {
            if (_token && [_tokenExpiry timeIntervalSinceNow] > 0) token = _token;
        }
        if (!token) {
            NSString *tok = nil; NSDate *exp = nil;
            SVSpotifyStatus st = [self fetchTokenId:cid secret:secret recordBlock:YES token:&tok expiry:&exp message:nil];
            if (st != SVSpotifyStatusOK) {
                if (st == SVSpotifyStatusAuthFailed) {
                    @synchronized (_stateLock) { if (gen == _generation) _authFailed = YES; }
                }
                result = st;
                break;
            }
            @synchronized (_stateLock) {
                if (gen == _generation) { _token = tok; _tokenExpiry = exp; }
            }
            token = tok;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        NSHTTPURLResponse *resp = nil;
        NSData *data = [self perform:req response:&resp];
        if (!data) { result = SVSpotifyStatusFailed; break; }
        if (resp.statusCode == 429) { [self noteRateLimit:resp]; result = SVSpotifyStatusBlocked; break; }
        if (resp.statusCode == 403) {  // forbidden for this app: treat like rejected credentials
            @synchronized (_stateLock) { if (gen == _generation) _authFailed = YES; }
            result = SVSpotifyStatusAuthFailed;
            break;
        }
        if (resp.statusCode == 401 && attempt == 0) {
            @synchronized (_stateLock) { _token = nil; _tokenExpiry = nil; }
            continue;
        }
        if (resp.statusCode != 200) { result = SVSpotifyStatusFailed; break; }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) { result = SVSpotifyStatusFailed; break; }
        if (outJson) *outJson = json;
        result = SVSpotifyStatusOK;
        break;
    }
    [self noteOutcome:result generation:gen];
    return result;
}

#pragma mark - Public

- (void)searchArtist:(NSString *)name urgent:(BOOL)urgent
          completion:(void (^)(std::vector<spmatch::Candidate>, SVSpotifyStatus))completion {
    if (name.length == 0) { completion({}, SVSpotifyStatusOK); return; }
    [self schedule:^{
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
    } urgent:urgent];
}

- (void)albumsForArtistId:(NSString *)artistId urgent:(BOOL)urgent
               completion:(void (^)(NSArray<NSString *> *, NSArray<NSString *> *, NSArray<NSString *> *, long, SVSpotifyStatus))completion {
    NSCharacterSet *bad = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
    if (artistId.length == 0 || artistId.length > 40 || [artistId rangeOfCharacterFromSet:bad].location != NSNotFound) {
        completion(nil, nil, @[], -1, SVSpotifyStatusFailed);
        return;
    }
    [self schedule:^{
        NSMutableArray<NSString *> *all = [NSMutableArray array], *primary = [NSMutableArray array];
        NSMutableOrderedSet<NSString *> *artistNames = [NSMutableOrderedSet orderedSet];
        long total = -1;
        for (int page = 0; page < 2; page++) {
            NSDictionary *json = nil;
            SVSpotifyStatus st = [self getPath:[NSString stringWithFormat:@"/v1/artists/%@/albums", artistId] query:@[
                [NSURLQueryItem queryItemWithName:@"include_groups" value:@"album,single,appears_on,compilation"],
                [NSURLQueryItem queryItemWithName:@"limit" value:@"50"],
                [NSURLQueryItem queryItemWithName:@"offset" value:[NSString stringWithFormat:@"%d", page * 50]]]
                                  json:&json];
            if (st != SVSpotifyStatusOK) { completion(nil, nil, @[], -1, st); return; }
            if (page == 0 && [json[@"total"] respondsToSelector:@selector(longValue)]) total = [json[@"total"] longValue];
            NSArray *items = [json[@"items"] isKindOfClass:[NSArray class]] ? json[@"items"] : @[];
            for (id item in items) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *t = item[@"name"];
                if (![t isKindOfClass:[NSString class]] || t.length == 0) continue;
                [all addObject:t];
                if ([item[@"artists"] isKindOfClass:[NSArray class]])
                    for (id a in item[@"artists"])
                        if ([a isKindOfClass:[NSDictionary class]] && [a[@"name"] isKindOfClass:[NSString class]] && [a[@"name"] length])
                            [artistNames addObject:a[@"name"]];
                NSString *g = [item[@"album_group"] isKindOfClass:[NSString class]] ? item[@"album_group"] : @"";
                if ([g isEqualToString:@"album"] || [g isEqualToString:@"single"]) [primary addObject:t];
            }
            if (![json[@"next"] isKindOfClass:[NSString class]]) break;
        }
        completion(all, primary, artistNames.array, total, SVSpotifyStatusOK);
    } urgent:urgent];
}

- (void)downloadImageAtURL:(NSURL *)url completion:(void (^)(NSData *_Nullable))completion {
    static NSArray<NSString *> *hosts;
    static SVRedirectGuard *guard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = @[@"scdn.co"];
        guard = [SVRedirectGuard guardWithHosts:hosts];
    });
    if (![SVRedirectGuard url:url isAllowedForHosts:hosts]) { completion(nil); return; }
    NSURLSessionDataTask *task = [_cdnSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *r, NSError *error) {
        NSInteger status = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        completion((error || status != 200) ? nil : data);
    }];
    task.delegate = guard;  // re-checks the host on every redirect
    [task resume];
}

- (void)testClientId:(NSString *)clientId secret:(NSString *)secret
          completion:(void (^)(BOOL, NSString *))completion {
    if (clientId.length == 0 || secret.length == 0) { completion(NO, @"Enter both Client ID and Client Secret"); return; }
    if ([self isBlocked]) { completion(NO, @"Spotify is rate-limiting this app; try again later"); return; }
    [self schedule:^{
        NSString *msg = nil;
        SVSpotifyStatus st = [self fetchTokenId:clientId secret:secret recordBlock:NO token:nil expiry:nil message:&msg];
        completion(st == SVSpotifyStatusOK, st == SVSpotifyStatusOK ? @"OK" : (msg ?: @"Failed"));
    } urgent:YES];
}

@end
