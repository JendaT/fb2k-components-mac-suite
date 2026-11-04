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

// Bounded retry for a single segment: one dropped GET out of dozens used to
// discard a 50-75 MB assembly that was nearly complete. Transient causes only
// -- a transport error, 5xx or 429. A 4xx is a verdict, not a hiccup, so it
// fails immediately (an expired signed URL needs a fresh resolve, not another
// attempt). Matches the TIDAL player spec's 3 attempts at 500/1000/2000 ms.
static const int kSegmentMaxAttempts = 3;

// Segments fetched at once per assembly. One at a time, a 53 MB hi-res track
// took ~7s on a link that could carry it in a fraction of that: each ~700 KB
// GET is latency-bound, not bandwidth-bound. Stays under the session's six
// connections per host so a concurrent prefetch is not starved outright.
static const NSUInteger kSegmentParallelism = 4;
static const useconds_t kSegmentBackoffMs[] = {500, 1000, 2000};

static BOOL dashStatusIsRetryable(NSInteger statusCode, NSError *transportError) {
    if (transportError) return YES;
    return statusCode == 429 || (statusCode >= 500 && statusCode < 600);
}

// Sleep in short slices so a cancelled track does not sit out the full backoff.
// Returns NO if cancellation cut the wait short.
static BOOL dashBackoffSleep(useconds_t totalMs, BOOL (^cancelled)(void)) {
    for (useconds_t waited = 0; waited < totalMs; waited += 50) {
        if (cancelled && cancelled()) return NO;
        usleep(50 * 1000);
    }
    return !(cancelled && cancelled());
}

// Synchronous GET on a shared ephemeral session. Returns nil on failure,
// non-2xx, or when cancelled() flips to YES. Mirrors the decoder's old
// inline downloader, minus the fb2k abort_callback dependency.
static NSData *dashSyncGETOnce(NSString *url, BOOL (^cancelled)(void),
                               NSInteger *outStatus, NSError **outError) {
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
    __block NSError *transportError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithURL:[NSURL URLWithString:url]
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
            statusCode = ((NSHTTPURLResponse *)resp).statusCode;
        }
        transportError = err;
        if (!err && statusCode >= 200 && statusCode < 300) {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    while (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (cancelled && cancelled()) {
            [task cancel];
            if (outStatus) *outStatus = 0;
            if (outError) *outError = nil;
            return nil;
        }
    }
    if (outStatus) *outStatus = statusCode;
    if (outError) *outError = transportError;
    return result;
}

static NSData *dashSyncGET(NSString *url, BOOL (^cancelled)(void)) {
    if (url.length == 0) return nil;

    for (int attempt = 0; attempt < kSegmentMaxAttempts; attempt++) {
        if (cancelled && cancelled()) return nil;

        NSInteger statusCode = 0;
        NSError *transportError = nil;
        NSData *data = dashSyncGETOnce(url, cancelled, &statusCode, &transportError);
        if (data) return data;

        // Cancelled mid-flight: no status, no error, nothing to retry.
        if (statusCode == 0 && !transportError) return nil;

        BOOL last = (attempt == kSegmentMaxAttempts - 1);
        if (!dashStatusIsRetryable(statusCode, transportError) || last) {
            tidal::logError([[NSString stringWithFormat:@"DASH GET %@ → %@ (after %d attempt%s)",
                              [url lastPathComponent],
                              transportError ? transportError.localizedDescription
                                             : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode],
                              attempt + 1, attempt == 0 ? "" : "s"] UTF8String]);
            return nil;
        }
        if (!dashBackoffSleep(kSegmentBackoffMs[attempt], cancelled)) return nil;
    }
    return nil;
}

// One in-flight assembly. Waiters block on the group; result is published
// on the meta queue before dispatch_group_leave.
//
// `waiters` and `prefetchWanted` say whether anyone still cares. Skipping
// through a hi-res playlist used to leave one full 50-75 MB download running
// per skipped track, all competing for the same six connections the track that
// actually landed needs.
@interface JLTidalDashOp : NSObject
@property (nonatomic, strong) dispatch_group_t group;
@property (nonatomic, strong, nullable) NSData *result;
@property (nonatomic) NSInteger waiters;
@property (nonatomic) BOOL prefetchWanted;
@property (atomic) BOOL abandoned;
// The assembly as it grows, plus how it ended. Guarded by @synchronized(op):
// a progressive reader (JLTidalDashStream) copies out of the buffer while
// the workers are still appending to it.
@property (nonatomic, strong, nullable) NSMutableData *buffer;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL failed;
@end
@implementation JLTidalDashOp
@end

@interface JLTidalDashStream ()
- (instancetype)initWithOp:(JLTidalDashOp *)op cache:(JLTidalDashCache *)cache;
@end

@interface JLTidalDashCache ()
@property (nonatomic, strong) dispatch_queue_t meta;   // serial: guards state below
@property (nonatomic, strong) dispatch_queue_t work;   // concurrent: assembly
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSData *> *blobs;
@property (nonatomic, strong) NSMutableArray<NSString *> *order;  // LRU, oldest first
@property (nonatomic, strong) NSMutableDictionary<NSString *, JLTidalDashOp *> *ops;
@property (atomic) BOOL stopped;
- (void)releaseWaiterForOp:(JLTidalDashOp *)op;
@end

// Blobs, LRU order and in-flight ops are all keyed by this. Track IDs are
// digits-only (validated in URLUtils::parseURL), so "|" cannot occur in one.
static NSString *blobKey(NSString *trackID, JLTidalQuality quality) {
    return [NSString stringWithFormat:@"%@|%@", trackID, JLTidalQualityToString(quality)];
}

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

- (NSData *)cachedBlobForTrackID:(NSString *)trackID quality:(JLTidalQuality)quality {
    if (trackID.length == 0) return nil;
    NSString *key = blobKey(trackID, quality);
    __block NSData *result = nil;
    dispatch_sync(self.meta, ^{
        result = self.blobs[key];
        if (result) [self touchLocked:key];
    });
    return result;
}

- (void)prefetchTrackID:(NSString *)trackID
                quality:(JLTidalQuality)quality
          mediaTemplate:(NSString *)mediaTemplate
           segmentCount:(NSInteger)segmentCount {
    if (self.stopped || trackID.length == 0 || segmentCount <= 0) return;
    NSString *key = blobKey(trackID, quality);
    dispatch_async(self.meta, ^{
        [self ensureOpLocked:key trackID:trackID mediaTemplate:mediaTemplate segmentCount:segmentCount];
        // A prefetch is a standing interest: it keeps the assembly alive even
        // when no decoder is waiting on it yet.
        self.ops[key].prefetchWanted = YES;
    });
}

- (NSData *)blobForTrackID:(NSString *)trackID
                   quality:(JLTidalQuality)quality
             mediaTemplate:(NSString *)mediaTemplate
              segmentCount:(NSInteger)segmentCount
               isCancelled:(BOOL (^)(void))isCancelled {
    if (trackID.length == 0 || segmentCount <= 0) return nil;

    NSString *key = blobKey(trackID, quality);
    __block NSData *cached = nil;
    __block JLTidalDashOp *op = nil;
    dispatch_sync(self.meta, ^{
        cached = self.blobs[key];
        if (cached) {
            [self touchLocked:key];
            return;
        }
        [self ensureOpLocked:key trackID:trackID mediaTemplate:mediaTemplate segmentCount:segmentCount];
        op = self.ops[key];
        op.waiters++;
    });

    if (cached) return cached;
    if (!op) return [self cachedBlobForTrackID:trackID quality:quality];  // completed between calls

    // Wait for the shared assembly, polling for caller cancellation. Dropping
    // out releases this waiter's interest; when nothing wants the blob any
    // more the assembly cancels itself instead of downloading to completion.
    BOOL __block cancelledOut = NO;
    while (dispatch_group_wait(op.group, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (isCancelled && isCancelled()) {
            cancelledOut = YES;
            break;
        }
    }
    dispatch_sync(self.meta, ^{
        op.waiters--;
        if (op.waiters <= 0 && !op.prefetchWanted) op.abandoned = YES;
    });
    if (cancelledOut) return nil;
    return op.result;
}

- (void)abandonPrefetchesExceptTrackID:(NSString *)trackID quality:(JLTidalQuality)quality {
    NSString *keep = blobKey(trackID, quality);
    dispatch_async(self.meta, ^{
        // Someone is already fetching this track: a second open of it (the
        // waveform seekbar decodes the playing track too) is not a jump, and
        // the prefetch that started for what follows must survive it.
        JLTidalDashOp *own = self.ops[keep];
        if (own && !own.abandoned) return;
        NSUInteger dropped = 0;
        for (NSString *key in self.ops) {
            if ([key isEqualToString:keep]) continue;
            JLTidalDashOp *op = self.ops[key];
            // A decoder is waiting on it: that is a play, not a guess.
            if (op.waiters > 0 || op.abandoned) continue;
            op.prefetchWanted = NO;
            op.abandoned = YES;
            dropped++;
        }
        if (dropped > 0) {
            tidal::logDebug([[NSString stringWithFormat:@"Cancelled %lu stale prefetch(es) for a cold track open",
                             (unsigned long)dropped] UTF8String]);
        }
    });
}

- (JLTidalDashStream *)openStreamForTrackID:(NSString *)trackID
                                    quality:(JLTidalQuality)quality
                              mediaTemplate:(NSString *)mediaTemplate
                               segmentCount:(NSInteger)segmentCount {
    if (trackID.length == 0 || segmentCount <= 0) return nil;
    NSString *key = blobKey(trackID, quality);
    __block JLTidalDashOp *op = nil;
    dispatch_sync(self.meta, ^{
        if (self.blobs[key]) return;  // whole blob already here: use it
        [self ensureOpLocked:key trackID:trackID mediaTemplate:mediaTemplate segmentCount:segmentCount];
        op = self.ops[key];
        op.waiters++;
    });
    return op ? [[JLTidalDashStream alloc] initWithOp:op cache:self] : nil;
}

// A stream's waiter slot, given back exactly once. Async: a stream can be
// released from anywhere, including a block already running on meta.
- (void)releaseWaiterForOp:(JLTidalDashOp *)op {
    dispatch_async(self.meta, ^{
        op.waiters--;
        if (op.waiters <= 0 && !op.prefetchWanted) op.abandoned = YES;
    });
}

- (void)shutdown {
    self.stopped = YES;
    dispatch_async(self.meta, ^{
        [self.blobs removeAllObjects];
        [self.order removeAllObjects];
    });
}

#pragma mark - Internal (all run on self.meta)

- (void)touchLocked:(NSString *)key {
    [self.order removeObject:key];
    [self.order addObject:key];
}

- (void)ensureOpLocked:(NSString *)key
               trackID:(NSString *)trackID
         mediaTemplate:(NSString *)mediaTemplate
          segmentCount:(NSInteger)segmentCount {
    if (self.stopped) return;
    if (self.blobs[key]) return;
    // An abandoned op is winding down and will publish nil; attaching to it
    // would fail a track the user has just come back to. Start afresh -- the
    // old op's completion only removes the entry if it is still its own.
    JLTidalDashOp *existing = self.ops[key];
    if (existing && !existing.abandoned) return;

    JLTidalDashOp *op = [[JLTidalDashOp alloc] init];
    op.group = dispatch_group_create();
    dispatch_group_enter(op.group);
    self.ops[key] = op;

    NSString *tpl = [mediaTemplate copy];
    dispatch_async(self.work, ^{
        NSData *data = [self assembleTrackID:trackID mediaTemplate:tpl
                                segmentCount:segmentCount op:op];
        // Readers poll these; set before the meta hop so a stream never sees
        // a buffer that has stopped growing without being told why.
        @synchronized (op) {
            op.finished = YES;
            op.failed = (data.length == 0);
        }
        dispatch_async(self.meta, ^{
            // Re-check stopped: a late assembly must not repopulate the
            // cache after shutdown has cleared it.
            if (!self.stopped && data.length > 0) {
                self.blobs[key] = data;
                [self.order removeObject:key];
                [self.order addObject:key];
                [self evictLocked];
            }
            if (self.ops[key] == op) [self.ops removeObjectForKey:key];
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
               segmentCount:(NSInteger)segmentCount
                         op:(JLTidalDashOp *)op {
    NSArray<NSString *> *urls = [JLTidalDashCachePolicy segmentURLsForTemplate:mediaTemplate
                                                                         count:segmentCount];
    if (urls.count == 0) return nil;
    const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();

    __weak JLTidalDashCache *weakSelf = self;
    __weak JLTidalDashOp *weakOp = op;
    BOOL (^cancelled)(void) = ^BOOL{
        JLTidalDashCache *s = weakSelf;
        if (s == nil || s.stopped) return YES;
        JLTidalDashOp *o = weakOp;
        return o != nil && o.abandoned;
    };

    // Reserve capacity up front (~1 MB per segment) so the buffer does not
    // repeatedly reallocate on its way to a 50-75 MB hi-res blob. Clamp the
    // hint so a hostile server-declared segment count cannot demand
    // gigabytes of address space before a single byte arrives.
    static const NSUInteger kMaxAssembledBytes = 1024u * 1024u * 1024u;  // 1 GB
    NSUInteger capacityHint = MIN((NSUInteger)urls.count, (NSUInteger)512) * 1024 * 1024;
    NSMutableData *out = [NSMutableData dataWithCapacity:capacityHint];
    @synchronized (op) { op.buffer = out; }

    // Workers claim segment indexes in order and fetch concurrently. Finished
    // segments are appended as soon as every earlier one is in, so at most a
    // few out-of-order segments are held aside -- never a second copy of the
    // whole track. All state below is guarded by the op, which is also what
    // progressive readers lock to copy out of `out`.
    NSObject *lock = op;
    NSMutableArray *pending = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSUInteger i = 0; i < urls.count; i++) [pending addObject:[NSNull null]];
    __block NSUInteger nextToFetch = 0;
    __block NSUInteger nextToAppend = 0;
    __block NSInteger failedIndex = -1;
    __block BOOL overflow = NO;

    // One failed segment dooms the blob, so it also stops the other workers.
    BOOL (^stop)(void) = ^BOOL{
        if (cancelled()) return YES;
        @synchronized (lock) { return failedIndex >= 0 || overflow; }
    };

    dispatch_group_t workers = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    NSUInteger workerCount = MIN(kSegmentParallelism, (NSUInteger)urls.count);
    for (NSUInteger w = 0; w < workerCount; w++) {
        dispatch_group_async(workers, queue, ^{
            for (;;) {
                NSUInteger idx;
                @synchronized (lock) {
                    if (failedIndex >= 0 || overflow || nextToFetch >= urls.count) return;
                    idx = nextToFetch++;
                }
                if (cancelled()) return;
                NSData *seg = dashSyncGET(urls[idx], stop);
                @synchronized (lock) {
                    if (!seg) {
                        if (failedIndex < 0 && !overflow) failedIndex = (NSInteger)idx;
                        return;
                    }
                    pending[idx] = seg;
                    while (nextToAppend < urls.count && pending[nextToAppend] != [NSNull null]) {
                        [out appendData:pending[nextToAppend]];
                        pending[nextToAppend] = [NSNull null];
                        nextToAppend++;
                    }
                    if (out.length > kMaxAssembledBytes) overflow = YES;
                }
            }
        });
    }
    dispatch_group_wait(workers, DISPATCH_TIME_FOREVER);

    if (cancelled()) return nil;
    if (overflow) {
        tidal::logError([[NSString stringWithFormat:@"DASH assembly for %@ exceeded %lu MB, aborting",
                          trackID, (unsigned long)(kMaxAssembledBytes / (1024 * 1024))] UTF8String]);
        return nil;
    }
    if (failedIndex >= 0 || nextToAppend != urls.count) {
        tidal::logError([[NSString stringWithFormat:@"DASH segment %ld of %lu failed for %@",
                          (long)(failedIndex >= 0 ? failedIndex + 1 : (NSInteger)nextToAppend + 1),
                          (unsigned long)urls.count, trackID] UTF8String]);
        return nil;
    }
    // Whether a prefetch finished before its track was needed is the first
    // question for any gap between tracks.
    tidal::logDebug([[NSString stringWithFormat:@"DASH assembled %@: %lu segments, %.1f MB in %.1fs",
                     trackID, (unsigned long)urls.count, out.length / (1024.0 * 1024.0),
                     CFAbsoluteTimeGetCurrent() - started] UTF8String]);
    return out;
}

@end

@implementation JLTidalDashStream {
    JLTidalDashOp *_op;
    __weak JLTidalDashCache *_cache;
    BOOL _closed;
}

- (instancetype)initWithOp:(JLTidalDashOp *)op cache:(JLTidalDashCache *)cache {
    self = [super init];
    if (self) {
        _op = op;
        _cache = cache;
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)withBytes:(void (NS_NOESCAPE ^)(const uint8_t *bytes, NSUInteger length,
                                        BOOL complete, BOOL failed))block {
    JLTidalDashOp *op = _op;
    @synchronized (op) {
        NSMutableData *buf = op.buffer;
        block((const uint8_t *)buf.bytes, buf.length, op.finished && !op.failed, op.failed);
    }
}

- (NSData *)waitForBlobWithCancel:(BOOL (^)(void))isCancelled {
    JLTidalDashOp *op = _op;
    while (dispatch_group_wait(op.group, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) != 0) {
        if (isCancelled && isCancelled()) return nil;
    }
    return op.result;
}

- (void)close {
    @synchronized (self) {
        if (_closed) return;
        _closed = YES;
    }
    [_cache releaseWaiterForOp:_op];
}

@end
