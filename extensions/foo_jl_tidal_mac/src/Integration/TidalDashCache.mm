//
//  TidalDashCache.mm
//  foo_jl_tidal_mac
//

#import "TidalDashCache.h"
#import "../Core/DashCachePolicy.h"
#include "../Core/TidalLog.h"

// Total blob budget. Hi-res tracks run ~50-75 MB each, so this keeps a
// handful resident — the currently playing track plus a prefetched next
// one, with headroom for replays. Eviction is oldest-first (see policy).
static const long long kDashCacheCapBytes = 320LL * 1024 * 1024;  // ~320 MB

// Synchronous GET on a shared ephemeral session. Returns nil on failure,
// non-2xx, or when cancelled() flips to YES. Mirrors the decoder's old
// inline downloader, minus the fb2k abort_callback dependency.
static NSData *dashSyncGET(NSString *url, BOOL (^cancelled)(void)) {
    if (url.length == 0) return nil;
    static NSURLSession *session = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        cfg.timeoutIntervalForResource = 120;
        cfg.HTTPMaximumConnectionsPerHost = 6;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });

    __block NSData *result = nil;
    __block NSInteger statusCode = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:url]
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = ((NSHTTPURLResponse *)resp).statusCode;
        }
        if (!err && statusCode >= 200 && statusCode < 300) {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (cancelled && cancelled()) {
            [task cancel];
            return nil;
        }
    }
    if (!result && statusCode != 0) {
        tidal::logError([[NSString stringWithFormat:@"DASH GET %@ → HTTP %ld",
                          [url lastPathComponent], (long)statusCode] UTF8String]);
    }
    return result;
}

// One in-flight assembly. Waiters block on the group; result is published
// on the meta queue before dispatch_group_leave.
@interface JLTidalDashOp : NSObject
@property (nonatomic, strong) dispatch_group_t group;
@property (nonatomic, strong, nullable) NSData *result;
@end
@implementation JLTidalDashOp
@end

@interface JLTidalDashCache ()
@property (nonatomic, strong) dispatch_queue_t meta;   // serial: guards state below
@property (nonatomic, strong) dispatch_queue_t work;   // concurrent: assembly
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *blobs;
@property (nonatomic, strong) NSMutableArray<NSString *> *order;  // LRU, oldest first
@property (nonatomic, strong) NSMutableDictionary<NSString *, JLTidalDashOp *> *ops;
@property (atomic) BOOL stopped;
@end

@implementation JLTidalDashCache

+ (instancetype)shared {
    static JLTidalDashCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[JLTidalDashCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _meta = dispatch_queue_create("com.foobar2000.tidal.dashcache.meta", DISPATCH_QUEUE_SERIAL);
        _work = dispatch_queue_create("com.foobar2000.tidal.dashcache.work", DISPATCH_QUEUE_CONCURRENT);
        _blobs = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _ops = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Public

- (NSData *)cachedBlobForTrackID:(NSString *)trackID {
    if (trackID.length == 0) return nil;
    __block NSData *result = nil;
    dispatch_sync(self.meta, ^{
        result = self.blobs[trackID];
        if (result) [self touchLocked:trackID];
    });
    return result;
}

- (void)prefetchTrackID:(NSString *)trackID
          mediaTemplate:(NSString *)mediaTemplate
           segmentCount:(NSInteger)segmentCount {
    if (self.stopped || trackID.length == 0 || segmentCount <= 0) return;
    dispatch_async(self.meta, ^{
        [self ensureOpLocked:trackID mediaTemplate:mediaTemplate segmentCount:segmentCount];
    });
}

- (NSData *)blobForTrackID:(NSString *)trackID
             mediaTemplate:(NSString *)mediaTemplate
              segmentCount:(NSInteger)segmentCount
               isCancelled:(BOOL (^)(void))isCancelled {
    if (trackID.length == 0 || segmentCount <= 0) return nil;

    __block NSData *cached = nil;
    __block JLTidalDashOp *op = nil;
    dispatch_sync(self.meta, ^{
        cached = self.blobs[trackID];
        if (cached) {
            [self touchLocked:trackID];
            return;
        }
        [self ensureOpLocked:trackID mediaTemplate:mediaTemplate segmentCount:segmentCount];
        op = self.ops[trackID];
    });

    if (cached) return cached;
    if (!op) return [self cachedBlobForTrackID:trackID];  // completed between calls

    // Wait for the shared assembly, polling for caller cancellation.
    while (dispatch_group_wait(op.group, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (isCancelled && isCancelled()) return nil;
    }
    return op.result;
}

- (void)shutdown {
    self.stopped = YES;
    dispatch_async(self.meta, ^{
        [self.blobs removeAllObjects];
        [self.order removeAllObjects];
    });
}

#pragma mark - Internal (all run on self.meta)

- (void)touchLocked:(NSString *)trackID {
    [self.order removeObject:trackID];
    [self.order addObject:trackID];
}

- (void)ensureOpLocked:(NSString *)trackID
         mediaTemplate:(NSString *)mediaTemplate
          segmentCount:(NSInteger)segmentCount {
    if (self.stopped) return;
    if (self.blobs[trackID] || self.ops[trackID]) return;

    JLTidalDashOp *op = [[JLTidalDashOp alloc] init];
    op.group = dispatch_group_create();
    dispatch_group_enter(op.group);
    self.ops[trackID] = op;

    NSString *tpl = [mediaTemplate copy];
    dispatch_async(self.work, ^{
        NSData *data = [self assembleTrackID:trackID mediaTemplate:tpl segmentCount:segmentCount];
        dispatch_async(self.meta, ^{
            // Re-check stopped: a late assembly must not repopulate the
            // cache after shutdown has cleared it.
            if (!self.stopped && data.length > 0) {
                self.blobs[trackID] = data;
                [self.order removeObject:trackID];
                [self.order addObject:trackID];
                [self evictLocked];
            }
            [self.ops removeObjectForKey:trackID];
            op.result = data;
            dispatch_group_leave(op.group);
        });
    });
}

- (void)evictLocked {
    NSMutableDictionary<NSString *, NSNumber *> *sizes = [NSMutableDictionary dictionary];
    for (NSString *key in self.order) {
        sizes[key] = @(self.blobs[key].length);
    }
    NSArray<NSString *> *evict = [JLTidalDashCachePolicy evictionKeysForOrder:self.order
                                                                        sizes:sizes
                                                                     capBytes:kDashCacheCapBytes];
    for (NSString *key in evict) {
        [self.blobs removeObjectForKey:key];
        [self.order removeObject:key];
    }
    if (evict.count > 0) {
        tidal::logDebug([[NSString stringWithFormat:@"DASH cache evicted %lu blob(s)",
                          (unsigned long)evict.count] UTF8String]);
    }
}

#pragma mark - Assembly (runs on self.work, holds no lock)

- (NSData *)assembleTrackID:(NSString *)trackID
              mediaTemplate:(NSString *)mediaTemplate
               segmentCount:(NSInteger)segmentCount {
    NSArray<NSString *> *urls = [JLTidalDashCachePolicy segmentURLsForTemplate:mediaTemplate
                                                                         count:segmentCount];
    if (urls.count == 0) return nil;

    __weak JLTidalDashCache *weakSelf = self;
    BOOL (^cancelled)(void) = ^BOOL{
        JLTidalDashCache *s = weakSelf;
        return s == nil || s.stopped;
    };

    // Reserve capacity up front (~1 MB per segment) so the buffer does not
    // repeatedly reallocate on its way to a 50-75 MB hi-res blob. Clamp the
    // hint so a hostile server-declared segment count cannot demand
    // gigabytes of address space before a single byte arrives.
    static const NSUInteger kMaxAssembledBytes = 1024u * 1024u * 1024u;  // 1 GB
    NSUInteger capacityHint = MIN((NSUInteger)urls.count, (NSUInteger)512) * 1024 * 1024;
    NSMutableData *out = [NSMutableData dataWithCapacity:capacityHint];
    NSInteger idx = 0;
    for (NSString *url in urls) {
        if (cancelled()) return nil;
        NSData *seg = dashSyncGET(url, cancelled);
        if (!seg) {
            tidal::logError([[NSString stringWithFormat:@"DASH segment %ld of %lu failed for %@",
                              (long)(idx + 1), (unsigned long)urls.count, trackID] UTF8String]);
            return nil;
        }
        [out appendData:seg];
        if (out.length > kMaxAssembledBytes) {
            tidal::logError([[NSString stringWithFormat:@"DASH assembly for %@ exceeded %lu MB, aborting",
                              trackID, (unsigned long)(kMaxAssembledBytes / (1024 * 1024))] UTF8String]);
            return nil;
        }
        idx++;
    }
    tidal::logDebug([[NSString stringWithFormat:@"DASH cache assembled %@: %lu segments → %.1f MB",
                      trackID, (unsigned long)urls.count, out.length / (1024.0 * 1024.0)] UTF8String]);
    return out;
}

@end
