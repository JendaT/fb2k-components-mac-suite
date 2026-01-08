//
//  TidalAlbumArtCache.mm
//  foo_jl_tidal_mac
//
//  Async album art loading and caching for Tidal covers
//

#import "TidalAlbumArtCache.h"
#import "../Core/TidalConfig.h"

static NSString * const kTidalImageBaseURL = @"https://resources.tidal.com/images";

@interface JLTidalAlbumArtCache ()
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *imageCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *loadingKeys;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pendingCompletions;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@end

@implementation JLTidalAlbumArtCache

+ (instancetype)shared {
    static JLTidalAlbumArtCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalAlbumArtCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _imageCache = [[NSCache alloc] init];
        _imageCache.totalCostLimit = 50 * 1024 * 1024; // 50MB default
        _loadingKeys = [NSMutableSet set];
        _pendingCompletions = [NSMutableDictionary dictionary];
        _maxCacheSize = 50 * 1024 * 1024;
        _syncQueue = dispatch_queue_create("com.foobar2000.tidal.artcache", DISPATCH_QUEUE_SERIAL);

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 15;
        config.timeoutIntervalForResource = 30;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

- (void)setMaxCacheSize:(NSUInteger)maxCacheSize {
    _maxCacheSize = maxCacheSize;
    _imageCache.totalCostLimit = maxCacheSize;
}

#pragma mark - Public API

- (void)loadImageForCoverID:(NSString *)coverID
                       size:(NSInteger)size
                 completion:(void (^)(NSImage * _Nullable image))completion {
    if (!coverID.length) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil);
            });
        }
        return;
    }

    NSString *cacheKey = [self cacheKeyForCoverID:coverID size:size];

    // Check cache first
    NSImage *cached = [self.imageCache objectForKey:cacheKey];
    if (cached) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached);
            });
        }
        return;
    }

    // Check if already loading
    dispatch_sync(self.syncQueue, ^{
        if ([self.loadingKeys containsObject:cacheKey]) {
            // Add to pending completions
            if (completion) {
                NSMutableArray *pending = self.pendingCompletions[cacheKey];
                if (!pending) {
                    pending = [NSMutableArray array];
                    self.pendingCompletions[cacheKey] = pending;
                }
                [pending addObject:[completion copy]];
            }
            return;
        }
        [self.loadingKeys addObject:cacheKey];
    });

    // Start loading
    NSURL *url = [[self class] coverURLForCoverID:coverID size:size];

    NSURLSessionDataTask *task = [self.urlSession dataTaskWithURL:url
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSImage *image = nil;

        if (data && !error) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse.statusCode == 200) {
                image = [[NSImage alloc] initWithData:data];
                if (image) {
                    // Estimate size for cache cost
                    NSUInteger cost = data.length;
                    [self.imageCache setObject:image forKey:cacheKey cost:cost];
                }
            }
        }

        // Get pending completions
        __block NSArray *completions = nil;
        dispatch_sync(self.syncQueue, ^{
            [self.loadingKeys removeObject:cacheKey];
            completions = [self.pendingCompletions[cacheKey] copy];
            [self.pendingCompletions removeObjectForKey:cacheKey];
        });

        // Call all completions on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(image);
            }
            for (void (^pending)(NSImage *) in completions) {
                pending(image);
            }
        });
    }];

    [task resume];
}

- (nullable NSImage *)cachedImageForCoverID:(NSString *)coverID size:(NSInteger)size {
    if (!coverID.length) return nil;
    NSString *cacheKey = [self cacheKeyForCoverID:coverID size:size];
    return [self.imageCache objectForKey:cacheKey];
}

- (BOOL)isLoadingCoverID:(NSString *)coverID size:(NSInteger)size {
    if (!coverID.length) return NO;
    NSString *cacheKey = [self cacheKeyForCoverID:coverID size:size];
    __block BOOL loading = NO;
    dispatch_sync(self.syncQueue, ^{
        loading = [self.loadingKeys containsObject:cacheKey];
    });
    return loading;
}

- (void)clearCache {
    [self.imageCache removeAllObjects];
    dispatch_sync(self.syncQueue, ^{
        [self.loadingKeys removeAllObjects];
        [self.pendingCompletions removeAllObjects];
    });
}

#pragma mark - URL Construction

+ (NSURL *)coverURLForCoverID:(NSString *)coverID size:(NSInteger)size {
    // Tidal cover IDs use hyphens but URL path uses slashes
    // e.g., "abc123-def456-ghi789" -> "abc123/def456/ghi789"
    NSString *pathID = [coverID stringByReplacingOccurrencesOfString:@"-" withString:@"/"];

    // Normalize size to Tidal supported sizes
    NSInteger normalizedSize = [self normalizeSize:size];

    NSString *urlString = [NSString stringWithFormat:@"%@/%@/%ldx%ld.jpg",
                           kTidalImageBaseURL,
                           pathID,
                           (long)normalizedSize,
                           (long)normalizedSize];

    return [NSURL URLWithString:urlString];
}

+ (NSInteger)normalizeSize:(NSInteger)size {
    // Tidal supports: 80, 160, 320, 640, 750, 1080, 1280
    if (size <= 80) return 80;
    if (size <= 160) return 160;
    if (size <= 320) return 320;
    if (size <= 640) return 640;
    if (size <= 750) return 750;
    if (size <= 1080) return 1080;
    return 1280;
}

#pragma mark - Private

- (NSString *)cacheKeyForCoverID:(NSString *)coverID size:(NSInteger)size {
    NSInteger normalizedSize = [[self class] normalizeSize:size];
    return [NSString stringWithFormat:@"%@_%ld", coverID, (long)normalizedSize];
}

@end
